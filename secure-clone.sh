#!/usr/bin/env bash
set -euo pipefail

# Secure way to clone with credentials. Preferred: Docker/K8s secret mounted at /run/secrets/git_token
#
# Supports:
# - GitHub: set GIT_REPO=owner/repo (default), or GIT_URL=https://github.com/owner/repo.git
# - Azure DevOps: either set
#     - GIT_URL=https://dev.azure.com/<org>/<project>/_git/<repo>
#   or
#     - GIT_PROVIDER=azure and GIT_REPO=<org>/<project>/<repo> (or <org>/<project>/_git/<repo>)
#
# Usage examples:
#   GIT_REPO=owner/repo GIT_BRANCH=main ./secure-clone.sh
#   GIT_PROVIDER=azure GIT_REPO=org/project/repo ./secure-clone.sh
#   GIT_URL=https://dev.azure.com/org/project/_git/repo ./secure-clone.sh
# Optional env:
#   GIT_TOKEN_FILE=/run/secrets/git_token (preferred) or GIT_TOKEN=<pat>
#   GIT_USERNAME=x-access-token (GitHub) | azdo (Azure DevOps)
#   GIT_HOST=github.com|dev.azure.com (overrides host detection when building from GIT_REPO)
#   PROJECT_DIR=/workspace  (repos will be under $PROJECT_DIR/repos/<name>)
#   GIT_REPOS="owner/repo1,owner/repo2 https://dev.azure.com/org/project/_git/repo3" (optional multi-repo)

if [[ -z "${GIT_URL:-}" && -z "${GIT_REPO:-}" && -z "${GIT_REPOS:-}" ]]; then
  echo "Error: set one of GIT_URL, GIT_REPO, or GIT_REPOS (list)" >&2
  echo "  - GIT_REPO example (GitHub): owner/repo" >&2
  echo "  - GIT_REPO example (Azure with GIT_PROVIDER=azure): org/project/repo or org/project/_git/repo" >&2
  echo "  - GIT_REPOS examples: 'owner/a,owner/b' or 'https://dev.azure.com/org/project/_git/repo'" >&2
  exit 1
fi

TOKEN=""
if [[ -n "${GIT_TOKEN_FILE:-}" && -f "${GIT_TOKEN_FILE}" ]]; then
  # Trim trailing newlines/CR from token files to avoid auth failures
  TOKEN=$(tr -d '\r\n' < "${GIT_TOKEN_FILE}")
elif [[ -n "${GIT_TOKEN:-}" ]]; then
  echo "Warning: Using token from environment variable" >&2
  TOKEN="${GIT_TOKEN}"
else
  echo "Error: No Git token provided (set GIT_TOKEN_FILE or GIT_TOKEN)" >&2
  exit 1
fi

BASE_DIR="${PROJECT_DIR:-/workspace}"
REPOS_ROOT="$BASE_DIR"

# Ensure the repos root exists and is writable (should be a named volume mounted at /workspace)
mkdir -p "$REPOS_ROOT"
if ! tmpfile="$REPOS_ROOT/.permtest.$$"; : >"$tmpfile" 2>/dev/null; then
  echo "Error: '$REPOS_ROOT' is not writable. Ensure a Docker named volume is mounted at $REPOS_ROOT with permissions for the runtime user." >&2
  exit 1
fi
rm -f "$tmpfile" || true

cd "$REPOS_ROOT"

build_url_from_slug() {
  local slug="$1" provider_lc host
  provider_lc="${GIT_PROVIDER:-}"
  provider_lc="${provider_lc,,}"
  host="${GIT_HOST:-}"
  if [[ -z "$host" ]]; then
    if [[ "$provider_lc" == "azure" || "$provider_lc" == "ado" || "$provider_lc" == "azure-devops" ]]; then
      host="dev.azure.com"
    else
      host="github.com"
    fi
  fi
  if [[ "$host" == "github.com" && -z "$provider_lc" ]]; then
    printf "https://github.com/%s.git\n" "$slug"
    return 0
  fi
  local repo_path="$slug"
  if [[ "$repo_path" != *"/_git/"* ]]; then
    IFS='/' read -r _org _project _repo rest <<<"$repo_path"
    if [[ -n "$_org" && -n "$_project" && -n "$_repo" && -z "${rest:-}" ]]; then
      repo_path="${_org}/${_project}/_git/${_repo}"
    fi
  fi
  printf "https://%s/%s\n" "$host" "$repo_path"
}

repo_name_from_ref() {
  local ref="$1"
  # If URL, strip trailing .git and extract segment after /_git/ or last path component
  if [[ "$ref" =~ ^https?:// ]]; then
    ref="${ref%.git}"
    if [[ "$ref" == *"/_git/"* ]]; then
      printf "%s\n" "${ref##*/_git/}"
    else
      printf "%s\n" "${ref##*/}"
    fi
  else
    # Slug: owner/repo or org/project/repo
    ref="${ref##*/}"
    printf "%s\n" "$ref"
  fi
}

# Build a list of repo references (URLs or slugs)
declare -a REFS=()
if [[ -n "${GIT_REPOS:-}" ]]; then
  # Support comma, semicolon, space, or newline separated
  refs_raw="$GIT_REPOS"
  refs_raw="${refs_raw//,/ }"; refs_raw="${refs_raw//;/ }"
  # shellcheck disable=SC2206
  REFS=($refs_raw)
else
  if [[ -n "${GIT_URL:-}" ]]; then
    REFS+=("$GIT_URL")
  else
    REFS+=("$GIT_REPO")
  fi
fi

# Avoid leaking token in process listings by using env var expansion inside URL
# Using git -c to avoid writing credentials to config
GIT_BRANCH="${GIT_BRANCH:-main}"
GIT_ASKPASS_SCRIPT=$(mktemp -p "${HOME:-/home/devuser}")
trap 'rm -f "$GIT_ASKPASS_SCRIPT"' EXIT

USERNAME_DEFAULT="x-access-token"  # GitHub accepts this with PATs; override via GIT_USERNAME
GIT_USERNAME_VALUE="${GIT_USERNAME:-$USERNAME_DEFAULT}"

cat >"$GIT_ASKPASS_SCRIPT" <<'EOF'
#!/usr/bin/env bash
prompt="$1"
if [[ "$prompt" == *"Username"* ]]; then
  echo "$GIT_USERNAME_VALUE"
else
  echo "$GIT_TOKEN"
fi
EOF
chmod 700 "$GIT_ASKPASS_SCRIPT"

export GIT_ASKPASS="$GIT_ASKPASS_SCRIPT"
export GIT_TOKEN="$TOKEN"

clone_or_update() {
  local url="$1" name="$2" branch="$3"
  local dest="$REPOS_ROOT/$name"

  mkdir -p "$dest"
  cd "$dest"
  if [[ -d .git ]]; then
    echo "[$name] Updating existing repo..." >&2
    local origin
    origin=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ -n "$origin" && "$origin" != *"$name"* && "$origin" != *"$url"* ]]; then
      if [[ "${GIT_FORCE_RECLONE:-}" == "1" ]]; then
        echo "[$name] Origin mismatch. Re-cloning due to GIT_FORCE_RECLONE=1" >&2
        cd "$REPOS_ROOT"
        rm -rf "$dest"
        git -c credential.helper= -c core.askpass="$GIT_ASKPASS_SCRIPT" clone --branch "$branch" "$url" "$dest"
      else
        echo "[$name] Origin ($origin) does not match ($url). Set GIT_FORCE_RECLONE=1 to replace." >&2
        cd "$REPOS_ROOT"; return 1
      fi
    else
      git remote set-url origin "$url" || true
      git fetch --all --prune
      if git show-ref --verify --quiet "refs/heads/$branch"; then
        git checkout "$branch"
      else
        git checkout -B "$branch" "origin/$branch" || git checkout -b "$branch"
      fi
      git pull --ff-only origin "$branch" || true
      cd "$REPOS_ROOT"
    fi
  else
    if [[ -n "$(ls -A "$dest" 2>/dev/null || true)" ]]; then
      if [[ "${GIT_FORCE_RECLONE:-}" == "1" ]]; then
        echo "[$name] Non-git dir not empty. Re-cloning due to GIT_FORCE_RECLONE=1" >&2
        rm -rf "$dest"
      else
        echo "[$name] Destination exists and is not a git repo. Set GIT_FORCE_RECLONE=1 to replace." >&2
        cd "$REPOS_ROOT"; return 1
      fi
    fi
    git -c credential.helper= -c core.askpass="$GIT_ASKPASS_SCRIPT" clone --branch "$branch" "$url" "$dest"
    cd "$REPOS_ROOT"
  fi
}

# Iterate over all requested repos
for ref in "${REFS[@]}"; do
  # Normalize URL
  REPO_URL="${ref}"
  if [[ ! "$REPO_URL" =~ ^https?:// ]]; then
    REPO_URL="$(build_url_from_slug "$ref")"
  fi

  # Username default per provider
  if [[ "$REPO_URL" == *"dev.azure.com"* || "$REPO_URL" == *"visualstudio.com"* ]]; then
    GIT_USERNAME_VALUE="${GIT_USERNAME:-azdo}"
  else
    GIT_USERNAME_VALUE="${GIT_USERNAME:-x-access-token}"
  fi
  export GIT_USERNAME_VALUE

  NAME="$(repo_name_from_ref "$ref")"
  clone_or_update "$REPO_URL" "$NAME" "$GIT_BRANCH"
done

unset TOKEN GIT_TOKEN GIT_USERNAME_VALUE

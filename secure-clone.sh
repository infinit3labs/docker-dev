#!/usr/bin/env bash
set -euo pipefail

# Secure way to clone with credentials. Preferred: Docker/K8s secret mounted at /run/secrets/git_token
# Usage: GIT_REPO=owner/repo [GIT_BRANCH=main] [GIT_TOKEN_FILE=/run/secrets/git_token] ./secure-clone.sh

if [[ -z "${GIT_REPO:-}" ]]; then
  echo "Error: GIT_REPO must be set (format: owner/repo)" >&2
  exit 1
fi

TOKEN=""
if [[ -n "${GIT_TOKEN_FILE:-}" && -f "${GIT_TOKEN_FILE}" ]]; then
  TOKEN=$(<"${GIT_TOKEN_FILE}")
elif [[ -n "${GIT_TOKEN:-}" ]]; then
  echo "Warning: Using token from environment variable" >&2
  TOKEN="${GIT_TOKEN}"
else
  echo "Error: No Git token provided (set GIT_TOKEN_FILE or GIT_TOKEN)" >&2
  exit 1
fi

TARGET_DIR="${TARGET_DIR:-/workspace/repo}"
mkdir -p "${TARGET_DIR}"

# Avoid leaking token in process listings by using env var expansion inside URL
# Using git -c to avoid writing credentials to config
GIT_BRANCH="${GIT_BRANCH:-main}"
GIT_ASKPASS_SCRIPT=$(mktemp)
trap 'rm -f "$GIT_ASKPASS_SCRIPT"' EXIT

cat >"$GIT_ASKPASS_SCRIPT" <<'EOF'
#!/usr/bin/env bash
echo "$GIT_TOKEN"
EOF
chmod 700 "$GIT_ASKPASS_SCRIPT"

GIT_ASKPASS="$GIT_ASKPASS_SCRIPT" GIT_USERNAME="oauth2" GIT_TOKEN="$TOKEN" \
  git -c credential.helper= -c core.askpass="$GIT_ASKPASS_SCRIPT" \
  clone --branch "$GIT_BRANCH" "https://oauth2:@github.com/${GIT_REPO}.git" "$TARGET_DIR"

unset TOKEN GIT_TOKEN

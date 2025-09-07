# Secure Dev Container: Build, Run, and Back Up (Docker + Compose)

An all-in-one developer container with Ubuntu 24.04, Python (pyenv + Poetry), Node.js, OpenJDK 21, Apache Spark, Azure CLI, Oracle Instant Client, and a polished zsh experience (Oh My Zsh + Powerlevel10k). Secrets are never baked into the image; private repos can be securely cloned at runtime.

## What you get

- Ubuntu 24.04 base, non-root user (devuser)
- Python via pyenv (3.12.x), Poetry with in-project venvs
- Node.js (pinned major), OpenJDK 21, Apache Spark
- Azure CLI, Oracle Instant Client
- Oh My Zsh + Powerlevel10k + plugins
- Secure runtime cloning of private repos (no secrets in image)

## Prerequisites

- macOS with Docker Desktop (Docker Engine + Compose v2)
- zsh shell (default on macOS)
- Optional: Install a Nerd Font for best Powerlevel10k visuals

Project layout highlights:

- `Dockerfile` – secure multi-stage build
- `docker-compose.secure.yaml` – service with volumes, secrets, env
- `build-secure.sh` – helper: build + quick secret keyword check + Trivy scan
- `entrypoint.sh` – in-container setup (secure clone + Poetry install)
- `secure-clone.sh` – safe private repo cloning via token file/secret
- `secrets/git_token` – local secret file you create (mounted by Compose)
- `workspace/` – host folder mapped to `/workspace` in the container

## 1) One-time setup

Create the secret file used by Compose to mount your Git token (GitHub or Azure DevOps PAT) as `/run/secrets/git_token` and ensure the local workspace directory exists (mapped to `/workspace` in the container):

```bash
mkdir -p secrets
printf '%s' 'YOUR_GIT_PAT' > secrets/git_token
chmod 600 secrets/git_token
mkdir -p workspace
```

Notes:

- The token is only read at runtime; it is not embedded in the image.
- The Compose file can mount your `~/.gitconfig` and `~/.ssh` read-only into the container. Ensure `~/.ssh` permissions are strict (700 dir, 600 keys).
- Ensure `secure-clone.sh` is executable on the host so it can be invoked when mounted:

```bash
chmod +x secure-clone.sh
```

## 2) Build the image

Option A — recommended: use the helper script (includes a quick secret keyword scan and Trivy vulnerability scan):

```bash
chmod +x build-secure.sh
./build-secure.sh
```

Option B — build directly with Docker:

```bash
DOCKER_BUILDKIT=1 docker build -t docker-dev-secure:latest -f Dockerfile .
```

Option C — let Compose handle the build:

```bash
docker compose -f docker-compose.secure.yaml build
```

Option D — multi-arch build (arm64 host producing amd64+arm64):

```bash
# Create and use a buildx builder once
docker buildx create --use --name devbuilder || docker buildx use devbuilder

# Build and push a manifest list to your registry (replace tag)
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t youruser/docker-dev-secure:latest \
  -f Dockerfile \
  --push .

# Now any amd64 or arm64 host pulling your tag gets the right variant
```

## 2a) Multi-arch quick start (amd64 + arm64)

Prerequisites:

- Docker Buildx available (Docker Desktop: built-in. Linux: install buildx and enable binfmt emulation if cross-compiling):

  ```bash
  # Optional on Linux-only hosts (Desktop includes this)
  docker run --privileged --rm tonistiigi/binfmt --install all
  ```

Steps:

1) Choose a registry tag for your image (replace with your own):

  - Example: `youruser/docker-dev-secure:latest` or `ghcr.io/yourorg/docker-dev-secure:latest`

2) Build and push a multi-arch image (same as Option D above):

  ```bash
  docker buildx create --use --name devbuilder || docker buildx use devbuilder
  docker buildx build \
    --platform linux/amd64,linux/arm64 \
    -t youruser/docker-dev-secure:latest \
    -f Dockerfile \
    --push .
  ```

3) Point Compose at that tag by setting `IMAGE_NAME` (via `.env` or environment):

  ```bash
  echo IMAGE_NAME=youruser/docker-dev-secure:latest > .env
  ```

4) Run on any host (amd64 or arm64):

  ```bash
  docker compose -f docker-compose.secure.yaml up -d
  ```

Notes and alternatives:

- Local-only without pushing: Buildx cannot "--load" a multi-arch image into the local daemon in one shot. Use one of:
  - Build and load a single-arch image for the current host: `docker buildx build --platform $(docker info --format '{{.Architecture}}' | sed 's/x86_64/amd64/') -t local/dev:latest -f Dockerfile --load .`
  - Or export archives per-arch: `--output type=tar,dest=dev-amd64.tar` and load on each host with `docker load -i dev-amd64.tar`.
  - Recommended for teams: push a multi-arch tag to a registry and use `IMAGE_NAME` to reference it.

Troubleshooting:

- "–load only supports a single platform": Use `--push` for multi-arch, or build per-arch with `--load`.
- Platform mismatch warnings: either build/pull the correct arch, or set `platform:` under the compose service to force (`linux/amd64` or `linux/arm64`).

## 3) Configure runtime settings (optional)

The Compose file sets a few environment variables for the `dev` service:

- `GIT_TOKEN_FILE=/run/secrets/git_token` (points to the mounted secret)
- For GitHub: set `GIT_REPO=owner/repo` or `GIT_URL=https://github.com/owner/repo.git`
- For Azure DevOps: set `GIT_URL=https://dev.azure.com/<org>/<project>/_git/<repo>`
  or set `GIT_PROVIDER=azure` and `GIT_REPO=<org>/<project>/<repo>`
- Optional: `GIT_HOST=dev.azure.com`, `GIT_USERNAME=azdo` (Azure DevOps)
- `GIT_BRANCH=main`

You can edit these in `docker-compose.secure.yaml` or override them on the command line with `--env-file` or `-e` flags. If `GIT_REPO` is provided, `entrypoint.sh` will run `secure-clone.sh` to clone the repo into `/workspace/repo` at container start.

## 4) Run the dev environment (Compose)

Interactive foreground run (shows logs and opens zsh):

```bash
docker compose -f docker-compose.secure.yaml up --build
```

Detached mode (run in background):

```bash
docker compose -f docker-compose.secure.yaml up -d --build
```

What happens on startup:

1. Secrets and volumes are mounted.
2. If `GIT_REPO` is set, `secure-clone.sh` clones it using the token from `/run/secrets/git_token` without persisting credentials.
3. If a `pyproject.toml` exists under the working directory (`/workspace`), Poetry creates an in-project `.venv` and installs dependencies. Optional groups via `POETRY_GROUPS=dev,docs`.
4. zsh starts as the default shell.

Where files live:

- Host `./workspace` is mapped to container `/workspace`.
- If you enabled secure clone, your repo appears at `/workspace/repo` by default (override with `TARGET_DIR`).

### Day-2 operations

- Attach a shell in a running container:

  ```bash
  docker compose -f docker-compose.secure.yaml exec dev zsh
  ```

- View logs:

  ```bash
  docker compose -f docker-compose.secure.yaml logs -f
  ```

- Stop services:

  ```bash
  docker compose -f docker-compose.secure.yaml down
  ```

- Clean up volumes too (removes Compose-managed volumes; your mapped `./workspace` stays as-is):

  ```bash
  docker compose -f docker-compose.secure.yaml down -v
  ```

- Rebuild after Dockerfile changes:

  ```bash
  docker compose -f docker-compose.secure.yaml build --no-cache
  ```

## 5) Secure repo cloning (manual use)

You can also run `secure-clone.sh` by hand inside the container:

```bash
export GIT_REPO=owner/private-repo
export GIT_BRANCH=main
export GIT_TOKEN_FILE=/run/secrets/git_token
./secure-clone.sh
```

It uses a temporary ASKPASS script so the token is never shown in process lists and is not written to git config. For Azure DevOps, set `GIT_URL=...` or `GIT_PROVIDER=azure` with `GIT_REPO=<org>/<project>/<repo>` and optionally `GIT_USERNAME=azdo`.

## 6) Poetry environment behavior

At container start, `entrypoint.sh` will:

- Optionally run `secure-clone.sh` if `$GIT_REPO` is set
- If `pyproject.toml` is present, ensure an in-project `.venv` and run `poetry install`
- Include optional groups by setting `POETRY_GROUPS`, e.g. `POETRY_GROUPS=dev,docs`

To skip Poetry steps, ensure there’s no `pyproject.toml` in `/workspace`.

## 7) Back up or distribute the image

Use the backup helper to save/load/push/pull images:

```bash
chmod +x backup-docker.sh
./backup-docker.sh save docker-dev-secure:latest ./backups
./backup-docker.sh load docker-dev-secure:latest ./backups
```

Other common methods:

- File backup (local):

  ```bash
  docker save docker-dev-secure:latest > ./backups/dev-env-$(date +%Y%m%d).tar
  docker load < ./backups/dev-env-YYYYMMDD.tar
  ```

- Docker Hub (sharing):

  ```bash
  docker tag docker-dev-secure:latest youruser/dev-env:latest
  docker push youruser/dev-env:latest
  docker pull youruser/dev-env:latest
  ```

- Private registry:

  ```bash
  docker tag docker-dev-secure:latest registry.example.com/dev-env:latest
  docker push registry.example.com/dev-env:latest
  docker pull registry.example.com/dev-env:latest
  ```

Best practices:

1. Back up after major changes
2. Use version tags (e.g., v1.0.0, v1.1.0)
3. Store backups in multiple locations
4. Automate with the script for consistency
5. Document what each image contains

## 8) Security best practices

- Never bake secrets into the image; use Docker/K8s secrets or a secret manager
- Run as non-root; limit permissions on bind mounts
- Pin versions and run periodic scans (e.g., Trivy)
- Prefer official repositories and verify checksums/GPG where available

## 9) Troubleshooting

- Permission denied accessing `~/.ssh` from the container: ensure strict permissions (e.g., `chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_*`).
- Token not found: confirm `secrets/git_token` exists and is referenced under `secrets:` in the Compose file.
- Slow `poetry install`: first run builds wheels; subsequent runs are faster. Consider caching with the same image or keeping the container running.
- Fonts look off in the prompt: install a Nerd Font locally and set it in your terminal.
- Azure CLI or Node require outbound network to fetch packages; ensure your host network allows it during build.
 - Platform mismatch warning: If you see "The requested image's platform (linux/arm64) does not match the detected host platform (linux/amd64)", force x86_64 by adding to your compose service:

   ```yaml
   services:
     dev:
       platform: linux/amd64
       build:
         platform: linux/amd64
   ```

   Then rebuild and start: `docker compose -f docker-compose.secure.yaml up -d --build`. If you need both architectures, build a multi-arch image with Buildx: `docker buildx build --platform linux/amd64,linux/arm64 -t your/image:tag --push .` and reference it in compose.

Notes for multi-arch:
- The Dockerfile is now arch-aware (JAVA_HOME and Oracle Instant Client adapt to amd64/arm64).
- For local-only use on one machine, you can omit Buildx and just `docker compose build` on that machine.
- For sharing across archs, use Buildx to push a multi-arch tag and reference it via `IMAGE_NAME`.

## Reference: Compose service `dev`

- Image: builds from local `Dockerfile`, tagged `docker-dev-secure:latest`
- Secrets: mounts `secrets/git_token` to `/run/secrets/git_token`
- Volumes:
  - `./workspace:/workspace:rw` – your working directory
  - `~/.gitconfig:/home/devuser/.gitconfig:ro`
  - `~/.ssh:/home/devuser/.ssh:ro`
- Entrypoint: `/usr/local/bin/entrypoint.sh` (then `/bin/zsh`)

## License / Attribution

This Docker configuration pulls and installs third-party tooling. Review licenses for each dependency (Python, Node.js, OpenJDK, Spark, Azure CLI, Oracle Instant Client, Oh My Zsh, Powerlevel10k, plugins) before distribution.

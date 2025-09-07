# End-to-End Guide: Build & Deploy with Docker and Compose

This guide walks you through building the secure dev image and running it with Docker Compose using the files in this repo.

## What you get

- Ubuntu 24.04 base, non-root user (`devuser`)
- Python via pyenv (3.12.x), Poetry with in-project venvs
- Node.js (pinned major), OpenJDK 21, Apache Spark
- Azure CLI, Oracle Instant Client
- Oh My Zsh + Powerlevel10k + plugins
- Secure runtime cloning of private repos (no secrets baked into image)

## Prerequisites

- macOS with Docker Desktop (Docker Engine + Compose v2)
- zsh shell (default on macOS)
- Optional: Nerd Font installed for best Powerlevel10k experience

Project layout highlights:

- `Dockerfile` – secure multi-stage build
- `docker-compose.secure.yaml` – service definition with volumes, secrets, and env
- `build-secure.sh` – helper: build + Trivy scan
- `entrypoint.sh` – in-container setup (secure clone + Poetry install)
- `secure-clone.sh` – safe private repo cloning using a token file/secret
- `secrets/git_token` – local Compose secret file (you create this)
- `workspace/` – host folder mapped to `/workspace` in the container

## 1) One-time setup

Create the secret file used by Compose to mount your GitHub token as `/run/secrets/git_token` and ensure the local workspace directory exists (mapped to `/workspace` in the container):

```bash
mkdir -p secrets
printf '%s' 'YOUR_GH_PAT' > secrets/git_token
chmod 600 secrets/git_token
mkdir -p workspace
```

Notes:

- This token is only read at runtime; it is not embedded in the image.
- The Compose file also mounts your `~/.gitconfig` and `~/.ssh` read-only into the container for convenience. Ensure `~/.ssh` permissions are restricted (typically 600 for private keys, 700 for the folder).

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

Tip: ensure `secure-clone.sh` is executable on the host so it can be invoked when mounted:

```bash
chmod +x secure-clone.sh
```

## 3) Configure runtime settings (optional)

The Compose file sets a few environment variables for the `dev` service:

- `GIT_TOKEN_FILE=/run/secrets/git_token` (points to the mounted secret)
- `GIT_REPO=owner/repo` (set to your private repo slug, e.g., `org/project`)
- `GIT_BRANCH=main`

You can edit these in `docker-compose.secure.yaml` or override them on the command line with `--env-file` or `-e` flags. If `GIT_REPO` is provided, `entrypoint.sh` will run `secure-clone.sh` to clone the repo into `/workspace/repo` at container start.

## 4) Run the dev environment (deploy via Compose)

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
3. If a `pyproject.toml` exists under the working directory (`/workspace`), Poetry creates an in-project `.venv` and installs dependencies. You can include optional groups via `POETRY_GROUPS=dev,docs`.
4. zsh starts as the default shell.

Where files live:

- Host `./workspace` is mapped to container `/workspace`.
- If you enabled secure clone, your repo appears at `/workspace/repo` by default (override with `TARGET_DIR`).

## 5) Day-2 operations

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

- Clean up volumes too (removes Compose-managed volumes; takes the mapped `./workspace` as-is):

  ```bash
  docker compose -f docker-compose.secure.yaml down -v
  ```

- Rebuild after making Dockerfile changes:

  ```bash
  docker compose -f docker-compose.secure.yaml build --no-cache
  ```

## 6) Secure repo cloning (manual use)

You can also run `secure-clone.sh` by hand inside the container:

```bash
export GIT_REPO=owner/private-repo
export GIT_BRANCH=main
export GIT_TOKEN_FILE=/run/secrets/git_token
./secure-clone.sh
```

It uses a temporary ASKPASS script so the token is never shown in process lists and is not written to git config.

## 7) Back up or distribute the image

Use the backup helper to save/load/push/pull images:

```bash
chmod +x backup-docker.sh
./backup-docker.sh save docker-dev-secure:latest ./backups
./backup-docker.sh load docker-dev-secure:latest ./backups
```

More options and best practices: see `DOCKER_BACKUP_README.md`.

## Customization

- Change the repo and branch in `docker-compose.secure.yaml` or via env overrides.
- Adjust mounted volumes (e.g., map a different host path to `/workspace`).
- Pin or change Oh My Zsh / theme / plugin refs via Docker build args (`OHMYZSH_REF`, `P10K_REF`, etc.).
- Control Poetry behavior with `POETRY_GROUPS` to include optional dependency groups.

## Troubleshooting

- Permission denied accessing `~/.ssh` from the container: ensure strict permissions on `~/.ssh` and files (e.g., `chmod 700 ~/.ssh && chmod 600 ~/.ssh/id_*`).
- Token not found: confirm `secrets/git_token` exists and is referenced under `secrets:` in the Compose file.
- Slow `poetry install`: first run builds wheels; subsequent runs are faster. Consider caching with the same image or keeping the container running.
- Fonts look off in the prompt: install a Nerd Font locally and set it in your terminal.
- Azure CLI or Node require outbound network to fetch packages; ensure your host network allows it during build.

## Reference

Compose service `dev` (from `docker-compose.secure.yaml`):

- Image: builds from local `Dockerfile`, tagged `docker-dev-secure:latest`
- Secrets: mounts `secrets/git_token` to `/run/secrets/git_token`
- Volumes:
  - `./workspace:/workspace:rw` – your working directory
  - `~/.gitconfig:/home/devuser/.gitconfig:ro`
  - `~/.ssh:/home/devuser/.ssh:ro`
- Entrypoint: `/usr/local/bin/entrypoint.sh` (then `/bin/zsh`)

## See also

- `USAGE.md` – features and additional notes
- `DOCKER_BACKUP_README.md` – image backup and restore options

# Secure Dev Image: Usage Guide

This guide explains how to build, run, and use the secure dev container with Oh My Zsh, Poetry, Node, Java, Spark, Azure CLI, and Oracle Instant Client.

## Features

- Ubuntu 24.04 base, non-root runtime user
- Python (pyenv, pinned version), Poetry (pinned), pipx
- Node.js (pinned major from official NodeSource repo)
- OpenJDK 21, Apache Spark with checksum verification
- Azure CLI from official repo
- Oracle Instant Client with ldconfig integration
- Oh My Zsh + Powerlevel10k + zsh-autosuggestions + zsh-syntax-highlighting
- Healthcheck and minimal PATH
- No secrets baked into the image; secure runtime cloning supported

## Prerequisites

- Docker installed
- (Optional) Docker Compose
- (Optional) Create a Docker secret for your GitHub token:

```bash
printf '%s' 'YOUR_GH_PAT' | docker secret create git_token -
```

## Build

You can build directly or via the helper script:

```bash
# Fast path
DOCKER_BUILDKIT=1 docker build -t docker-dev-secure:latest -f Dockerfile .

# With security checks and Trivy scan
chmod +x build-secure.sh
./build-secure.sh
```

## Run

Simple run:

```bash
docker run --rm -it \
  -v "$(pwd)/workspace:/workspace:rw" \
  docker-dev-secure:latest
```

Using Docker Compose with a Git token secret and dev volumes:

```bash
# Ensure you created the secret once
printf '%s' 'YOUR_GH_PAT' | docker secret create git_token -

docker compose -f docker-compose.secure.yaml up --build
```

## Secure Repo Clone at Runtime

Use `secure-clone.sh` to clone a private repo without placing tokens in the Dockerfile or image history.

```bash
# Inside the container
export GIT_REPO=owner/repo
export GIT_BRANCH=main
export GIT_TOKEN_FILE=/run/secrets/git_token
./secure-clone.sh
```

`secure-clone.sh` uses an askpass shim so the token isn’t exposed in the process list or git config.

## Poetry Environment Setup

The container runs `entrypoint.sh` which will:

- Optionally run `secure-clone.sh` if `$GIT_REPO` is set
- If `pyproject.toml` is present, ensure an in-project `.venv` and run `poetry install`
- You can include optional groups by setting `POETRY_GROUPS`, for example: `POETRY_GROUPS=dev,docs`

To skip Poetry steps, ensure there’s no `pyproject.toml` in the working directory.

## Oh My Zsh and Powerlevel10k

- Zsh theme and plugins are installed for the `devuser`. If your prompt needs configuration, edit `/home/devuser/.zshrc`.
- Powerlevel10k can be customized by adding a `.p10k.zsh` file in the home directory and sourcing it from `.zshrc`.

## Environment Variables

- `PROJECT_DIR` (default `/workspace`): Entry point working directory
- `GIT_REPO`, `GIT_BRANCH` (optional): Used by `secure-clone.sh` if you want automatic cloning on start
- `GIT_TOKEN_FILE` or `GIT_TOKEN`: Location/value of Git token for cloning (prefer file/secret)
- `POETRY_GROUPS` (optional): Comma-separated groups for `poetry install --with`

## Security Best Practices

- Never bake secrets into the image; use Docker/K8s secrets or a secret manager
- Run as non-root in production; only grant minimal permissions to bind mounts
- Keep versions pinned and run periodic scans (e.g., Trivy) for vulnerabilities
- Prefer official repositories and verify checksums/GPG where available

## Troubleshooting

- If Node or Azure CLI fail to install, the host network or keyring may be restricted. Ensure outbound access and try again.
- If Powerlevel10k glyphs look odd, install a Nerd Font on your terminal and set it in your terminal profile.
- If Poetry install is slow, consider caching the build stage or mirroring repositories internally.

## License / Attribution

This Docker configuration pulls and installs third-party tooling. Review licenses for each dependency (Python, Node.js, OpenJDK, Spark, Azure CLI, Oracle Instant Client, Oh My Zsh, Powerlevel10k, plugins) before distribution.

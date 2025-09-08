# syntax=docker/dockerfile:1.7
#### Secure multi-stage build with pinned versions and least privilege

# -------- Builder stage: toolchains and dependencies (amd64 only) --------
FROM --platform=linux/amd64 ubuntu:24.04 AS builder

ARG PYTHON_VERSION=3.12.3
ARG SPARK_VERSION=4.0.0
ARG NODE_MAJOR=22
ARG POETRY_VERSION=2.1.4

# System packages (build + runtime libs). Keep minimal and clean up.
RUN set -eux; \
    apt-get update; \
    apt-get upgrade -y; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      gnupg \
      lsb-release \
      unzip \
      wget \
      zsh \
      pipx \
      fonts-powerline \
      build-essential \
      libssl-dev \
      zlib1g-dev \
      libbz2-dev \
      libreadline-dev \
      libsqlite3-dev \
      llvm \
      libncursesw5-dev \
      xz-utils \
      tk-dev \
      libxml2-dev \
      libxmlsec1-dev \
      libffi-dev \
      liblzma-dev; \
    rm -rf /var/lib/apt/lists/*; \
    pipx ensurepath; \
    update-ca-certificates


# pyenv (pin tag) and Python toolchain
ENV PYENV_ROOT=/opt/pyenv
ENV PATH=$PYENV_ROOT/shims:$PYENV_ROOT/bin:$PATH
RUN set -eux; \
    git clone --depth 1 https://github.com/pyenv/pyenv.git "$PYENV_ROOT"; \
    pyenv install "${PYTHON_VERSION}"; \
    pyenv global "${PYTHON_VERSION}"; \
    python -m pip install --upgrade pip

# Python runtime env hardening
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONHASHSEED=random \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# Node.js from NodeSource with keyring verification (pin major)
RUN set -eux; \
    mkdir -p /usr/share/keyrings; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /usr/share/keyrings/nodesource.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*

# OpenJDK 21 (headless) - amd64
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends openjdk-21-jdk-headless; \
    rm -rf /var/lib/apt/lists/*
# Map JAVA_HOME for amd64
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV PATH=$JAVA_HOME/bin:$PATH

# Apache Spark (verify checksum via official .sha512 file)
RUN --mount=type=cache,target=/download_cache,id=download_cache \
        set -eux; \
        cd /download_cache; \
        SPARK_TGZ="spark-${SPARK_VERSION}-bin-hadoop3.tgz"; \
        SPARK_SHA="${SPARK_TGZ}.sha512"; \
        if [ -f "$SPARK_TGZ" ]; then \
            echo "Using cached $SPARK_TGZ"; \
        else \
            wget -q "https://downloads.apache.org/spark/spark-${SPARK_VERSION}/$SPARK_TGZ"; \
        fi; \
        if [ -f "$SPARK_SHA" ]; then \
            echo "Using cached $SPARK_SHA"; \
        else \
            wget -q "https://downloads.apache.org/spark/spark-${SPARK_VERSION}/$SPARK_SHA"; \
        fi; \
        sha512sum -c "$SPARK_SHA"; \
        tar -xzf "$SPARK_TGZ" -C /opt; \
        mv /opt/spark-${SPARK_VERSION}-bin-hadoop3 /opt/spark
ENV SPARK_HOME=/opt/spark
ENV PATH=$PATH:$SPARK_HOME/bin:$SPARK_HOME/sbin
ENV PYSPARK_PYTHON=python PYSPARK_DRIVER_PYTHON=python

# Poetry (pin)
RUN pipx install "poetry==${POETRY_VERSION}";

# Azure CLI: install via pipx to avoid repo dependency issues on Ubuntu 24.04
# This keeps the builder image lean and avoids "held broken packages" from apt.
RUN pipx install azure-cli

# Oracle Instant Client (amd64/x64) and configure loader
# Notes:
# - Pinned version and directory IDs for reproducibility.
ARG ORACLE_VERSION=21.19.0.0.0dbru
ARG ORACLE_DIR_ID=2119000
RUN --mount=type=cache,target=/download_cache,id=download_cache \
        set -eux; \
        cd /download_cache; \
        ORA_ZIP="instantclient-basic-linux.x64-${ORACLE_VERSION}.zip"; \
        ORA_URL="https://download.oracle.com/otn_software/linux/instantclient/${ORACLE_DIR_ID}/${ORA_ZIP}"; \
        if [ -f "${ORA_ZIP}" ]; then \
            echo "Using cached ${ORA_ZIP}"; \
        else \
            wget -q "${ORA_URL}"; \
        fi; \
        unzip -q "${ORA_ZIP}" -d /opt; \
        mv /opt/instantclient_21_19 /opt/oracle; \
        echo "/opt/oracle" > /etc/ld.so.conf.d/oracle.conf; \
        ldconfig
ENV LD_LIBRARY_PATH=/opt/oracle


# -------- Final stage: minimal runtime, non-root --------
FROM --platform=linux/amd64 ubuntu:24.04

# Copy only what is needed from builder
COPY --from=builder /opt /opt
COPY --from=builder /usr /usr
COPY --from=builder /etc/ld.so.conf.d/oracle.conf /etc/ld.so.conf.d/oracle.conf

# Create non-root user and prepare writable dirs
RUN set -eux; \
    groupadd -r devuser; \
    useradd -r -g devuser -m -s /bin/zsh devuser; \
    mkdir -p /workspace /workspace/repos /home/devuser/.cache/pypoetry /home/devuser/.cache/pip; \
    chown -R devuser:devuser /workspace /home/devuser/.cache; \
    chmod 0775 /workspace /workspace/repos || true; \
    ldconfig

ARG POETRY_VERSION=2.1.4
USER devuser
WORKDIR /workspace

# Minimal, explicit PATH and env
ENV PATH=/opt/pyenv/shims:/opt/pyenv/bin:/opt/spark/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/home/devuser/.local/bin \
    PYTHONPATH=/workspace \
    LD_LIBRARY_PATH=/opt/oracle \
    POETRY_CACHE_DIR=/home/devuser/.cache/pypoetry \
    PIP_CACHE_DIR=/home/devuser/.cache/pip \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONHASHSEED=random \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=0

# Provide JAVA_HOME at runtime for amd64
ENV JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
ENV PATH=$JAVA_HOME/bin:$PATH

# Ensure SSL certs are up to date (no sudo; run as root)
USER root
RUN set -eux; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --reinstall ca-certificates; \
    update-ca-certificates; \
    rm -rf /var/lib/apt/lists/*
USER devuser

# Install Poetry and Azure CLI for the runtime user (pinned Poetry)
RUN pipx ensurepath \
    && pipx install "poetry==${POETRY_VERSION}" \
    && pipx install azure-cli \
    && poetry config virtualenvs.in-project false \
    && poetry config virtualenvs.path /home/devuser/.cache/pypoetry/virtualenvs \
    && poetry config virtualenvs.create true \
    && poetry config installer.parallel true


# Copy entrypoint script with executable permissions set at build time
# Copy runtime scripts with executable permissions set at build time
COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 secure-clone.sh /usr/local/bin/secure-clone.sh

# Healthcheck for basic Python availability
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD python --version || exit 1

# Entrypoint ensures Poetry env setup; default command opens zsh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/bin/zsh", "-l"]

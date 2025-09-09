# ============================================================
# UC-enabled Spark Launcher - Configuration Template
# ------------------------------------------------------------
# This file is automatically loaded by spark_uc.ps1 if present
# in the same directory. It overrides the defaults in the
# launcher without editing the main script.
#
# USAGE:
#   1. Copy this file to the same folder as spark_uc.ps1
#   2. Adjust values below to match your environment
#   3. Run: .\spark_uc.ps1 <mode> [-DryRun]
#
# MODES (see spark_uc.ps1 for full details):
#   interact | test | verify | rebuild | clean | restore | status | logs | update
#
# DRY-RUN:
#   Add -DryRun parameter to preview commands without executing them.
# ============================================================

# ------------------------------------------------------------
# IMAGE & BUILD SETTINGS
# ------------------------------------------------------------

# Docker image name and tag for the UC-enabled Spark environment
$script:IMAGE_NAME = "local/spark-uc:latest"

# Versions for build arguments (used in Dockerfile)
$script:PYTHON_VERSION = "3.12.3"
$script:SPARK_VERSION = "4.0.0"
$script:DELTA_VERSION = "3.2.1"
$script:POETRY_VERSION = "2.1.4"

# Target platform for docker build (linux/amd64 ensures compatibility on Apple Silicon)
$script:PLATFORM = "linux/amd64"

# ------------------------------------------------------------
# STORAGE SETTINGS
# ------------------------------------------------------------

# STORAGE_MODE determines how workspace/warehouse are persisted:
#   bind   = bind-mount host directories (easy inspection, manual backup)
#   volume = use Docker named volumes (portable, isolated from host FS)
$script:STORAGE_MODE = "bind"

# When STORAGE_MODE=bind, specify host paths (absolute or relative to repo root)
$script:HOST_WORKSPACE = Join-Path $PWD "workspace"
$script:HOST_WAREHOUSE = Join-Path $PWD "warehouse"

# When STORAGE_MODE=volume, specify Docker volume names
$script:VOL_WORKSPACE = "workspace"
$script:VOL_WAREHOUSE = "warehouse"

# ------------------------------------------------------------
# UC ENVIRONMENT VARIABLES
# ------------------------------------------------------------

# UC catalog and schema to use inside Spark
$script:UC_CATALOG = "local"
$script:UC_SCHEMA = "dev"

# Path inside container where warehouse data is stored
$script:UC_WAREHOUSE = "/workspace/warehouse"

# Bootstrap UC metadata on container start (true/false)
$script:SPARK_BOOTSTRAP_UC = "true"

# Dry-run mode for UC bootstrap (true/false) — affects container init scripts
$script:UC_DRY_RUN = "false"

# ------------------------------------------------------------
# LOGGING & NAMING
# ------------------------------------------------------------

# Directory for launcher logs (relative or absolute)
$script:LOG_DIR = Join-Path $PWD "_logs"

# Enable or disable logging (true/false)
$script:ENABLE_LOG = $true

# Prefix for interactive container names (helps identify in docker ps/logs)
$script:CONTAINER_PREFIX = "spark-uc"

# Use PowerShell for timestamp formatting (always true in PowerShell)
$script:USE_POWERSHELL_TIME = $true

# ------------------------------------------------------------
# BACKUP/RESTORE BEHAVIOUR
# ------------------------------------------------------------

# Default backup filename pattern (overridden at runtime with timestamp)
# Example: warehouse_backup_YYYY-MM-DD_HH-MM-SS.tar.gz
# (No need to set here unless you want a fixed name)
# $script:BACKUP_FILE = Join-Path $PWD "warehouse_backup.tar.gz"

# ------------------------------------------------------------
# TEAM USAGE NOTES
# ------------------------------------------------------------
# - Keep this file under version control with sensible defaults
# - For personal overrides, copy to config.local.ps1 and adjust spark_uc.ps1 to load it
# - Avoid committing secrets; this file is safe for public repos
# - Modes 'clean' and 'restore' require explicit YES confirmation to prevent data loss
# - 'status' mode is safe to run anytime for diagnostics
# ============================================================

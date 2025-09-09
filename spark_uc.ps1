# ============================================================
# UC-enabled Spark multi-mode launcher (PowerShell version)
# Modes:
#   interact = build if needed, start zsh shell (named container)
#   test     = build if needed, run spark-sql smoke test, exit
#   verify   = build if needed, start container, exit immediately
#   rebuild  = force rebuild image (no cache), then zsh shell
#   clean    = remove image and data (with confirmation and optional backup)
#   restore  = restore data from tar.gz backup (with confirmation)
#   status   = show image/containers/storage status
#   logs     = attach to logs of the last interact/rebuild session (or by name)
#   update   = rebuild with --pull to refresh layers (cache allowed)
#
# Features:
#   - Centralized config via config.ps1 (auto-loaded if present)
#   - Cross-storage: bind (host folders) or volume (Docker named volumes)
#   - Common docker args, named container for interactive modes
#   - Backup/restore with integrity checks
#   - Dry-run option to preview commands
#   - Structured logging to file
# ============================================================

param(
    [Parameter(Position=0)]
    [string]$Mode = "interact",

    [switch]$DryRun
)

# ------------- Defaults (overridable via config.ps1) -------------
$script:IMAGE_NAME = "local/spark-uc:latest"
$script:PYTHON_VERSION = "3.12.3"
$script:SPARK_VERSION = "4.0.0"
$script:DELTA_VERSION = "3.2.1"
$script:POETRY_VERSION = "2.1.4"

# Storage mode: bind or volume
$script:STORAGE_MODE = "bind"
# When STORAGE_MODE=bind, use these host paths (relative to repo root)
$script:HOST_WORKSPACE = Join-Path $PWD "workspace"
$script:HOST_WAREHOUSE = Join-Path $PWD "warehouse"
# When STORAGE_MODE=volume, use these named volumes
$script:VOL_WORKSPACE = "workspace"
$script:VOL_WAREHOUSE = "warehouse"

# UC env defaults
$script:UC_CATALOG = "local"
$script:UC_SCHEMA = "dev"
$script:UC_WAREHOUSE = "/workspace/warehouse"
$script:SPARK_BOOTSTRAP_UC = "true"
$script:UC_DRY_RUN = "false"

# Logging
$script:LOG_DIR = Join-Path $PWD "_logs"
$script:ENABLE_LOG = $true

# Misc
$script:PLATFORM = "linux/amd64"
$script:CONTAINER_PREFIX = "spark-uc"

# ------------- Functions -------------

function Write-Log {
    param([string]$Message)
    if (!$script:ENABLE_LOG) { return }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "[$timestamp] $Message" | Out-File -FilePath $script:LOG_FILE -Append -Encoding UTF8
}

# ------------- Load external config if present -------------
$ConfigPath = Join-Path $PSScriptRoot "config.ps1"
if (Test-Path $ConfigPath) {
    . $ConfigPath
}

# ------------- Initialize logging -------------
$script:LOG_FILE = Join-Path $script:LOG_DIR "spark_uc.log"
if (!(Test-Path $script:LOG_DIR)) {
    New-Item -ItemType Directory -Path $script:LOG_DIR -Force | Out-Null
}

$TS = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
Write-Log "=== START mode=$Mode dryrun=$($DryRun.IsPresent) ts=$TS ==="

function Test-Docker {
    try {
        $null = & docker version 2>$null
        return $?
    }
    catch {
        Write-Host "[ERROR] Docker is not available in PATH or not running." -ForegroundColor Red
        return $false
    }
}

function Invoke-DockerCommand {
    param([string]$Command)

    Write-Log "RUN: $Command"

    if ($DryRun) {
        Write-Host "DRY-RUN: $Command" -ForegroundColor Yellow
        return 0
    }

    try {
        # Use cmd /c to execute the full command string as-is
        # This prevents PowerShell from incorrectly parsing complex docker commands
        $result = cmd /c $Command
        $exitCode = $LASTEXITCODE

        if ($exitCode -ne 0) {
            Write-Log "ERR($exitCode): $Command"
        }

        return $exitCode
    }
    catch {
        Write-Log "ERR(Exception): $Command - $($_.Exception.Message)"
        return 1
    }
}

function Test-ImageExists {
    $result = Invoke-DockerCommand "docker image inspect $script:IMAGE_NAME"
    return $result -eq 0
}

function Build-Image {
    param([string]$BuildMode = "")

    Write-Host "[BUILD] Building $script:IMAGE_NAME (python=$script:PYTHON_VERSION spark=$script:SPARK_VERSION delta=$script:DELTA_VERSION poetry=$script:POETRY_VERSION)" -ForegroundColor Green

    $env:DOCKER_BUILDKIT = "1"
    $cacheFlags = ""

    switch ($BuildMode) {
        "no_cache" { $cacheFlags = "--no-cache" }
        "pull" { $cacheFlags = "--pull" }
    }

    # Build the command with proper spacing
    $commandParts = @(
        "docker build"
        $cacheFlags
        "--platform=$script:PLATFORM"
        "--build-arg PYTHON_VERSION=$script:PYTHON_VERSION"
        "--build-arg SPARK_VERSION=$script:SPARK_VERSION"
        "--build-arg DELTA_VERSION=$script:DELTA_VERSION"
        "--build-arg POETRY_VERSION=$script:POETRY_VERSION"
        "-t $script:IMAGE_NAME"
        "."
    )

    $command = ($commandParts | Where-Object { $_ -ne "" }) -join " "

    return Invoke-DockerCommand $command
}

function Get-ContainerName {
    $rand = Get-Random -Minimum 1000 -Maximum 9999
    $containerName = "$script:CONTAINER_PREFIX-$rand"
    Write-Log "CNAME=$containerName"
    return $containerName
}

function Get-DockerMounts {
    $mountWorkspace = ""
    $mountWarehouse = ""

    if ($script:STORAGE_MODE -eq "bind") {
        if (!(Test-Path $script:HOST_WORKSPACE)) {
            New-Item -ItemType Directory -Path $script:HOST_WORKSPACE -Force | Out-Null
        }
        if (!(Test-Path $script:HOST_WAREHOUSE)) {
            New-Item -ItemType Directory -Path $script:HOST_WAREHOUSE -Force | Out-Null
        }
        $mountWorkspace = "-v `"$script:HOST_WORKSPACE`":/workspace"
        $mountWarehouse = "-v `"$script:HOST_WAREHOUSE`":/workspace/warehouse"
    }
    else {
        # Volume mode
        Invoke-DockerCommand "docker volume create ${script:VOL_WORKSPACE}" | Out-Null
        Invoke-DockerCommand "docker volume create ${script:VOL_WAREHOUSE}" | Out-Null
        $mountWorkspace = "-v ${script:VOL_WORKSPACE}:/workspace"
        $mountWarehouse = "-v ${script:VOL_WAREHOUSE}:/workspace/warehouse"
    }

    return $mountWorkspace, $mountWarehouse
}

function Get-EnvironmentVars {
    return "-e UC_CATALOG=$script:UC_CATALOG -e UC_SCHEMA=$script:UC_SCHEMA -e UC_WAREHOUSE=$script:UC_WAREHOUSE -e SPARK_BOOTSTRAP_UC=$script:SPARK_BOOTSTRAP_UC -e UC_DRY_RUN=$script:UC_DRY_RUN"
}

function Start-InteractiveMode {
    Write-Host "[MODE] Interactive shell" -ForegroundColor Cyan
    $containerName = Get-ContainerName
    $mountWorkspace, $mountWarehouse = Get-DockerMounts
    $envVars = Get-EnvironmentVars

    $command = "docker run --rm -it --name $containerName $envVars $mountWorkspace $mountWarehouse $script:IMAGE_NAME /bin/zsh -l"
    return Invoke-DockerCommand $command
}

function Start-TestMode {
    Write-Host "[MODE] Spark UC smoke test" -ForegroundColor Cyan
    $mountWorkspace, $mountWarehouse = Get-DockerMounts
    $envVars = Get-EnvironmentVars

    $testCommand = "echo '=== Namespaces in UC catalog ===' && spark-sql -S -e `"SHOW NAMESPACES IN `${UC_CATALOG:-$script:UC_CATALOG}`" && echo '=== Smoke test table contents ===' && spark-sql -S -e `"SELECT * FROM `${UC_CATALOG:-$script:UC_CATALOG}.`${UC_SCHEMA:-$script:UC_SCHEMA}.uc_smoke_test`""
    $command = "docker run --rm $envVars $mountWorkspace $mountWarehouse $script:IMAGE_NAME bash -lc `"$testCommand`""
    return Invoke-DockerCommand $command
}

function Start-VerifyMode {
    Write-Host "[MODE] Verify container startup" -ForegroundColor Cyan
    $mountWorkspace, $mountWarehouse = Get-DockerMounts
    $envVars = Get-EnvironmentVars

    $command = "docker run --rm $envVars $mountWorkspace $mountWarehouse $script:IMAGE_NAME bash -lc `"echo 'Container started successfully'; exit 0`""
    return Invoke-DockerCommand $command
}

function Start-StatusMode {
    Write-Host "[MODE] Status" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "[IMAGE] $script:IMAGE_NAME"
    if (Test-ImageExists) {
        Write-Host "  - present" -ForegroundColor Green
    } else {
        Write-Host "  - not present" -ForegroundColor Red
    }
    Write-Host ""

    Write-Host "[CONTAINERS] running with ancestor=$script:IMAGE_NAME"
    Invoke-DockerCommand "docker ps --filter `"ancestor=$script:IMAGE_NAME`" --format `"  - {{.ID}}  {{.Names}}  {{.Status}}`""
    Write-Host ""

    Write-Host "[RECENT] last 5 with ancestor=$script:IMAGE_NAME"
    Invoke-DockerCommand "docker ps -a --filter `"ancestor=$script:IMAGE_NAME`" --format `"  - {{.ID}}  {{.Names}}  {{.Status}}  {{.RunningFor}}`" --no-trunc"
    Write-Host ""

    if ($script:STORAGE_MODE -eq "bind") {
        Write-Host "[STORAGE] bind"
        Get-DirectorySize $script:HOST_WORKSPACE
        Get-DirectorySize $script:HOST_WAREHOUSE
    } else {
        Write-Host "[STORAGE] volumes"
        Get-VolumeSize $script:VOL_WORKSPACE
        Get-VolumeSize $script:VOL_WAREHOUSE
    }

    return 0
}

function Start-LogsMode {
    param([string]$TargetContainer = "")

    if (!$TargetContainer) {
        # Try to find from log file or running containers
        if (Test-Path $script:LOG_FILE) {
            $logContent = Get-Content $script:LOG_FILE | Where-Object { $_ -match "CNAME=" } | Select-Object -Last 1
            if ($logContent -match "CNAME=(.+)$") {
                $TargetContainer = $matches[1]
            }
        }

        if (!$TargetContainer) {
            # Fallback: latest container using this image
            try {
                $containers = & docker ps --filter "ancestor=$script:IMAGE_NAME" --format "{{.Names}}" 2>$null
                if ($containers) {
                    $TargetContainer = ($containers | Select-Object -First 1)
                }
            }
            catch { }
        }
    }

    if (!$TargetContainer) {
        Write-Host "[LOGS] No running container found. Provide a name: $($MyInvocation.MyCommand.Name) logs <container-name>" -ForegroundColor Red
        return 1
    }

    Write-Host "[LOGS] Attaching to: $TargetContainer" -ForegroundColor Cyan
    return Invoke-DockerCommand "docker logs -f `"$TargetContainer`""
}

function Start-CleanMode {
    Write-Host "[MODE] Clean image and data" -ForegroundColor Cyan
    Write-Host "WARNING: This will permanently delete:" -ForegroundColor Yellow
    Write-Host "  - Docker image: $script:IMAGE_NAME" -ForegroundColor Yellow

    if ($script:STORAGE_MODE -eq "bind") {
        Write-Host "  - Folders: $script:HOST_WORKSPACE and $script:HOST_WAREHOUSE" -ForegroundColor Yellow
    } else {
        Write-Host "  - Volumes: $script:VOL_WORKSPACE and $script:VOL_WAREHOUSE" -ForegroundColor Yellow
    }

    $confirm = Read-Host "Type YES to proceed"
    if ($confirm -ne "YES") {
        Write-Host "[CLEAN] Aborted by user." -ForegroundColor Yellow
        return 0
    }

    # Optional backup
    $backupConfirm = Read-Host "Backup data to compressed tar.gz before deletion (Y/N)?"
    if ($backupConfirm -eq "Y" -or $backupConfirm -eq "y") {
        $timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
        $backupFile = Join-Path $PWD "warehouse_backup_$timestamp.tar.gz"

        if ((Invoke-Backup $backupFile) -ne 0) {
            Write-Host "[CLEAN] Backup failed. Aborting." -ForegroundColor Red
            return 1
        }

        if ((Test-TarIntegrity $backupFile) -ne 0) {
            Write-Host "[CLEAN] Backup file failed integrity check. Aborting." -ForegroundColor Red
            return 1
        }

        Write-Host "[CLEAN] Backup complete: $backupFile" -ForegroundColor Green
    } else {
        Write-Host "[CLEAN] Skipping backup." -ForegroundColor Yellow
    }

    # Remove containers
    Write-Host "[CLEAN] Removing containers using image..." -ForegroundColor Cyan
    try {
        $containers = & docker ps -aq --filter "ancestor=$script:IMAGE_NAME" 2>$null
        if ($containers) {
            foreach ($container in $containers) {
                $result = Invoke-DockerCommand "docker rm -f $container"
                if ($result -ne 0) {
                    Write-Host "[WARN] Could not remove container $container" -ForegroundColor Yellow
                }
            }
        }
    }
    catch { }

    # Remove image
    Write-Host "[CLEAN] Removing image..." -ForegroundColor Cyan
    Invoke-DockerCommand "docker rmi -f $script:IMAGE_NAME" | Out-Null

    # Remove data
    Write-Host "[CLEAN] Removing data..." -ForegroundColor Cyan
    if ($script:STORAGE_MODE -eq "bind") {
        Remove-Directory $script:HOST_WORKSPACE
        Remove-Directory $script:HOST_WAREHOUSE
    } else {
        Invoke-DockerCommand "docker volume rm ${script:VOL_WORKSPACE}" | Out-Null
        Invoke-DockerCommand "docker volume rm ${script:VOL_WAREHOUSE}" | Out-Null
    }

    Write-Host "[CLEAN] Done." -ForegroundColor Green
    return 0
}

function Start-RestoreMode {
    Write-Host "[MODE] Restore data from tar.gz backup" -ForegroundColor Cyan
    $backupPath = Read-Host "Enter full path to backup .tar.gz"

    if (!(Test-Path $backupPath)) {
        Write-Host "[RESTORE] Backup file not found: $backupPath" -ForegroundColor Red
        return 1
    }

    Write-Host "WARNING: This will overwrite current data storage." -ForegroundColor Yellow
    $confirm = Read-Host "Type YES to proceed"
    if ($confirm -ne "YES") {
        Write-Host "[RESTORE] Aborted by user." -ForegroundColor Yellow
        return 0
    }

    # Preview current contents
    Write-Host "[RESTORE] Current contents preview:" -ForegroundColor Cyan
    if ($script:STORAGE_MODE -eq "bind") {
        if (Test-Path $script:HOST_WAREHOUSE) {
            Get-ChildItem $script:HOST_WAREHOUSE | Select-Object -First 20
        }
    } else {
        Invoke-DockerCommand "docker run --rm -v ${script:VOL_WAREHOUSE}:/dest alpine sh -lc `"ls -la /dest | head -n 50`""
    }

    # Restore
    Write-Host "[RESTORE] Restoring..." -ForegroundColor Cyan
    if ($script:STORAGE_MODE -eq "bind") {
        Remove-Directory $script:HOST_WAREHOUSE
        New-Item -ItemType Directory -Path $script:HOST_WAREHOUSE -Force | Out-Null
        $command = "docker run --rm -v `"$script:HOST_WAREHOUSE`":/dest -v `"$backupPath`":/backup.tar.gz alpine sh -lc `"cd /dest && tar -xzf /backup.tar.gz`""
        $result = Invoke-DockerCommand $command
    } else {
        Invoke-DockerCommand "docker volume rm ${script:VOL_WAREHOUSE}" | Out-Null
        Invoke-DockerCommand "docker volume create ${script:VOL_WAREHOUSE}" | Out-Null
        $command = "docker run --rm -v ${script:VOL_WAREHOUSE}:/dest -v `"$backupPath`":/backup.tar.gz alpine sh -lc `"cd /dest && tar -xzf /backup.tar.gz`""
        $result = Invoke-DockerCommand $command
    }

    Write-Host "[RESTORE] Restore complete." -ForegroundColor Green
    return $result
}

function Invoke-Backup {
    param([string]$OutputPath)

    Write-Host "[BACKUP] Creating compressed backup at $OutputPath" -ForegroundColor Cyan

    if ($script:STORAGE_MODE -eq "bind") {
        $srcMount = "-v `"$script:HOST_WAREHOUSE`":/src"
    } else {
        $srcMount = "-v ${script:VOL_WAREHOUSE}:/src"
    }

    $tempFile = Join-Path $PWD "__tmp_backup.tar.gz"
    $command = "docker run --rm $srcMount -v `"$PWD`":/dest alpine sh -lc `"cd /src && tar -czf /dest/__tmp_backup.tar.gz .`""
    $result = Invoke-DockerCommand $command

    if ($result -eq 0 -and (Test-Path $tempFile)) {
        if (Test-Path $OutputPath) {
            Remove-Item $OutputPath -Force
        }
        Move-Item $tempFile $OutputPath
        return 0
    }

    return 1
}

function Test-TarIntegrity {
    param([string]$ArchivePath)

    Write-Host "[VERIFY] Checking archive integrity: $ArchivePath" -ForegroundColor Cyan
    if (!(Test-Path $ArchivePath)) {
        return 1
    }

    $command = "docker run --rm -v `"$ArchivePath`":/archive.tar.gz alpine sh -lc `"tar -tzf /archive.tar.gz >/dev/null`""
    return Invoke-DockerCommand $command
}

function Remove-Directory {
    param([string]$Path)

    if (!(Test-Path $Path)) {
        return
    }

    Write-Host "[CLEAN] Removing directory: $Path" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "DRY-RUN: Remove-Item `"$Path`" -Recurse -Force" -ForegroundColor Yellow
        return
    }

    Remove-Item $Path -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-DirectorySize {
    param([string]$Path)

    if (!(Test-Path $Path)) {
        Write-Host "[DIR] $Path (missing)"
        return
    }

    try {
        $size = (Get-ChildItem -Recurse -Force -ErrorAction SilentlyContinue $Path | Measure-Object -Property Length -Sum).Sum
        if (!$size) { $size = 0 }
        Write-Host "[DIR] $Path size=$size bytes"
    }
    catch {
        Write-Host "[DIR] $Path size=unknown"
    }
}

function Get-VolumeSize {
    param([string]$VolumeName)

    try {
        $command = "docker run --rm -v ${VolumeName}:/v alpine sh -lc `"du -sb /v 2>/dev/null | awk '{print `$1}'`""
        $size = & docker run --rm -v "${VolumeName}:/v" alpine sh -lc "du -sb /v 2>/dev/null | awk '{print `$1}'" 2>$null
        if (!$size) { $size = 0 }
        Write-Host "[VOL] $VolumeName size=$size bytes"
    }
    catch {
        Write-Host "[VOL] $VolumeName size=unknown"
    }
}

# ------------- Pre-flight checks -------------
if (!(Test-Docker)) {
    Write-Log "FATAL: Docker not available"
    exit 1
}

# ------------- Build if needed -------------
switch ($Mode.ToLower()) {
    "rebuild" {
        if ((Build-Image "no_cache") -ne 0) {
            Write-Log "FATAL: Build failed"
            exit 1
        }
    }
    "update" {
        if ((Build-Image "pull") -ne 0) {
            Write-Log "FATAL: Build failed"
            exit 1
        }
    }
    default {
        if (!(Test-ImageExists)) {
            if ((Build-Image) -ne 0) {
                Write-Log "FATAL: Build failed"
                exit 1
            }
        }
    }
}

# ------------- Dispatch to mode -------------
$exitCode = 0

switch ($Mode.ToLower()) {
    "interact" { $exitCode = Start-InteractiveMode }
    "rebuild" { $exitCode = Start-InteractiveMode }
    "test" { $exitCode = Start-TestMode }
    "verify" { $exitCode = Start-VerifyMode }
    "clean" { $exitCode = Start-CleanMode }
    "restore" { $exitCode = Start-RestoreMode }
    "status" { $exitCode = Start-StatusMode }
    "logs" { $exitCode = Start-LogsMode }
    "update" {
        $exitCode = Start-StatusMode
    }
    default {
        Write-Host "[ERROR] Unknown mode: $Mode" -ForegroundColor Red
        Write-Host "Usage: $($MyInvocation.MyCommand.Name) [interact|test|verify|rebuild|clean|restore|status|logs|update] [-DryRun]" -ForegroundColor White
        $exitCode = 1
    }
}

Write-Log "=== END mode=$Mode rc=$exitCode ts=$(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss') ==="
exit $exitCode

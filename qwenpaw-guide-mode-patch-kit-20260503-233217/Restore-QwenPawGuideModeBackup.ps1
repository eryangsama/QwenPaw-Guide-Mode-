param(
    [string]$BackupDir = "",
    [string]$QwenPawRoot = "",
    [switch]$StartAfterRestore,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Resolve-LatestBackup {
    param([string]$RequestedBackup)

    if ($RequestedBackup -and $RequestedBackup.Trim().Length -gt 0) {
        if (Test-Path -LiteralPath $RequestedBackup) {
            return (Resolve-Path -LiteralPath $RequestedBackup).Path
        }
        throw "Backup dir not found: $RequestedBackup"
    }

    $root = Join-Path ([Environment]::GetFolderPath("Desktop")) "QwenPaw-guide-mode-patch-backups"
    if (-not (Test-Path -LiteralPath $root)) {
        throw "Backup root not found: $root"
    }

    $latest = Get-ChildItem -LiteralPath $root -Directory |
        Where-Object { $_.Name -like "backup-*" } |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1

    if (-not $latest) {
        throw "No backup-* folder found under $root"
    }

    return $latest.FullName
}

function Start-QwenPawDesktop {
    param([string]$Root)

    $vbs = Join-Path $Root "QwenPaw Desktop.vbs"
    $bat = Join-Path $Root "QwenPaw Desktop.bat"

    if (Test-Path -LiteralPath $vbs) {
        Start-Process -FilePath "wscript.exe" -ArgumentList "`"$vbs`"" -WindowStyle Hidden
        return
    }

    if (Test-Path -LiteralPath $bat) {
        Start-Process -FilePath $bat -WindowStyle Hidden
        return
    }

    Write-Warning "QwenPaw launcher not found. Start QwenPaw manually."
}

$resolvedBackup = Resolve-LatestBackup -RequestedBackup $BackupDir
$manifestPath = Join-Path $resolvedBackup "backup-manifest.json"
$originalRoot = Join-Path $resolvedBackup "original"

if (-not (Test-Path -LiteralPath $manifestPath)) {
    throw "Backup manifest not found: $manifestPath"
}
if (-not (Test-Path -LiteralPath $originalRoot)) {
    throw "Original backup folder not found: $originalRoot"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if (-not $QwenPawRoot -or $QwenPawRoot.Trim().Length -eq 0) {
    $QwenPawRoot = $manifest.qwenPawRoot
}
if (-not (Test-Path -LiteralPath $QwenPawRoot)) {
    throw "QwenPaw root not found: $QwenPawRoot"
}

Write-Host "Restoring backup: $resolvedBackup"
Write-Host "QwenPaw root:      $QwenPawRoot"

$restored = 0
foreach ($relative in $manifest.payloadFiles) {
    $source = Join-Path $originalRoot $relative
    $destination = Join-Path $QwenPawRoot $relative

    if (-not (Test-Path -LiteralPath $source)) {
        Write-Warning "No original backup for $relative; leaving current file in place."
        continue
    }

    if ($DryRun) {
        Write-Host "[dry-run] restore $relative"
        continue
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $source -Destination $destination -Force
    $restored += 1
}

if (-not $DryRun) {
    foreach ($relative in $manifest.payloadFiles) {
        if ($relative.EndsWith(".py")) {
            $cache = Join-Path (Split-Path -Parent (Join-Path $QwenPawRoot $relative)) "__pycache__"
            if (Test-Path -LiteralPath $cache) {
                Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

if ($StartAfterRestore -and -not $DryRun) {
    Start-QwenPawDesktop -Root $QwenPawRoot
}

Write-Host "Restore complete. Restored files: $restored"

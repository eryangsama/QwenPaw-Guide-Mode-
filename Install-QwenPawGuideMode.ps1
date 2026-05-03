param(
    [string]$QwenPawRoot = "",
    [string]$BackupRoot = "",
    [switch]$StartAfterInstall,
    [switch]$NoVerify,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Resolve-QwenPawRoot {
    param([string]$RequestedRoot)

    if ($RequestedRoot -and $RequestedRoot.Trim().Length -gt 0) {
        if (Test-Path -LiteralPath $RequestedRoot) {
            return (Resolve-Path -LiteralPath $RequestedRoot).Path
        }
        throw "QwenPaw root not found: $RequestedRoot"
    }

    $candidates = @(
        "D:\QwenPaw",
        "C:\QwenPaw",
        (Join-Path $env:LOCALAPPDATA "Programs\QwenPaw"),
        (Join-Path $env:ProgramFiles "QwenPaw")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate "Lib\site-packages\qwenpaw")) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "Could not find QwenPaw. Re-run with -QwenPawRoot 'D:\QwenPaw' or your actual install path."
}

function Copy-WithBackup {
    param(
        [string]$Source,
        [string]$Destination,
        [string]$RelativePath,
        [string]$BackupOriginalRoot,
        [bool]$DryRunMode
    )

    $destinationParent = Split-Path -Parent $Destination
    $backupDestination = Join-Path $BackupOriginalRoot $RelativePath
    $backupParent = Split-Path -Parent $backupDestination

    if ($DryRunMode) {
        Write-Host "[dry-run] patch $RelativePath"
        return [pscustomobject]@{
            path = $RelativePath
            targetExisted = (Test-Path -LiteralPath $Destination)
            backedUp = $false
            patched = $false
        }
    }

    New-Item -ItemType Directory -Path $destinationParent -Force | Out-Null
    New-Item -ItemType Directory -Path $backupParent -Force | Out-Null

    $targetExisted = Test-Path -LiteralPath $Destination
    if ($targetExisted) {
        Copy-Item -LiteralPath $Destination -Destination $backupDestination -Force
    }

    Copy-Item -LiteralPath $Source -Destination $Destination -Force

    return [pscustomobject]@{
        path = $RelativePath
        targetExisted = $targetExisted
        backedUp = $targetExisted
        patched = $true
    }
}

function Clear-QwenPawPyCache {
    param(
        [string]$Root,
        [string[]]$PayloadFiles,
        [bool]$DryRunMode
    )

    $pyParents = New-Object System.Collections.Generic.HashSet[string]
    foreach ($relative in $PayloadFiles) {
        if ($relative.EndsWith(".py")) {
            $parent = Split-Path -Parent (Join-Path $Root $relative)
            [void]$pyParents.Add($parent)
        }
    }

    foreach ($parent in $pyParents) {
        $cache = Join-Path $parent "__pycache__"
        if (Test-Path -LiteralPath $cache) {
            if ($DryRunMode) {
                Write-Host "[dry-run] clear $cache"
            } else {
                Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
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

$scriptRoot = $PSScriptRoot
if (-not $scriptRoot) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$resolvedRoot = Resolve-QwenPawRoot -RequestedRoot $QwenPawRoot

if (-not $BackupRoot -or $BackupRoot.Trim().Length -eq 0) {
    $BackupRoot = Join-Path ([Environment]::GetFolderPath("Desktop")) "QwenPaw-guide-mode-patch-backups"
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $BackupRoot "backup-$timestamp"
$originalBackupDir = Join-Path $backupDir "original"

Write-Host "QwenPaw root:  $resolvedRoot"
Write-Host "Backup dir:     $backupDir"

$payloadFilesList = @(
    "Lib\site-packages\qwenpaw\app\runner\guidance.py",
    "Lib\site-packages\qwenpaw\app\runner\control_commands\guide_handler.py",
    "Lib\site-packages\qwenpaw\app\runner\control_commands\__init__.py",
    "Lib\site-packages\qwenpaw\app\routers\console.py",
    "Lib\site-packages\qwenpaw\app\channels\base.py",
    "Lib\site-packages\qwenpaw\app\channels\command_registry.py",
    "Lib\site-packages\qwenpaw\agents\react_agent.py",
    "Lib\site-packages\qwenpaw\console\assets\index-CxhEuw8i.js",
    "Lib\site-packages\qwenpaw\console\assets\ui-vendor-DSFWj0or.js",
    "Lib\site-packages\qwenpaw\console\index.html"
)

$payloadBase = Join-Path $scriptRoot "payload"
$allOk = $true
$patchedList = @()
$skippedList = @()

foreach ($relative in $payloadFilesList) {
    $source = Join-Path $payloadBase $relative
    $destination = Join-Path $resolvedRoot $relative

    if (-not (Test-Path -LiteralPath $source)) {
        Write-Host "[SKIP] payload missing: $relative" -ForegroundColor Yellow
        $skippedList += $relative
        continue
    }

    $result = Copy-WithBackup -Source $source -Destination $destination -RelativePath $relative -BackupOriginalRoot $originalBackupDir -DryRunMode $DryRun

    if ($DryRun) {
        Write-Host "[dry-run] would patch: $($result.path)" -ForegroundColor Cyan
        if ($result.targetExisted) {
            Write-Host "         (backed up original)" -ForegroundColor DarkGray
        }
    } else {
        $color = if ($result.patched) { "Green" } else { "Yellow" }
        $label = if ($result.patched) { "[PATCHED]" } else { "[SKIPPED]" }
        Write-Host "$label $($result.path)" -ForegroundColor $color
        if ($result.backedUp) {
            Write-Host "       backed up original" -ForegroundColor DarkGray
        }
        $patchedList += $result.path
    }
}

if (-not $DryRun) {
    Clear-QwenPawPyCache -Root $resolvedRoot -PayloadFiles $payloadFilesList -DryRunMode $false

    $manifest = @{
        timestamp   = $timestamp
        qwenPawRoot = $resolvedRoot
        payloadFiles = $payloadFilesList
    }
    $manifestPath = Join-Path $backupDir "backup-manifest.json"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
    Set-Content -LiteralPath $manifestPath -Value ($manifest | ConvertTo-Json -Depth 3) -Encoding UTF8

    Write-Host ""
    Write-Host "Backup saved to: $backupDir" -ForegroundColor Cyan
    Write-Host "Patched $($patchedList.Count) file(s)." -ForegroundColor Green
    if ($skippedList.Count -gt 0) {
        Write-Host "Skipped $($skippedList.Count) file(s) (not in payload)." -ForegroundColor Yellow
    }

    if (-not $NoVerify) {
        Write-Host ""
        Write-Host "Running verification..." -ForegroundColor Cyan
        $verifyScript = Join-Path $scriptRoot "Verify-QwenPawGuideMode.ps1"
        if (Test-Path -LiteralPath $verifyScript) {
            & $verifyScript -QwenPawRoot $resolvedRoot
        } else {
            Write-Host "Verify script not found, skipping verification." -ForegroundColor Yellow
        }
    }

    if ($StartAfterInstall) {
        Write-Host ""
        Write-Host "Starting QwenPaw Desktop..." -ForegroundColor Cyan
        Start-QwenPawDesktop -Root $resolvedRoot
    }
}

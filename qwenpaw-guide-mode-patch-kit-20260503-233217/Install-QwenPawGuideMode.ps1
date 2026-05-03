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

$kitRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$payloadRoot = Join-Path $kitRoot "payload"
$payloadList = Join-Path $kitRoot "payload-files.txt"

if (-not (Test-Path -LiteralPath $payloadRoot)) {
    throw "Payload folder not found: $payloadRoot"
}
if (-not (Test-Path -LiteralPath $payloadList)) {
    throw "Payload file list not found: $payloadList"
}

$targetRoot = Resolve-QwenPawRoot -RequestedRoot $QwenPawRoot
if (-not $BackupRoot -or $BackupRoot.Trim().Length -eq 0) {
    $BackupRoot = Join-Path ([Environment]::GetFolderPath("Desktop")) "QwenPaw-guide-mode-patch-backups"
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $BackupRoot "backup-$timestamp"
$backupOriginalRoot = Join-Path $backupDir "original"
$payloadFiles = Get-Content -LiteralPath $payloadList | Where-Object { $_.Trim().Length -gt 0 }

Write-Host "QwenPaw root: $targetRoot"
Write-Host "Patch kit:    $kitRoot"
Write-Host "Backup dir:   $backupDir"

if (-not $DryRun) {
    New-Item -ItemType Directory -Path $backupOriginalRoot -Force | Out-Null
}

$records = @()
foreach ($relative in $payloadFiles) {
    $source = Join-Path $payloadRoot $relative
    $destination = Join-Path $targetRoot $relative

    if (-not (Test-Path -LiteralPath $source)) {
        throw "Payload file missing: $source"
    }

    if (-not (Test-Path -LiteralPath $destination)) {
        Write-Warning "Target file does not exist yet; it will be created: $relative"
    }

    $records += Copy-WithBackup -Source $source -Destination $destination -RelativePath $relative -BackupOriginalRoot $backupOriginalRoot -DryRunMode ([bool]$DryRun)
}

Clear-QwenPawPyCache -Root $targetRoot -PayloadFiles $payloadFiles -DryRunMode ([bool]$DryRun)

if (-not $DryRun) {
    $manifest = [pscustomobject]@{
        installedAt = (Get-Date).ToString("s")
        qwenPawRoot = $targetRoot
        patchKit = $kitRoot
        payloadFiles = $payloadFiles
        records = $records
    }
    $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $backupDir "backup-manifest.json") -Encoding UTF8
}

if (-not $NoVerify -and -not $DryRun) {
    $verifyScript = Join-Path $kitRoot "Verify-QwenPawGuideMode.ps1"
    if (Test-Path -LiteralPath $verifyScript) {
        & $verifyScript -QwenPawRoot $targetRoot
    }
}

if ($StartAfterInstall -and -not $DryRun) {
    Start-QwenPawDesktop -Root $targetRoot
}

if ($DryRun) {
    Write-Host "Dry run complete. No files changed."
    Write-Host "Backup would be saved at: $backupDir"
} else {
    Write-Host "Guide mode patch installed."
    Write-Host "Backup saved at: $backupDir"
}

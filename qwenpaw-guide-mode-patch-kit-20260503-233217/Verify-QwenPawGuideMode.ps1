param(
    [string]$QwenPawRoot = "D:\QwenPaw"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $QwenPawRoot)) {
    throw "QwenPaw root not found: $QwenPawRoot"
}

$guideWord = ([string][char]0x5f15) + ([string][char]0x5bfc)
$guideCommand = ([string][char]47) + $guideWord

$checks = @(
    @{
        path = "Lib\site-packages\qwenpaw\app\runner\control_commands\guide_handler.py"
        patterns = @("ChineseGuideAliasCommandHandler", ('command_name = "' + $guideCommand + '"'))
    },
    @{
        path = "Lib\site-packages\qwenpaw\app\runner\control_commands\__init__.py"
        patterns = @("ChineseGuideAliasCommandHandler")
    },
    @{
        path = "Lib\site-packages\qwenpaw\app\routers\console.py"
        patterns = @("Console guide queued", $guideWord)
    },
    @{
        path = "Lib\site-packages\qwenpaw\app\channels\command_registry.py"
        patterns = @(('"' + $guideCommand + '"'))
    },
    @{
        path = "Lib\site-packages\qwenpaw\agents\react_agent.py"
        patterns = @("Guidance action guard", "_force_guidance_action_if_text_only")
    },
    @{
        path = "Lib\site-packages\qwenpaw\console\index.html"
        patterns = @("guide-20260503-2258", "index-CxhEuw8i.js")
    },
    @{
        path = "Lib\site-packages\qwenpaw\console\assets\ui-vendor-DSFWj0or.js"
        patterns = @("/api/console/guide", $guideWord)
    }
)

$failed = @()
foreach ($check in $checks) {
    $fullPath = Join-Path $QwenPawRoot $check.path
    if (-not (Test-Path -LiteralPath $fullPath)) {
        $failed += "missing file: $($check.path)"
        continue
    }

    $content = Get-Content -LiteralPath $fullPath -Raw -Encoding UTF8
    foreach ($pattern in $check.patterns) {
        if (-not $content.Contains($pattern)) {
            $failed += "missing pattern '$pattern' in $($check.path)"
        }
    }
}

$python = Join-Path $QwenPawRoot "python.exe"
if (Test-Path -LiteralPath $python) {
    $code = "from qwenpaw.app.runner import control_commands; key=chr(47)+chr(0x5f15)+chr(0x5bfc); print(key in control_commands._COMMAND_REGISTRY)"
    $result = & $python -c $code 2>&1
    if ($LASTEXITCODE -ne 0 -or (($result | Select-Object -Last 1) -ne "True")) {
        $failed += "python import check failed: $result"
    }
}

if ($failed.Count -gt 0) {
    Write-Host "Guide mode verification failed:" -ForegroundColor Red
    foreach ($item in $failed) {
        Write-Host " - $item" -ForegroundColor Red
    }
    exit 1
}

Write-Host "Guide mode verification passed." -ForegroundColor Green

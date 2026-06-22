$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$script = Join-Path $root 'scripts\SafeBootMegaCleanup.ps1'
$launcher = Join-Path $root 'Run-SafeBootMegaCleanup.cmd'

if (-not (Test-Path -LiteralPath $script)) {
    throw "Missing script: $script"
}

if (-not (Test-Path -LiteralPath $launcher)) {
    throw "Missing launcher: $launcher"
}

$tokens = $null
$errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors.Count -gt 0) {
    $errors | Format-List | Out-String | Write-Error
    throw "PowerShell parser reported $($errors.Count) error(s)."
}

$content = Get-Content -LiteralPath $script -Raw
[scriptblock]::Create($content) | Out-Null

$requiredPatterns = @(
    'ms-contact-support',
    'ms-get-started',
    'B23D10C0-E52E-411E-9D5B-C09FDF709C7D',
    'SafeBootMegaCleanupFallback',
    '*SafeBootMegaCleanupVisible',
    '/d /k',
    'safebootalternateshell',
    'Control\SafeBoot\Minimal\Schedule',
    'Removing stale payload lock',
    'Get-Process -Id $existing.Pid',
    'AppData\Local\Temp',
    'del /f /s /q C:\*.tmp C:\*.temp',
    'Clear-RecycleBin',
    'C:\SafeBootMegaCleanup.log'
)

foreach ($pattern in $requiredPatterns) {
    if ($content -notlike "*$pattern*") {
        throw "Required marker missing from script: $pattern"
    }
}

$forbiddenPatterns = @(
    'WindowsApps\wt.exe',
    'wt.exe -',
    'start ms-contact-support',
    'AutoRun -PropertyType String'
)

foreach ($pattern in $forbiddenPatterns) {
    if ($content -like "*$pattern*") {
        throw "Forbidden fragile marker present in script: $pattern"
    }
}

$launcherContent = Get-Content -LiteralPath $launcher -Raw
if ($launcherContent -notlike '*scripts\SafeBootMegaCleanup.ps1*') {
    throw 'Launcher does not point to scripts\SafeBootMegaCleanup.ps1'
}

"SAFEBOOT_MEGA_CLEANUP_TEST_OK tokens=$($tokens.Count)"

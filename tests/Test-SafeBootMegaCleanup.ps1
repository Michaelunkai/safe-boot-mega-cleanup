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
    'B23D10C0-E52E-411E-9D5B-C09FDF709C7D',
    'SafeBootMegaCleanupFallback',
    'safebootalternateshell',
    'C:\SafeBootMegaCleanup.log'
)

foreach ($pattern in $requiredPatterns) {
    if ($content -notlike "*$pattern*") {
        throw "Required marker missing from script: $pattern"
    }
}

"SAFEBOOT_MEGA_CLEANUP_TEST_OK tokens=$($tokens.Count)"

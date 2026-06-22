[CmdletBinding()]
param(
    [ValidateSet('Install', 'Payload', 'ReturnNormal')]
    [string]$Mode = 'Install',

    [string]$Source = 'Manual'
)

$ErrorActionPreference = 'SilentlyContinue'

$Root = 'C:\ProgramData\SafeBootMegaCleanup'
$InstalledScript = Join-Path $Root 'SafeBootMegaCleanup.ps1'
$LauncherCmd = Join-Path $Root 'SafeBootMegaCleanup.cmd'
$LockPath = Join-Path $Root 'payload.lock.json'
$LogPath = 'C:\SafeBootMegaCleanup.log'
$Ps5 = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
$ConsoleHostGuid = '{B23D10C0-E52E-411E-9D5B-C09FDF709C7D}'

function Write-Step {
    param([string]$Message)

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Mode, $Message
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding ASCII -ErrorAction SilentlyContinue
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-AdminOrElevate {
    if (Test-IsAdmin) {
        return
    }

    if (-not $PSCommandPath) {
        throw 'Run this script from a saved .ps1 file, not from an unsaved console paste.'
    }

    Start-Process -FilePath $Ps5 -Verb RunAs -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $PSCommandPath),
        '-Mode', $Mode,
        '-Source', $Source
    )
    exit
}

function Set-ConsoleHostHive {
    param([string]$Base)

    $console = Join-Path $Base 'Console'
    $startup = Join-Path $console '%%Startup'
    New-Item -Path $console -Force | Out-Null
    New-Item -Path $startup -Force | Out-Null
    New-ItemProperty -Path $startup -Name DelegationConsole -PropertyType String -Value $ConsoleHostGuid -Force | Out-Null
    New-ItemProperty -Path $startup -Name DelegationTerminal -PropertyType String -Value $ConsoleHostGuid -Force | Out-Null
}

function Set-ConsoleHostEverywhere {
    Write-Step 'Forcing Windows Console Host instead of Windows Terminal/wt.exe.'
    Set-ConsoleHostHive 'HKCU:\'

    Get-ChildItem Registry::HKEY_USERS -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^S-\d-|^\.DEFAULT$' } |
        ForEach-Object { Set-ConsoleHostHive ('Registry::HKEY_USERS\' + $_.PSChildName) }

    $profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    Get-ChildItem $profileList -ErrorAction SilentlyContinue | ForEach-Object {
        $sid = $_.PSChildName
        if (-not (Test-Path ('Registry::HKEY_USERS\' + $sid))) {
            $profile = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProfileImagePath
            if ($profile) {
                $ntUser = Join-Path ([Environment]::ExpandEnvironmentVariables($profile)) 'NTUSER.DAT'
                if (Test-Path -LiteralPath $ntUser) {
                    $tempHive = 'CodexSafeBootTemp_' + ($sid -replace '[^A-Za-z0-9]', '_')
                    & reg.exe load ('HKU\' + $tempHive) $ntUser *> $null
                    if ($LASTEXITCODE -eq 0) {
                        Set-ConsoleHostHive ('Registry::HKEY_USERS\' + $tempHive)
                        & reg.exe unload ('HKU\' + $tempHive) *> $null
                    }
                }
            }
        }
    }
}

function Register-DummyProtocol {
    param([string]$Scheme)

    Write-Step ("Suppressing missing URI handler popup for {0}:." -f $Scheme)
    $key = "HKLM\SOFTWARE\Classes\$Scheme"
    $commandKey = "$key\shell\open\command"
    & reg.exe add $key /ve /t REG_SZ /d "URL:$Scheme" /f *> $null
    & reg.exe add $key /v 'URL Protocol' /t REG_SZ /d '' /f *> $null
    & reg.exe add $commandKey /ve /t REG_SZ /d '"C:\Windows\System32\cmd.exe" /d /c exit' /f *> $null
}

function Remove-BadStartupEntries {
    Write-Step 'Removing startup entries that can relaunch wt.exe, ms-contact-support, or stale cleanup state.'
    $bad = 'wt\.exe|WindowsApps\\wt\.exe|ms-contact-support|SafeBootMegaCleanup|OneTimeSafeModeTempCleanup'
    $runKeys = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    )

    foreach ($key in $runKeys) {
        if (-not (Test-Path $key)) {
            continue
        }

        (Get-ItemProperty $key).PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS' -and ([string]$_.Value) -match $bad } |
            ForEach-Object {
                Write-Step ("Removing startup value {0}\{1}" -f $key, $_.Name)
                Remove-ItemProperty -Path $key -Name $_.Name -Force -ErrorAction SilentlyContinue
            }
    }

    New-Item -Path 'HKLM:\SOFTWARE\Microsoft\Command Processor' -Force | Out-Null
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Command Processor' -Name AutoRun -ErrorAction SilentlyContinue
}

function Reset-SafeBootShell {
    Write-Step 'Resetting SafeBoot alternate shell to plain cmd.exe.'
    Get-ChildItem HKLM:\SYSTEM -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^ControlSet\d{3}$|^CurrentControlSet$' } |
        ForEach-Object {
            $controlSet = $_.PSChildName
            $safeBoot = "HKLM:\SYSTEM\$controlSet\Control\SafeBoot"
            if (Test-Path $safeBoot) {
                Set-ItemProperty -Path $safeBoot -Name AlternateShell -Value 'cmd.exe' -Force
                & reg.exe add "HKLM\SYSTEM\$controlSet\Control\SafeBoot\Minimal\Schedule" /ve /t REG_SZ /d Service /f *> $null
            }
        }

    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name Shell -Value 'explorer.exe' -Force
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -Name Userinit -Value 'C:\Windows\system32\userinit.exe,' -Force
}

function Remove-OldArtifacts {
    Write-Step 'Removing stale tasks, locks, and old one-liner artifacts.'
    Unregister-ScheduledTask -TaskName 'OneTimeSafeModeTempCleanupFallback' -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName 'SafeBootMegaCleanupFallback' -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'C:\ProgramData\OneTimeSafeBootTempCleanup\started.lock' -Force -ErrorAction SilentlyContinue
}

function Write-InstalledFiles {
    Write-Step 'Writing installed payload and visible command launcher.'
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Copy-Item -LiteralPath $PSCommandPath -Destination $InstalledScript -Force

    $cmdLines = @(
        '@echo off',
        'title SAFE MODE MEGA CLEANUP - CLASSIC CONSOLE HOST',
        'echo SAFE MODE MEGA CLEANUP STARTED - DO NOT CLOSE',
        ('"{0}" -NoProfile -ExecutionPolicy Bypass -File "{1}" -Mode Payload -Source VisibleCmd' -f $Ps5, $InstalledScript),
        'echo.',
        'echo Payload returned. If this window remains, read C:\SafeBootMegaCleanup.log',
        'timeout /t 10'
    )
    Set-Content -LiteralPath $LauncherCmd -Value $cmdLines -Encoding ASCII -Force
}

function Register-Launchers {
    Write-Step 'Registering Safe Mode visible RunOnce launcher and SYSTEM fallback.'
    $runOnce = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
    New-Item -Path $runOnce -Force | Out-Null
    New-ItemProperty -Path $runOnce -Name '*SafeBootMegaCleanupVisible' -PropertyType String -Value ('"{0}" /d /k "{1}"' -f "$env:SystemRoot\System32\cmd.exe", $LauncherCmd) -Force | Out-Null

    $fallbackScript = "Start-Sleep -Seconds 45; & '$InstalledScript' -Mode Payload -Source StartupFallback"
    $fallbackEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($fallbackScript))
    Register-ScheduledTask -TaskName 'SafeBootMegaCleanupFallback' `
        -Action (New-ScheduledTaskAction -Execute $Ps5 -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $fallbackEncoded") `
        -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Principal (New-ScheduledTaskPrincipal -UserId SYSTEM -RunLevel Highest) `
        -Force | Out-Null
}

function Set-SafeBootAndReboot {
    Write-Step 'Arming Safe Mode with Command Prompt and rebooting immediately.'
    & bcdedit.exe /deletevalue '{current}' safeboot *> $null
    & bcdedit.exe /deletevalue '{current}' safebootalternateshell *> $null

    & bcdedit.exe /set '{current}' safeboot minimal | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'bcdedit failed to set safeboot minimal.'
    }

    & bcdedit.exe /set '{current}' safebootalternateshell yes | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'bcdedit failed to set safebootalternateshell yes.'
    }

    shutdown.exe /r /t 0 /f
}

function Clear-SafeBoot {
    Write-Step 'Clearing SafeBoot flags so the next boot is normal.'
    & bcdedit.exe /deletevalue '{current}' safeboot *> $null
    & bcdedit.exe /deletevalue '{current}' safebootalternateshell *> $null
}

function Acquire-PayloadLock {
    if (Test-Path -LiteralPath $LockPath) {
        $existing = Get-Content -LiteralPath $LockPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($existing -and $existing.Pid -and (Get-Process -Id $existing.Pid -ErrorAction SilentlyContinue)) {
            Write-Step ("Another payload is already running with PID {0}; this instance exits." -f $existing.Pid)
            return $false
        }

        Write-Step 'Removing stale payload lock.'
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
    }

    @{ Pid = $PID; Started = (Get-Date).ToString('o'); Source = $Source } |
        ConvertTo-Json -Compress |
        Set-Content -LiteralPath $LockPath -Encoding ASCII -Force
    return $true
}

function Clear-TempTarget {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    Write-Step ("Clearing contents of {0}" -f $Path)
    Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

function Invoke-TempCleanup {
    Write-Step 'Starting temporary-file cleanup.'
    $targets = @(
        'C:\Windows\Temp',
        'C:\Windows\Prefetch',
        'C:\Windows\SoftwareDistribution\Download',
        'C:\Windows\LiveKernelReports',
        'C:\Windows\Minidump',
        'C:\ProgramData\Microsoft\Windows\WER\ReportArchive',
        'C:\ProgramData\Microsoft\Windows\WER\ReportQueue',
        'C:\ProgramData\Microsoft\Windows\DeliveryOptimization\Cache'
    )

    Get-ChildItem -LiteralPath 'C:\Users' -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $targets += @(
            (Join-Path $_.FullName 'AppData\Local\Temp'),
            (Join-Path $_.FullName 'AppData\Local\CrashDumps'),
            (Join-Path $_.FullName 'AppData\Local\Microsoft\Windows\INetCache')
        )
    }

    foreach ($target in ($targets | Where-Object { $_ } | Sort-Object -Unique)) {
        Clear-TempTarget -Path $target
    }

    Write-Step 'Deleting C:\*.tmp and C:\*.temp recursively through cmd.exe /d.'
    & "$env:SystemRoot\System32\cmd.exe" /d /c 'del /f /s /q C:\*.tmp C:\*.temp 2>nul'

    Write-Step 'Clearing C: recycle bin.'
    if (Get-Command Clear-RecycleBin -ErrorAction SilentlyContinue) {
        Clear-RecycleBin -DriveLetter C -Force -ErrorAction SilentlyContinue
    } else {
        Remove-Item -LiteralPath 'C:\$Recycle.Bin\*' -Recurse -Force -ErrorAction SilentlyContinue
    }

    Write-Step 'Temporary-file cleanup complete.'
}

function Invoke-Install {
    Require-AdminOrElevate
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Write-Step 'Installing SafeBootMegaCleanup.'

    Set-ConsoleHostEverywhere
    Register-DummyProtocol -Scheme 'ms-contact-support'
    Register-DummyProtocol -Scheme 'ms-get-started'
    Remove-BadStartupEntries
    Reset-SafeBootShell
    Remove-OldArtifacts
    Write-InstalledFiles
    Register-Launchers
    Set-SafeBootAndReboot
}

function Invoke-Payload {
    Require-AdminOrElevate
    New-Item -ItemType Directory -Path $Root -Force | Out-Null

    if (-not (Acquire-PayloadLock)) {
        return
    }

    Start-Transcript -Path $LogPath -Append | Out-Null
    try {
        Write-Step ("Payload started from {0}." -f $Source)
        Set-ConsoleHostEverywhere
        Register-DummyProtocol -Scheme 'ms-contact-support'
        Register-DummyProtocol -Scheme 'ms-get-started'
        Remove-BadStartupEntries
        Reset-SafeBootShell
        Invoke-TempCleanup
        Clear-SafeBoot
        Write-Step 'Payload finished; rebooting back to normal mode.'
    } finally {
        Remove-Item -LiteralPath $LockPath -Force -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName 'SafeBootMegaCleanupFallback' -Confirm:$false -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name '*SafeBootMegaCleanupVisible' -ErrorAction SilentlyContinue
        Clear-SafeBoot
        Stop-Transcript | Out-Null
        shutdown.exe /r /t 0 /f
    }
}

switch ($Mode) {
    'Install' { Invoke-Install }
    'Payload' { Invoke-Payload }
    'ReturnNormal' {
        Require-AdminOrElevate
        Clear-SafeBoot
        shutdown.exe /r /t 0 /f
    }
}

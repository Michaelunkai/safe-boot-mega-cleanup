# Safe Boot Mega Cleanup

Windows PowerShell 5 automation for a one-time Safe Mode cleanup pass.

## Purpose

This project packages `SafeBootMegaCleanup.ps1`, a Windows-only repair/cleanup script that:

- Forces classic Windows Console Host instead of Windows Terminal / `wt.exe`.
- Registers inert handlers for missing Safe Mode URI schemes such as `ms-contact-support`.
- Resets SafeBoot alternate shell to `cmd.exe`.
- Installs a visible Safe Mode launcher and a SYSTEM startup fallback.
- Cleans common C: temporary-file locations.
- Clears SafeBoot BCD flags and reboots back to normal mode.

## Usage

Open an elevated Windows PowerShell 5 window and run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "F:\study\Windows\System\Administration\Maintenance\Repair\PowerShell\Automation\safe-boot-mega-cleanup\scripts\SafeBootMegaCleanup.ps1" -Mode Install
```

Or run:

```cmd
Run-SafeBootMegaCleanup.cmd
```

## Logs

The runtime log is written to:

```text
C:\SafeBootMegaCleanup.log
```

## Safety Notes

`-Mode Install` intentionally changes SafeBoot BCD state and immediately reboots. Do not run it unless you are ready to reboot.

For parser-only verification, use:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\tests\Test-SafeBootMegaCleanup.ps1"
```

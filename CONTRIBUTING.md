# Contributing Guide

Thank you for contributing to this project! This repository contains automated scripts for enterprise migration workflows. To maintain high code quality, predictability, and safety, please follow these guidelines.

---

## Code Guidelines

### 1. PowerShell Best Practices
- **Strict Mode**: Always keep `Set-StrictMode -Version Latest` at the top of the execution flow to prevent undeclared variables and expression bugs.
- **Error Handling**: Use `$ErrorActionPreference = 'Stop'` and wrap remote/volatile API and PowerCLI operations in `try/catch` blocks.
- **Avoid plain strings for passwords**: Always handle password arguments using secure techniques. The script uses a custom `ConvertTo-SecurePassword` helper to accept strings, SecureStrings, or PSCredentials.
- **Clean Registry Handling**: When loading registry hives (`reg.exe load`), ensure the `finally` block unloads the hive (`reg.exe unload`) even if a failure occurs, to prevent locking target disk structures.

### 2. Logging and Output
- Do not use raw `Write-Host` or `Write-Output` for progress logging. Always use the built-in `Write-Log` wrapper to ensure all output is timestamped, categorized (`INFO`, `WARN`, `ERROR`, `SUCCESS`), color-coded, and mirrored to the local log file.

---

## Extending OS Support

The script auto-detects the target VM's guest OS version by inspecting the build number located inside the offline registry:
`HKLM\OFFLINESW_DETECT\Microsoft\Windows NT\CurrentVersion\CurrentBuildNumber`

To add support for a new Windows release (e.g. a future Windows Server or Client version):
1. **Identify the Build Number**: Find the standard build number of the new OS (e.g. Windows Server 2028 might use a build number like `30000`).
2. **Update mapping logic**: Modify the `Get-VirtIOGuestOSFolder` function inside `Invoke-HelperVMVirtIOInject.ps1`.
   ```powershell
   $folder = if     ($build -ge 30000) { '2k28'   } # Add new OS mapping here
             elseif ($build -ge 26100) { '2k25'   }
             ...
   ```
3. **Update Param ValidateSet**: Add the new folder name to the `[ValidateSet()]` validation on the `$GuestOSFolder` parameter at the top of the script.
   ```powershell
   [ValidateSet('2k28','2k25','2k22','2k19','2k16','2k12R2','w11','w10')]
   ```
4. **Driver Folder**: Create the corresponding folder (e.g. `viostor\2k28\amd64` and `vioscsi\2k28\amd64`) in your staged driver directory on the Helper VM.

---

## Testing Your Changes

Before submitting a pull request, perform the following validation:

1. **Syntax Check**: Run `Get-Command` or `LanguageMode` syntax verification to ensure there are no parser errors:
   ```powershell
   powershell -Command "InstructionCheck -Path .\Invoke-HelperVMVirtIOInject.ps1"
   ```
2. **Dry Run**: Run the script against a test VM using a mock vCenter or a non-production VM.
3. **Verify Hives Unmounted**: Confirm that no `OFFLINESYS_INJECT` or `OFFLINESW_DETECT` registry keys remain under `HKLM` on your Helper VM after a completed or aborted run.
4. **Log Review**: Ensure the log output format remains intact and readable.

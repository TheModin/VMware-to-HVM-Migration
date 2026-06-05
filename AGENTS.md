# Agent Instructions — Prepp-Mig

This workspace contains a single PowerShell 7 script: `Invoke-VMwareWindowsMigrationToVME.ps1`.  
See [README.md](README.md) for architecture overview and [CONTRIBUTING.md](CONTRIBUTING.md) for extension/testing guidelines.

---

## Validate After Every Edit

Run the parse check before any test execution (run from the repository root):
```powershell
pwsh -NoProfile -Command "& {
    \$e = \$t = \$null
    [void][System.Management.Automation.Language.Parser]::ParseFile(
        (Resolve-Path '.\Invoke-VMwareWindowsMigrationToVME.ps1'),
        [ref]\$t, [ref]\$e
    )
    if (\$e.Count -eq 0) { 'PARSE_OK' } else { \$e | ForEach-Object { \$_.Message } }
}"
```
Must print `PARSE_OK`. Fix any errors before running the script.

---

## Script Structure

| Region | Lines (approx) | Purpose |
|--------|----------------|---------|
| `param(...)` | 94–146 | All script parameters |
| Validation block | 148–259 | PS7 gate, PowerCLI check, param dependency checks |
| Helper functions | 151–2143 | All named functions (do not touch order) |
| Main execution block | 2147–end | PostMigrationOnly fast-path, vCenter connect, full migration flow |

Key functions:
- `Connect-VC` — wraps PowerCLI `Connect-VIServer` with `VCSkipSSL` and optional credential pass-through
- `Invoke-MorpheusMigration` — all Morpheus API logic (Steps 1–5)
- `Get-VirtIOGuestOSFolder` — offline hive OS detection
- `Enable-AttachedDiskOnHelper` / `Disable-AttachedDiskOnHelper` — helper VM disk management
- `Get-OfflineWindowsDrive` — identifies Windows drive letter on attached offline disk
- `Remove-VMwareToolsViaTask` — Morpheus agent task execution for VMware Tools removal
- `Remove-VMwareToolsViaWinRM` — direct WinRM fallback for VMware Tools removal
- `Install-MorpheusAgent` — Morpheus agent installation via WinRM
- `Set-MorpheusInstanceCredentials` — sets SSH/WinRM credentials on the Morpheus server record so agent finalize connects with the correct OS admin account
- `Invoke-PostMigrationVMwareToolsRemoval` — orchestrates post-migration cleanup
- `Select-FromList` — shared numbered console menu utility used by both Resolve- functions
- `Resolve-MorpheusTargetParameters` — interactive selection menus for Cloud, Pool, Network, and Datastore
- `Resolve-VCenterTargetParameters` — interactive selection menus for TargetVMName, HelperVMName, and VirtIODriverPath

---

## Critical Conventions

### Logging
Always use `Write-Log`, never `Write-Host` / `Write-Output` directly:
```powershell
Write-Log "message"                  # INFO (default)
Write-Log "message" -Level WARN
Write-Log "message" -Level ERROR
Write-Log "message" -Level SUCCESS
```

### Guest scripts (Invoke-VMScript)
Use **single-quoted here-strings** with `__PLACEHOLDER__` substitution — never double-quoted here-strings:
```powershell
$script = (@'
Get-Disk -Number __DISK_NUMBER__
'@) -replace '__DISK_NUMBER__', $DiskNumber
```
Double-quoted `@"..."@` expands all `$variables` in the **outer PowerShell scope**, corrupting guest scripts.

### Falsy-zero guard
Disk numbers can be `0`. Test with `.Count -gt 0`, not `if ($collection)`:
```powershell
if ($KnownDiskNumbers.Count -gt 0) { ... }   # correct
if ($KnownDiskNumbers) { ... }               # WRONG — @(0) is falsy
```

### Password handling
`HelperVMPassword` and `TargetVMPassword` are typed `[object]` and always routed through `ConvertTo-SecurePassword`, which accepts `string | SecureString | PSCredential`. Never accept raw strings for these without routing through that helper.

`MorpheusToken` and `MorpheusPassword` are typed `[System.Security.SecureString]` and do **not** go through `ConvertTo-SecurePassword` — callers must pass them as SecureStrings directly (e.g. `ConvertTo-SecureString "value" -AsPlainText -Force`).

---

## Morpheus API Quirks (learned from live testing)

Reference: [Morpheus Migration API — addMigration](https://apidocs.morpheusdata.com/reference/addmigration)

| Behaviour | Impact | Handling in code |
|-----------|--------|-----------------|
| Completed plans are **auto-deleted** | `GET /api/migrations/{id}` returns 404 after success | Polling treats 404 / "not found" as SUCCESS |
| No `/cancel` or `/stop` endpoints | Rollback can only use `DELETE /api/migrations/{id}` | `Remove-MorpheusArtifacts` is DELETE-only |
| Plan field is `servers`, not `vms` | Wrong key → empty migration (plan runs but does nothing) | Always use `servers: [{id: ...}]` |
| Network mapping: use plan-level `networks[].{sourceNetwork.id, destinationNetwork.id}` where `sourceNetwork.id` is the backing network ID from `server.interfaces[].network.id` (NOT the NIC id) | Per-server `vmConfig.networkInterfaces` causes Morpheus NPE "Cannot get property 'destinationNetwork' on null object" | Use plan-level `networks` array; fetch source network id from `/api/servers/{id}` interfaces[0].network.id |
| `targetPool` is always required, even for Private/HVM clouds with no resource pools | Missing targetPool → 400 "targetPool is required" | For Private/HVM clouds, pass a hypervisor host server ID (e.g., mvmHost type) as targetPool |
| Failed plans are **not** auto-deleted | User can inspect them in **Tools › Migrations** | Do not DELETE a plan already in `failed` state |
| Execute task endpoint: `POST /api/tasks/{id}/execute` | Execute body needs `{ "job": { "targetType": "instance", "instances": [id] } }` | `Remove-VMwareToolsViaTask` uses this pattern |
| Task execution ID in `jobExecution.id` (not `execution.id`) | Wrong field → null executionId → poll fails | Extract from `$resp.jobExecution.id` |
| Poll execution via `GET /api/job-executions/{id}` | Output at `.jobExecution.process.output` or `.process.events[0].output` | Check both fields; status done = `success`/`error` |
| PowerShell task type code is `winrmTask` (not `script`) | `script` = Shell/Bash; wrong type runs nothing on Windows | Always use `taskType: { code: 'winrmTask' }` for PS |
| Script content goes in `file.content` (not `taskContent`) | `taskContent` is not a real API field — content silently ignored | Use `file: { sourceType: 'local', content: '...' }` |

---

## Extending OS Support

See [CONTRIBUTING.md](CONTRIBUTING.md#extending-os-support) — requires updating `Get-VirtIOGuestOSFolder` build-number mapping and the `[ValidateSet]` on `$GuestOSFolder`.

---

## PowerShell Requirement

The script enforces **PowerShell 7.0+** at runtime (line ~171). Do not use PS5-only syntax (e.g., `??` operator alternative forms, `ForEach-Object -Parallel`).  
`SkipCertificateCheck` on `Invoke-RestMethod` is PS7-only — used intentionally.

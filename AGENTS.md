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
| `param(...)` | 93–128 | All script parameters |
| Validation block | 130–220 | PS7 gate, PowerCLI check, param dependency checks |
| Helper functions | 230–2062 | All named functions (do not touch order) |
| Main execution block | 2064–end | PostMigrationOnly fast-path, vCenter connect, full migration flow |

Key functions:
- `Invoke-MorpheusMigration` — all Morpheus API logic (Steps 1–5)
- `Get-VirtIOGuestOSFolder` — offline hive OS detection
- `Enable-AttachedDiskOnHelper` / `Disable-AttachedDiskOnHelper` — helper VM disk management
- `Get-OfflineWindowsDrive` — identifies Windows drive letter on attached offline disk
- `Remove-VMwareToolsViaTask` — Morpheus agent task execution for VMware Tools removal
- `Remove-VMwareToolsViaWinRM` — direct WinRM fallback for VMware Tools removal
- `Install-MorpheusAgent` — Morpheus agent installation via WinRM
- `Invoke-PostMigrationVMwareToolsRemoval` — orchestrates post-migration cleanup

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
Never accept raw strings without routing through `ConvertTo-SecurePassword`. The helper accepts `string | SecureString | PSCredential`.

---

## Morpheus API Quirks (learned from live testing)

Reference: [Morpheus Migration API — addMigration](https://apidocs.morpheusdata.com/reference/addmigration)

| Behaviour | Impact | Handling in code |
|-----------|--------|-----------------|
| Completed plans are **auto-deleted** | `GET /api/migrations/{id}` returns 404 after success | Polling treats 404 / "not found" as SUCCESS |
| No `/cancel` or `/stop` endpoints | Rollback can only use `DELETE /api/migrations/{id}` | `Remove-MorpheusArtifacts` is DELETE-only |
| Plan field is `servers`, not `vms` | Wrong key → empty migration (plan runs but does nothing) | Always use `servers: [{id: ...}]` |
| Network mapping: use `networkInterfaces[].destinationNetwork.id` with source NIC `id` fetched from `/api/servers/{id}` | Missing source NIC id → Morpheus NPE at runtime | Fetch server detail before building vmConfig |
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

The script enforces **PowerShell 7.0+** at runtime (line ~136). Do not use PS5-only syntax (e.g., `??` operator alternative forms, `ForEach-Object -Parallel`).  
`SkipCertificateCheck` on `Invoke-RestMethod` is PS7-only — used intentionally.

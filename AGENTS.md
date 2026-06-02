# Agent Instructions — Prepp-Mig

This workspace contains a single PowerShell 7 script: `Invoke-HelperVMVirtIOInject.ps1`.  
See [README.md](README.md) for architecture overview and [CONTRIBUTING.md](CONTRIBUTING.md) for extension/testing guidelines.

---

## Validate After Every Edit

Run the parse check before any test execution:
```powershell
pwsh -NoProfile -Command "& { `$e = `$t = `$null; [void][System.Management.Automation.Language.Parser]::ParseFile('C:\Scripts\Prepp-Mig\Invoke-HelperVMVirtIOInject.ps1', [ref]`$t, [ref]`$e); if (`$e.Count -eq 0) { 'PARSE_OK' } else { `$e | ForEach-Object { `$_.Message } } }"
```
Must print `PARSE_OK`. Fix any errors before running the script.

---

## Script Structure

| Region | Lines (approx) | Purpose |
|--------|----------------|---------|
| `param(...)` | 81–109 | All script parameters |
| Validation block | 136–160 | PS7 gate, param dependency checks |
| Helper functions | 164–890 | All named functions (do not touch order) |
| Main execution block | 893–end | Try/catch/finally orchestration |

Key functions:
- `Invoke-MorpheusMigration` — all Morpheus API logic (Steps 1–5)
- `Get-VirtIOGuestOSFolder` — offline hive OS detection
- `Enable-AttachedDiskOnHelper` / `Disable-AttachedDiskOnHelper` — helper VM disk management
- `Get-OfflineWindowsDrive` — identifies Windows drive letter on attached offline disk

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

---

## Extending OS Support

See [CONTRIBUTING.md](CONTRIBUTING.md#extending-os-support) — requires updating `Get-VirtIOGuestOSFolder` build-number mapping and the `[ValidateSet]` on `$GuestOSFolder`.

---

## PowerShell Requirement

The script enforces **PowerShell 7.0+** at runtime (line ~136). Do not use PS5-only syntax (e.g., `??` operator alternative forms, `ForEach-Object -Parallel`).  
`SkipCertificateCheck` on `Invoke-RestMethod` is PS7-only — used intentionally.

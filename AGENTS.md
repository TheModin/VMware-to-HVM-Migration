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

### WinRM management channel

The post-migration WinRM path (`Remove-VMwareToolsViaWinRM`) connects from a **domain-joined management host** to a **workgroup target VM**. Several settings are required for this to work:

| Requirement | Why | Where set |
|-------------|-----|-----------|
| `.\<user>` credential prefix | Bare `administrator` on a domain-joined client is NTLM-qualified as `DOMAIN\administrator`; the workgroup VM rejects it | `Remove-VMwareToolsViaWinRM` normalises `TargetVMUser` to `.\user` when no `\` or `@` is present |
| `AllowUnencrypted = $true` on **target service** | Plain HTTP (port 5985) sessions are rejected without this on hardened Windows Server configs | Pre-migration guest script (`Enable-WinRMOnTarget`) runs `Set-Item WSMan:\localhost\Service\AllowUnencrypted -Value $true` |
| `AllowUnencrypted = $true` on **client** | Client must also accept unencrypted transport | Set in `Remove-VMwareToolsViaWinRM` before `New-PSSession`; restored in `finally` |
| Firewall rule **Profile Any** | Post-migration HVM NIC may be classified as Public by Windows NLA; Default WinRM rule only applies to Domain/Private | Pre-migration guest script creates `New-NetFirewallRule -Profile Any` for port 5985/5986 |
| Target IP in `WSMan:\localhost\Client\TrustedHosts` | Required for Negotiate/NTLM over HTTP to a non-domain host | Added temporarily in `Remove-VMwareToolsViaWinRM`; restored in `finally` |

Do **not** add `Set-WSManInstance -ResourceURI winrm/config/service/auth` restrictions (`Negotiate=$true`, `Basic=$false`) to the pre-migration guest script — these broke WinRM connectivity in testing.

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
| `api/servers?name=X` returns **both** vCenter and HVM records when a VM has been migrated before | `Select-Object -First 1` may pick the stale HVM copy (externalId = VM name, not a moref) → Morpheus can't resolve the VM in vSphere → SOAP fault "object has already been deleted" | Prefer the record whose `externalId` matches `^vm-\d+$` (vSphere moref); fall back to zone name containing `vcenter`/`vmware` |
| `POST /api/servers/{id}/install-agent` is unreliable in this environment | Returns immediately but `agentInstalled` stays `False` for 15+ min before timing out; root cause is Morpheus server → guest auth issue | Script times out after 15 min and falls back to direct WinRM; the WinRM path is the reliable production route |

---

## PowerCLI Quirks (learned from live testing)

| Quirk | Impact | Handling in code |
|-------|--------|-----------------|
| `Get-Task -Entity <VM>` parameter not available in all PowerCLI versions | `A parameter cannot be found that matches parameter name 'Entity'` | Use pipeline input: `$TargetVM \| Get-Task` — works in all versions |
| `Get-Task` without scoping loads **all tasks** across all VMs | Very slow in large vCenters; silently times out in the poll loop | Always scope via pipeline: `$TargetVM \| Get-Task` |

---

## Extending OS Support

See [CONTRIBUTING.md](CONTRIBUTING.md#extending-os-support) — requires updating `Get-VirtIOGuestOSFolder` build-number mapping and the `[ValidateSet]` on `$GuestOSFolder`.

---

## PowerShell Requirement

The script enforces **PowerShell 7.0+** at runtime (line ~171). Do not use PS5-only syntax (e.g., `??` operator alternative forms, `ForEach-Object -Parallel`).  
`SkipCertificateCheck` on `Invoke-RestMethod` is PS7-only — used intentionally.

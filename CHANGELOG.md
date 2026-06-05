# Changelog

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] - 2026-06-05

### Added

- **Offline VirtIO driver injection via Helper VM loopback mount** — shuts down the
  target VM, hot-attaches its boot VMDK to a Windows Helper VM on the same ESXi host,
  injects `viostor` and `vioscsi` drivers with DISM, and patches the offline SYSTEM
  hive to `Start=0` — all without requiring network connectivity to the target VM.
- **Automatic OS version detection** — reads `CurrentBuildNumber` and `ProductName`
  from the target's offline SOFTWARE registry hive to select the correct VirtIO driver
  folder (supports `2k25`, `2k22`, `2k19`, `2k16`, `2k12R2`, `w11`, `w10`).
- **Automatic snapshot consolidation** — detects existing snapshot chains (including
  multi-root trees from backup tools), prompts for confirmation, and consolidates
  before disk operations begin.
- **Safety snapshot** — creates a named recovery snapshot after driver injection so
  the VM can be rolled back if the first boot fails. Optional auto-delete with
  `-DeleteSnapshot`.
- **VirtIO Guest Tools staging and silent install** — copies the tools bundle onto
  the mounted offline disk and runs the installer silently after first boot. Disable
  with `-DoNotInstallGuestTools`.
- **Interactive parameter discovery** — when VM names, Morpheus Cloud/Pool/Network/
  Datastore IDs are omitted, the script queries vCenter and Morpheus and presents
  numbered selection menus at runtime.
- **Automatic vMotion host alignment** — if the Helper VM and Target VM are on
  different ESXi hosts, the script vMotions the Helper VM to the target host before
  attaching the disk, then vMotions it back.
- **End-to-end Morpheus HVM migration** — authenticates to the Morpheus REST API,
  creates a migration plan, starts it, and polls for completion with 404-as-success
  handling (Morpheus auto-deletes completed plans). Enable with `-TriggerMorpheusMigration`.
- **Bearer token auto-refresh** — if the Morpheus token expires during a long-running
  migration poll, the script transparently refreshes it and retries.
- **Post-migration Morpheus agent installation** — installs the Morpheus agent on the
  migrated HVM instance via WinRM so the instance becomes fully managed.
- **Automatic VMware Tools removal** — removes VMware Tools from the migrated HVM
  instance via a Morpheus agent task, with direct WinRM fallback if the agent path
  is unavailable. Disable with `-DoNotRemoveVMwareTools`.
- **Pre-migration WinRM and RDP enablement** — enables WinRM (for post-migration
  management) and RDP (for console access after cutover) on the target VM via
  VMware guest scripts before migration. Disable individually with
  `-DoNotRemoveVMwareTools` / `-DoNotEnableRDP`.
- **`-MigrationOnly` mode** — skips the VirtIO injection phase for VMs that were
  already prepared in a prior run; goes directly to the Morpheus migration step.
- **`-CreatePlanOnly` mode** — creates the Morpheus migration plan without starting
  it, for review in the Morpheus UI before committing to the cutover.
- **`-PostMigrationOnly` mode** — bypasses vCenter entirely and re-runs post-migration
  cleanup (agent install + VMware Tools removal) against an already-migrated Morpheus
  instance. Requires `-MorpheusInstanceId`.
- **TLS skip flags** — `-VCSkipSSL`, `-WinRMSkipSSL`, and `-MorpheusSkipSSL` for
  environments with self-signed certificates, with explicit warnings logged on use.
- **Structured logging** — all output written via `Write-Log` with `INFO`/`WARN`/
  `ERROR`/`SUCCESS` levels, timestamps, colour coding, and mirroring to a log file
  at `C:\Windows\Logs\VirtIO-HelperInject\HelperVirtIO_yyyyMMdd_HHmmss.log`.
- **4 Architectural Decision Records** documenting key design choices (ADR-0001 to
  ADR-0004) in `docs/adr/`.

### Fixed

- Corrected network mapping payload to use per-server `vmConfig.networkInterfaces`
  with source NIC ID (Morpheus silently ignores a plan-level `networks` key).
- `reg.exe load` exit code now validated; stale hive mounts from failed prior runs
  produce a clear diagnostic error instead of reading the wrong registry data.
- `CreatePlanOnly` no longer deletes the plan it just created (was: sentinel `throw`
  caught by rollback handler).
- Multiple snapshot roots (e.g. Veeam + manual) now all consolidated, not just the
  first root.
- `Wait-ForMorpheusInstance` start attempts capped at 3 to prevent issuing 60+
  consecutive start commands over the full timeout window.
- Resolved null-dereference on `interfaces[0]`/`volumes[0]` when the Morpheus server
  record has no NICs or volumes synced yet.

### Security

- All API credentials (`MorpheusToken`, `MorpheusPassword`, `VCPassword`) stored as
  `[System.Security.SecureString]`; bearer token decrypted via `Marshal.SecureStringToBSTR`
  with `ZeroFreeBSTR` in a `finally` block — plaintext never persists in memory.
- VM passwords (`HelperVMPassword`, `TargetVMPassword`) routed through
  `ConvertTo-SecurePassword`, which accepts string/SecureString/PSCredential and
  converts to `SecureString` before first use.
- WinRM connections use HTTPS with certificate validation by default; skip flags
  require explicit opt-in and log a production warning.
- Log directory created with restrictive ACLs (Administrators only).
- Input validation on `VirtIODriverPath` (must be absolute Windows path, no `..`,
  no shell-special characters) and `MorpheusServer` (hostname only, no scheme or path).

### Changed

- Script renamed from `Invoke-HelperVMVirtIOInject.ps1` to
  `Invoke-VMwareWindowsMigrationToVME.ps1` to reflect the full end-to-end scope of
  the tool.

[1.0.0]: https://github.com/TheModin/VMware-to-HVM-Migration/commits/main

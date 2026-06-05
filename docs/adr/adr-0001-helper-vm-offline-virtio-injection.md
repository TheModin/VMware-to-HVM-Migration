---
title: "ADR-0001: Helper VM Offline VirtIO Driver Injection"
status: "Accepted"
date: "2026-06-05"
authors: "Migration Script Architect"
tags: ["architecture", "decision", "virtio", "migration", "helper-vm"]
supersedes: ""
superseded_by: ""
---

# ADR-0001: Helper VM Offline VirtIO Driver Injection

## Status

Proposed | **Accepted** | Rejected | Superseded | Deprecated

## Context

Windows VMs migrated from VMware vSphere to KVM-based platforms (such as HPE Morpheus VM Essentials) inevitably encounter an `INACCESSIBLE_BOOT_DEVICE` BSOD on first boot. This occurs because:

- VMware presents storage controllers via the `vmxnet3` and `pvscsi` adapter models.
- KVM presents storage via `virtio-blk` or `virtio-scsi` controllers.
- Windows only boots successfully if the storage driver for the target controller is already present **and** set to `Start=0` (boot-start) in the registry before the OS hands off to the boot loader.

The problem must be solved **before** the migration is triggered — once the VM is inside the KVM hypervisor, it cannot boot to perform self-remediation.

Three approaches exist: inject drivers into the live running VM before migration, inject offline via the VMware snapshot mechanism, or use a network-mounted helper VM as a loopback disk mount host. The solution must work without requiring a custom image, kernel modules on the ESXi host, or agent installation on every target VM.

## Decision

Use a **Windows Helper VM** running on the same ESXi host as the target VM to perform offline driver injection. The workflow is:

1. Gracefully shut down the target VM and consolidate all snapshots.
2. Identify the target's boot disk VMDK via PowerCLI.
3. Temporarily attach the VMDK to the Helper VM as an additional disk using the VMware hot-add capability.
4. Bring the disk online in the Helper VM, detect the Windows OS partition, and mount it.
5. Inject `viostor` and `vioscsi` drivers using `DISM /Add-Driver` against the offline image.
6. Load the target's offline `SYSTEM` registry hive and set `Start=0` for both driver services in the correct `ControlSet`.
7. Unload the hive, take the disk offline, and detach it from the Helper VM.
8. Power on the target VM for a boot-verification phase.

The Helper VM runs the injection scripts via VMware VIX (`Invoke-VMScript`) so no WinRM or agent is needed on the Helper VM for the injection phase itself.

## Consequences

### Positive

- **POS-001**: Zero network-hop injection — the driver files are copied directly from the Helper VM's local filesystem to the mounted VMDK; no staging server or SMB share required.
- **POS-002**: Works on any Windows VM visible to PowerCLI regardless of guest OS agent state — the target VM can be completely unresponsive or have no network connectivity.
- **POS-003**: Fully automated — no manual console access, no in-guest agent installation, no custom ESXi kernel modules.
- **POS-004**: Offline registry modification is deterministic; it does not depend on Windows being bootable or having a running service stack.
- **POS-005**: The Helper VM is reusable across migrations — only the VirtIO driver path needs to be staged once per cluster.

### Negative

- **NEG-001**: Requires the Helper VM and Target VM to reside on the same ESXi host; the script performs automatic vMotion alignment but this depends on vMotion being licensed and functional.
- **NEG-002**: Snapshot consolidation is destructive and irreversible — all existing snapshots are permanently committed before the disk can be mounted. Users must have an independent backup.
- **NEG-003**: VMware VIX (`Invoke-VMScript`) requires VMware Tools to be running on the Helper VM; if Tools are not running or out of date, guest script execution fails.
- **NEG-004**: VMDK hot-add is not supported on all ESXi configurations (e.g. certain storage policies, vVols). Incompatible configurations will fail at the disk-attach step.
- **NEG-005**: Only one target disk can be mounted at a time; injecting drivers into a multi-disk VM with an OS on a non-primary disk requires the probing loop to succeed across all disks.

## Alternatives Considered

### Live In-Guest Injection Before Migration

- **ALT-001**: **Description**: Connect to the running target VM via WinRM or SSH, download the VirtIO drivers inside the guest, and install them using `pnputil` or `DISM` against the live Windows installation. Then modify the registry live.
- **ALT-002**: **Rejection Reason**: Requires the target VM to have network connectivity, WinRM enabled, and a reachable credential. Many migration targets are in unknown network states. Live injection also risks driver conflicts with the currently-loaded storage drivers and may require a reboot before migration — introducing a second planned downtime window. The offline approach is safer and more deterministic.

### VMware Guest Customization / Pre-Migration Script

- **ALT-003**: **Description**: Use vCenter's Guest Customization framework or a vSphere alarm/script hook to trigger driver injection as a pre-migration step automatically.
- **ALT-004**: **Rejection Reason**: Guest Customization is designed for post-deploy Sysprep workflows, not driver injection. Custom scripts via this path still require agent connectivity and do not address the offline SYSTEM hive `Start=0` requirement. The vSphere API surface for this is limited and not officially supported for third-party driver injection.

### Convert VM with virt-v2v

- **ALT-005**: **Description**: Use Red Hat's `virt-v2v` tool on a Linux conversion host to handle driver injection and disk format conversion simultaneously.
- **ALT-006**: **Rejection Reason**: `virt-v2v` requires a Linux conversion host with access to both the VMware storage layer and the target KVM platform. It also performs disk format conversion (VMDK → qcow2) which is out of scope — Morpheus VM Essentials manages its own storage. Additionally, `virt-v2v` has historically had issues with certain Windows versions and Active Directory domain membership.

### Custom Sysprep / Golden Image Approach

- **ALT-007**: **Description**: Require all migration candidates to first be re-imaged from a golden image that already includes VirtIO drivers pre-installed.
- **ALT-008**: **Rejection Reason**: Not applicable to lift-and-shift migrations of existing production VMs. Re-imaging would require data migration and application re-installation, defeating the purpose of a VM migration workflow.

## Implementation Notes

- **IMP-001**: The Helper VM must run Windows Server 2016 or later and have VMware Tools installed and running. The VirtIO driver directory (`viostor\<os-folder>\amd64\` and `vioscsi\<os-folder>\amd64\`) must be pre-staged on the Helper VM's local disk.
- **IMP-002**: OS version detection uses an offline read of the `SOFTWARE` registry hive (`CurrentBuildNumber` and `ProductName` keys) to avoid relying on vCenter guest metadata, which can be stale. Build number ranges are mapped to driver folder names in `Get-VirtIOGuestOSFolder`.
- **IMP-003**: Registry hive load/unload uses `reg.exe load` / `reg.exe unload` with a `finally` block and `[gc]::Collect()` + 2-second sleep to force PowerShell to release registry provider handles before the unload. LASTEXITCODE is checked on both load and unload.
- **IMP-004**: If the Helper VM and Target VM are on different ESXi hosts, the script automatically vMotions the Helper VM to the target host before attaching the disk and vMotions it back afterwards.
- **IMP-005**: The unique temporary registry key `HKLM\OFFLINESW_DETECT` (for SOFTWARE) and `HKLM\OFFLINESYS_INJECT` (for SYSTEM) must be manually unloaded on the Helper VM if a run aborts unexpectedly. See TROUBLESHOOTING.md §3.

## References

- **REF-001**: `Get-VirtIOGuestOSFolder` function — OS detection logic (line ~1825)
- **REF-002**: `Set-OfflineBootStart` function — SYSTEM hive ControlSet patching (line ~609)
- **REF-003**: `Invoke-DISMInjection` function — DISM driver injection (line ~588)
- **REF-004**: [VirtIO drivers for Windows — Red Hat documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_and_managing_virtualization/optimizing-virtual-machine-performance-in-rhel_configuring-and-managing-virtualization)
- **REF-005**: TROUBLESHOOTING.md §3 — Registry hive lock recovery
- **REF-006**: CONTRIBUTING.md — Extending OS support (new build number mappings)

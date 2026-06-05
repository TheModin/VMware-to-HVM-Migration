# Troubleshooting Guide

This guide covers common issues encountered while using the `Invoke-VMwareWindowsMigrationToVME.ps1` script and outlines practical methods for resolution.

---

## 1. Snapshot Consolidation Failures

### Symptom:
The script fails during the snapshot removal phase or outputs a "remote host communication error" when attempting to attach the target disk to the helper VM.

### Explanation:
VMware locks all delta (snapshot) disks to the VM's active namespace. If you attempt to mount a disk that has active child snapshots, ESXi blocks the operation to prevent data corruption.
Furthermore, the script can only safely mount a **base (non-snapshot) VMDK**.

### Resolution:
1. **Manual Consolidation**: Right-click the Target VM in vSphere, select **Snapshots > Consolidate**.
2. **Increase Timeout**: If the VM has massive active snapshots, the default 10-minute timeout for consolidation in the script may be exceeded. You can manually commit the snapshots in vCenter prior to running the script.
3. **Check Lock Status**: Ensure no backup appliance (e.g. Veeam) has a lingering lock on the VMDK.

---

## 2. ESXi Host Mismatch & vMotion Failures

### Symptom:
The script errors out during the host alignment phase:
`"VM host mismatch and migration failed. Please manually align hosts..."`

### Explanation:
ESXi cannot cross-attach a virtual disk to a VM on another host (unless using highly complex multi-writer clustered VMDK setups, which is unsupported here). The Helper VM and Target VM **must** reside on the same physical ESXi hypervisor during the injection phase.

### Resolution:
1. **DRS Intervention**: If VMware DRS (Distributed Resource Scheduler) is set to Fully Automated, it might immediately migrate the Helper VM back to another host after the script aligns them.
   - *Fix*: Create a temporary **"Keep Together" VM/Host affinity rule** or set DRS to **Manual/Partially Automated** for the Helper VM during the maintenance window.
2. **vMotion Network**: Ensure vMotion is healthy on the target cluster. If the vMotion network is saturated or disconnected, the automated host migration will fail.

---

## 3. Registry Hive Locks (`reg.exe` fails to load or unload)

### Symptom A — Hive fails to load (stale mount):
The script fails with:
`"SOFTWARE hive failed to load on <drive>. A stale mount from a prior failed run may be present at HKLM\OFFLINESW_DETECT on the helper VM."`

### Symptom B — Hive fails to unload (active handle):
The script fails with:
`"SOFTWARE hive did not unload cleanly (HIVE_UNLOAD_FAILED or missing token). A handle may still be open on the target disk."`

### Explanation:
**Symptom A** occurs when a previous run of the script aborted before the `finally` block could unload the offline hive. The key `HKLM\OFFLINESW_DETECT` (or `HKLM\OFFLINESYS_INJECT`) remains mounted on the Helper VM. Attempting to load the same key name a second time fails with a non-zero exit code.

**Symptom B** occurs when the helper VM loads the target VM's registry hive but a monitoring agent, security scanner, or PowerShell process holds a handle open, preventing `reg.exe unload` from succeeding.

### Resolution:
**For Symptom A (stale mount):**
1. On the Helper VM, open an elevated command prompt and run:
   ```cmd
   reg unload HKLM\OFFLINESW_DETECT
   reg unload HKLM\OFFLINESYS_INJECT
   ```
2. If the keys no longer exist, the unload will report an error — that is fine; it means the hive is already clear.
3. Alternatively, **reboot the Helper VM** to force-release all loaded hives, then run the script again.

**For Symptom B (active handle):**
1. **Garbage Collection**: The script already includes a `[gc]::Collect()` + sleep delay before `reg.exe unload` to release PowerShell registry provider handles. If this is still failing, a third-party process is likely holding the handle.
2. **AV Exclusions**: Add temporary exclusions for `HKLM\OFFLINESYS_INJECT` and `HKLM\OFFLINESW_DETECT` on the Helper VM's Antivirus (e.g. Microsoft Defender) to prevent active locking during scanning.
3. **Manual Recovery**: Reboot the Helper VM to force-release all locked hives.

---

## 4. Helper VM Drive Assignment Issues

### Symptom:
The script fails to find a drive letter or returns `NODISK` / `NOTFOUND`.

### Explanation:
The script brings the newly attached disk online and automatically scans for the largest partition containing the `Windows\System32\config\SYSTEM` path. If the drive is encrypted with BitLocker or uses an unsupported partition format (e.g. dynamic disks, Storage Spaces), detection will fail.

### Resolution:
1. **BitLocker / Encryption**: Ensure the target VM's system drive is **decrypted** before migration. The helper VM cannot natively read or inject drivers into a locked BitLocker volume.
2. **SAN / Storage policy**: If the helper VM's OS policy is set to keep new disks offline, verify that `Set-Disk -IsOffline $false` is working in your environment.
3. **Manual Letter Verification**: Run `Get-Disk` and `Get-Partition` inside the Helper VM while the script is paused or running to confirm the disk is visible to Windows.

---

## 5. Morpheus API Errors (404 / 401 / 403)

### Symptom:
The script triggers the migration but fails with REST API errors:
`"Invoke-RestMethod : The remote server returned an error: (404) Not Found."`

### Explanation:
Morpheus VM Essentials API endpoints can slightly vary across release versions. Additionally, expired tokens, self-signed certificates, or incorrect Cloud IDs can trigger authorization or validation blocks.

### Resolution:
1. **SSL Verification**: If your Morpheus appliance uses a self-signed certificate, make sure to pass the `-MorpheusSkipSSL` switch.
2. **Validate Cloud ID**: Ensure the `-MorpheusTargetCloudId` is correct. You can find this in Morpheus under **Infrastructure > Clouds** (or hover over the cloud in the UI to see its database ID in the URL, or query the `/api/clouds` API endpoint).
3. **Check Local Swagger**: If you encounter `404 Not Found` on `/api/migrations` or `/api/servers`, open the Swagger documentation on your Morpheus appliance at `https://<MorpheusServer>/api/swagger.json` to verify endpoint syntax.
4. **Long-running migrations and token expiry**: Morpheus bearer tokens have a finite lifetime. If a migration runs longer than the token validity period, the script automatically detects the `401 Unauthorized` response and refreshes the token transparently. If the token refresh itself fails (e.g. the credentials are no longer valid), the script will throw. Ensure your Morpheus credentials remain valid for the duration of the migration.

---

## 6. WinRM Connection Failures Post-Migration

### Symptom:
The post-migration cleanup step fails with:
`"WinRM connection failed"` or `"Access denied"` errors when connecting to the migrated HVM instance.

### Explanation:
The post-migration cleanup (Morpheus agent install + VMware Tools removal) connects to the HVM instance via WinRM using the `-TargetVMUser` / `-TargetVMPassword` credentials. Several things can prevent this:
- The VM's IP address in Morpheus has not yet refreshed from the VMware-era address to the new KVM address.
- WinRM was not enabled on the source VM before migration (the script enables it automatically when `-DoNotRemoveVMwareTools` is not set, but if the pre-migration WinRM step failed, it will not be available post-migration).
- Windows Firewall on the migrated VM is blocking WinRM ports (5985/5986).

### Resolution:
1. **Verify IP address**: Check the migrated instance's IP in the Morpheus UI. If it still shows the old VMware-era IP, wait for the next Morpheus cloud sync or trigger a manual refresh in the UI.
2. **Enable WinRM manually**: If WinRM was not pre-enabled, connect to the HVM instance via the Morpheus console or RDP and run `Enable-PSRemoting -Force` in an elevated PowerShell session.
3. **Re-run post-migration only**: Once WinRM is accessible, use `-PostMigrationOnly -MorpheusInstanceId <id>` to re-run cleanup without repeating the full migration.

---

## 7. Source VM Left Powered Off After Migration Failure

### Symptom:
A migration failed mid-way, and the source VM is now powered off in vSphere. The script has exited with an error.

### Explanation:
The migration workflow shuts down the source VM before triggering the Morpheus migration plan. If the migration fails after shutdown, the script attempts to automatically restart the source VM to restore accessibility. If the restart also fails (or if `-SkipRollbackRestart` was passed), the VM remains powered off.

### Resolution:
1. **Check the Morpheus UI**: Navigate to **Tools › Migrations** and review the failed plan for error details before attempting recovery.
2. **Power on manually**: If the source VM did not restart automatically, power it on in vCenter.
3. **Avoid re-running immediately**: If the migration plan is in `failed` state in Morpheus, do not delete it yet — it provides useful diagnostics. The script will not attempt to delete a plan already in `failed` state.
4. **Re-attempt migration**: Once the source VM is healthy, use `-MigrationOnly -TriggerMorpheusMigration` to retry only the Morpheus migration phase (skipping VirtIO re-injection).

---

## 8. Multi-Disk VM — OS Disk Not Found

### Symptom:
The script fails with an error during the disk probing phase:
`"Could not identify the offline Windows OS disk"` or the drive letter scan reports `NOTFOUND` across all probed disks.

### Explanation:
On VMs with many data disks (e.g. SQL servers), the script iterates through all attached disks to find the one containing `Windows\System32\config\SYSTEM`. Encrypted disks (BitLocker) and dynamic disk volumes will not pass detection.

### Resolution:
1. **Check BitLocker**: Ensure the system disk is **not** BitLocker-encrypted before migration. The Helper VM cannot read a locked BitLocker volume.
2. **Simplify disk layout**: As a diagnostic step, temporarily detach non-OS data disks from the target VM before running the script, then re-attach after migration.
3. **Override auto-detection**: Pass `-GuestOSFolder <folder>` (e.g. `-GuestOSFolder 2k25`) to skip the offline hive OS detection entirely and use the specified VirtIO folder directly.

---

## 9. Target VM Blue Screen on First Boot

### Symptom:
The target VM boot verification times out, and connecting to the VMware Console shows an `INACCESSIBLE_BOOT_DEVICE` Blue Screen (BSOD).

### Explanation:
This happens if:
1. The VirtIO drivers were not successfully copied or matched to the target's operating system version.
2. The driver startup type was not set to boot start (`Start = 0`) in the correct registry control set.

### Resolution:
1. **Check OS Mapping Log**: Review the log file to confirm the script auto-detected the correct OS build and mapped it to the right folder (e.g., mapped Windows Server 2025 to `2k25`).
2. **Rollback**: Power off the target VM in vCenter and restore it to the pre-injection safety snapshot (`Post-VirtIO-Injection`, or the custom name you specified with `-SnapshotName`) created by the script.
3. **Verify Driver Files**: Confirm that `viostor.sys`, `vioscsi.sys` and their corresponding `.inf` files exist in the driver path on the Helper VM.

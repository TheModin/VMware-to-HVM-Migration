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

## 3. Registry Hive Locks (`reg.exe` fails to unload)

### Symptom:
The script fails with:
`"Offline registry hive did not unload cleanly. Output: HIVE_UNLOADED was not received."`
OR the disk detachment phase fails because the target OS files are locked.

### Explanation:
When the helper VM loads the target VM's registry hive (`SOFTWARE` or `SYSTEM`), Windows starts tracking active handles on those hives. If a monitoring agent, security scanner, or PowerShell process holds a handle open, `reg.exe unload` fails.

### Resolution:
1. **Garbage Collection**: The script includes a garbage collection trigger `[gc]::Collect()` and a short sleep delay inside the helper block to release PowerShell registry provider handles.
2. **AV Exclusions**: Temporary exclusions of `HKLM\OFFLINESYS_INJECT` and `HKLM\OFFLINESW_DETECT` on the Helper VM's Antivirus (e.g. Microsoft Defender) can prevent active locking during scanning.
3. **Manual Recovery**: If a hive remains locked, reboot the Helper VM to force-release all locked registry hives, then run the script again.

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

---

## 6. Target VM Blue Screen on First Boot

### Symptom:
The target VM boot verification times out, and connecting to the VMware Console shows an `INACCESSIBLE_BOOT_DEVICE` Blue Screen (BSOD).

### Explanation:
This happens if:
1. The VirtIO drivers were not successfully copied or matched to the target's operating system version.
2. The driver startup type was not set to boot start (`Start = 0`) in the correct registry control set.

### Resolution:
1. **Check OS Mapping Log**: Review the log file to confirm the script auto-detected the correct OS build and mapped it to the right folder (e.g., mapped Windows Server 2025 to `2k25`).
2. **Rollback**: Power off the target VM in vCenter and restore it to the pre-injection safety snapshot (`Pre-VirtIO-Injection`) created by the script.
3. **Verify Driver Files**: Confirm that `viostor.sys`, `vioscsi.sys` and their corresponding `.inf` files exist in the driver path on the Helper VM.

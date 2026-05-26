#Requires -RunAsAdministrator

# Script: Invoke-HelperVMVirtIOInject.ps1
# Purpose: Offline VirtIO storage driver injection for Windows Server VMs before
#          migration from VMware to HPE Morpheus VM Essentials / HVM.
# 
# How it works:
#   1. Connects to vCenter with PowerCLI
#   2. Shuts down the target VM gracefully (force-off after timeout)
#   3. Consolidates any snapshots so the base VMDK can be attached elsewhere
#   4. Attaches the base VMDK to a helper Windows VM on the same ESXi host
#   5. Brings the disk online inside the helper VM
#   6. Locates the offline Windows volume on the attached disk
#   7. Detects the real OS version from the offline SOFTWARE registry hive
#   8. Uses DISM to inject viostor and vioscsi drivers into the offline image
#   9. Sets viostor and vioscsi to BOOT_START (Start=0) in the offline registry
#  10. (Optional) Copies the VirtIO driver folder directly to the target disk
#      while it is still mounted on the helper VM (local Copy-Item, no network)
#  11. Offlines the disk inside the helper VM and detaches it
#  12. Takes a safety snapshot of the target VM (post-injection rollback point)
#  13. Starts the target VM and waits for VMware Tools to confirm successful boot
#  14. (Optional) Runs virtio-win-guest-tools.exe silently on the now-live target VM
#  15. (Optional) Shuts down the target VM and triggers a Morpheus migration plan
#      to import it into the HPE VM Essentials HVM cloud
#
# Requirements:
#   - Run from a management PC with VMware PowerCLI installed
#   - A helper Windows VM (2016 or later) on the SAME ESXi host as the target VM
#     with VMware Tools installed and running
#   - VirtIO drivers pre-staged on the helper VM, e.g. C:\Drivers\virtio-win
#     with subfolders for each supported OS:
#       viostor\2k25\amd64, viostor\2k22\amd64, viostor\2k19\amd64, etc.
#   - Local Administrator credentials for the helper VM
#
# Parameters:
#   VCServer         - vCenter FQDN or IP
#   TargetVMName     - Name of the Windows Server VM to prepare for migration
#   HelperVMName     - Name of the helper Windows VM on the same ESXi host
#   HelperVMUser     - Local admin username on the helper VM
#   HelperVMPassword - Password for the helper VM admin account
#   VirtIODriverPath - Path as seen from the HELPER VM to the VirtIO driver root
#   GuestOSFolder    - (Optional) Override the auto-detected VirtIO OS subfolder.
#                      Auto-detected from the offline SOFTWARE registry hive on the
#                      target disk (reliable even on older vCenter that mis-reports
#                      the guest OS, e.g. reporting 2022 for a 2025 VM).
#                      Supported values: 2k25, 2k22, 2k19, 2k16, 2k12R2, w11, w10
#   SnapshotName     - Name for the post-injection safety snapshot
#   ForceHardStopMin - Minutes to wait for graceful shutdown before forcing off
#   SkipSnapshot     - Switch: skip creating a snapshot after injection
#   DeleteSnapshot   - Switch: delete the snapshot after confirmed successful boot
#   InstallGuestTools - Switch: while the target disk is still mounted on the helper
#                      VM, copy VirtIODriverPath directly onto the target disk
#                      (C:\Windows\Temp\virtio-win-install), then after boot run
#                      virtio-win-guest-tools.exe silently and clean up.
#                      No zip, no management-PC hop — pure local Copy-Item.
#   TargetVMUser     - Local admin username on the target VM (required with -InstallGuestTools)
#   TargetVMPassword - Password for the target VM admin account (required with -InstallGuestTools)
#   TriggerMorpheusMigration - Switch: after boot verification shut down the VM and
#                      trigger a Morpheus migration plan to import it into HVM.
#                      Requires -MorpheusServer and -MorpheusTargetCloudId.
#   MorpheusServer   - Morpheus/VM Essentials FQDN or IP (no https:// prefix)
#   MorpheusToken    - Morpheus API bearer token (preferred over user/password)
#   MorpheusUser     - Morpheus username (used to obtain token if -MorpheusToken absent)
#   MorpheusPassword - Morpheus password (used to obtain token if -MorpheusToken absent)
#   MorpheusTargetCloudId - Morpheus cloud ID of the target HVM cluster (required)
#   MorpheusSkipSSL  - Switch: skip SSL certificate validation (for self-signed certs)
#   MorpheusMigrationTimeoutHours - Hours to wait for migration to complete (default 4)
#
# Example:
#   .\Invoke-HelperVMVirtIOInject.ps1 `
#     -VCServer vcsa01.lab.local `
#     -TargetVMName WIN2025-APP01 `
#     -HelperVMName HELPER-WIN01 `
#     -HelperVMUser Administrator `
#     -HelperVMPassword "P@ssw0rd!" `
#     -VirtIODriverPath "C:\Drivers\virtio-win"

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VCServer,
    [Parameter(Mandatory)][string]$TargetVMName,
    [Parameter(Mandatory)][string]$HelperVMName,
    [Parameter(Mandatory)][string]$HelperVMUser,
    [Parameter(Mandatory)][object]$HelperVMPassword,
    [Parameter(Mandatory)][string]$VirtIODriverPath,
    [ValidateSet('2k25','2k22','2k19','2k16','2k12R2','w11','w10')][string]$GuestOSFolder = '',  # blank = auto-detect from offline SOFTWARE hive on the target disk
    [string]$SnapshotName = 'Pre-VirtIO-Injection',
    [int]$ForceHardStopMin = 10,
    [switch]$SkipSnapshot,
    [switch]$DeleteSnapshot,
    [switch]$InstallGuestTools,
    [string]$TargetVMUser,
    [object]$TargetVMPassword,
    [switch]$TriggerMorpheusMigration,
    [string]$MorpheusServer,
    [string]$MorpheusToken,
    [string]$MorpheusUser,
    [string]$MorpheusPassword,
    [string]$MorpheusTargetCloudId,
    [switch]$MorpheusSkipSSL,
    [int]$MorpheusMigrationTimeoutHours = 4,
    [string]$LogPath = 'C:\Windows\Logs\VirtIO-HelperInject'
)

function ConvertTo-SecurePassword {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Password
    )

    if ($null -eq $Password) {
        return $null
    }

    if ($Password -is [System.Security.SecureString]) {
        return $Password
    }

    if ($Password -is [System.Management.Automation.PSCredential]) {
        return $Password.Password
    }

    if ($Password -is [string]) {
        return ConvertTo-SecureString $Password -AsPlainText -Force
    }

    throw 'Password parameter must be a string, SecureString, or PSCredential.'
}

$HelperVMPassword = ConvertTo-SecurePassword -Password $HelperVMPassword
$TargetVMPassword = ConvertTo-SecurePassword -Password $TargetVMPassword

if ($InstallGuestTools -and (-not $TargetVMUser -or -not $TargetVMPassword)) {
    throw '-TargetVMUser and -TargetVMPassword are required when -InstallGuestTools is specified.'
}

if ($TriggerMorpheusMigration) {
    if (-not $MorpheusServer)        { throw '-MorpheusServer is required when -TriggerMorpheusMigration is specified.' }
    if (-not $MorpheusTargetCloudId) { throw '-MorpheusTargetCloudId is required when -TriggerMorpheusMigration is specified.' }
    if (-not $MorpheusToken -and (-not $MorpheusUser -or -not $MorpheusPassword)) {
        throw 'Either -MorpheusToken or both -MorpheusUser and -MorpheusPassword are required with -TriggerMorpheusMigration.'
    }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $LogPath)) { New-Item -ItemType Directory -Path $LogPath | Out-Null }
$LogFile = Join-Path $LogPath "HelperVirtIO_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    Write-Host $line -ForegroundColor $(switch ($Level) {
            'INFO' { 'Cyan' }
            'WARN' { 'Yellow' }
            'ERROR' { 'Red' }
            'SUCCESS' { 'Green' }
        })
    Add-Content -Path $LogFile -Value $line
}

function Connect-VC {
    Write-Log "Loading PowerCLI and connecting to $VCServer..."
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
    Connect-VIServer -Server $VCServer | Out-Null
    Write-Log "Connected to vCenter." -Level SUCCESS
}

function Stop-VMGracefully {
    param($VM)
    if ($VM.PowerState -ne 'PoweredOn') {
        Write-Log "$($VM.Name) is already powered off." -Level WARN
        return
    }
    Write-Log "Requesting graceful shutdown of $($VM.Name)..."
    try { Shutdown-VMGuest -VM $VM -Confirm:$false -ErrorAction Stop | Out-Null } catch {
        Write-Log "Guest shutdown failed (VMware Tools may not be running): $_" -Level WARN
    }
    $deadline = (Get-Date).AddMinutes($ForceHardStopMin)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep 10
        if ((Get-VM -Id $VM.Id).PowerState -eq 'PoweredOff') {
            Write-Log "$($VM.Name) shut down cleanly." -Level SUCCESS
            return
        }
    }
    Write-Log "Timeout reached. Forcing power off $($VM.Name)..." -Level WARN
    Stop-VM -VM $VM -Kill -Confirm:$false | Out-Null
    Start-Sleep 5
    Write-Log "$($VM.Name) forced off." -Level SUCCESS
}

function New-SafetySnapshot {
    param($VM)
    if ($SkipSnapshot) { Write-Log "SkipSnapshot set, skipping." -Level WARN; return }
    Write-Log "Creating safety snapshot '$SnapshotName' on $($VM.Name)..."
    New-Snapshot -VM $VM -Name $SnapshotName -Description "Post-VirtIO injection $(Get-Date)" -Confirm:$false | Out-Null
    Write-Log "Snapshot created." -Level SUCCESS
}

function Remove-SafetySnapshot {
    param($VM)
    if (-not $DeleteSnapshot) { Write-Log "Leaving snapshot in place. Use -DeleteSnapshot to remove it."; return }
    $snap = Get-Snapshot -VM $VM -Name $SnapshotName -ErrorAction SilentlyContinue
    if ($snap) {
        Remove-Snapshot -Snapshot $snap -RemoveChildren -Confirm:$false | Out-Null
        Write-Log "Safety snapshot removed." -Level SUCCESS
    }
}

function Remove-AllSnapshots {
    # Snapshot delta disks cannot be attached to another VM.
    # All snapshots must be consolidated into the base disk before attaching.
    # This function removes all snapshots (commits them into the base disk)
    # and then waits for consolidation to complete.
    param($VM)
    $snapshots = Get-Snapshot -VM $VM -ErrorAction SilentlyContinue
    if (-not $snapshots) {
        Write-Log "No snapshots found on $($VM.Name). Nothing to consolidate."
        return
    }
    Write-Log "$(@($snapshots).Count) snapshot(s) found. Consolidating all snapshots before disk attach..." -Level WARN
    Write-Log "Removing all snapshots and committing delta changes into base disk..."
    Get-Snapshot -VM $VM | Select-Object -First 1 | Remove-Snapshot -RemoveChildren -Confirm:$false | Out-Null
    Write-Log "Waiting for snapshot consolidation to complete..."
    $timeout = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $timeout) {
        Start-Sleep -Seconds 10
        $vmRefresh = Get-VM -Id $VM.Id
        $remaining = Get-Snapshot -VM $vmRefresh -ErrorAction SilentlyContinue
        if (-not $remaining) {
            Write-Log "All snapshots consolidated. Base disk is now clean." -Level SUCCESS
            return
        }
        Write-Log "Waiting for consolidation... snapshots still present: $(@($remaining).Count)"
    }
    throw "Snapshot consolidation timed out after 10 minutes. Check vSphere for errors."
}

function Add-TargetDiskToHelper {
    # Only the base (non-snapshot) VMDK can be attached to another VM.
    # Snapshot child delta disks are locked to the parent VM chain and
    # will cause a remote host communication error if you try to attach them.
    # Remove-AllSnapshots must be called before this function.
    param($HelperVM, [string]$DiskPath)

    $attachedDisk = Get-HardDisk -VM $HelperVM | Where-Object { $_.Filename -eq $DiskPath }
    if ($attachedDisk) {
        Write-Log "Disk $DiskPath is already attached to helper VM $($HelperVM.Name) as $($attachedDisk.Name)." -Level WARN
        return
    }

    Write-Log "Attaching $DiskPath to helper VM $($HelperVM.Name)..."
    $newDisk = New-HardDisk -VM $HelperVM -DiskPath $DiskPath -Confirm:$false
    Write-Log "Disk attached to helper VM as '$($newDisk.Name)'." -Level SUCCESS
}

function Remove-TargetDiskFromHelper {
    param($HelperVM, [string]$DiskPath)
    Write-Log "Detaching target disk from helper VM $($HelperVM.Name)..."
    $attachedDisk = Get-HardDisk -VM $HelperVM | Where-Object { $_.Filename -eq $DiskPath }
    if ($attachedDisk) {
        Remove-HardDisk -HardDisk $attachedDisk -DeletePermanently:$false -Confirm:$false
        Write-Log "Disk detached from helper VM." -Level SUCCESS
    }
    else {
        Write-Log "Could not find the attached disk on helper VM. Check manually." -Level WARN
    }
}

function Invoke-HelperScript {
    param($HelperVM, [string]$Script, [string]$Description)
    Write-Log "Running on helper VM: $Description"
    $cred = New-Object System.Management.Automation.PSCredential(
        $HelperVMUser,
        $HelperVMPassword
    )
    $result = Invoke-VMScript -VM $HelperVM -ScriptText $Script -ScriptType PowerShell `
        -GuestCredential $cred -ErrorAction Stop
    Write-Log "Output: $($result.ScriptOutput)"
    return $result.ScriptOutput
}

function Enable-AttachedDiskOnHelper {
    param($HelperVM)
    Write-Log "Bringing newly attached disk online inside helper VM..."
    $diskScript = @'
$disks = Get-Disk | Where-Object { $_.OperationalStatus -eq 'Offline' -or $_.IsReadOnly }
foreach ($d in $disks) {
    Write-Host "Bringing Disk $($d.Number) online..."
    Set-Disk -Number $d.Number -IsReadOnly $false
    Set-Disk -Number $d.Number -IsOffline $false
}
$remaining = Get-Disk | Where-Object { $_.OperationalStatus -eq 'Offline' }
if ($remaining) { Write-Host "WARNING: Some disks still offline" } else { Write-Host "All disks online." }
'@
    Invoke-HelperScript -HelperVM $HelperVM -Script $diskScript -Description 'Bring attached disk online'
}

function Get-OfflineWindowsDrive {
    # Finds the Windows OS partition on the newly attached disk inside the helper VM.
    # Strategy:
    #   1. Identify the attached disk as the highest-numbered online disk
    #      (it is always the last disk added to the helper VM)
    #   2. Sort its partitions by size descending - the OS partition is always
    #      the largest partition on a Windows Server disk
    #   3. For each candidate partition, temporarily assign a drive letter if
    #      none exists using Add-PartitionAccessPath
    #   4. Check for Windows\System32\config\SYSTEM to confirm OS partition
    #   5. Clean up any temporary letters assigned to non-OS partitions
    #   6. Return the drive letter of the confirmed OS partition
    param($HelperVM)
    Write-Log "Searching for Windows OS partition on attached disk..."
    $findScript = @'
$systemDrive = $env:SystemDrive.TrimEnd('\')

$targetDisk = Get-Disk | Where-Object { $_.OperationalStatus -eq 'Online' } | Sort-Object Number | Select-Object -Last 1
if (-not $targetDisk) { Write-Host "NODISK"; exit 1 }
Write-Host "Scanning Disk $($targetDisk.Number) ($($targetDisk.FriendlyName)) - $([math]::Round($targetDisk.Size/1GB,1)) GB"

$tempLetters = @()
$foundDrive  = $null

$partitions = Get-Partition -DiskNumber $targetDisk.Number |
    Where-Object { $_.Type -notin @('Reserved','Unknown','System') -and $_.Size -gt 1GB } |
    Sort-Object Size -Descending

foreach ($part in $partitions) {
    $letter = $part.DriveLetter
    $tempAssigned = $false

    if (-not $letter -or $letter -eq [char]0) {
        $availLetter = 68..90 | ForEach-Object { [char]$_ } | Where-Object {
            -not (Get-PSDrive -Name ([string]$_) -ErrorAction SilentlyContinue)
        } | Select-Object -First 1
        if (-not $availLetter) {
            Write-Host "No free drive letter available, skipping partition $($part.PartitionNumber)"
            continue
        }
        try {
            Add-PartitionAccessPath -DiskNumber $targetDisk.Number -PartitionNumber $part.PartitionNumber -AccessPath "$($availLetter):" -ErrorAction Stop
            $letter = $availLetter
            $tempAssigned = $true
            $tempLetters += [PSCustomObject]@{ Letter = "$($availLetter):"; Disk = $targetDisk.Number; Part = $part.PartitionNumber }
            Write-Host "Assigned temp letter $($availLetter): to partition $($part.PartitionNumber) ($([math]::Round($part.Size/1GB,1)) GB)"
        } catch {
            Write-Host "Could not assign letter to partition $($part.PartitionNumber): $_"
            continue
        }
    } else {
        Write-Host "Partition $($part.PartitionNumber) already has letter $($letter): ($([math]::Round($part.Size/1GB,1)) GB)"
    }

    $checkPath = "$($letter):\Windows\System32\config\SYSTEM"
    Write-Host "Checking: $checkPath"

    if (Test-Path $checkPath) {
        $foundDrive = "$($letter):"
        Write-Host "WINROOT:$foundDrive"
        break
    }

    if ($tempAssigned) {
        Remove-PartitionAccessPath -DiskNumber $targetDisk.Number -PartitionNumber $part.PartitionNumber -AccessPath "$($letter):" -ErrorAction SilentlyContinue
        $tempLetters = $tempLetters | Where-Object { $_.Letter -ne "$($letter):" }
        Write-Host "Removed temp letter $($letter): (not Windows partition)"
    }
}

if (-not $foundDrive) {
    foreach ($tl in $tempLetters) {
        Remove-PartitionAccessPath -DiskNumber $tl.Disk -PartitionNumber $tl.Part -AccessPath $tl.Letter -ErrorAction SilentlyContinue
    }
    Write-Host "NOTFOUND"
    exit 1
}
'@
    $out = Invoke-HelperScript -HelperVM $HelperVM -Script $findScript -Description 'Find offline Windows drive'
    $driveLetter = ($out.Trim().Split("`n") | Where-Object { $_ -match '^WINROOT:[A-Z]:' } | Select-Object -Last 1) -replace 'WINROOT:', ''
    if (-not $driveLetter) {
        throw "Could not find a Windows installation on the attached disk. Output: $out"
    }
    Write-Log "Offline Windows OS partition found at $driveLetter" -Level SUCCESS
    return $driveLetter
}

function Invoke-DISMInjection {
    param($HelperVM, [string]$OfflineDrive)
    foreach ($svc in @('viostor', 'vioscsi')) {
        $driverPath = "$VirtIODriverPath\$svc\$GuestOSFolder\amd64"
        $dismScript = @"
`$driverPath = '$driverPath'
`$imagePath  = '$OfflineDrive\'
if (-not (Test-Path `$driverPath)) { Write-Host "MISSING:`$driverPath"; exit 1 }
`$result = & dism.exe /Image:"`$imagePath" /Add-Driver /Driver:"`$driverPath" /Recurse 2>&1
Write-Host `$result
if (`$LASTEXITCODE -ne 0) { Write-Host "DISM_FAILED:Exit`$LASTEXITCODE"; exit 1 }
Write-Host "DISM_OK"
"@
        $out = Invoke-HelperScript -HelperVM $HelperVM -Script $dismScript -Description "DISM inject $svc"
        if ($out -match 'DISM_FAILED' -or $out -match 'MISSING:') {
            throw "DISM injection failed for $svc. Output: $out"
        }
        Write-Log "DISM injection OK for $svc." -Level SUCCESS
    }
}

function Set-OfflineBootStart {
    param($HelperVM, [string]$OfflineDrive)
    Write-Log "Setting viostor and vioscsi to BOOT_START in offline registry..."
    $regScript = @"
`$hive = '$OfflineDrive\Windows\System32\config\SYSTEM'
`$tempKey = 'HKLM\OFFLINESYS_INJECT'
reg.exe load `$tempKey `$hive | Out-Null
try {
    `$selectPath = 'Registry::HKEY_LOCAL_MACHINE\OFFLINESYS_INJECT\Select'
    `$cs = (Get-ItemProperty -Path `$selectPath -Name Current).Current
    `$csKey = 'ControlSet{0:d3}' -f `$cs
    foreach (`$svc in @('viostor','vioscsi')) {
        `$svcPath = "Registry::HKEY_LOCAL_MACHINE\OFFLINESYS_INJECT\`$csKey\Services\`$svc"
        if (Test-Path `$svcPath) {
            New-ItemProperty -Path `$svcPath -Name Start -PropertyType DWord -Value 0 -Force | Out-Null
            Write-Host "SET_BOOT_START:`$svc"
        } else {
            Write-Host "KEY_MISSING:`$svc"
        }
    }
} finally {
    [gc]::Collect()
    Start-Sleep -Seconds 2
    reg.exe unload `$tempKey | Out-Null
    Write-Host "HIVE_UNLOADED"
}
"@
    $out = Invoke-HelperScript -HelperVM $HelperVM -Script $regScript -Description 'Set offline BOOT_START registry'
    if ($out -match 'KEY_MISSING') {
        Write-Log "One or more service keys missing in offline registry. Verify manually." -Level WARN
    }
    if (-not ($out -match 'HIVE_UNLOADED')) {
        throw "Offline registry hive did not unload cleanly. Output: $out"
    }
    Write-Log "Offline BOOT_START registry update completed." -Level SUCCESS
}

function Disable-AttachedDiskOnHelper {
    param($HelperVM, [string]$DriveLetter)
    Write-Log "Setting attached disk offline inside helper VM before detaching..."
    $offlineScript = @"
`$letter = '$DriveLetter'
`$vol = Get-Volume -DriveLetter (`$letter.TrimEnd(':'))
if (`$vol) {
    `$disk = `$vol | Get-Partition | Get-Disk
    Set-Disk -Number `$disk.Number -IsOffline `$true
    Write-Host "DISK_OFFLINED"
} else { Write-Host "VOL_NOT_FOUND" }
"@
    $out = Invoke-HelperScript -HelperVM $HelperVM -Script $offlineScript -Description 'Offline disk before detach'
    if ($out -match 'VOL_NOT_FOUND') {
        Write-Log "Could not find volume $DriveLetter to offline. Proceeding with caution." -Level WARN
    }
    else {
        Write-Log "Disk offlined in helper VM." -Level SUCCESS
    }
}

function Test-TargetReadiness {
    param($TargetVM)
    Write-Log "Waiting for target VM to boot and VMware Tools to report running..."
    $timeout = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $timeout) {
        $vm = Get-VM -Id $TargetVM.Id
        if ($vm.ExtensionData.Guest.ToolsRunningStatus -eq 'guestToolsRunning') {
            Write-Log "VMware Tools running on $($vm.Name). Boot confirmed OK." -Level SUCCESS
            return $true
        }
        Start-Sleep 15
    }
    Write-Log "Timed out waiting for VMware Tools on $($TargetVM.Name). Verify manually." -Level WARN
    return $false
}

function Copy-VirtIOToOfflineDisk {
    # Copies the VirtIO driver folder directly from the helper VM filesystem onto
    # the target disk while it is still mounted as a local volume on the helper VM.
    # Because both source and destination are local paths on the helper VM this is
    # a single Copy-Item call — no zip, no network transfer, no management-PC hop.
    #
    # Destination on the target disk: <offlineDrive>\Windows\Temp\virtio-win-install\
    # The folder will be there waiting when the target VM boots.
    param($HelperVM, [string]$OfflineDrive)

    $destPath = "$OfflineDrive\Windows\Temp\virtio-win-install"
    Write-Log "Copying '$VirtIODriverPath' -> '$destPath' (local copy on helper VM)..."

    $cred = New-Object System.Management.Automation.PSCredential(
        $HelperVMUser, $HelperVMPassword)

    $copyScript = @"
if (Test-Path '$destPath') { Remove-Item '$destPath' -Recurse -Force }
New-Item -ItemType Directory -Path '$destPath' | Out-Null
Copy-Item -Path '$VirtIODriverPath\*' -Destination '$destPath' -Recurse -Force
`$count = (Get-ChildItem '$destPath' -Recurse -File).Count
Write-Host "COPY_OK:files=`$count"
"@
    $out = Invoke-VMScript -VM $HelperVM -ScriptText $copyScript -ScriptType PowerShell `
                           -GuestCredential $cred -ErrorAction Stop
    if ($out.ScriptOutput -notmatch 'COPY_OK') {
        throw "Failed to copy VirtIO folder to offline disk. Output: $($out.ScriptOutput)"
    }
    $summary = ($out.ScriptOutput -split "`n" | Where-Object { $_ -match 'COPY_OK' }).Trim()
    Write-Log "VirtIO folder copied to offline disk. $summary" -Level SUCCESS
}

function Install-VirtIOGuestTools {
    # Runs virtio-win-guest-tools.exe silently on the target VM after it has booted.
    # The installer was already placed at C:\Windows\Temp\virtio-win-install\ by
    # Copy-VirtIOToOfflineDisk while the disk was mounted, so no file transfer is
    # needed here — just execute and clean up.
    param($TargetVM)

    $targetCred = New-Object System.Management.Automation.PSCredential(
        $TargetVMUser, $TargetVMPassword)

    $installDir = 'C:\Windows\Temp\virtio-win-install'

    Write-Log "Running virtio-win-guest-tools.exe on $($TargetVM.Name)..."
    $installScript = @"
`$installer = '$installDir\virtio-win-guest-tools.exe'
if (-not (Test-Path `$installer)) { Write-Host 'INSTALLER_NOT_FOUND'; exit 1 }
`$proc = Start-Process -FilePath `$installer -ArgumentList '/install /quiet /norestart' -Wait -PassThru
Write-Host "INSTALL_EXIT:`$(`$proc.ExitCode)"
# Exit code 3010 = success, reboot required
if (`$proc.ExitCode -ne 0 -and `$proc.ExitCode -ne 3010) { Write-Host 'INSTALL_FAILED'; exit 1 }
Write-Host 'INSTALL_OK'
Remove-Item '$installDir' -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'CLEANUP_OK'
"@
    $out = Invoke-VMScript -VM $TargetVM -ScriptText $installScript -ScriptType PowerShell `
                           -GuestCredential $targetCred -ErrorAction Stop
    Write-Log "Installer output: $($out.ScriptOutput.Trim())"
    if ($out.ScriptOutput -notmatch 'INSTALL_OK') {
        throw "virtio-win-guest-tools installation failed on $($TargetVM.Name). Output: $($out.ScriptOutput)"
    }
    Write-Log "virtio-win-guest-tools installed successfully on $($TargetVM.Name)." -Level SUCCESS
}

function Invoke-MorpheusMigration {
    # Triggers a VM migration plan in HPE Morpheus VM Essentials via the REST API.
    #
    # Flow:
    #   1. Obtain/validate API bearer token
    #   2. Locate the VM in Morpheus by name (GET /api/servers)
    #   3. Create a migration plan targeting the HVM cloud (POST /api/migrations)
    #   4. Start the migration plan (POST /api/migrations/{id}/run)
    #   5. Poll GET /api/migrations/{id} until status is 'complete', 'failed', or timeout
    #
    # NOTE: API endpoint paths and payload schema can vary by VM Essentials version.
    # If you hit 404s, verify the exact paths against your local Swagger docs at:
    #   https://<MorpheusServer>/api/swagger.json
    # or capture the browser Network tab calls from Tools > Migrations in the UI.
    param($TargetVM)

    $baseUri = "https://$MorpheusServer"

    # Suppress SSL certificate errors for self-signed certs (PowerShell 5.x compatible)
    if ($MorpheusSkipSSL) {
        if (-not ([System.Management.Automation.PSTypeName]'TrustAllCertsPolicy').Type) {
            Add-Type @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class TrustAllCertsPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
        }
        [System.Net.ServicePointManager]::CertificatePolicy = New-Object TrustAllCertsPolicy
    }

    # --- Step 1: Obtain bearer token ---
    $token = $MorpheusToken
    if (-not $token) {
        Write-Log "Obtaining Morpheus API token for user '$MorpheusUser'..."
        $authBody = "username=$([uri]::EscapeDataString($MorpheusUser))" +
                    "&password=$([uri]::EscapeDataString($MorpheusPassword))" +
                    "&grant_type=password&client_id=morph-api"
        $authResp = Invoke-RestMethod -Uri "$baseUri/oauth/token" -Method POST `
                        -Body $authBody -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop
        $token = $authResp.access_token
        Write-Log "Morpheus API token obtained." -Level SUCCESS
    }
    $headers = @{ Authorization = "Bearer $token" }

    # --- Step 2: Find VM in Morpheus ---
    Write-Log "Looking up '$($TargetVM.Name)' in Morpheus..."
    $encodedName = [uri]::EscapeDataString($TargetVM.Name)
    $searchResp = Invoke-RestMethod -Uri "$baseUri/api/servers?name=$encodedName&max=10" `
                      -Method GET -Headers $headers -ErrorAction Stop
    $morphVM = $searchResp.servers | Where-Object { $_.name -eq $TargetVM.Name } | Select-Object -First 1
    if (-not $morphVM) {
        throw ("'$($TargetVM.Name)' was not found in Morpheus. " +
               "Ensure the VMware cloud integration has discovered this VM in the Morpheus UI.")
    }
    Write-Log "Found in Morpheus: id=$($morphVM.id), cloud=$($morphVM.cloud.name)" -Level SUCCESS

    # --- Step 3: Create migration plan ---
    $planName = "PreppMig-$($TargetVM.Name)-$(Get-Date -Format 'yyyyMMdd-HHmm')"
    Write-Log "Creating Morpheus migration plan '$planName'..."
    $planBody = @{
        migration = @{
            name        = $planName
            targetCloud = @{ id = [int]$MorpheusTargetCloudId }
            vms         = @( @{ id = $morphVM.id } )
        }
    } | ConvertTo-Json -Depth 5
    $createResp = Invoke-RestMethod -Uri "$baseUri/api/migrations" -Method POST `
                      -Headers $headers -Body $planBody -ContentType 'application/json' -ErrorAction Stop
    $planId = $createResp.migration.id
    Write-Log "Migration plan created: id=$planId" -Level SUCCESS

    # --- Step 4: Start the migration plan ---
    Write-Log "Starting migration plan $planId..."
    Invoke-RestMethod -Uri "$baseUri/api/migrations/$planId/run" -Method POST `
        -Headers $headers -ContentType 'application/json' -ErrorAction Stop | Out-Null
    Write-Log "Migration plan started. Polling for completion (timeout: $MorpheusMigrationTimeoutHours hr)..." -Level SUCCESS

    # --- Step 5: Poll for completion ---
    $deadline = (Get-Date).AddHours($MorpheusMigrationTimeoutHours)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        $statusResp = Invoke-RestMethod -Uri "$baseUri/api/migrations/$planId" `
                          -Method GET -Headers $headers -ErrorAction Stop
        $status = $statusResp.migration.status
        $pct    = $statusResp.migration.percentComplete
        Write-Log "Migration status: $status ($pct%)"
        switch ($status) {
            'complete'  {
                Write-Log "'$($TargetVM.Name)' migrated successfully to HVM cloud." -Level SUCCESS
                return
            }
            'failed'    { throw "Morpheus migration FAILED for '$($TargetVM.Name)'. Check Tools > Migrations in the Morpheus UI for details." }
            'cancelled' { throw "Morpheus migration was CANCELLED for '$($TargetVM.Name)'." }
        }
    }
    Write-Log "Timed out after $MorpheusMigrationTimeoutHours hour(s) waiting for migration. Check the Morpheus UI." -Level WARN
}

function Get-VirtIOGuestOSFolder {
    # Detects the actual Windows OS version by loading the offline SOFTWARE registry
    # hive from the target disk already mounted on the helper VM, then reading
    # CurrentBuildNumber from Microsoft\Windows NT\CurrentVersion.
    #
    # This is more reliable than vCenter's GuestId/GuestFullName, which older vCenter
    # versions cap at Windows Server 2022 even when the VM actually runs 2025.
    #
    # Build number -> VirtIO subfolder mapping:
    #   >= 26100  -> 2k25   (Windows Server 2025 / Windows 11 24H2)
    #   >= 20348  -> 2k22   (Windows Server 2022)
    #   >= 17763  -> 2k19   (Windows Server 2019)
    #   >= 14393  -> 2k16   (Windows Server 2016)
    #   >=  9200  -> 2k12R2 (Windows Server 2012 / 2012 R2)
    param($HelperVM, [string]$OfflineDrive)

    Write-Log "Detecting OS version from offline SOFTWARE hive on $OfflineDrive..."
    $cred = New-Object System.Management.Automation.PSCredential(
        $HelperVMUser, $HelperVMPassword)

    $detectScript = @"
`$hive    = '$OfflineDrive\Windows\System32\config\SOFTWARE'
`$tempKey = 'HKLM\OFFLINESW_DETECT'
if (-not (Test-Path `$hive)) { Write-Host 'HIVE_NOT_FOUND'; exit 1 }
reg.exe load `$tempKey `$hive 2>&1 | Out-Null
try {
    `$cvPath  = 'Registry::HKEY_LOCAL_MACHINE\OFFLINESW_DETECT\Microsoft\Windows NT\CurrentVersion'
    `$cv      = Get-ItemProperty -Path `$cvPath -ErrorAction Stop
    `$build   = `$cv.CurrentBuildNumber
    `$product = if (`$cv.ProductName) { `$cv.ProductName } else { `$cv.DisplayVersion }
    Write-Host "BUILD:`$build"
    Write-Host "PRODUCT:`$product"
} finally {
    [gc]::Collect()
    Start-Sleep -Seconds 2
    reg.exe unload `$tempKey 2>&1 | Out-Null
    Write-Host 'HIVE_UNLOADED'
}
"@
    $out = Invoke-VMScript -VM $HelperVM -ScriptText $detectScript -ScriptType PowerShell `
                           -GuestCredential $cred -ErrorAction Stop

    if ($out.ScriptOutput -match 'HIVE_NOT_FOUND') {
        throw "SOFTWARE hive not found on $OfflineDrive. Cannot auto-detect OS. Use -GuestOSFolder to override."
    }
    if ($out.ScriptOutput -notmatch 'HIVE_UNLOADED') {
        throw "SOFTWARE hive did not unload cleanly. Output: $($out.ScriptOutput)"
    }

    $buildStr   = ($out.ScriptOutput -split "`n" | Where-Object { $_ -match '^BUILD:' } | Select-Object -Last 1) -replace 'BUILD:',''
    $productStr = ($out.ScriptOutput -split "`n" | Where-Object { $_ -match '^PRODUCT:' } | Select-Object -Last 1) -replace 'PRODUCT:',''
    $build      = [int]$buildStr.Trim()
    $product    = $productStr.Trim()

    Write-Log "Offline disk OS: '$product' (Build: $build)"

    $folder = if     ($build -ge 26100) { '2k25'   }
              elseif ($build -ge 20348) { '2k22'   }
              elseif ($build -ge 17763) { '2k19'   }
              elseif ($build -ge 14393) { '2k16'   }
              elseif ($build -ge 9200)  { '2k12R2' }
              else                      { $null    }

    if (-not $folder) {
        throw ("Cannot map OS build $build ('$product') to a VirtIO driver subfolder. " +
               "Use -GuestOSFolder to override manually.")
    }
    Write-Log "Mapped build $build -> VirtIO subfolder: $folder" -Level SUCCESS
    return $folder
}

Write-Log "=== HPE Morpheus Pre-Migration VirtIO Injection via Helper VM ==="
Write-Log "Target VM      : $TargetVMName"
Write-Log "Helper VM      : $HelperVMName"
Write-Log "VirtIO Path    : $VirtIODriverPath (path as seen from inside the helper VM)"
Write-Log "OS Folder      : $(if ($GuestOSFolder) { "$GuestOSFolder (override)" } else { '(auto-detect from offline disk)' })"
Write-Log "Guest Tools    : $(if ($InstallGuestTools) { 'yes' } else { 'no' })"
Write-Log "Morpheus Mig.  : $(if ($TriggerMorpheusMigration) { "yes -> $MorpheusServer (cloud id: $MorpheusTargetCloudId)" } else { 'no' })"
Write-Log "Log File       : $LogFile"

Connect-VC

$targetVM = Get-VM -Name $TargetVMName -ErrorAction Stop
$helperVM = Get-VM -Name $HelperVMName -ErrorAction Stop

# GuestOSFolder is resolved later, after the target disk is mounted on the helper VM,
# so the offline SOFTWARE hive can be read for accurate OS detection.

$targetHost = $targetVM.VMHost
$helperHost = $helperVM.VMHost
if ($targetHost.Name -ne $helperHost.Name) {
    Write-Log "Target VM is on $($targetHost.Name) but Helper VM is on $($helperHost.Name)." -Level WARN
    Write-Log "Attempting to migrate Helper VM $($helperVM.Name) to host $($targetHost.Name)..."
    try {
        Move-VM -VM $helperVM -Destination $targetHost -Confirm:$false -ErrorAction Stop | Out-Null
        Write-Log "Helper VM successfully migrated to $($targetHost.Name)." -Level SUCCESS
        # Refresh helper VM object to update host properties
        $helperVM = Get-VM -Id $helperVM.Id
    } catch {
        Write-Log "Failed to migrate Helper VM: $_" -Level ERROR
        throw "VM host mismatch and migration failed. Please manually align hosts. Error: $_"
    }
} else {
    Write-Log "Both VMs confirmed on same ESXi host: $($targetHost.Name)" -Level SUCCESS
}

if ($helperVM.PowerState -ne 'PoweredOn') {
    Write-Log "Helper VM $HelperVMName is not powered on. Starting it now..." -Level WARN
    Start-VM -VM $helperVM -Confirm:$false | Out-Null
}

Write-Log "Waiting for VMware Tools to report running on helper VM $HelperVMName..."
$helperTimeout = (Get-Date).AddMinutes(10)
$helperReady = $false
while ((Get-Date) -lt $helperTimeout) {
    $helperVM = Get-VM -Id $helperVM.Id
    if ($helperVM.ExtensionData.Guest.ToolsRunningStatus -eq 'guestToolsRunning') {
        Write-Log "Helper VM $HelperVMName is ready (VMware Tools running)." -Level SUCCESS
        $helperReady = $true
        break
    }
    Start-Sleep 15
}
if (-not $helperReady) {
    throw "Timed out waiting for Helper VM $HelperVMName to boot and VMware Tools to report running."
}

$attachedDiskPath = $null
$diskOfflined = $false
$vmStarted = $false

try {
    Stop-VMGracefully -VM $targetVM

    Remove-AllSnapshots -VM $targetVM

    Write-Log "Identifying base disk path for $($targetVM.Name)..."
    $baseDisk = Get-HardDisk -VM $targetVM | Sort-Object Name | Select-Object -First 1
    $attachedDiskPath = $baseDisk.Filename
    Write-Log "Base disk path: $attachedDiskPath"

    Add-TargetDiskToHelper -HelperVM $helperVM -DiskPath $attachedDiskPath
    Start-Sleep -Seconds 5

    Enable-AttachedDiskOnHelper -HelperVM $helperVM
    $offlineDrive = Get-OfflineWindowsDrive -HelperVM $helperVM

    # Resolve the VirtIO OS subfolder now that the disk is mounted and readable.
    # If -GuestOSFolder was passed explicitly that takes priority; otherwise detect
    # from the actual offline SOFTWARE hive so the correct drivers are injected.
    if (-not $GuestOSFolder) {
        $GuestOSFolder = Get-VirtIOGuestOSFolder -HelperVM $helperVM -OfflineDrive $offlineDrive
    } else {
        Write-Log "GuestOSFolder override in use: $GuestOSFolder" -Level WARN
    }

    Invoke-DISMInjection -HelperVM $helperVM -OfflineDrive $offlineDrive
    Set-OfflineBootStart -HelperVM $helperVM -OfflineDrive $offlineDrive

    # Copy the VirtIO folder onto the target disk now, while it is still mounted
    # on the helper VM as a local volume. This is a direct Copy-Item — no zip,
    # no management-PC hop. The files will be at C:\Windows\Temp\virtio-win-install\
    # when the target VM boots.
    if ($InstallGuestTools) {
        Copy-VirtIOToOfflineDisk -HelperVM $helperVM -OfflineDrive $offlineDrive
    }

    Disable-AttachedDiskOnHelper -HelperVM $helperVM -DriveLetter $offlineDrive
    $diskOfflined = $true

    Remove-TargetDiskFromHelper -HelperVM $helperVM -DiskPath $attachedDiskPath
    $attachedDiskPath = $null

    New-SafetySnapshot -VM $targetVM

    Write-Log "Starting target VM $TargetVMName..."
    Start-VM -VM $targetVM -Confirm:$false | Out-Null
    $vmStarted = $true

    $booted = Test-TargetReadiness -TargetVM $targetVM
    if ($booted) {
        if ($InstallGuestTools) {
            Install-VirtIOGuestTools -TargetVM $targetVM
        }
        if ($TriggerMorpheusMigration) {
            # Morpheus migration is an offline process - the source VM must be shut
            # down so the disk is not in use during streaming/conversion.
            Write-Log "Shutting down $TargetVMName before triggering Morpheus migration..."
            Stop-VMGracefully -VM $targetVM
            Invoke-MorpheusMigration -TargetVM $targetVM
            Write-Log "SUCCESS: $TargetVMName has been migrated to HPE VM Essentials." -Level SUCCESS
        } else {
            Write-Log "SUCCESS: $TargetVMName VirtIO injection complete and boot verified. Ready for Morpheus migration." -Level SUCCESS
        }
        Remove-SafetySnapshot -VM $targetVM
    }
    else {
        Write-Log "WARNING: Boot check timed out. Verify VM manually before migrating." -Level WARN
    }
}
catch {
    Write-Log "FATAL ERROR: $_" -Level ERROR
    if ($attachedDiskPath) {
        Write-Log "Cleanup: removing attached disk from helper VM..." -Level WARN
        try { Remove-TargetDiskFromHelper -HelperVM $helperVM -DiskPath $attachedDiskPath } catch {
            Write-Log "Could not detach disk from helper VM: $_" -Level ERROR
        }
    }
    if (-not $vmStarted) {
        Write-Log "Attempting to restart target VM after failure..." -Level WARN
        try { Start-VM -VM $targetVM -Confirm:$false | Out-Null } catch {
            Write-Log "Could not restart target VM: $_" -Level ERROR
        }
    }
    throw
}
finally {
    Disconnect-VIServer -Server $VCServer -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Write-Log "Disconnected from vCenter. Log: $LogFile"
}

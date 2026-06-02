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
#  15. Schedules silent VMware Tools removal on the live target VM via a detached
#      background process (decoupled from the VIX channel) then waits for the OS
#      to shut itself down cleanly.  Use -DoNotRemoveVMwareTools to skip this step.
#  16. (Optional) Triggers a Morpheus migration plan to import the VM into HVM
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
#   DoNotInstallGuestTools - Switch: skip the VirtIO guest tools copy and silent install.
#                      By default the script copies VirtIODriverPath directly onto the
#                      target disk (C:\Windows\Temp\virtio-win-install) while it is still
#                      mounted on the helper VM, then after boot runs
#                      virtio-win-guest-tools.exe silently and cleans up.
#                      No zip, no management-PC hop — pure local Copy-Item.
#                      Specify this switch to disable that behaviour.
#   TargetVMUser     - Local admin username on the target VM (required unless both -DoNotInstallGuestTools and -DoNotRemoveVMwareTools are set)
#   TargetVMPassword - Password for the target VM admin account (required unless both -DoNotInstallGuestTools and -DoNotRemoveVMwareTools are set)
#   DoNotRemoveVMwareTools - Switch: skip the automatic post-migration VMware Tools removal.
#                      By default, when -TriggerMorpheusMigration is set, the script
#                      removes VMware Tools from the HVM instance after migration via
#                      the Morpheus agent (with direct WinRM as fallback).
#                      Specify this switch to skip removal.
#   DoNotEnableRDP   - Switch: skip the automatic Remote Desktop enablement pre-migration.
#                      By default the script enables RDP on the target VM (via VMware guest
#                      script) before migration so the HVM instance is immediately accessible
#                      via Remote Desktop.  Specify this switch to skip this step.
#   TriggerMorpheusMigration - Switch: after boot verification shut down the VM and
#                      trigger a Morpheus migration plan to import it into HVM.
#                      Requires -MorpheusServer and -MorpheusTargetCloudId.
#   MorpheusServer   - Morpheus/VM Essentials FQDN or IP (no https:// prefix)
#   MorpheusToken    - Morpheus API bearer token (preferred over user/password)
#   MorpheusUser     - Morpheus username (used to obtain token if -MorpheusToken absent)
#   MorpheusPassword - Morpheus password (used to obtain token if -MorpheusToken absent)
#   MorpheusTargetCloudId - Morpheus cloud ID of the target HVM cluster (required)
#   MorpheusTargetNetworkId - (Optional) Morpheus ID of the target network to connect the VM
#   MorpheusTargetStoreId   - (Optional) Morpheus ID of the target storage/datastore for disk placement
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
    [string]$TargetVMName = '',
    [string]$HelperVMName = '',
    [Parameter(Mandatory)][string]$HelperVMUser,
    [Parameter(Mandatory)][object]$HelperVMPassword,
    [string]$VirtIODriverPath = '',
    [ValidateSet('2k25','2k22','2k19','2k16','2k12R2','w11','w10')][string]$GuestOSFolder = '',  # blank = auto-detect from offline SOFTWARE hive on the target disk
    [string]$SnapshotName = 'Pre-VirtIO-Injection',
    [int]$ForceHardStopMin = 10,
    [switch]$SkipSnapshot,
    [switch]$DeleteSnapshot,
    [switch]$DoNotInstallGuestTools,
    [string]$TargetVMUser,
    [object]$TargetVMPassword,
    [switch]$DoNotRemoveVMwareTools,
    [switch]$DoNotEnableRDP,
    [switch]$TriggerMorpheusMigration,
    [string]$MorpheusServer,
    [string]$MorpheusToken,
    [string]$MorpheusUser,
    [string]$MorpheusPassword,
    [string]$MorpheusTargetCloudId,
    [string]$MorpheusTargetNetworkId,
    [string]$MorpheusTargetStoreId,
    [string]$MorpheusTargetPoolId,
    [switch]$MorpheusSkipSSL,
    [int]$MorpheusMigrationTimeoutHours = 4,
    [switch]$MigrationOnly,
    [switch]$SkipRollbackRestart,
    [switch]$CreatePlanOnly,
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

$InstallGuestTools = -not $DoNotInstallGuestTools.IsPresent
$RemoveVMwareTools = -not $DoNotRemoveVMwareTools.IsPresent
$EnableRDP = -not $DoNotEnableRDP.IsPresent

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "This script requires PowerShell 7.0 or later. Current version: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    throw 'PowerShell 7.0 or later is required to run this script.'
}

$needsTargetCreds = $InstallGuestTools -or ($RemoveVMwareTools -and $TriggerMorpheusMigration)
if ($needsTargetCreds -and (-not $TargetVMUser -or -not $TargetVMPassword)) {
    throw '-TargetVMUser and -TargetVMPassword are required for guest tools installation and/or VMware Tools removal. Use -DoNotInstallGuestTools and -DoNotRemoveVMwareTools to skip both.'
}

if ($MigrationOnly -and -not $TriggerMorpheusMigration) {
    throw '-MigrationOnly requires -TriggerMorpheusMigration to be specified.'
}

if ($TriggerMorpheusMigration) {
    if (-not $MorpheusServer)        { throw '-MorpheusServer is required when -TriggerMorpheusMigration is specified.' }
    if (-not $MorpheusToken -and (-not $MorpheusUser -or -not $MorpheusPassword)) {
        throw 'Either -MorpheusToken or both -MorpheusUser and -MorpheusPassword are required with -TriggerMorpheusMigration.'
    }
    # $MorpheusTargetCloudId, $MorpheusTargetNetworkId, $MorpheusTargetPoolId, and
    # $MorpheusTargetStoreId are resolved interactively if not provided (see Resolve-MorpheusTargetParameters).
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
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Scope Session -Confirm:$false | Out-Null
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

function Get-HelperDiskNumbers {
    param($HelperVM)

    $listScript = @'
$nums = Get-Disk | Select-Object -ExpandProperty Number | Sort-Object
foreach ($n in $nums) { Write-Host "DISKNUM:$n" }
'@
    $out = Invoke-HelperScript -HelperVM $HelperVM -Script $listScript -Description 'List helper VM disk numbers'
    return @($out.Trim().Split("`n") |
            Where-Object { $_ -match '^DISKNUM:\d+' } |
            ForEach-Object { [int](($_ -replace 'DISKNUM:', '').Trim()) })
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
    param(
        $HelperVM,
        [int[]]$KnownDiskNumbers
    )
    Write-Log 'Bringing newly attached disk online inside helper VM...'

    $knownCsv = if ($KnownDiskNumbers.Count -gt 0) { ($KnownDiskNumbers | ForEach-Object { [string]$_ }) -join ',' } else { '' }
    $diskScript = (@'
$knownCsv = '__KNOWN_CSV__'
$known = @()
if ($knownCsv) {
    $known = $knownCsv.Split(',') | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ }
}

$newDisks = @(Get-Disk | Where-Object { $known -notcontains $_.Number } | Sort-Object Number)
if ($newDisks.Count -eq 0) { Write-Host 'ATTACHED_DISK_NOT_FOUND'; exit 1 }
if ($newDisks.Count -gt 1) {
    Write-Host "ATTACHED_DISK_AMBIGUOUS:$(($newDisks | Select-Object -ExpandProperty Number) -join ',')"
    exit 1
}

$d = $newDisks[0]
Write-Host "ATTACHED_DISK_NUMBER:$($d.Number)"

if ($d.IsReadOnly) {
    Set-Disk -Number $d.Number -IsReadOnly $false -ErrorAction Stop
}

if ($d.IsOffline -or $d.OperationalStatus -eq 'Offline') {
    Set-Disk -Number $d.Number -IsOffline $false -ErrorAction Stop
}

Write-Host "ATTACHED_DISK_ONLINE:$($d.Number)"
'@) -replace '__KNOWN_CSV__', $knownCsv
    $out = Invoke-HelperScript -HelperVM $HelperVM -Script $diskScript -Description 'Bring attached disk online'
    if ($out -match 'ATTACHED_DISK_NOT_FOUND') {
        throw 'Unable to identify newly attached disk on helper VM.'
    }
    if ($out -match 'ATTACHED_DISK_AMBIGUOUS') {
        throw "Unable to uniquely identify newly attached disk on helper VM. Output: $out"
    }

    $diskNumber = ($out.Trim().Split("`n") |
        Where-Object { $_ -match '^ATTACHED_DISK_NUMBER:\d+' } |
        Select-Object -Last 1) -replace 'ATTACHED_DISK_NUMBER:', ''
    if (-not $diskNumber) {
        throw "Could not parse attached disk number from helper output: $out"
    }
    return [int]$diskNumber
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
    param(
        $HelperVM,
        [int]$DiskNumber
    )
    Write-Log "Searching for Windows OS partition on attached disk..."
    $findScript = (@'
$systemDrive = $env:SystemDrive.TrimEnd('\')

$targetDisk = Get-Disk -Number __DISK_NUMBER__ -ErrorAction SilentlyContinue
if (-not $targetDisk) { Write-Host "NODISK"; exit 1 }
if ($targetDisk.IsOffline -or $targetDisk.OperationalStatus -eq 'Offline') {
    Write-Host "DISK_OFFLINE:__DISK_NUMBER__"
    exit 1
}
Write-Host "Scanning Disk $($targetDisk.Number) ($($targetDisk.FriendlyName)) - $([math]::Round($targetDisk.Size/1GB,1)) GB"
Write-Host "TARGET_DISK_NUMBER:$($targetDisk.Number)"

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
'@) -replace '__DISK_NUMBER__', $DiskNumber
    $out = Invoke-HelperScript -HelperVM $HelperVM -Script $findScript -Description 'Find offline Windows drive'
    if ($out -match 'NODISK' -or $out -match 'DISK_OFFLINE') {
        throw "Target disk $DiskNumber is not online/available on helper VM. Output: $out"
    }
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
        $dismScript = (@'
$driverPath = '__DRIVER_PATH__'
$imagePath  = '__OFFLINE_DRIVE__\'
if (-not (Test-Path $driverPath)) { Write-Host "MISSING:$driverPath"; exit 1 }
$result = & dism.exe /Image:"$imagePath" /Add-Driver /Driver:"$driverPath" /Recurse 2>&1
Write-Host $result
if ($LASTEXITCODE -ne 0) { Write-Host "DISM_FAILED:Exit$LASTEXITCODE"; exit 1 }
Write-Host "DISM_OK"
'@) -replace '__DRIVER_PATH__', $driverPath -replace '__OFFLINE_DRIVE__', $OfflineDrive
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
    $regScript = (@'
$hive = '__OFFLINE_DRIVE__\Windows\System32\config\SYSTEM'
$tempKey = 'HKLM\OFFLINESYS_INJECT'
reg.exe load $tempKey $hive | Out-Null
try {
    $selectPath = 'Registry::HKEY_LOCAL_MACHINE\OFFLINESYS_INJECT\Select'
    $cs = (Get-ItemProperty -Path $selectPath -Name Current).Current
    $csKey = 'ControlSet{0:d3}' -f $cs
    foreach ($svc in @('viostor','vioscsi')) {
        $svcPath = "Registry::HKEY_LOCAL_MACHINE\OFFLINESYS_INJECT\$csKey\Services\$svc"
        if (Test-Path $svcPath) {
            New-ItemProperty -Path $svcPath -Name Start -PropertyType DWord -Value 0 -Force | Out-Null
            Write-Host "SET_BOOT_START:$svc"
        } else {
            Write-Host "KEY_MISSING:$svc"
        }
    }
} finally {
    [gc]::Collect()
    Start-Sleep -Seconds 2
    reg.exe unload $tempKey | Out-Null
    Write-Host "HIVE_UNLOADED"
}
'@) -replace '__OFFLINE_DRIVE__', $OfflineDrive
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
    param(
        $HelperVM,
        [int]$DiskNumber
    )
    Write-Log "Setting attached disk offline inside helper VM before detaching..."
    $offlineScript = (@'
$disk = Get-Disk -Number __DISK_NUMBER__ -ErrorAction SilentlyContinue
if ($disk) {
    Set-Disk -Number $disk.Number -IsOffline $true
    Write-Host "DISK_OFFLINED"
} else { Write-Host "DISK_NOT_FOUND" }
'@) -replace '__DISK_NUMBER__', $DiskNumber
    $out = Invoke-HelperScript -HelperVM $HelperVM -Script $offlineScript -Description 'Offline disk before detach'
    if ($out -match 'DISK_NOT_FOUND') {
        Write-Log "Could not find disk $DiskNumber to offline. Proceeding with caution." -Level WARN
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

    $copyScript = (@'
if (Test-Path '__DEST_PATH__') { Remove-Item '__DEST_PATH__' -Recurse -Force }
New-Item -ItemType Directory -Path '__DEST_PATH__' | Out-Null
Copy-Item -Path '__VIRTIO_PATH__\*' -Destination '__DEST_PATH__' -Recurse -Force
$count = (Get-ChildItem '__DEST_PATH__' -Recurse -File).Count
Write-Host "COPY_OK:files=$count"
'@) -replace '__DEST_PATH__', $destPath -replace '__VIRTIO_PATH__', $VirtIODriverPath
    $out = Invoke-HelperScript -HelperVM $HelperVM -Script $copyScript -Description 'Copy VirtIO folder to offline disk'
    if ($out -notmatch 'COPY_OK') {
        throw "Failed to copy VirtIO folder to offline disk. Output: $out"
    }
    $summary = ($out -split "`n" | Where-Object { $_ -match 'COPY_OK' }).Trim()
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

    Write-Log "Running virtio-win-guest-tools.exe on $($TargetVM.Name)..."
    $installScript = (@'
$installer = 'C:\Windows\Temp\virtio-win-install\virtio-win-guest-tools.exe'
if (-not (Test-Path $installer)) { Write-Host 'INSTALLER_NOT_FOUND'; exit 1 }
$proc = Start-Process -FilePath $installer -ArgumentList '/install /quiet /norestart' -Wait -PassThru
Write-Host "INSTALL_EXIT:$($proc.ExitCode)"
# Exit code 3010 = success, reboot required
if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) { Write-Host 'INSTALL_FAILED'; exit 1 }
Write-Host 'INSTALL_OK'
Remove-Item 'C:\Windows\Temp\virtio-win-install' -Recurse -Force -ErrorAction SilentlyContinue
Write-Host 'CLEANUP_OK'
'@)
    $out = Invoke-VMScript -VM $TargetVM -ScriptText $installScript -ScriptType PowerShell `
                           -GuestCredential $targetCred -ErrorAction Stop
    Write-Log "Installer output: $($out.ScriptOutput.Trim())"
    if ($out.ScriptOutput -notmatch 'INSTALL_OK') {
        throw "virtio-win-guest-tools installation failed on $($TargetVM.Name). Output: $($out.ScriptOutput)"
    }
    Write-Log "virtio-win-guest-tools installed successfully on $($TargetVM.Name)." -Level SUCCESS
}

function Enable-WinRMOnTarget {
    # Enables WinRM on the target VM via Invoke-VMScript so the post-migration
    # management channel is available once the VM boots on HVM.
    #
    # This is a best-effort pre-migration step. If it fails, a WARN is logged
    # and the migration continues — WinRM-based post-migration cleanup will be
    # unavailable but the migration itself is not blocked.
    #
    # Steps performed inside the guest:
    #   1. Enable-PSRemoting -Force
    #   2. Open WINRM-HTTP-In-TCP-PUBLIC rule (if present)
    #   3. Add explicit rules for ports 5985 (HTTP) and 5986 (HTTPS)
    #   4. Enable Basic and Negotiate WinRM authentication
    #   5. Allow unencrypted traffic (required for HTTP / IP-based connections)
    param($TargetVM)

    $targetCred = New-Object System.Management.Automation.PSCredential($TargetVMUser, $TargetVMPassword)

    Write-Log "Enabling WinRM on $($TargetVM.Name) for post-migration management channel..."
    $winrmScript = @'
$ErrorActionPreference = 'Stop'
Enable-PSRemoting -Force
Enable-NetFirewallRule -Name 'WINRM-HTTP-In-TCP-PUBLIC' -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'WinRM HTTP' -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'WinRM HTTPS' -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow -ErrorAction SilentlyContinue
Set-WSManInstance -ResourceURI winrm/config/service/auth -ValueSet @{Basic=$true}
Set-WSManInstance -ResourceURI winrm/config/service/auth -ValueSet @{Negotiate=$true}
Set-WSManInstance -ResourceURI winrm/config/service -ValueSet @{AllowUnencrypted=$true}
Write-Host 'WINRM_ENABLED'
'@
    try {
        $out = Invoke-VMScript -VM $TargetVM -ScriptText $winrmScript -ScriptType PowerShell `
                               -GuestCredential $targetCred -ErrorAction Stop
        Write-Log "WinRM setup output: $($out.ScriptOutput.Trim())"
        if ($out.ScriptOutput -notmatch 'WINRM_ENABLED') {
            throw "WinRM enablement returned unexpected output on $($TargetVM.Name): $($out.ScriptOutput)"
        }
        Write-Log "WinRM enabled on $($TargetVM.Name)." -Level SUCCESS
    } catch {
        Write-Log "WinRM enablement failed on $($TargetVM.Name) (non-fatal, migration will continue): $_" -Level WARN
        Write-Log "Post-migration VMware Tools removal via WinRM may not be available." -Level WARN
    }
}

function Enable-RDPOnTarget {
    # Enables Remote Desktop on the target VM via Invoke-VMScript so the HVM
    # instance is immediately accessible via RDP after migration.
    #
    # This is a best-effort pre-migration step. If it fails, a WARN is logged
    # and the migration continues — the VM will need RDP enabled manually later.
    #
    # Steps performed inside the guest:
    #   1. Allow RDP connections (fDenyTSConnections = 0)
    #   2. Enable the Remote Desktop firewall rule group
    #   3. Disable NLA (UserAuthentication = 0) so RDP works without domain context
    param($TargetVM)

    $targetCred = New-Object System.Management.Automation.PSCredential($TargetVMUser, $TargetVMPassword)

    Write-Log "Enabling Remote Desktop on $($TargetVM.Name) for post-migration access..."
    $rdpScript = @'
$ErrorActionPreference = 'Stop'
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name UserAuthentication -Value 0
Write-Host 'RDP_ENABLED'
'@
    try {
        $out = Invoke-VMScript -VM $TargetVM -ScriptText $rdpScript -ScriptType PowerShell `
                               -GuestCredential $targetCred -ErrorAction Stop
        Write-Log "RDP setup output: $($out.ScriptOutput.Trim())"
        if ($out.ScriptOutput -notmatch 'RDP_ENABLED') {
            throw "RDP enablement returned unexpected output on $($TargetVM.Name): $($out.ScriptOutput)"
        }
        Write-Log "Remote Desktop enabled on $($TargetVM.Name)." -Level SUCCESS
    } catch {
        Write-Log "RDP enablement failed on $($TargetVM.Name) (non-fatal, migration will continue): $_" -Level WARN
        Write-Log "Post-migration Remote Desktop access may require manual configuration." -Level WARN
    }
}

function Invoke-MorpheusRestMethod {
    # Thin wrapper around Invoke-RestMethod that injects SkipCertificateCheck
    # when $MorpheusSkipSSL is set. Defined at script scope so all Morpheus
    # helper functions can share it without nesting.
    param(
        [Parameter(Mandatory)][string]$Uri,
        [ValidateSet('GET','POST','PUT','PATCH','DELETE')][string]$Method = 'GET',
        [hashtable]$Headers,
        $Body,
        [string]$ContentType
    )

    $invokeParams = @{ Uri = $Uri; Method = $Method; ErrorAction = 'Stop' }
    if ($Headers)        { $invokeParams.Headers = $Headers }
    if ($null -ne $Body) { $invokeParams.Body = $Body }
    if ($ContentType)    { $invokeParams.ContentType = $ContentType }
    if ($MorpheusSkipSSL) {
        $invokeParams.SkipCertificateCheck = $true
    }

    return Invoke-RestMethod @invokeParams
}

function Get-MorpheusAuthHeaders {
    # Obtains a Morpheus API bearer token (or reuses $MorpheusToken if provided)
    # and returns a headers hashtable ready for use with Invoke-MorpheusRestMethod.
    $baseUri = "https://$MorpheusServer"
    $token = $MorpheusToken
    if (-not $token) {
        Write-Log "Obtaining Morpheus API token for user '$MorpheusUser'..."
        $authBody = "username=$([uri]::EscapeDataString($MorpheusUser))" +
                    "&password=$([uri]::EscapeDataString($MorpheusPassword))" +
                    "&grant_type=password&client_id=morph-api"
        $authResp = Invoke-MorpheusRestMethod -Uri "$baseUri/oauth/token" -Method POST `
                        -Body $authBody -ContentType 'application/x-www-form-urlencoded'
        $token = $authResp.access_token
        Write-Log 'Morpheus API token obtained.' -Level SUCCESS
    }
    return @{ Authorization = "Bearer $token" }
}

function Get-MorpheusInstanceIdByName {
    # Looks up a Morpheus instance by exact name and returns its integer ID.
    # Retries several times with a delay to account for post-migration discovery lag.
    param(
        [Parameter(Mandatory)][string]$Name,
        [hashtable]$Headers,
        [int]$RetryCount = 5,
        [int]$RetryDelaySec = 30
    )

    $baseUri = "https://$MorpheusServer"
    $encodedName = [uri]::EscapeDataString($Name)
    for ($i = 0; $i -lt $RetryCount; $i++) {
        try {
            $resp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/instances?name=$encodedName&max=10" `
                        -Method GET -Headers $Headers
            $instance = $resp.instances | Where-Object { $_.name -eq $Name } | Select-Object -First 1
            if ($instance) {
                Write-Log "Found Morpheus instance '$Name': id=$($instance.id)" -Level SUCCESS
                return [int]$instance.id
            }
            Write-Log "Instance '$Name' not yet visible in Morpheus (attempt $($i+1)/$RetryCount). Retrying in ${RetryDelaySec}s..." -Level WARN
        } catch {
            Write-Log "Error looking up instance '$Name': $_ — retrying in ${RetryDelaySec}s..." -Level WARN
        }
        if ($i -lt $RetryCount - 1) { Start-Sleep -Seconds $RetryDelaySec }
    }
    throw "Could not find Morpheus instance '$Name' after $RetryCount attempts. Verify the VM appeared in Morpheus as an HVM instance."
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
    $migrationPlanId = $null

    # PowerShell 7+ only path: use per-request certificate skip when requested.
    if ($MorpheusSkipSSL) {
        Write-Log 'Using per-request certificate skip for Morpheus API calls.' -Level WARN
    }

    function Remove-MorpheusArtifacts {
        param(
            [int]$PlanId,
            [hashtable]$Headers
        )

        if (-not $PlanId) { return }

        Write-Log "Rollback: removing Morpheus migration artifacts for plan $PlanId..." -Level WARN
        try {
            Invoke-MorpheusRestMethod -Uri "$baseUri/api/migrations/$PlanId" -Method DELETE -Headers $Headers | Out-Null
            Write-Log "Rollback: deleted Morpheus migration plan $PlanId." -Level SUCCESS
        } catch {
            if ("$_" -match 'not found|404') {
                Write-Log "Rollback: migration plan $PlanId already removed (auto-deleted or completed). OK." -Level SUCCESS
            } else {
                throw "Delete migration plan failed ($PlanId): $_"
            }
        }
    }

    try {
        # --- Step 1: Obtain bearer token ---
        $headers = Get-MorpheusAuthHeaders

        # --- Step 2: Find VM in Morpheus ---
        Write-Log "Looking up '$($TargetVM.Name)' in Morpheus..."
        $encodedName = [uri]::EscapeDataString($TargetVM.Name)
        $searchResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/servers?name=$encodedName&max=10" `
                          -Method GET -Headers $headers
        $morphVM = $searchResp.servers | Where-Object { $_.name -eq $TargetVM.Name } | Select-Object -First 1
        if (-not $morphVM) {
            throw ("'$($TargetVM.Name)' was not found in Morpheus. " +
                   'Ensure the VMware cloud integration has discovered this VM in the Morpheus UI.')
        }
        $cloudInfo = 'unknown'
        if ($morphVM.PSObject.Properties['cloud'] -and $morphVM.cloud) {
            $cloudInfo = $morphVM.cloud.name
        } elseif ($morphVM.PSObject.Properties['zone'] -and $morphVM.zone) {
            $cloudInfo = $morphVM.zone.name
        }
        Write-Log "Found in Morpheus: id=$($morphVM.id), cloud=$cloudInfo" -Level SUCCESS

        # --- Step 3: Create migration plan ---
        $sourceCloudId = if ($morphVM.PSObject.Properties['zone'] -and $morphVM.zone) { $morphVM.zone.id } else { $morphVM.zoneId }
        $planName = "PreppMig-$($TargetVM.Name)-$(Get-Date -Format 'yyyyMMdd-HHmm')"
        Write-Log "Creating Morpheus migration plan '$planName' (sourceCloud=$sourceCloudId, targetCloud=$MorpheusTargetCloudId)..."

        # Build per-server object, including NIC mappings if a target network was specified
        $serverObj = [ordered]@{ id = [int]$morphVM.id }

        # Fetch source server details once (needed for network + datastore source IDs)
        $srvResp = $null
        $migObj_networks = $null
        $migObj_datastores = $null
        if ($MorpheusTargetNetworkId -or $MorpheusTargetStoreId) {
            Write-Log "Looking up source server details for server $($morphVM.id)..."
            $srvResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/servers/$($morphVM.id)" -Method GET -Headers $headers
        }

        # Plan-level networks: sourceNetwork (auto-detected from first NIC) + destinationNetwork
        if ($MorpheusTargetNetworkId) {
            $netId = if ($MorpheusTargetNetworkId -match '^\d+$') { [int]$MorpheusTargetNetworkId } else { $MorpheusTargetNetworkId }
            $firstNic = @($srvResp.server.interfaces)[0]
            $srcNetId = [int]$firstNic.network.id
            $migObj_networks = @( @{ sourceNetwork = @{ id = $srcNetId }; destinationNetwork = @{ id = $netId } } )
            Write-Log "Network mapping: sourceNetwork.id=$srcNetId ($($firstNic.network.name)) -> destinationNetwork.id=$netId"
        }

        # Plan-level datastores: sourceDatastore (auto-detected from first volume) + destinationDatastore
        if ($MorpheusTargetStoreId) {
            $storeId = if ($MorpheusTargetStoreId -match '^\d+$') { [int]$MorpheusTargetStoreId } else { $MorpheusTargetStoreId }
            $firstVol = @($srvResp.server.volumes)[0]
            $srcDsId = [int]$firstVol.datastoreId
            $migObj_datastores = @( @{ sourceDatastore = @{ id = $srcDsId }; destinationDatastore = @{ id = $storeId } } )
            Write-Log "Datastore mapping: sourceDatastore.id=$srcDsId ($($firstVol.datastore.name)) -> destinationDatastore.id=$storeId"
        }

        $migObj = [ordered]@{
            name        = $planName
            sourceCloud = @{ id = [int]$sourceCloudId }
            targetCloud = @{ id = [int]$MorpheusTargetCloudId }
            servers     = @( $serverObj )
            targetPool  = @{ id = [int]$MorpheusTargetPoolId }
        }
        if ($migObj_networks)   { $migObj.networks   = $migObj_networks }
        if ($migObj_datastores) { $migObj.datastores  = $migObj_datastores }
        $planBody = @{ migration = $migObj } | ConvertTo-Json -Depth 6
        Write-Log "Plan body: $planBody"
        $createResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/migrations" -Method POST `
                          -Headers $headers -Body $planBody -ContentType 'application/json'
        $migrationPlanId = $createResp.migration.id
        Write-Log "Migration plan created: id=$migrationPlanId" -Level SUCCESS

        # Log the saved plan back from Morpheus so we can verify what was stored
        Write-Log 'Querying saved plan from Morpheus to verify stored configuration...'
        $savedPlan = Invoke-MorpheusRestMethod -Uri "$baseUri/api/migrations/$migrationPlanId" -Method GET -Headers $headers
        Write-Log "Saved plan response: $($savedPlan | ConvertTo-Json -Depth 8)"

        if ($CreatePlanOnly) {
            Write-Log "CreatePlanOnly: plan $migrationPlanId created and logged. Not starting. Inspect it in Morpheus UI under Tools > Migrations." -Level WARN
            throw "CreatePlanOnly: stopping after plan creation."
        }

        # --- Step 4: Start the migration plan ---
        Write-Log "Starting migration plan $migrationPlanId..."
        Invoke-MorpheusRestMethod -Uri "$baseUri/api/migrations/$migrationPlanId/run" -Method POST `
            -Headers $headers -ContentType 'application/json' | Out-Null
        Write-Log "Migration plan started. Polling for completion (timeout: $MorpheusMigrationTimeoutHours hr)..." -Level SUCCESS

        # --- Step 5: Poll for completion ---
        $planAlreadyFailed = $false
        $migrationDone = $false
        $deadline = (Get-Date).AddHours($MorpheusMigrationTimeoutHours)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 30
            $statusResp = $null
            try {
                $statusResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/migrations/$migrationPlanId" `
                                  -Method GET -Headers $headers
            } catch {
                # Morpheus auto-removes completed plans; a 404/not-found means it finished
                if ("$_" -match 'not found|404|Migration Plan not found') {
                    Write-Log "Migration plan $migrationPlanId was auto-removed by Morpheus — treating as completed." -Level SUCCESS
                    $migrationDone = $true
                    break
                }
                throw
            }
            if ($migrationDone) { break }
            # Handle success:false body with 'not found' (non-throwing HTTP 200)
            if ($statusResp -and $statusResp.PSObject.Properties['success'] -and
                    $statusResp.success -eq $false -and
                    "$($statusResp.msg)" -match 'not found') {
                Write-Log "Migration plan $migrationPlanId was auto-removed by Morpheus — treating as completed." -Level SUCCESS
                $migrationDone = $true
                break
            }
            $status = $statusResp.migration.status
            $pct = if ($statusResp.migration.PSObject.Properties['percentComplete']) { $statusResp.migration.percentComplete } else { $null }
            $pctStr = if ($null -ne $pct) { " ($pct%)" } else { '' }
            Write-Log "Migration status: $status$pctStr"
            switch ($status) {
                'complete'  { $migrationDone = $true }
                'completed' { $migrationDone = $true }
                'failed'    {
                    $planAlreadyFailed = $true
                    # Log all available error details from the response before throwing
                    $mig = $statusResp.migration
                    $errorDetails = @()
                    if ($mig.PSObject.Properties['statusMessage'] -and $mig.statusMessage) { $errorDetails += "statusMessage: $($mig.statusMessage)" }
                    if ($mig.PSObject.Properties['errorMessage']  -and $mig.errorMessage)  { $errorDetails += "errorMessage: $($mig.errorMessage)" }
                    if ($mig.PSObject.Properties['message']       -and $mig.message)       { $errorDetails += "message: $($mig.message)" }
                    # Log per-server status if available
                    if ($mig.PSObject.Properties['servers'] -and $mig.servers) {
                        foreach ($srv in $mig.servers) {
                            $srvName = if ($srv.PSObject.Properties['name']) { $srv.name } else { '?' }
                            $srvStatus = if ($srv.PSObject.Properties['status']) { $srv.status } else { '?' }
                            $srvMsg = if ($srv.PSObject.Properties['statusMessage'] -and $srv.statusMessage) { " - $($srv.statusMessage)" } else { '' }
                            $errorDetails += "server[$srvName] status=$srvStatus$srvMsg"
                        }
                    }
                    if ($errorDetails.Count -gt 0) {
                        Write-Log "Migration failure details:" -Level ERROR
                        $errorDetails | ForEach-Object { Write-Log "  $_" -Level ERROR }
                    } else {
                        Write-Log "No additional error details in migration response. Check Tools > Migrations in the Morpheus UI (plan id=$migrationPlanId)." -Level ERROR
                    }
                    throw "Morpheus migration FAILED for '$($TargetVM.Name)'. See log above for details."
                }
                'cancelled' { throw "Morpheus migration was CANCELLED for '$($TargetVM.Name)'." }
            }
            if ($migrationDone) { break }
        }
        if (-not $migrationDone) {
            throw "Timed out after $MorpheusMigrationTimeoutHours hour(s) waiting for migration."
        }

        # --- Step 6: Find new Morpheus instance ID ---
        # The migrated VM now lives as an HVM instance in Morpheus. Retrieve its ID
        # so callers can perform post-migration operations (e.g. agent install, cleanup).
        # Returns 0 if the instance cannot be located (post-migration cleanup will be skipped).
        $instanceId = 0
        try {
            $instanceId = Get-MorpheusInstanceIdByName -Name $TargetVM.Name -Headers $headers
        } catch {
            Write-Log "Migration succeeded but could not determine Morpheus instance ID for '$($TargetVM.Name)': $_. Post-migration cleanup will be skipped." -Level WARN
        }
        if ($instanceId -gt 0 -and $TargetVMPassword -ne $null) {
            Set-MorpheusInstanceCredentials -InstanceId $instanceId -Headers $headers
        }
        return $instanceId
    } catch {
        $migrationError = $_
        $rollbackIssue = $null
        if ($migrationPlanId) {
            if ($planAlreadyFailed) {
                Write-Log "Migration plan $migrationPlanId is in 'failed' state — leaving it in the Morpheus UI for inspection. Delete it manually after reviewing the error." -Level WARN
            } else {
                try {
                    Remove-MorpheusArtifacts -PlanId $migrationPlanId -Headers $headers
                } catch {
                    $rollbackIssue = $_
                }
            }
        }

        if ($rollbackIssue) {
            throw "Morpheus migration failed (${migrationError}). Rollback failed for plan ${migrationPlanId}: ${rollbackIssue}"
        }
        throw "Morpheus migration failed and rollback completed for plan ${migrationPlanId}. Error: ${migrationError}"
    }
}

function Wait-ForMorpheusInstance {
    # Polls the Morpheus API until the specified instance reaches 'running' state
    # with an IP address assigned, then returns that IP. If the instance is found
    # in 'stopped' state an attempt is made to start it before continuing to poll.
    param(
        [Parameter(Mandatory)][int]$InstanceId,
        [hashtable]$Headers,
        [int]$TimeoutMinutes = 30
    )

    $baseUri = "https://$MorpheusServer"
    Write-Log "Waiting for Morpheus instance $InstanceId to reach running state with IP (timeout: $TimeoutMinutes min)..."
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        try {
            $resp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/instances/$InstanceId" `
                        -Method GET -Headers $Headers
            $instance = $resp.instance
            $status = $instance.status
            # Use interfaces[0].ipAddress — the actual VM network IP.
            # connectionInfo[0].ip returns the KVM management link-local address (169.254.x.x)
            # which is not routable from the management PC.
            $ip = $null
            if ($instance.PSObject.Properties['interfaces'] -and
                    $instance.interfaces -and $instance.interfaces.Count -gt 0) {
                $ip = $instance.interfaces[0].ipAddress
            }
            Write-Log "Instance $InstanceId status=$status ip=$(if ($ip) { $ip } else { 'none' })"
            if ($status -eq 'running' -and $ip -and $ip -ne '0.0.0.0' -and
                    $ip -notlike '169.254.*') {
                Write-Log "Instance $InstanceId is running at $ip." -Level SUCCESS
                return $ip
            }
            if ($status -eq 'stopped') {
                Write-Log "Instance $InstanceId is stopped — attempting to start..." -Level WARN
                try {
                    Invoke-MorpheusRestMethod -Uri "$baseUri/api/instances/$InstanceId/start" `
                        -Method PUT -Headers $Headers | Out-Null
                } catch {
                    Write-Log "Could not start instance ${InstanceId}: $_" -Level WARN
                }
            }
        } catch {
            Write-Log "Error polling instance ${InstanceId}: $_ — retrying..." -Level WARN
        }
    }
    throw "Timed out after $TimeoutMinutes min waiting for Morpheus instance $InstanceId to reach running state with IP."
}

function Install-MorpheusAgent {
    # Installs the Morpheus agent on an HVM instance via WinRM using the Morpheus API.
    # Throws if installation times out so the caller can fall back to direct WinRM.
    param(
        [Parameter(Mandatory)][int]$InstanceId,
        [hashtable]$Headers,
        [int]$TimeoutMinutes = 15
    )

    $baseUri = "https://$MorpheusServer"
    $instResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/instances/$InstanceId" `
                    -Method GET -Headers $Headers
    if ($instResp.instance.PSObject.Properties['agentInstalled'] -and $instResp.instance.agentInstalled) {
        Write-Log "Morpheus agent already installed on instance $InstanceId." -Level SUCCESS
        return
    }

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($TargetVMPassword)
    try {
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        $agentBody = @{
            installAgent = @{
                username      = $TargetVMUser
                password      = $plainPassword
                winrmPort     = 5985
                winrmProtocol = 'http'
                useWinRM      = $true
                windows       = $true
            }
        } | ConvertTo-Json
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    Write-Log "Triggering Morpheus agent installation on instance $InstanceId via WinRM..."
    Invoke-MorpheusRestMethod -Uri "$baseUri/api/instances/$InstanceId/install-agent" -Method POST `
        -Headers $Headers -Body $agentBody -ContentType 'application/json' | Out-Null
    Write-Log "Agent installation triggered. Polling for completion (timeout: $TimeoutMinutes min)..."
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        $instResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/instances/$InstanceId" `
                        -Method GET -Headers $Headers
        if ($instResp.instance.PSObject.Properties['agentInstalled'] -and $instResp.instance.agentInstalled) {
            Write-Log "Morpheus agent installed on instance $InstanceId." -Level SUCCESS
            return
        }
        Write-Log "Waiting for agent installation on instance $InstanceId..."
    }
    throw "Morpheus agent installation timed out on instance $InstanceId after $TimeoutMinutes min."
}

function Set-MorpheusInstanceCredentials {
    # Sets the SSH/WinRM credentials on the Morpheus server record for the migrated
    # instance so that the Morpheus finalize step can connect to the VM.
    # Morpheus sometimes inherits the cloud-init default user instead of the real
    # OS admin account; this step corrects that immediately after migration.
    param(
        [Parameter(Mandatory)][int]$InstanceId,
        [hashtable]$Headers
    )

    $baseUri = "https://$MorpheusServer"

    # Get the server ID from the instance record (servers is an array of IDs).
    $instResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/instances/$InstanceId" `
                    -Method GET -Headers $Headers
    $serverIds = $instResp.instance.servers
    if (-not $serverIds -or $serverIds.Count -eq 0) {
        Write-Log "Cannot determine server ID for instance $InstanceId — credential update skipped." -Level WARN
        return
    }
    $serverId = $serverIds[0]

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($TargetVMPassword)
    try {
        $plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        $body = @{
            server = @{
                sshUsername = $TargetVMUser
                sshPassword = $plainPassword
            }
        } | ConvertTo-Json
    } finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    try {
        Invoke-MorpheusRestMethod -Uri "$baseUri/api/servers/$serverId" `
            -Method PUT -Headers $Headers -Body $body -ContentType 'application/json' | Out-Null
        Write-Log "Morpheus server $serverId credentials set to '$TargetVMUser'." -Level SUCCESS
    } catch {
        Write-Log "Could not update credentials on server ${serverId}: $_ — finalize step may fail." -Level WARN
    }
}

function Remove-VMwareToolsViaTask {
    # Removes VMware Tools from a running Morpheus HVM instance by creating a
    # one-off PowerShell task, executing it on the instance, then cleaning up.
    # Requires the Morpheus agent to be installed on the instance.
    #
    # NOTE: Task result polling uses /api/task-results/:id which may vary by
    # Morpheus version. If this path fails the caller should fall back to
    # Remove-VMwareToolsViaWinRM.
    param(
        [Parameter(Mandatory)][int]$InstanceId,
        [hashtable]$Headers,
        [int]$TimeoutMinutes = 10
    )

    $baseUri = "https://$MorpheusServer"
    $taskId = $null

    # Registry-based lookup (avoids slow Win32_Product), with QuietUninstallString
    # preferred over raw product-code uninstall.
    $removalScript = @'
$regPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
$toolsKey = Get-ChildItem $regPaths -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
    Where-Object { $_.DisplayName -like 'VMware Tools*' } |
    Select-Object -First 1
if (-not $toolsKey) { Write-Output 'VMWARETOOLS_NOT_FOUND'; exit 0 }
Write-Output "FOUND: $($toolsKey.DisplayName) $($toolsKey.DisplayVersion)"
$uninstallCmd = if ($toolsKey.QuietUninstallString) { $toolsKey.QuietUninstallString }
               elseif ($toolsKey.UninstallString)  { "$($toolsKey.UninstallString) /qn /norestart" }
               else                                { "msiexec.exe /x `"$($toolsKey.PSChildName)`" /qn /norestart" }
Write-Output "UNINSTALL_CMD: $uninstallCmd"
$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $uninstallCmd" -Wait -PassThru
Write-Output "EXIT: $($proc.ExitCode)"
if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) { Write-Output 'VMWARETOOLS_REMOVED' }
else { Write-Output "REMOVAL_FAILED:$($proc.ExitCode)"; exit 1 }
'@
    try {
        Write-Log "Creating Morpheus task for VMware Tools removal on instance $InstanceId..."
        $taskBody = @{
            task = @{
                name          = "VmwareToolsRemoval-$(Get-Date -Format 'yyyyMMddHHmm')"
                taskType      = @{ code = 'script' }
                taskContent   = $removalScript
                executeTarget = 'resource'
            }
        } | ConvertTo-Json -Depth 5
        $taskResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/tasks" -Method POST `
                        -Headers $Headers -Body $taskBody -ContentType 'application/json'
        $taskId = $taskResp.task.id
        Write-Log "Morpheus task created: id=$taskId"

        $execBody = @{ task = @{ id = $taskId } } | ConvertTo-Json
        $execResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/instances/$InstanceId/execute-task" `
                        -Method POST -Headers $Headers -Body $execBody -ContentType 'application/json'
        $executionId = $execResp.execution.id
        Write-Log "Task $taskId execution started: executionId=$executionId. Polling (timeout: $TimeoutMinutes min)..."

        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 15
            try {
                $resultResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/task-results/$executionId" `
                                  -Method GET -Headers $Headers
                $exStatus = $resultResp.execution.status
                $output   = $resultResp.execution.output
                Write-Log "Task execution status: $exStatus output: $output"
                if ($exStatus -eq 'success' -or ($output -match 'VMWARETOOLS_REMOVED|VMWARETOOLS_NOT_FOUND')) {
                    Write-Log "VMware Tools removal via Morpheus task succeeded on instance $InstanceId." -Level SUCCESS
                    return
                }
                if ($exStatus -eq 'failed') { throw "Morpheus task execution failed. Output: $output" }
            } catch {
                Write-Log "Error polling task result (will retry): $_" -Level WARN
            }
        }
        throw "Timed out waiting for Morpheus task execution result on instance $InstanceId."
    } finally {
        if ($taskId) {
            try {
                Invoke-MorpheusRestMethod -Uri "$baseUri/api/tasks/$taskId" `
                    -Method DELETE -Headers $Headers | Out-Null
                Write-Log "Morpheus task $taskId deleted."
            } catch {
                Write-Log "Could not delete Morpheus task ${taskId}: $_" -Level WARN
            }
        }
    }
}

function Remove-VMwareToolsViaWinRM {
    # Removes VMware Tools from a running VM via direct WinRM from the management PC.
    # Used as fallback when the Morpheus agent / task path is unavailable.
    #
    # Temporarily adds the target IP to WSMan TrustedHosts so Negotiate auth works
    # over HTTP/IP. The original TrustedHosts value is restored in finally.
    param(
        [Parameter(Mandatory)][string]$TargetIP,
        [int]$TimeoutMinutes = 10
    )

    $cred = New-Object System.Management.Automation.PSCredential($TargetVMUser, $TargetVMPassword)

    # Temporarily trust the target IP for Negotiate auth over HTTP.
    $trustedHostsPath = 'WSMan:\localhost\Client\TrustedHosts'
    $originalTrustedHosts = (Get-Item $trustedHostsPath).Value
    $trustedHostsModified = $false
    if ($originalTrustedHosts -notmatch "(^|,)\s*$([regex]::Escape($TargetIP))\s*(,|$)") {
        $newValue = if ($originalTrustedHosts -and $originalTrustedHosts.Trim()) {
            "$originalTrustedHosts,$TargetIP"
        } else {
            $TargetIP
        }
        Set-Item $trustedHostsPath -Value $newValue -Force
        $trustedHostsModified = $true
        Write-Log "Added $TargetIP to WSMan TrustedHosts for WinRM connection."
    }

    try {
        Write-Log "Connecting to $TargetIP via WinRM to remove VMware Tools (timeout: $TimeoutMinutes min)..."
        $sessionOpts = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $session = $null
        while ((Get-Date) -lt $deadline -and -not $session) {
            try {
                $session = New-PSSession -ComputerName $TargetIP -Port 5985 -Credential $cred `
                               -Authentication Negotiate -SessionOption $sessionOpts -ErrorAction Stop
            } catch {
                Write-Log "WinRM not yet reachable at ${TargetIP}: $_ — retrying in 30s..." -Level WARN
                Start-Sleep -Seconds 30
            }
        }
        if (-not $session) {
            throw "Could not establish WinRM session to $TargetIP within $TimeoutMinutes min."
        }

        try {
            Write-Log "WinRM session established. Running VMware Tools removal script on $TargetIP..."
            $result = Invoke-Command -Session $session -ScriptBlock {
                $regPaths = @(
                    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
                )
                $toolsKey = Get-ChildItem $regPaths -ErrorAction SilentlyContinue |
                    ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
                    Where-Object { $_.DisplayName -like 'VMware Tools*' } |
                    Select-Object -First 1
                if (-not $toolsKey) { return 'VMWARETOOLS_NOT_FOUND' }
                $uninstallCmd = if ($toolsKey.QuietUninstallString) { $toolsKey.QuietUninstallString }
                               elseif ($toolsKey.UninstallString)  { "$($toolsKey.UninstallString) /qn /norestart" }
                               else                                { "msiexec.exe /x `"$($toolsKey.PSChildName)`" /qn /norestart" }
                $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList "/c $uninstallCmd" -Wait -PassThru
                if ($proc.ExitCode -eq 0 -or $proc.ExitCode -eq 3010) { return "VMWARETOOLS_REMOVED:$($proc.ExitCode)" }
                return "REMOVAL_FAILED:$($proc.ExitCode)"
            }
            Write-Log "VMware Tools removal result: $result"
            if ($result -match 'VMWARETOOLS_REMOVED|VMWARETOOLS_NOT_FOUND') {
                Write-Log "VMware Tools removal via WinRM succeeded on $TargetIP." -Level SUCCESS
            } else {
                Write-Log "VMware Tools removal may not have completed on ${TargetIP}: $result" -Level WARN
            }
        } finally {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    } finally {
        if ($trustedHostsModified) {
            Set-Item $trustedHostsPath -Value $originalTrustedHosts -Force
            Write-Log "Restored WSMan TrustedHosts to original value."
        }
    }
}

function Invoke-PostMigrationVMwareToolsRemoval {
    # Orchestrates post-migration VMware Tools removal from a Morpheus HVM instance.
    #
    # Flow:
    #   1. Wait for the instance to reach 'running' state and obtain its IP
    #   2. Attempt Morpheus agent installation via WinRM (Morpheus API)
    #   3. If agent installed: remove tools via Morpheus task execution
    #   4. If agent unavailable or task fails: remove tools via direct WinRM
    param([Parameter(Mandatory)][int]$InstanceId)

    $headers = Get-MorpheusAuthHeaders
    Write-Log "Starting post-migration VMware Tools removal for Morpheus instance $InstanceId..."

    $targetIP = Wait-ForMorpheusInstance -InstanceId $InstanceId -Headers $headers

    $agentAvailable = $false
    try {
        Install-MorpheusAgent -InstanceId $InstanceId -Headers $headers
        $agentAvailable = $true
    } catch {
        Write-Log "Morpheus agent installation skipped or failed: $_ — will use direct WinRM fallback." -Level WARN
    }

    if ($agentAvailable) {
        try {
            Remove-VMwareToolsViaTask -InstanceId $InstanceId -Headers $headers
            return
        } catch {
            Write-Log "Morpheus task-based removal failed: $_ — falling back to WinRM." -Level WARN
        }
    }

    Remove-VMwareToolsViaWinRM -TargetIP $targetIP
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
    $detectScript = (@'
$hive    = '__OFFLINE_DRIVE__\Windows\System32\config\SOFTWARE'
$tempKey = 'HKLM\OFFLINESW_DETECT'
if (-not (Test-Path $hive)) { Write-Host 'HIVE_NOT_FOUND'; exit 1 }
reg.exe load $tempKey $hive 2>&1 | Out-Null
try {
    $cvPath  = 'Registry::HKEY_LOCAL_MACHINE\OFFLINESW_DETECT\Microsoft\Windows NT\CurrentVersion'
    $cv      = Get-ItemProperty -Path $cvPath -ErrorAction Stop
    $build   = $cv.CurrentBuildNumber
    $product = if ($cv.ProductName) { $cv.ProductName } else { $cv.DisplayVersion }
    Write-Host "BUILD:$build"
    Write-Host "PRODUCT:$product"
} finally {
    [gc]::Collect()
    Start-Sleep -Seconds 2
    reg.exe unload $tempKey 2>&1 | Out-Null
    Write-Host 'HIVE_UNLOADED'
}
'@) -replace '__OFFLINE_DRIVE__', $OfflineDrive
    $out = Invoke-HelperScript -HelperVM $HelperVM -Script $detectScript -Description 'Detect OS from offline SOFTWARE hive'

    if ($out -match 'HIVE_NOT_FOUND') {
        throw "SOFTWARE hive not found on $OfflineDrive. Cannot auto-detect OS. Use -GuestOSFolder to override."
    }
    if ($out -notmatch 'HIVE_UNLOADED') {
        throw "SOFTWARE hive did not unload cleanly. Output: $out"
    }

    $buildStr   = ($out -split "`n" | Where-Object { $_ -match '^BUILD:' } | Select-Object -Last 1) -replace 'BUILD:',''
    $productStr = ($out -split "`n" | Where-Object { $_ -match '^PRODUCT:' } | Select-Object -Last 1) -replace 'PRODUCT:',''
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

function Select-FromList {
    # Displays a numbered console menu and returns the selected item.
    # Items is an array of any objects; DisplayScript formats each one for display.
    # Loops until a valid number is entered.
    param(
        [Parameter(Mandatory)][array]$Items,
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][scriptblock]$DisplayScript
    )

    Write-Host ""
    Write-Host "  $Prompt" -ForegroundColor Cyan
    Write-Host "  $('─' * [Math]::Min($Prompt.Length, 72))" -ForegroundColor DarkCyan
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $display = & $DisplayScript $Items[$i]
        Write-Host ("  {0,3}. {1}" -f ($i + 1), $display)
    }
    Write-Host ""
    while ($true) {
        $raw = (Read-Host "  Enter number (1-$($Items.Count))").Trim()
        if ($raw -match '^\d+$') {
            $idx = [int]$raw - 1
            if ($idx -ge 0 -and $idx -lt $Items.Count) {
                Write-Host ""
                return $Items[$idx]
            }
        }
        Write-Host "  Invalid selection — please enter a number between 1 and $($Items.Count)." -ForegroundColor Yellow
    }
}

function Resolve-MorpheusTargetParameters {
    # Queries the Morpheus API to present interactive selection menus for any unspecified
    # target parameters: cloud, resource pool, network, and datastore.
    # Only called when -TriggerMorpheusMigration is set.
    # Assigns discovered values directly to the script-scope parameter variables.

    if (-not $TriggerMorpheusMigration) { return }

    Write-Log "Resolving Morpheus target parameters..."
    $baseUri = "https://$MorpheusServer"
    $headers = Get-MorpheusAuthHeaders

    # --- Cloud (zone) ---
    if (-not $MorpheusTargetCloudId) {
        Write-Log "No -MorpheusTargetCloudId specified — querying available clouds..."
        $zonesResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/zones?max=100" `
                         -Method GET -Headers $headers
        $clouds = $zonesResp.zones | Sort-Object name
        if (-not $clouds -or $clouds.Count -eq 0) {
            throw "No Morpheus clouds found. Specify -MorpheusTargetCloudId manually."
        }
        if ($clouds.Count -eq 1) {
            $script:MorpheusTargetCloudId = [string]$clouds[0].id
            Write-Log "Auto-selected only available cloud: $($clouds[0].name) (id=$($script:MorpheusTargetCloudId))" -Level SUCCESS
        } else {
            $selected = Select-FromList -Items $clouds -Prompt "Select target Morpheus cloud:" -DisplayScript {
                param($z) "$($z.id): $($z.name) [$($z.zoneType.name)]"
            }
            $script:MorpheusTargetCloudId = [string]$selected.id
            Write-Log "Selected Morpheus cloud: $($selected.name) (id=$($script:MorpheusTargetCloudId))"
        }
    }

    if (-not $MorpheusTargetCloudId) {
        throw "-MorpheusTargetCloudId could not be resolved. Specify it explicitly."
    }

    # --- Resource pool ---
    if (-not $MorpheusTargetPoolId) {
        Write-Log "No -MorpheusTargetPoolId specified — querying resource pools for cloud $MorpheusTargetCloudId..."
        $poolsResp = Invoke-MorpheusRestMethod `
                         -Uri "$baseUri/api/resource-pools?zoneId=$MorpheusTargetCloudId&max=100" `
                         -Method GET -Headers $headers
        $pools = $poolsResp.resourcePools | Sort-Object name
        if (-not $pools -or $pools.Count -eq 0) {
            $script:MorpheusTargetPoolId = '1'
            Write-Log "No resource pools found for cloud $MorpheusTargetCloudId — defaulting to pool ID 1." -Level WARN
        } elseif ($pools.Count -eq 1) {
            $script:MorpheusTargetPoolId = [string]$pools[0].id
            Write-Log "Auto-selected only available pool: $($pools[0].name) (id=$($script:MorpheusTargetPoolId))" -Level SUCCESS
        } else {
            $selected = Select-FromList -Items $pools -Prompt "Select target resource pool:" -DisplayScript {
                param($p) "$($p.id): $($p.name)"
            }
            $script:MorpheusTargetPoolId = [string]$selected.id
            Write-Log "Selected resource pool: $($selected.name) (id=$($script:MorpheusTargetPoolId))"
        }
    }

    # --- Network ---
    if (-not $MorpheusTargetNetworkId) {
        Write-Log "No -MorpheusTargetNetworkId specified — querying networks for cloud $MorpheusTargetCloudId..."
        $netsResp = Invoke-MorpheusRestMethod `
                        -Uri "$baseUri/api/networks?zoneId=$MorpheusTargetCloudId&max=100" `
                        -Method GET -Headers $headers
        $nets = $netsResp.networks | Sort-Object name
        if (-not $nets -or $nets.Count -eq 0) {
            Write-Log "No networks found for cloud $MorpheusTargetCloudId — migration will use default network." -Level WARN
        } elseif ($nets.Count -eq 1) {
            $script:MorpheusTargetNetworkId = [string]$nets[0].id
            Write-Log "Auto-selected only available network: $($nets[0].name) (id=$($script:MorpheusTargetNetworkId))" -Level SUCCESS
        } else {
            $selected = Select-FromList -Items $nets -Prompt "Select target network:" -DisplayScript {
                param($n) "$($n.id): $($n.name)"
            }
            $script:MorpheusTargetNetworkId = [string]$selected.id
            Write-Log "Selected network: $($selected.name) (id=$($script:MorpheusTargetNetworkId))"
        }
    }

    # --- Datastore ---
    if (-not $MorpheusTargetStoreId) {
        Write-Log "No -MorpheusTargetStoreId specified — querying datastores for cloud $MorpheusTargetCloudId..."
        $storeResp = Invoke-MorpheusRestMethod `
                         -Uri "$baseUri/api/datastores?zoneId=$MorpheusTargetCloudId&max=100" `
                         -Method GET -Headers $headers
        $stores = $storeResp.datastores | Sort-Object name
        if (-not $stores -or $stores.Count -eq 0) {
            Write-Log "No datastores found for cloud $MorpheusTargetCloudId — using default storage." -Level WARN
        } elseif ($stores.Count -eq 1) {
            $script:MorpheusTargetStoreId = [string]$stores[0].id
            Write-Log "Auto-selected only available datastore: $($stores[0].name) (id=$($script:MorpheusTargetStoreId))" -Level SUCCESS
        } else {
            $selected = Select-FromList -Items $stores -Prompt "Select target datastore (disk placement):" -DisplayScript {
                param($d)
                $free = if ($d.PSObject.Properties['freeSpace'] -and $d.freeSpace) {
                    " — $([math]::Round($d.freeSpace / 1GB, 1)) GB free"
                } else { '' }
                "$($d.id): $($d.name)$free"
            }
            $script:MorpheusTargetStoreId = [string]$selected.id
            Write-Log "Selected datastore: $($selected.name) (id=$($script:MorpheusTargetStoreId))"
        }
    }
}

function Resolve-VCenterTargetParameters {
    # Queries vCenter to present interactive selection menus for any unspecified
    # VM parameters: TargetVMName, HelperVMName, and VirtIODriverPath.
    # Must be called after Connect-VC.
    # Assigns discovered values directly to the script-scope parameter variables.

    # --- Target VM ---
    if (-not $TargetVMName) {
        Write-Log "No -TargetVMName specified — querying vCenter for available VMs..."
        $allVMs = Get-VM | Where-Object {
            $_.ExtensionData.Config.GuestId -like '*windows*' -or
            $_.Guest.OSFullName -like '*Windows*'
        } | Sort-Object Name
        if (-not $allVMs -or $allVMs.Count -eq 0) {
            $allVMs = Get-VM | Sort-Object Name
        }
        if (-not $allVMs -or $allVMs.Count -eq 0) {
            throw "No VMs found in vCenter. Specify -TargetVMName manually."
        }
        $selected = Select-FromList -Items @($allVMs) -Prompt "Select VM to migrate:" -DisplayScript {
            param($v) "$($v.Name)  [$($v.PowerState)]  $($v.Guest.OSFullName)  [host: $($v.VMHost.Name)]"
        }
        $script:TargetVMName = $selected.Name
        Write-Log "Selected target VM: $($script:TargetVMName)"
    }

    # HelperVMName and VirtIODriverPath not needed for MigrationOnly runs
    if ($MigrationOnly) { return }

    # --- Helper VM ---
    if (-not $HelperVMName) {
        Write-Log "No -HelperVMName specified — querying vCenter for available helper VMs..."
        # Resolve the target VM's ESXi host so same-host VMs sort first
        $targetVMObj = Get-VM -Name $TargetVMName -ErrorAction SilentlyContinue
        $targetHostName = if ($targetVMObj) { $targetVMObj.VMHost.Name } else { '' }

        $candidates = Get-VM | Where-Object {
            $_.Name -ne $TargetVMName -and (
                $_.ExtensionData.Config.GuestId -like '*windows*' -or
                $_.Guest.OSFullName -like '*Windows*'
            )
        } | Sort-Object @{ Expression = { $_.VMHost.Name -ne $targetHostName }; Ascending = $true }, Name
        # Fallback: show all non-target VMs if no Windows filter matches
        if (-not $candidates -or $candidates.Count -eq 0) {
            $candidates = Get-VM | Where-Object { $_.Name -ne $TargetVMName } | Sort-Object Name
        }
        if (-not $candidates -or $candidates.Count -eq 0) {
            throw "No candidate helper VMs found in vCenter. Specify -HelperVMName manually."
        }
        $selected = Select-FromList -Items @($candidates) `
            -Prompt "Select helper VM (Windows VM with VirtIO drivers staged):" `
            -DisplayScript {
                param($v)
                $tag = if ($targetHostName -and $v.VMHost.Name -eq $targetHostName) { ' [SAME HOST]' } else { " [host: $($v.VMHost.Name)]" }
                "$($v.Name)  [$($v.PowerState)]$tag"
            }
        $script:HelperVMName = $selected.Name
        Write-Log "Selected helper VM: $($script:HelperVMName)"
    }

    # --- VirtIO driver path ---
    if (-not $VirtIODriverPath) {
        Write-Host ""
        Write-Host "  No -VirtIODriverPath specified." -ForegroundColor Cyan
        Write-Host "  Enter the path to the VirtIO driver folder AS SEEN FROM INSIDE the helper VM." -ForegroundColor Cyan
        Write-Host "  Common locations: C:\Drivers\virtio-win  |  C:\virtio-win  |  D:\virtio-win" -ForegroundColor DarkGray
        Write-Host ""
        $entered = (Read-Host "  VirtIO driver path").Trim()
        if (-not $entered) {
            throw "VirtIO driver path is required. Re-run with -VirtIODriverPath to specify it explicitly."
        }
        $script:VirtIODriverPath = $entered
        Write-Log "VirtIO driver path set to: $($script:VirtIODriverPath)"
    }
}

# --- Resolve Morpheus target parameters before connecting to vCenter ---
if ($TriggerMorpheusMigration) {
    Resolve-MorpheusTargetParameters
}

# --- Connect to vCenter (needed for both VM discovery and the migration itself) ---
Connect-VC

# --- Resolve vCenter parameters (TargetVMName, HelperVMName, VirtIODriverPath) ---
Resolve-VCenterTargetParameters

Write-Log "=== HPE Morpheus Pre-Migration VirtIO Injection via Helper VM ==="
Write-Log "Target VM      : $TargetVMName"
Write-Log "Helper VM      : $(if ($HelperVMName) { $HelperVMName } else { 'N/A (MigrationOnly)' })"
Write-Log "VirtIO Path    : $(if ($VirtIODriverPath) { "$VirtIODriverPath (path as seen from inside the helper VM)" } else { 'N/A (MigrationOnly)' })"
Write-Log "OS Folder      : $(if ($GuestOSFolder) { "$GuestOSFolder (override)" } else { '(auto-detect from offline disk)' })"
Write-Log "Guest Tools    : $(if ($InstallGuestTools) { 'yes' } else { 'no' })"
Write-Log "Remove VMware  : $(if ($RemoveVMwareTools) { "yes (post-migration via Morpheus agent / WinRM, when -TriggerMorpheusMigration is set)" } else { 'no' })"
Write-Log "Enable RDP     : $(if ($EnableRDP) { 'yes (pre-migration via VMware guest script)' } else { 'no' })"
Write-Log "Morpheus Mig.  : $(if ($TriggerMorpheusMigration) { "yes -> $MorpheusServer (cloud: $MorpheusTargetCloudId, net: $(if ($MorpheusTargetNetworkId) { $MorpheusTargetNetworkId } else { 'default' }), store: $(if ($MorpheusTargetStoreId) { $MorpheusTargetStoreId } else { 'default' }))" } else { 'no' })"
Write-Log "Log File       : $LogFile"

$targetVM = Get-VM -Name $TargetVMName -ErrorAction Stop

if ($MigrationOnly) {
    Write-Log 'MigrationOnly: skipping VirtIO injection, proceeding directly to Morpheus migration.' -Level WARN
    $migrationAttempted = $false
    try {
        if ($RemoveVMwareTools) {
            Enable-WinRMOnTarget -TargetVM $targetVM
        }
        if ($EnableRDP) {
            Enable-RDPOnTarget -TargetVM $targetVM
        }
        Stop-VMGracefully -VM $targetVM
        $migrationAttempted = $true
        $morpheusInstanceId = Invoke-MorpheusMigration -TargetVM $targetVM
        Write-Log "SUCCESS: $TargetVMName has been migrated to HPE VM Essentials." -Level SUCCESS
        if ($RemoveVMwareTools -and $morpheusInstanceId -gt 0) {
            try {
                Invoke-PostMigrationVMwareToolsRemoval -InstanceId $morpheusInstanceId
            } catch {
                Write-Log "Post-migration VMware Tools removal failed (non-fatal): $_" -Level WARN
            }
        } elseif ($RemoveVMwareTools) {
            Write-Log 'Could not determine Morpheus instance ID — skipping post-migration VMware Tools removal.' -Level WARN
        }
    } catch {
        Write-Log "FATAL ERROR: $_" -Level ERROR
        if ($migrationAttempted) {
            if ($SkipRollbackRestart) {
                Write-Log 'SkipRollbackRestart: leaving source VM powered off for troubleshooting.' -Level WARN
            } else {
                Write-Log 'Migration failed; ensuring VMware source VM is powered on again...' -Level WARN
                try {
                    $vmState = Get-VM -Id $targetVM.Id -ErrorAction Stop
                    if ($vmState.PowerState -ne 'PoweredOn') {
                        Start-VM -VM $targetVM -Confirm:$false | Out-Null
                        Write-Log 'Source VM restarted in VMware after migration failure.' -Level WARN
                    } else {
                        Write-Log 'Source VM already powered on after migration failure.' -Level WARN
                    }
                } catch {
                    Write-Log "Could not restart source VM after migration failure: $_" -Level ERROR
                }
            }
        }
        throw
    } finally {
        Disconnect-VIServer -Server $VCServer -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        Write-Log "Disconnected from vCenter. Log: $LogFile"
    }
    return
}

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
$attachedDiskNumber = $null
$diskOfflined = $false
$vmStarted = $false
$migrationAttempted = $false

try {
    Stop-VMGracefully -VM $targetVM

    Remove-AllSnapshots -VM $targetVM

    Write-Log "Identifying OS disk for $($targetVM.Name) across all attached VMDKs..."
    $candidateDisks = Get-HardDisk -VM $targetVM |
        Sort-Object @{Expression = { $_.ExtensionData.ControllerKey }}, @{Expression = { $_.ExtensionData.UnitNumber }}

    if (-not $candidateDisks -or $candidateDisks.Count -eq 0) {
        throw "No hard disks found on target VM $($targetVM.Name)."
    }

    Write-Log "Evaluating $($candidateDisks.Count) disk candidate(s) to find offline Windows OS disk..."

    $offlineDrive = $null
    foreach ($candidateDisk in $candidateDisks) {
        $candidatePath = $candidateDisk.Filename
        $controllerKey = $candidateDisk.ExtensionData.ControllerKey
        $unitNumber = $candidateDisk.ExtensionData.UnitNumber
        $candidateAttachedDiskNumber = $null

        Write-Log "Testing disk candidate path=$candidatePath (controllerKey=$controllerKey, unit=$unitNumber)..."
        $knownDiskNumbers = Get-HelperDiskNumbers -HelperVM $helperVM

        Add-TargetDiskToHelper -HelperVM $helperVM -DiskPath $candidatePath
        Start-Sleep -Seconds 5

        try {
            $candidateAttachedDiskNumber = Enable-AttachedDiskOnHelper -HelperVM $helperVM -KnownDiskNumbers $knownDiskNumbers
            $candidateDrive = Get-OfflineWindowsDrive -HelperVM $helperVM -DiskNumber $candidateAttachedDiskNumber

            $attachedDiskPath = $candidatePath
            $attachedDiskNumber = $candidateAttachedDiskNumber
            $offlineDrive = $candidateDrive

            Write-Log "OS disk confirmed: $attachedDiskPath (helper disk number $attachedDiskNumber, offline drive $offlineDrive)." -Level SUCCESS
            break
        } catch {
            Write-Log "Candidate $candidatePath is not the target OS disk. Reason: $_" -Level WARN
            if ($candidateAttachedDiskNumber -ne $null) {
                try { Disable-AttachedDiskOnHelper -HelperVM $helperVM -DiskNumber $candidateAttachedDiskNumber } catch {
                    Write-Log "Could not offline candidate disk $candidateAttachedDiskNumber before detach: $_" -Level WARN
                }
            }
            try { Remove-TargetDiskFromHelper -HelperVM $helperVM -DiskPath $candidatePath } catch {
                Write-Log "Could not detach candidate disk ${candidatePath}: $_" -Level WARN
            }
        }
    }

    if (-not $attachedDiskPath -or -not $offlineDrive -or $attachedDiskNumber -eq $null) {
        throw "Could not identify the offline Windows OS disk on target VM $($targetVM.Name)."
    }

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

    Disable-AttachedDiskOnHelper -HelperVM $helperVM -DiskNumber $attachedDiskNumber
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
        if ($RemoveVMwareTools) {
            Enable-WinRMOnTarget -TargetVM $targetVM
        }
        if ($EnableRDP) {
            Enable-RDPOnTarget -TargetVM $targetVM
        }
        if ($TriggerMorpheusMigration) {
            Write-Log "Shutting down $TargetVMName before triggering Morpheus migration..."
            Stop-VMGracefully -VM $targetVM
            $migrationAttempted = $true
            $morpheusInstanceId = Invoke-MorpheusMigration -TargetVM $targetVM
            Write-Log "SUCCESS: $TargetVMName has been migrated to HPE VM Essentials." -Level SUCCESS
            if ($RemoveVMwareTools -and $morpheusInstanceId -gt 0) {
                try {
                    Invoke-PostMigrationVMwareToolsRemoval -InstanceId $morpheusInstanceId
                } catch {
                    Write-Log "Post-migration VMware Tools removal failed (non-fatal): $_" -Level WARN
                }
            } elseif ($RemoveVMwareTools) {
                Write-Log 'Could not determine Morpheus instance ID — skipping post-migration VMware Tools removal.' -Level WARN
            }
            # The source VM is shut down but still exists in VMware; snapshot removal proceeds normally.
            Remove-SafetySnapshot -VM $targetVM
        } else {
            Write-Log "SUCCESS: $TargetVMName VirtIO injection complete and boot verified. Ready for Morpheus migration." -Level SUCCESS
            Remove-SafetySnapshot -VM $targetVM
        }
    }
    else {
        Write-Log "WARNING: Boot check timed out. Verify VM manually before migrating." -Level WARN
    }
}
catch {
    Write-Log "FATAL ERROR: $_" -Level ERROR
    if ($attachedDiskNumber -ne $null -and -not $diskOfflined) {
        Write-Log "Cleanup: offlining attached helper disk number $attachedDiskNumber..." -Level WARN
        try {
            Disable-AttachedDiskOnHelper -HelperVM $helperVM -DiskNumber $attachedDiskNumber
        } catch {
            Write-Log "Could not offline attached disk on helper VM: $_" -Level WARN
        }
    }
    if ($attachedDiskPath) {
        Write-Log "Cleanup: removing attached disk from helper VM..." -Level WARN
        try { Remove-TargetDiskFromHelper -HelperVM $helperVM -DiskPath $attachedDiskPath } catch {
            Write-Log "Could not detach disk from helper VM: $_" -Level ERROR
        }
    }
    if ($migrationAttempted) {
        if ($SkipRollbackRestart) {
            Write-Log 'SkipRollbackRestart: leaving source VM powered off for troubleshooting.' -Level WARN
        } else {
            Write-Log "Migration failed; ensuring VMware source VM is powered on again..." -Level WARN
            try {
                $vmState = Get-VM -Id $targetVM.Id -ErrorAction Stop
                if ($vmState.PowerState -ne 'PoweredOn') {
                    Start-VM -VM $targetVM -Confirm:$false | Out-Null
                    Write-Log "Source VM restarted in VMware after migration failure." -Level WARN
                } else {
                    Write-Log "Source VM already powered on after migration failure." -Level WARN
                }
            } catch {
                Write-Log "Could not restart source VM after migration failure: $_" -Level ERROR
            }
        }
    }
    elseif (-not $vmStarted) {
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

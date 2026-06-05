#Requires -RunAsAdministrator

# Script: Invoke-VMwareWindowsMigrationToVME.ps1
# Purpose: End-to-end automated migration of Windows Server VMs from VMware to
#          HPE Morpheus VM Essentials (HVM) with VirtIO driver injection,
#          pre-migration preparation, Morpheus plan execution, and post-migration cleanup.
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
#   SnapshotName     - Name for the post-injection safety snapshot (default: 'Post-VirtIO-Injection')
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
    [string]$VCServer = '',
    [string]$TargetVMName = '',
    [string]$HelperVMName = '',
    [string]$HelperVMUser = '',
    [object]$HelperVMPassword = $null,
    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_)) { return $true }
        if ($_ -notmatch '^[A-Za-z]:\\') { throw "VirtIODriverPath must be an absolute Windows path (e.g. C:\Drivers\virtio-win). Got: '$_'" }
        if ($_ -match '\.\.')            { throw "VirtIODriverPath must not contain '..'. Got: '$_'" }
        if ($_ -match "[';`"&|<>]")      { throw "VirtIODriverPath must not contain shell-special characters. Got: '$_'" }
        return $true
    })]
    [string]$VirtIODriverPath = '',
    [ValidateSet('2k25','2k22','2k19','2k16','2k12R2','w11','w10')][string]$GuestOSFolder = '',  # blank = auto-detect from offline SOFTWARE hive on the target disk
    [string]$SnapshotName = 'Post-VirtIO-Injection',
    [int]$ForceHardStopMin = 10,
    [switch]$SkipSnapshot,
    [switch]$DeleteSnapshot,
    [switch]$DoNotInstallGuestTools,
    [string]$TargetVMUser,
    [object]$TargetVMPassword,
    [switch]$DoNotRemoveVMwareTools,
    [switch]$DoNotEnableRDP,
    [switch]$TriggerMorpheusMigration,
    [ValidateScript({
        if ([string]::IsNullOrWhiteSpace($_)) { return $true }
        if ($_ -match '^https?://')  { throw "MorpheusServer must be a hostname or IP only — do not include 'https://'. Got: '$_'" }
        if ($_ -match '[/\\?#]')     { throw "MorpheusServer must be a plain hostname or IP with no path or query. Got: '$_'" }
        return $true
    })]
    [string]$MorpheusServer,
    [System.Security.SecureString]$MorpheusToken,
    [string]$MorpheusUser,
    [System.Security.SecureString]$MorpheusPassword,
    [string]$MorpheusTargetCloudId,
    [string]$MorpheusTargetNetworkId,
    [string]$MorpheusTargetStoreId,
    [string]$MorpheusTargetPoolId,
    [switch]$MorpheusSkipSSL,
    [switch]$VCSkipSSL,
    [switch]$WinRMSkipSSL,
    [string]$VCUser = '',
    [System.Security.SecureString]$VCPassword = $null,
    [int]$MorpheusMigrationTimeoutHours = 4,
    [switch]$MigrationOnly,
    [switch]$SkipRollbackRestart,
    [switch]$CreatePlanOnly,
    [switch]$PostMigrationOnly,
    [int]$MorpheusInstanceId = 0,
    [string]$LogPath = 'C:\Windows\Logs\VirtIO-HelperInject'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-SecurePassword {
    param(
        [Parameter(Mandatory)][AllowNull()][object]$Password
    )

    if ($null -eq $Password)                                                { return $null }
    if ($Password -is [System.Security.SecureString])                       { return $Password }
    if ($Password -is [System.Management.Automation.PSCredential])          { return $Password.Password }
    if ($Password -is [string])  { return ConvertTo-SecureString $Password -AsPlainText -Force }

    throw "Password must be a [string], [SecureString], or [PSCredential]. Got: $($Password.GetType().FullName)"
}

if ($HelperVMPassword) { $HelperVMPassword = ConvertTo-SecurePassword -Password $HelperVMPassword }
$TargetVMPassword = ConvertTo-SecurePassword -Password $TargetVMPassword

$InstallGuestTools = -not $DoNotInstallGuestTools.IsPresent
$RemoveVMwareTools = -not $DoNotRemoveVMwareTools.IsPresent
$EnableRDP = -not $DoNotEnableRDP.IsPresent

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Host "This script requires PowerShell 7.0 or later. Current version: $($PSVersionTable.PSVersion)" -ForegroundColor Red
    throw 'PowerShell 7.0 or later is required to run this script.'
}

if (-not $PostMigrationOnly) {
    $hasVcf    = [bool](Get-Module -ListAvailable -Name 'VCF.PowerCLI')
    $hasLegacy = [bool](Get-Module -ListAvailable -Name 'VMware.PowerCLI')

    if (-not $hasVcf) {
        if ($hasLegacy) {
            Write-Host '' -ForegroundColor Red
            Write-Host 'VMware.PowerCLI is installed but VCF.PowerCLI is required.' -ForegroundColor Red
            Write-Host 'Broadcom replaced VMware.PowerCLI with VCF.PowerCLI. Please upgrade:' -ForegroundColor Yellow
            Write-Host ''
            Write-Host '    Uninstall-Module VMware.PowerCLI -AllVersions' -ForegroundColor Cyan
            Write-Host '    Install-Module VCF.PowerCLI -AllowClobber -SkipPublisherCheck' -ForegroundColor Cyan
            Write-Host ''
            Write-Host '  -AllowClobber     : resolves cmdlet name conflicts from the old package' -ForegroundColor DarkGray
            Write-Host '  -SkipPublisherCheck : required because VCF.PowerCLI is signed with a Broadcom' -ForegroundColor DarkGray
            Write-Host '                        certificate, not the original VMware one' -ForegroundColor DarkGray
        } else {
            Write-Host '' -ForegroundColor Red
            Write-Host 'VCF.PowerCLI is not installed. This script requires VCF.PowerCLI.' -ForegroundColor Red
            Write-Host 'Install it with:' -ForegroundColor Yellow
            Write-Host ''
            Write-Host '    Install-Module VCF.PowerCLI -AllowClobber -SkipPublisherCheck' -ForegroundColor Cyan
        }
        Write-Host ''
        Write-Host 'Full installation guide: https://developer.broadcom.com/powercli/installation-guide' -ForegroundColor Yellow
        Write-Host '' -ForegroundColor Red
        throw 'VCF.PowerCLI is required. See the installation instructions above.'
    }
}

if ($PostMigrationOnly) {
    if ($MorpheusInstanceId -le 0) {
        throw '-MorpheusInstanceId is required with -PostMigrationOnly (e.g. -MorpheusInstanceId 193).'
    }
    if (-not $MorpheusServer) {
        throw '-MorpheusServer is required with -PostMigrationOnly.'
    }
    if (-not $MorpheusToken -and (-not $MorpheusUser -or -not $MorpheusPassword)) {
        throw 'Either -MorpheusToken or both -MorpheusUser and -MorpheusPassword are required with -PostMigrationOnly.'
    }
} else {
    # vCenter params are required for all non-PostMigrationOnly modes
    if (-not $VCServer)         { throw '-VCServer is required.' }
    if (-not $HelperVMUser)     { throw '-HelperVMUser is required.' }
    if (-not $HelperVMPassword) { throw '-HelperVMPassword is required.' }
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

if ($MorpheusSkipSSL) {
    Write-Host '[WARN] -MorpheusSkipSSL is set. TLS certificate validation is DISABLED for all Morpheus API calls. Do not use in production.' -ForegroundColor Yellow
}
if ($VCSkipSSL) {
    Write-Host '[WARN] -VCSkipSSL is set. vCenter TLS certificate validation is DISABLED. Do not use in production.' -ForegroundColor Yellow
}
if ($WinRMSkipSSL) {
    Write-Host '[WARN] -WinRMSkipSSL is set. WinRM TLS certificate validation is DISABLED. Do not use in production.' -ForegroundColor Yellow
}

if (-not (Test-Path $LogPath)) {
    New-Item -ItemType Directory -Path $LogPath | Out-Null
    $acl = Get-Acl $LogPath
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        'BUILTIN\Administrators', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl $LogPath $acl
}
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
    $certAction = if ($VCSkipSSL) { 'Ignore' } else { 'Fail' }
    if ($VCSkipSSL) {
        Write-Log 'WARNING: -VCSkipSSL is set. vCenter TLS certificate validation is DISABLED. Do not use in production.' -Level WARN
    }
    Set-PowerCLIConfiguration -InvalidCertificateAction $certAction -Scope Session -Confirm:$false | Out-Null
    if ($VCUser -and $VCPassword) {
        $vcCred = New-Object System.Management.Automation.PSCredential($VCUser, $VCPassword)
        Connect-VIServer -Server $VCServer -Credential $vcCred | Out-Null
        Write-Log "Connected to vCenter as '$VCUser'." -Level SUCCESS
    } else {
        Connect-VIServer -Server $VCServer | Out-Null
        Write-Log "Connected to vCenter." -Level SUCCESS
    }
}

function Stop-VMGracefully {
    param($VM)
    if ($VM.PowerState -ne 'PoweredOn') {
        Write-Log "$($VM.Name) is already powered off." -Level WARN
        return
    }
    Write-Log "Requesting graceful shutdown of $($VM.Name)..."
    try { Shutdown-VMGuest -VM $VM -Confirm:$false -ErrorAction Stop | Out-Null } catch {
        Write-Log "Guest shutdown failed (VMware Tools may not be running): $($_.Exception.Message)" -Level WARN
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
    $snapshots = @(Get-Snapshot -VM $VM -ErrorAction SilentlyContinue)
    if ($snapshots.Count -eq 0) {
        Write-Log "No snapshots found on $($VM.Name). Nothing to consolidate."
        return
    }

    Write-Log "SNAPSHOT WARNING: $($snapshots.Count) snapshot(s) found on $($VM.Name):" -Level WARN
    foreach ($snap in $snapshots) {
        Write-Log "  - '$($snap.Name)' (created: $($snap.Created))" -Level WARN
    }
    Write-Log "All snapshots will be permanently merged into the base disk. This CANNOT be undone." -Level WARN
    Write-Log "To cancel and handle snapshots manually, answer anything other than 'YES'." -Level WARN

    $confirm = Read-Host "Type 'YES' to confirm snapshot consolidation and continue"
    if ($confirm -cne 'YES') {
        throw "Snapshot consolidation cancelled. Consolidate or delete snapshots manually in vSphere, then retry."
    }

    Write-Log "Consolidating all snapshots on $($VM.Name)..."
    # Remove all root-level snapshots (those with no parent) with their children.
    # A VM can have multiple independent snapshot chains; removing only -First 1 would
    # leave the others in place and cause the consolidation wait to time out.
    $roots = @(Get-Snapshot -VM $VM -ErrorAction SilentlyContinue | Where-Object { $null -eq $_.Parent })
    foreach ($root in $roots) {
        Remove-Snapshot -Snapshot $root -RemoveChildren -Confirm:$false | Out-Null
    }
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
    if ($LASTEXITCODE -ne 0) {
        Write-Host "HIVE_UNLOAD_FAILED:$LASTEXITCODE"
    } else {
        Write-Host "HIVE_UNLOADED"
    }
}
'@) -replace '__OFFLINE_DRIVE__', $OfflineDrive
    $out = Invoke-HelperScript -HelperVM $HelperVM -Script $regScript -Description 'Set offline BOOT_START registry'
    if ($out -match 'KEY_MISSING') {
        Write-Log "One or more service keys missing in offline registry. Verify manually." -Level WARN
    }
    if (-not ($out -match 'HIVE_UNLOADED')) {
        throw "Offline registry hive did not unload cleanly (HIVE_UNLOAD_FAILED or missing token). A handle may still be open on the target disk. Output: $out"
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
    #   2. Open WinRM HTTP on Domain/Private profiles only (port 5985)
    #   3. Open WinRM HTTPS (port 5986)
    #   4. Enable Negotiate auth; disable Basic auth
    #   NLA (Network Level Authentication) is intentionally left enabled for security.
    param($TargetVM)

    $targetCred = New-Object System.Management.Automation.PSCredential($TargetVMUser, $TargetVMPassword)

    Write-Log "Enabling WinRM on $($TargetVM.Name) for post-migration management channel..."
    $winrmScript = @'
$ErrorActionPreference = 'Stop'
Enable-PSRemoting -Force
# Open WinRM HTTP only on Domain and Private profiles — not Public
New-NetFirewallRule -DisplayName 'WinRM HTTP (Domain/Private)' -Direction Inbound -Protocol TCP -LocalPort 5985 -Action Allow -Profile Domain,Private -ErrorAction SilentlyContinue
New-NetFirewallRule -DisplayName 'WinRM HTTPS' -Direction Inbound -Protocol TCP -LocalPort 5986 -Action Allow -ErrorAction SilentlyContinue
Set-WSManInstance -ResourceURI winrm/config/service/auth -ValueSet @{Negotiate=$true}
Set-WSManInstance -ResourceURI winrm/config/service/auth -ValueSet @{Basic=$false}
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
        Write-Log "WinRM enablement failed on $($TargetVM.Name) (non-fatal, migration will continue): $($_.Exception.Message)" -Level WARN
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
    #   NLA (Network Level Authentication) is intentionally left enabled for security.
    param($TargetVM)

    $targetCred = New-Object System.Management.Automation.PSCredential($TargetVMUser, $TargetVMPassword)

    Write-Log "Enabling Remote Desktop on $($TargetVM.Name) for post-migration access..."
    $rdpScript = @'
$ErrorActionPreference = 'Stop'
Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name fDenyTSConnections -Value 0
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop' -ErrorAction SilentlyContinue
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
        Write-Log "RDP enablement failed on $($TargetVM.Name) (non-fatal, migration will continue): $($_.Exception.Message)" -Level WARN
        Write-Log "Post-migration Remote Desktop access may require manual configuration." -Level WARN
    }
}

function Invoke-MorpheusRestMethod {
    # Thin wrapper around Invoke-RestMethod that injects SkipCertificateCheck
    # when $MorpheusSkipSSL is set. Defined at script scope so all Morpheus
    # helper functions can share it without nesting.
    # On first SSL failure the function automatically sets $script:MorpheusSkipSSL
    # and retries, so self-signed certs work without requiring the flag explicitly.
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

    try {
        return Invoke-RestMethod @invokeParams
    } catch {
        # If this looks like a certificate error and -MorpheusSkipSSL was not set,
        # fail with a clear message rather than silently downgrading TLS security.
        $isCertError = $_.Exception.Message -match 'certificate|UntrustedRoot|RemoteCertificate|SSL'
        if ($isCertError -and -not $MorpheusSkipSSL) {
            throw ("SSL certificate validation failed for '$Uri'. " +
                   "If your Morpheus server uses a self-signed certificate, " +
                   "re-run the script with -MorpheusSkipSSL. " +
                   "Original error: $($_.Exception.Message)")
        }
        throw
    }
}

function Get-MorpheusAuthHeaders {
    # Obtains a Morpheus API bearer token (or reuses $MorpheusToken if provided)
    # and returns a headers hashtable ready for use with Invoke-MorpheusRestMethod.
    $baseUri = "https://$MorpheusServer"
    $token = $null

    if ($MorpheusToken) {
        # Decrypt SecureString only at the moment of use; zero the unmanaged BSTR copy immediately.
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($MorpheusToken)
        try {
            $token = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }

    if (-not $token) {
        Write-Log "Obtaining Morpheus API token for user '$MorpheusUser'..."
        $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($MorpheusPassword)
        try {
            $morpheusPasswordPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            $authBody = "username=$([uri]::EscapeDataString($MorpheusUser))" +
                        "&password=$([uri]::EscapeDataString($morpheusPasswordPlain))" +
                        "&grant_type=password&client_id=morph-api"
        } finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            Remove-Variable -Name morpheusPasswordPlain -ErrorAction SilentlyContinue
        }
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
            Write-Log "Error looking up instance '$Name': $($_.Exception.Message) — retrying in ${RetryDelaySec}s..." -Level WARN
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
            if ($_.Exception.Message -match 'not found|404') {
                Write-Log "Rollback: migration plan $PlanId already removed (auto-deleted or completed). OK." -Level SUCCESS
            } else {
                throw "Delete migration plan failed ($PlanId): $($_.Exception.Message)"
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
        $sourceCloudId = $null
        if ($morphVM.PSObject.Properties['zone']  -and $morphVM.zone)  { $sourceCloudId = $morphVM.zone.id  }
        elseif ($morphVM.PSObject.Properties['cloud'] -and $morphVM.cloud) { $sourceCloudId = $morphVM.cloud.id }
        elseif ($morphVM.PSObject.Properties['zoneId'] -and $morphVM.zoneId) { $sourceCloudId = $morphVM.zoneId }

        if (-not $sourceCloudId) {
            throw ("Cannot determine source cloud for VM '$($TargetVM.Name)' (id=$($morphVM.id)). " +
                   "The Morpheus server response contained neither 'zone', 'cloud', nor 'zoneId'. " +
                   "Ensure the VMware cloud sync is current.")
        }

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
            $interfaces = @($srvResp.server.interfaces)
            if ($interfaces.Count -eq 0) {
                throw "Cannot build network mapping: server $($morphVM.id) has no interfaces in Morpheus. Verify the cloud sync is complete."
            }
            $firstNic = $interfaces[0]
            $srcNetId = [int]$firstNic.network.id
            $migObj_networks = @( @{ sourceNetwork = @{ id = $srcNetId }; destinationNetwork = @{ id = $netId } } )
            Write-Log "Network mapping: sourceNetwork.id=$srcNetId ($($firstNic.network.name)) -> destinationNetwork.id=$netId"
        }

        # Plan-level datastores: sourceDatastore (auto-detected from first volume) + destinationDatastore
        if ($MorpheusTargetStoreId) {
            $storeId = if ($MorpheusTargetStoreId -match '^\d+$') { [int]$MorpheusTargetStoreId } else { $MorpheusTargetStoreId }
            $volumes = @($srvResp.server.volumes)
            if ($volumes.Count -eq 0) {
                throw "Cannot build datastore mapping: server $($morphVM.id) has no volumes in Morpheus. Verify the cloud sync is complete."
            }
            $firstVol = $volumes[0]
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
        Write-Log "Migration plan '$planName': sourceCloud=$sourceCloudId, targetCloud=$MorpheusTargetCloudId, server=$($morphVM.id)"
        $createResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/migrations" -Method POST `
                          -Headers $headers -Body $planBody -ContentType 'application/json'
        $migrationPlanId = $createResp.migration.id
        Write-Log "Migration plan created: id=$migrationPlanId" -Level SUCCESS

        # Verify the plan was stored correctly by fetching just the key fields
        $savedPlan = Invoke-MorpheusRestMethod -Uri "$baseUri/api/migrations/$migrationPlanId" -Method GET -Headers $headers
        Write-Log "Plan verified: id=$($savedPlan.migration.id), status=$($savedPlan.migration.status)"

        if ($CreatePlanOnly) {
            Write-Log "CreatePlanOnly: plan $migrationPlanId created. Inspect it in Morpheus UI under Tools > Migrations." -Level SUCCESS
            return $migrationPlanId
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
                if ($_.Exception.Message -match 'not found|404|Migration Plan not found') {
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
            Write-Log "Migration succeeded but could not determine Morpheus instance ID for '$($TargetVM.Name)': $($_.Exception.Message). Post-migration cleanup will be skipped." -Level WARN
        }
        if ($instanceId -gt 0 -and $null -ne $TargetVMPassword) {
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
            throw "Morpheus migration failed ($($migrationError.Exception.Message)). Rollback failed for plan ${migrationPlanId}: $($rollbackIssue.Exception.Message)"
        }
        $rollbackMsg = if ($migrationPlanId) { "Rollback completed for plan $migrationPlanId." }
                       else                  { 'No migration plan was created; no rollback needed.' }
        throw "Morpheus migration failed. $rollbackMsg Error: $($migrationError.Exception.Message)"
    }
}

function Wait-ForMorpheusInstance {
    # Polls the Morpheus API until the specified instance reaches 'running' state
    # with an IP address assigned, then returns that IP. If the instance is found
    # in 'stopped' state an attempt is made to start it before continuing to poll.
    # When running but IP is absent, triggers a Morpheus instance refresh to force
    # the hypervisor to sync network state. Returns $null on timeout (does not throw)
    # so callers can proceed with Morpheus-agent-based steps that don't require IP.
    # IP is read from connectionInfo[0].ip (Morpheus-maintained, stays current after
    # KVM migration). interfaces[].ipAddress may hold stale VMware-era addresses.
    param(
        [Parameter(Mandatory)][int]$InstanceId,
        [hashtable]$Headers,
        [int]$TimeoutMinutes = 30
    )

    $baseUri = "https://$MorpheusServer"
    Write-Log "Waiting for Morpheus instance $InstanceId to reach running state with IP (timeout: $TimeoutMinutes min)..."
    $deadline       = (Get-Date).AddMinutes($TimeoutMinutes)
    $pollCount      = 0
    $refreshEvery   = 3   # trigger a refresh every N polls when running but no IP
    $startAttempts  = 0
    $maxStartAttempts = 3

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        $pollCount++
        try {
            $resp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/instances/$InstanceId" `
                        -Method GET -Headers $Headers
            $instance = $resp.instance
            $status = $instance.status
            # Select the VM's routable IP.
            # After KVM migration, connectionInfo[0].ip is the address Morpheus actively
            # updates from the hypervisor. interfaces[].ipAddress may retain a stale
            # pre-migration VMware address and is used only as a last resort.
            $validIp = { param($a) $a -and $a -ne '0.0.0.0' -and $a -notlike '169.254.*' }
            $ip = $null

            # Primary: connectionInfo[0].ip (Morpheus-managed, always current)
            if ($instance.PSObject.Properties['connectionInfo'] -and $instance.connectionInfo) {
                $connIp = @($instance.connectionInfo)[0].ip
                if (& $validIp $connIp) { $ip = $connIp }
            }

            # Fallback: first valid IP from interfaces[]
            if (-not $ip -and $instance.PSObject.Properties['interfaces'] -and $instance.interfaces) {
                $fallback = @($instance.interfaces) |
                    Where-Object { & $validIp $_.ipAddress } |
                    Select-Object -First 1
                if ($fallback) { $ip = $fallback.ipAddress }
            }

            Write-Log "Instance $InstanceId status=$status ip=$(if ($ip) { $ip } else { 'none' })"

            if ($status -eq 'running' -and $ip) {
                Write-Log "Instance $InstanceId is running at $ip." -Level SUCCESS
                return $ip
            }

            if ($status -eq 'running' -and -not $ip) {
                # IP not yet populated — trigger a Morpheus sync every N polls so the
                # hypervisor guest-agent data is refreshed into the Morpheus DB.
                if ($pollCount % $refreshEvery -eq 0) {
                    Write-Log "Instance $InstanceId running but no IP yet — triggering Morpheus refresh..."
                    try {
                        Invoke-MorpheusRestMethod -Uri "$baseUri/api/instances/$InstanceId/refresh" `
                            -Method POST -Headers $Headers | Out-Null
                    } catch {
                        Write-Log "Refresh request failed (non-fatal): $($_.Exception.Message)" -Level WARN
                    }
                }
            }

            if ($status -eq 'stopped') {
                if ($startAttempts -lt $maxStartAttempts) {
                    $startAttempts++
                    Write-Log "Instance $InstanceId is stopped — start attempt $startAttempts/$maxStartAttempts..." -Level WARN
                    try {
                        Invoke-MorpheusRestMethod -Uri "$baseUri/api/instances/$InstanceId/start" `
                            -Method PUT -Headers $Headers | Out-Null
                    } catch {
                        Write-Log "Could not start instance ${InstanceId}: $($_.Exception.Message)" -Level WARN
                    }
                } else {
                    throw "Instance $InstanceId remains in 'stopped' state after $maxStartAttempts start attempts. Check the HVM platform for errors."
                }
            }
        } catch {
            Write-Log "Error polling instance ${InstanceId}: $($_.Exception.Message) — retrying..." -Level WARN
        }
    }
    Write-Log ("Timed out after $TimeoutMinutes min waiting for IP on instance $InstanceId. " +
               "Proceeding without IP — WinRM-based steps will be skipped.") -Level WARN
    return $null
}

function Install-MorpheusAgent {
    # Installs the Morpheus agent on an HVM instance via the server management API.
    # Uses PUT /api/servers/{serverId}/install-agent — credentials must already be
    # set on the server record (done by Set-MorpheusInstanceCredentials).
    # NOTE: agentInstalled / guestAgentStatus live on the SERVER record
    # (/api/servers/{id}), not on the instance record — poll the server endpoint.
    param(
        [Parameter(Mandatory)][int]$InstanceId,
        [hashtable]$Headers,
        [int]$TimeoutMinutes = 15
    )

    $baseUri = "https://$MorpheusServer"

    # Resolve the primary server ID from the instance record
    $instResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/instances/$InstanceId" `
                    -Method GET -Headers $Headers
    $serverIds = $instResp.instance.servers
    if (-not $serverIds -or $serverIds.Count -eq 0) {
        throw "Cannot resolve server ID for instance $InstanceId — agent install skipped."
    }
    $serverId = $serverIds[0]

    # Pre-check: agent is considered installed only when all three fields are populated.
    # agentInstalled alone can be a stale flag inherited from the VMware server record.
    # guestAgentStatus alone can show 'connected' before the agent is fully registered.
    # agentVersion being non-empty is the strongest signal of a complete installation.
    $srvResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/servers/$serverId" `
                    -Method GET -Headers $Headers
    $agentReady = $srvResp.server.agentInstalled -and
                  $srvResp.server.guestAgentStatus -eq 'connected' -and
                  -not [string]::IsNullOrEmpty($srvResp.server.agentVersion)
    if ($agentReady) {
        Write-Log "Morpheus agent installed on instance $InstanceId (server $serverId, v$($srvResp.server.agentVersion))." -Level SUCCESS
        return
    }

    Write-Log "Triggering Morpheus agent installation on server $serverId (instance $InstanceId)..."
    Invoke-MorpheusRestMethod -Uri "$baseUri/api/servers/$serverId/install-agent" `
        -Method PUT -Headers $Headers | Out-Null

    Write-Log "Agent installation triggered. Polling for completion (timeout: $TimeoutMinutes min)..."
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        $srvResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/servers/$serverId" `
                        -Method GET -Headers $Headers
        $agentReady = $srvResp.server.agentInstalled -and
                      $srvResp.server.guestAgentStatus -eq 'connected' -and
                      -not [string]::IsNullOrEmpty($srvResp.server.agentVersion)
        if ($agentReady) {
            Write-Log "Morpheus agent installed on instance $InstanceId (server $serverId, v$($srvResp.server.agentVersion))." -Level SUCCESS
            return
        }
        Write-Log "Waiting for agent installation on instance $InstanceId (agentInstalled=$($srvResp.server.agentInstalled), status=$($srvResp.server.guestAgentStatus), version=$($srvResp.server.agentVersion))..."
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
    $body = $null
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
        $plainPassword = $null
    }

    try {
        Invoke-MorpheusRestMethod -Uri "$baseUri/api/servers/$serverId" `
            -Method PUT -Headers $Headers -Body $body -ContentType 'application/json' | Out-Null
        Write-Log "Morpheus server $serverId credentials set to '$TargetVMUser'." -Level SUCCESS
    } catch {
        Write-Log "Could not update credentials on server ${serverId}: $($_.Exception.Message) — finalize step may fail." -Level WARN
    } finally {
        $body = $null
    }
}

# Shared VMware Tools removal script used by both Remove-VMwareToolsViaTask (Morpheus task path)
# and Remove-VMwareToolsViaWinRM (direct WinRM fallback). Defined once here to avoid duplication.
# The script implements a 3-stage removal strategy:
#   Stage 1 — env var bypass (VIT_MSI_DISABLE_VMX_CHECK): works on some VMware Tools versions.
#   Stage 2 — MSI database patch via COM: removes VM_LogStart and VM_CheckRequirements from the
#             cached MSI CustomAction table, then re-runs msiexec. Reliable when cache is intact.
#   Stage 3 — manual forced cleanup: stops services, deletes files and registry keys entirely
#             outside MSI. Used when the installer cache is missing or both MSI approaches fail.
$script:VmtRemovalScript = @'
function Remove-VMwareToolsInternal {
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $toolsKey = Get-ChildItem $regPaths -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
        Where-Object { $_.DisplayName -like 'VMware Tools*' } |
        Select-Object -First 1
    if (-not $toolsKey) { Write-Output 'VMWARETOOLS_NOT_FOUND'; return }
    Write-Output "FOUND: $($toolsKey.DisplayName) $($toolsKey.DisplayVersion)"
    $productCode = $toolsKey.PSChildName

    # Stage 1: set env var to bypass VMX hardware check
    [System.Environment]::SetEnvironmentVariable('VIT_MSI_DISABLE_VMX_CHECK', '1', 'Machine')
    $p = Start-Process msiexec.exe -ArgumentList "/x $productCode /qn /norestart" -Wait -PassThru -NoNewWindow
    Write-Output "STAGE1_EXIT: $($p.ExitCode)"
    if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) { Write-Output 'VMWARETOOLS_REMOVED'; return }

    # Stage 2: patch cached MSI via COM using InvokeMember (required for WindowsInstaller COM in PS)
    # Uses packed-GUID registry lookup for the exact LocalPackage path (ref: KGHague gist).
    # Deletes VM_LogStart and VM_CheckRequirements from the CustomAction table (not InstallExecuteSequence).
    Write-Output "Stage 1 returned $($p.ExitCode) — attempting MSI database patch..."
    $localPackage = $null
    try {
        $guid = [System.Guid]::Parse($productCode.Trim('{}'))
        $gs = $guid.ToString('N')
        $idxLen = [ordered]@{ 0=8; 8=4; 12=4; 16=2; 18=2; 20=12 }
        $packed = ''
        foreach ($kv in $idxLen.GetEnumerator()) {
            $sub = $gs.Substring($kv.Key, $kv.Value)
            if ($kv.Key -eq 20) {
                ($sub -split '(.{2})' | Where-Object { $_ }) | ForEach-Object {
                    $ch = $_ -split '(.{1})' | Where-Object { $_ }
                    [System.Array]::Reverse($ch); $packed += $ch -join ''
                }
            } else {
                $ch = $sub.ToCharArray(); [System.Array]::Reverse($ch); $packed += $ch -join ''
            }
        }
        $packedGuid = [System.Guid]::Parse($packed).ToString('N').ToUpper()
        $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\S-1-5-18\Products\$packedGuid\InstallProperties"
        $localPackage = (Get-ItemProperty -Path $regPath -ErrorAction Stop).LocalPackage
        Write-Output "Found LocalPackage: $localPackage"
    } catch { Write-Output "LocalPackage lookup failed: $_ — cannot patch MSI" }

    if ($localPackage -and (Test-Path $localPackage)) {
        $patched = $false
        $ins2 = $null; $db2 = $null; $vw2 = $null
        try {
            $ins2 = New-Object -ComObject WindowsInstaller.Installer
            $db2  = $ins2.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $ins2, @($localPackage, 2))
            $vw2  = $db2.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $db2,
                        @("DELETE FROM CustomAction WHERE Action='VM_LogStart' OR Action='VM_CheckRequirements'"))
            $vw2.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $vw2, $null)
            $vw2.GetType().InvokeMember('Close',   'InvokeMethod', $null, $vw2, $null)
            $db2.GetType().InvokeMember('Commit',  'InvokeMethod', $null, $db2, $null)
            Write-Output 'MSI patched: VM_LogStart and VM_CheckRequirements removed from CustomAction'
            $patched = $true
        } catch { Write-Output "MSI patch failed: $_" }
        finally {
            if ($vw2)  { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($vw2)  | Out-Null }
            if ($db2)  { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($db2)  | Out-Null }
            if ($ins2) { [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($ins2) | Out-Null }
        }
        if ($patched) {
            $p2 = Start-Process msiexec.exe -ArgumentList "/x `"$localPackage`" /qn /norestart" -Wait -PassThru -NoNewWindow
            Write-Output "STAGE2_EXIT: $($p2.ExitCode)"
            if ($p2.ExitCode -eq 0 -or $p2.ExitCode -eq 3010) { Write-Output 'VMWARETOOLS_REMOVED'; return }
            Write-Output "Stage 2 returned $($p2.ExitCode) — falling back to manual removal"
        }
    } else { Write-Output 'LocalPackage not found on disk — falling back to manual removal' }

    # Stage 3: manual forced cleanup (bypasses MSI entirely)
    Write-Output 'Starting manual VMware Tools cleanup...'
    foreach ($svc in @('VMTools', 'VGAuthService', 'vmvss', 'VMwareCAFCommAmqpListener', 'VMwareCAFManagementAgentHost')) {
        Stop-Service $svc -Force -ErrorAction SilentlyContinue
        & sc.exe delete $svc 2>&1 | Out-Null
    }
    $vmDir = 'C:\Program Files\VMware'
    if (Test-Path $vmDir) { Remove-Item $vmDir -Recurse -Force -ErrorAction SilentlyContinue; Write-Output "Deleted: $vmDir" }
    foreach ($regKey in @(
        'HKLM:\SOFTWARE\VMware, Inc.',
        'HKLM:\SOFTWARE\WOW6432Node\VMware, Inc.',
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$productCode",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\$productCode"
    )) {
        if (Test-Path $regKey) { Remove-Item $regKey -Recurse -Force -ErrorAction SilentlyContinue; Write-Output "Removed: $regKey" }
    }
    Write-Output 'VMWARETOOLS_REMOVED_MANUAL'
}
Remove-VMwareToolsInternal
'@

function Remove-VMwareToolsViaTask {
    # Removes VMware Tools from a running Morpheus HVM instance by creating a
    # one-off PowerShell task, executing it on the instance, then cleaning up.
    # Requires the Morpheus agent to be installed on the instance.
    #
    # NOTE: Task result polling uses /api/task-results/:id which may vary by
    # Morpheus version. If this path fails the caller should fall back to
    # Remove-VMwareToolsViaWinRM.
    #
    # The removal script is defined at script scope ($script:VmtRemovalScript)
    # and shared with Remove-VMwareToolsViaWinRM to avoid duplication.
    param(
        [Parameter(Mandatory)][int]$InstanceId,
        [hashtable]$Headers,
        [int]$TimeoutMinutes = 10
    )

    $baseUri = "https://$MorpheusServer"
    $taskId = $null

    $removalScript = $script:VmtRemovalScript
    $taskName = 'VMware Tools Removal'
    # Reuse the persistent task if it already exists; create it only if not found.
    $searchResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/tasks?name=$([Uri]::EscapeDataString($taskName))" `
                      -Method GET -Headers $Headers
    $existingTask = $searchResp.tasks | Where-Object { $_.name -eq $taskName } | Select-Object -First 1
    if ($existingTask) {
        $taskId = $existingTask.id
        Write-Log "Reusing existing Morpheus task '$taskName' (id=$taskId)."
    } else {
        Write-Log "Creating Morpheus task '$taskName' for VMware Tools removal..."
        $taskBody = @{
            task = @{
                name          = $taskName
                taskType      = @{ code = 'winrmTask' }
                executeTarget = 'resource'
                file          = @{
                    sourceType = 'local'
                    content    = $removalScript
                }
                taskOptions   = @{ 'winrm.elevated' = $null }
            }
        } | ConvertTo-Json -Depth 6
        $taskResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/tasks" -Method POST `
                        -Headers $Headers -Body $taskBody -ContentType 'application/json'
        $taskId = $taskResp.task.id
        Write-Log "Morpheus task '$taskName' created: id=$taskId"
    }

    $execBody = @{
        job = @{
            targetType = 'instance'
            instances  = @($InstanceId)
        }
    } | ConvertTo-Json -Depth 4
    $execResp    = Invoke-MorpheusRestMethod -Uri "$baseUri/api/tasks/$taskId/execute" `
                       -Method POST -Headers $Headers -Body $execBody -ContentType 'application/json'
    $executionId = $execResp.jobExecution.id
    Write-Log "Task $taskId execution started: jobExecutionId=$executionId. Polling (timeout: $TimeoutMinutes min)..."

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        try {
            $resultResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/job-executions/$executionId" `
                              -Method GET -Headers $Headers
            $exStatus = $resultResp.jobExecution.status
            # Output may be at process.output (flat) or in process.events[0].output (per-event)
            $output   = $resultResp.jobExecution.process.output
            if (-not $output) {
                $output = ($resultResp.jobExecution.process.events | Select-Object -First 1).output
            }
            Write-Log "Task execution status: $exStatus output: $output"
            if ($exStatus -eq 'success' -or ($output -match 'VMWARETOOLS_REMOVED|VMWARETOOLS_REMOVED_MANUAL|VMWARETOOLS_NOT_FOUND')) {
                Write-Log "VMware Tools removal via Morpheus task succeeded on instance $InstanceId." -Level SUCCESS
                return
            }
            if ($exStatus -eq 'error') { throw "Morpheus task execution failed. Output: $output" }
        } catch {
            Write-Log "Error polling task result (will retry): $($_.Exception.Message)" -Level WARN
        }
    }
    throw "Timed out waiting for Morpheus task execution result on instance $InstanceId."
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
        if ($WinRMSkipSSL) {
            Write-Log "WinRMSkipSSL: TLS validation is DISABLED for WinRM sessions to $TargetIP." -Level WARN
            $sessionOpts = New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck
        } else {
            $sessionOpts = New-PSSessionOption
        }
        # Single shared deadline covering both the connection phase and the polling phase.
        # Using two independent deadlines from the same variable would silently double the wall time.
        $functionDeadline = (Get-Date).AddMinutes($TimeoutMinutes)
        $session = $null
        while ((Get-Date) -lt $functionDeadline -and -not $session) {
            try {
                $session = New-PSSession -ComputerName $TargetIP -Port 5985 -Credential $cred `
                               -Authentication Negotiate -SessionOption $sessionOpts -ErrorAction Stop
            } catch {
                Write-Log "WinRM not yet reachable at ${TargetIP}: $($_.Exception.Message) — retrying in 30s..." -Level WARN
                Start-Sleep -Seconds 30
            }
        }
        if (-not $session) {
            throw "Could not establish WinRM session to $TargetIP within $TimeoutMinutes min."
        }

        $ts         = Get-Date -Format 'yyyyMMddHHmmss'
        $taskName   = "VmtRemoval_$ts"
        $scriptFile = "C:\Windows\Temp\vmtools_remove_$ts.ps1"
        $resultFile = "C:\Windows\Temp\vmtools_result_$ts.txt"
        $resultText = $null

        try {
            Write-Log "WinRM session established. Deploying VMware Tools removal task on $TargetIP..."
            $vmRemovalScript = $script:VmtRemovalScript
            # Write the removal script to a temp file on the remote machine.
            Invoke-Command -Session $session -ArgumentList $vmRemovalScript, $scriptFile -ScriptBlock {
                param($content, $path) Set-Content -Path $path -Value $content -Encoding UTF8
            }
            # Register and start a SYSTEM scheduled task so removal runs independently of the WinRM session.
            # Running directly in the session risks an aborted connection when VMware services are stopped or
            # msiexec triggers a reboot — the scheduled task survives both scenarios.
            Invoke-Command -Session $session -ArgumentList $taskName, $scriptFile, $resultFile -ScriptBlock {
                param($tname, $sf, $rf)
                $action    = New-ScheduledTaskAction -Execute 'cmd.exe' `
                                 -Argument "/c powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$sf`" >> `"$rf`" 2>&1"
                $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
                Register-ScheduledTask -TaskName $tname -Action $action -Principal $principal -Force | Out-Null
                Start-ScheduledTask -TaskName $tname
            }
            Write-Log "Scheduled task '$taskName' started. Closing WinRM session before removal begins..."
        } finally {
            # Disconnect immediately so a service/reboot event during removal doesn't abort this session.
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            $session = $null
        }

        # Poll for scheduled task completion — opens a fresh WinRM session each attempt so a reboot is survivable.
        Write-Log "Polling for VMware Tools removal completion on $TargetIP (timeout: $TimeoutMinutes min)..."
        while ((Get-Date) -lt $functionDeadline) {
            Start-Sleep -Seconds 20
            $pollSession = $null
            try {
                $pollSession = New-PSSession -ComputerName $TargetIP -Port 5985 -Credential $cred `
                                   -Authentication Negotiate -SessionOption $sessionOpts -ErrorAction Stop
                $taskState = Invoke-Command -Session $pollSession -ArgumentList $taskName -ScriptBlock {
                    param($tn)
                    $t = Get-ScheduledTask -TaskName $tn -ErrorAction SilentlyContinue
                    if ($t) { $t.State } else { 'NotFound' }
                }
                if ($taskState -notin @('Running', 'Queued')) {
                    $rawOutput = Invoke-Command -Session $pollSession -ArgumentList $resultFile -ScriptBlock {
                        param($rf) if (Test-Path $rf) { Get-Content $rf -Raw } else { 'RESULT_FILE_MISSING' }
                    }
                    $resultText = if ($rawOutput) { "$rawOutput".Trim() } else { '' }
                    Invoke-Command -Session $pollSession -ArgumentList $taskName, $scriptFile, $resultFile -ScriptBlock {
                        param($tn, $sf, $rf)
                        Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
                        Remove-Item $sf, $rf -Force -ErrorAction SilentlyContinue
                    }
                    break
                }
                Write-Log "VMware Tools removal still running on $TargetIP (task state: $taskState)..."
            } catch {
                Write-Log "WinRM not yet reachable at $TargetIP — retrying in 20s..." -Level WARN
            } finally {
                if ($pollSession) { Remove-PSSession $pollSession -ErrorAction SilentlyContinue }
            }
        }

        # Cleanup guard: if the polling loop timed out while the task was still running,
        # attempt to unregister the scheduled task and temp files to avoid leftovers.
        if (-not $resultText) {
            Write-Log "Polling timed out on $TargetIP. Attempting scheduled task cleanup..." -Level WARN
            $cleanupSession = $null
            try {
                $cleanupSession = New-PSSession -ComputerName $TargetIP -Port 5985 -Credential $cred `
                                      -Authentication Negotiate -SessionOption $sessionOpts -ErrorAction SilentlyContinue
                if ($cleanupSession) {
                    Invoke-Command -Session $cleanupSession -ArgumentList $taskName, $scriptFile, $resultFile -ScriptBlock {
                        param($tn, $sf, $rf)
                        Unregister-ScheduledTask -TaskName $tn -Confirm:$false -ErrorAction SilentlyContinue
                        Remove-Item $sf, $rf -Force -ErrorAction SilentlyContinue
                    }
                }
            } catch {
                Write-Log "Cleanup after polling timeout failed (non-fatal): $($_.Exception.Message)" -Level WARN
            } finally {
                if ($cleanupSession) { Remove-PSSession $cleanupSession -ErrorAction SilentlyContinue }
            }
        }

        if ($resultText) {
            Write-Log "VMware Tools removal result: $resultText"
            if ($resultText -match 'VMWARETOOLS_REMOVED|VMWARETOOLS_REMOVED_MANUAL|VMWARETOOLS_NOT_FOUND') {
                Write-Log "VMware Tools removal via WinRM succeeded on $TargetIP." -Level SUCCESS
            } else {
                # Result file is incomplete — msiexec likely triggered a reboot before the success token
                # was written. Verify directly: if VMware Tools is gone from the registry, that is success.
                Write-Log "Result file incomplete (msiexec may have rebooted the VM). Verifying registry on $TargetIP..."
                $verifySession = $null
                $verifyDeadline = (Get-Date).AddMinutes(5)
                while ((Get-Date) -lt $verifyDeadline -and -not $verifySession) {
                    try {
                        $verifySession = New-PSSession -ComputerName $TargetIP -Port 5985 -Credential $cred `
                                             -Authentication Negotiate -SessionOption $sessionOpts -ErrorAction Stop
                    } catch {
                        Write-Log "WinRM not yet ready for verification at ${TargetIP} — retrying in 20s..." -Level WARN
                        Start-Sleep -Seconds 20
                    }
                }
                if ($verifySession) {
                    try {
                        $verifyResult = Invoke-Command -Session $verifySession -ScriptBlock {
                            $regPaths = @(
                                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
                            )
                            $toolsKey = Get-ChildItem $regPaths -ErrorAction SilentlyContinue |
                                ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
                                Where-Object { $_.DisplayName -like 'VMware Tools*' } |
                                Select-Object -First 1
                            if ($toolsKey) { "STILL_INSTALLED: $($toolsKey.DisplayName) $($toolsKey.DisplayVersion)" }
                            else           { 'NOT_INSTALLED' }
                        }
                        if ($verifyResult -eq 'NOT_INSTALLED') {
                            Write-Log "VMware Tools no longer present in registry — removal succeeded (via reboot)." -Level SUCCESS
                        } else {
                            Write-Log "VMware Tools removal may not have completed on ${TargetIP}: $verifyResult" -Level WARN
                        }
                    } finally {
                        Remove-PSSession $verifySession -ErrorAction SilentlyContinue
                    }
                } else {
                    Write-Log "Could not reconnect to $TargetIP for verification — removal status unknown." -Level WARN
                }
            }
        } else {
            Write-Log "Timed out waiting for VMware Tools removal result from $TargetIP (timeout: $TimeoutMinutes min)." -Level WARN
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
    #   1. Wait for the instance to reach 'running' state and obtain its IP (may be null on timeout)
    #   2. Attempt Morpheus agent installation via the server management API
    #   3. If agent installed: remove tools via Morpheus task execution (no IP required)
    #   4. If agent unavailable or task fails AND IP is available: remove tools via direct WinRM
    param([Parameter(Mandatory)][int]$InstanceId)

    $headers = Get-MorpheusAuthHeaders
    Write-Log "Starting post-migration VMware Tools removal for Morpheus instance $InstanceId..."

    $targetIP = Wait-ForMorpheusInstance -InstanceId $InstanceId -Headers $headers
    if (-not $targetIP) {
        Write-Log "No routable IP available for instance $InstanceId — WinRM fallback will be skipped if agent path fails." -Level WARN
    }

    $agentAvailable = $false
    try {
        Install-MorpheusAgent -InstanceId $InstanceId -Headers $headers
        $agentAvailable = $true
    } catch {
        Write-Log "Morpheus agent installation skipped or failed: $($_.Exception.Message) — will use direct WinRM fallback." -Level WARN
    }

    if ($agentAvailable) {
        try {
            Remove-VMwareToolsViaTask -InstanceId $InstanceId -Headers $headers
            return
        } catch {
            Write-Log "Morpheus task-based removal failed: $($_.Exception.Message) — falling back to WinRM." -Level WARN
        }
    }

    if ($targetIP) {
        Remove-VMwareToolsViaWinRM -TargetIP $targetIP
    } else {
        Write-Log ("Cannot remove VMware Tools: Morpheus agent unavailable and no routable IP for WinRM. " +
                   "Remove VMware Tools manually from the migrated VM.") -Level WARN
    }
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
    #   Client (Windows 10/11 detected from ProductName):
    #     >= 22000  -> w11   (Windows 11)
    #     <  22000  -> w10   (Windows 10)
    #   Server:
    #     >= 26100  -> 2k25   (Windows Server 2025)
    #     >= 20348  -> 2k22   (Windows Server 2022)
    #     >= 17763  -> 2k19   (Windows Server 2019)
    #     >= 14393  -> 2k16   (Windows Server 2016)
    #     >=  9200  -> 2k12R2 (Windows Server 2012 / 2012 R2)
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
    if ($LASTEXITCODE -ne 0) {
        Write-Host "HIVE_UNLOAD_FAILED:$LASTEXITCODE"
    } else {
        Write-Host 'HIVE_UNLOADED'
    }
}
'@) -replace '__OFFLINE_DRIVE__', $OfflineDrive
    $out = Invoke-HelperScript -HelperVM $HelperVM -Script $detectScript -Description 'Detect OS from offline SOFTWARE hive'

    if ($out -match 'HIVE_NOT_FOUND') {
        throw "SOFTWARE hive not found on $OfflineDrive. Cannot auto-detect OS. Use -GuestOSFolder to override."
    }
    if ($out -notmatch 'HIVE_UNLOADED') {
        throw "SOFTWARE hive did not unload cleanly (HIVE_UNLOAD_FAILED or missing token). A handle may still be open on the target disk. Output: $out"
    }

    $buildStr   = ($out -split "`n" | Where-Object { $_ -match '^BUILD:' } | Select-Object -Last 1) -replace 'BUILD:',''
    $productStr = ($out -split "`n" | Where-Object { $_ -match '^PRODUCT:' } | Select-Object -Last 1) -replace 'PRODUCT:',''
    $buildStr   = $buildStr.Trim()
    $product    = $productStr.Trim()

    if (-not $buildStr -or $buildStr -notmatch '^\d+$') {
        throw ("Could not read CurrentBuildNumber from offline SOFTWARE hive on $OfflineDrive. " +
               "Raw hive output: $out. Use -GuestOSFolder to specify the driver folder manually.")
    }
    $build = [int]$buildStr

    Write-Log "Offline disk OS: '$product' (Build: $build)"

    $isClient = $product -match 'Windows (10|11)'
    $folder = if ($isClient) {
        if ($build -ge 22000) { 'w11' } else { 'w10' }
    } elseif ($build -ge 26100) { '2k25'   }
      elseif ($build -ge 20348) { '2k22'   }
      elseif ($build -ge 17763) { '2k19'   }
      elseif ($build -ge 14393) { '2k16'   }
      elseif ($build -ge 9200)  { '2k12R2' }
      else                      { $null    }

    if (-not $folder) {
        throw ("Cannot map OS build $build ('$product') to a VirtIO driver subfolder. " +
               "Use -GuestOSFolder to override manually.")
    }
    Write-Log "Mapped build $build ('$product') -> VirtIO subfolder: $folder" -Level SUCCESS
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
        Write-Log "No -MorpheusTargetCloudId specified — querying available HVM/KVM clouds..."
        $zonesResp = Invoke-MorpheusRestMethod -Uri "$baseUri/api/zones?max=100" `
                         -Method GET -Headers $headers
        # Exclude VMware vCenter source clouds — only offer HVM/KVM targets
        $vmwareCodes = @('vmware', 'vsphere')
        $clouds = $zonesResp.zones |
                  Where-Object { $vmwareCodes -notcontains $_.zoneType.code } |
                  Sort-Object name
        if (-not $clouds -or $clouds.Count -eq 0) {
            throw ("No HVM/KVM target clouds found in Morpheus. " +
                   "Verify that an HVM cloud is configured, or specify -MorpheusTargetCloudId manually.")
        }
        if ($clouds.Count -eq 1) {
            $script:MorpheusTargetCloudId = [string]$clouds[0].id
            Write-Log "Auto-selected only available HVM cloud: $($clouds[0].name) (id=$($script:MorpheusTargetCloudId))" -Level SUCCESS
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
        # Filter to pools that belong to the selected HVM cloud (API can return cross-cloud results)
        $pools = $poolsResp.resourcePools |
                 Where-Object { $_.zone.id -eq [int]$MorpheusTargetCloudId } |
                 Sort-Object name
        if (-not $pools -or $pools.Count -eq 0) {
            throw ("No resource pools found in Morpheus for cloud $MorpheusTargetCloudId. " +
                   "Verify that at least one resource pool exists under Infrastructure > Compute > Resource Pools " +
                   "for the target cloud, or specify -MorpheusTargetPoolId manually.")
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
                         -Uri "$baseUri/api/data-stores?max=100" `
                         -Method GET -Headers $headers
        # Filter to datastores belonging to the selected HVM cloud (zoneId not supported as query param)
        $stores = $storeResp.dataStores |
                  Where-Object { $_.zone.id -eq [int]$MorpheusTargetCloudId } |
                  Sort-Object name
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

# --- PostMigrationOnly: skip vCenter entirely, run post-migration steps on an existing instance ---
if ($PostMigrationOnly) {
    Write-Log "=== HPE Morpheus Post-Migration Steps (PostMigrationOnly) ==="
    Write-Log "Morpheus instance : $MorpheusInstanceId"
    Write-Log "Morpheus server   : $MorpheusServer"
    Write-Log "Log File          : $LogFile"
    try {
        Invoke-PostMigrationVMwareToolsRemoval -InstanceId $MorpheusInstanceId
        Write-Log "Post-migration steps completed for Morpheus instance $MorpheusInstanceId." -Level SUCCESS
    } catch {
        Write-Log "Post-migration steps failed: $($_.Exception.Message)" -Level ERROR
        throw
    }
    return
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
                Write-Log "Post-migration VMware Tools removal failed (non-fatal): $($_.Exception.Message)" -Level WARN
            }
        } elseif ($RemoveVMwareTools) {
            Write-Log 'Could not determine Morpheus instance ID — skipping post-migration VMware Tools removal.' -Level WARN
        }
    } catch {
        Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level ERROR
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
                    Write-Log "Could not restart source VM after migration failure: $($_.Exception.Message)" -Level ERROR
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
        Write-Log "Failed to migrate Helper VM: $($_.Exception.Message)" -Level ERROR
        throw "VM host mismatch and migration failed. Please manually align hosts. Error: $($_.Exception.Message)"
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
            Write-Log "Candidate $candidatePath is not the target OS disk. Reason: $($_.Exception.Message)" -Level WARN
            if ($null -ne $candidateAttachedDiskNumber) {
                try { Disable-AttachedDiskOnHelper -HelperVM $helperVM -DiskNumber $candidateAttachedDiskNumber } catch {
                    Write-Log "Could not offline candidate disk $candidateAttachedDiskNumber before detach: $($_.Exception.Message)" -Level WARN
                }
            }
            try { Remove-TargetDiskFromHelper -HelperVM $helperVM -DiskPath $candidatePath } catch {
                Write-Log "Could not detach candidate disk ${candidatePath}: $($_.Exception.Message)" -Level WARN
            }
        }
    }

    if (-not $attachedDiskPath -or -not $offlineDrive -or $null -eq $attachedDiskNumber) {
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
                    Write-Log "Post-migration VMware Tools removal failed (non-fatal): $($_.Exception.Message)" -Level WARN
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
    Write-Log "FATAL ERROR: $($_.Exception.Message)" -Level ERROR
    if ($null -ne $attachedDiskNumber -and -not $diskOfflined) {
        Write-Log "Cleanup: offlining attached helper disk number $attachedDiskNumber..." -Level WARN
        try {
            Disable-AttachedDiskOnHelper -HelperVM $helperVM -DiskNumber $attachedDiskNumber
        } catch {
            Write-Log "Could not offline attached disk on helper VM: $($_.Exception.Message)" -Level WARN
        }
    }
    if ($attachedDiskPath) {
        Write-Log "Cleanup: removing attached disk from helper VM..." -Level WARN
        try { Remove-TargetDiskFromHelper -HelperVM $helperVM -DiskPath $attachedDiskPath } catch {
            Write-Log "Could not detach disk from helper VM: $($_.Exception.Message)" -Level ERROR
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
                Write-Log "Could not restart source VM after migration failure: $($_.Exception.Message)" -Level ERROR
            }
        }
    }
    elseif (-not $vmStarted) {
        Write-Log "Attempting to restart target VM after failure..." -Level WARN
        try { Start-VM -VM $targetVM -Confirm:$false | Out-Null } catch {
            Write-Log "Could not restart target VM: $($_.Exception.Message)" -Level ERROR
        }
    }
    throw
}
finally {
    Disconnect-VIServer -Server $VCServer -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
    Write-Log "Disconnected from vCenter. Log: $LogFile"
}

#!/usr/bin/env pwsh
# Export-VSphereConfigs.ps1
#
# Exports vSphere/vCenter infrastructure configuration via PowerCLI.
# Requires VMware.PowerCLI to be installed.
# Reuses an existing vCenter session if one is active; otherwise connects.
#
# Usage: .\scripts\Export-VSphereConfigs.ps1

$ErrorActionPreference = "Stop"

# Suppress PowerCLI CEIP and update nag on every run.
Set-PowerCLIConfiguration -ParticipateInCEIP $false -Confirm:$false -Scope Session 2>$null | Out-Null

$VCENTER      = "vcenter.vollminlab.com"
$VCENTER_USER = "vollmin@vsphere.local"
$REPO         = Split-Path $PSScriptRoot -Parent
$OUT_DIR      = Join-Path $REPO "hosts\vsphere"

New-Item -ItemType Directory -Path $OUT_DIR -Force | Out-Null

function Save-Json {
    param([string]$Name, [object]$Data)
    $path = Join-Path $OUT_DIR "$Name.json"
    $content = $Data | ConvertTo-Json -Depth 10
    # Write with LF line endings (not CRLF) so git doesn't see spurious changes.
    [System.IO.File]::WriteAllText($path, ($content -replace "`r`n", "`n") + "`n")
    $bytes = (Get-Item $path).Length
    Write-Host "  pulled $Name.json ($bytes bytes)"
}

# ── Connection ────────────────────────────────────────────────────────────────
if ($global:DefaultVIServer -and $global:DefaultVIServer.IsConnected) {
    Write-Host "==> vCenter: $($global:DefaultVIServer.Name) (existing session)"
} else {
    Write-Host "==> Connecting to vCenter at $VCENTER"
    # Try op CLI for credentials; fall back to interactive prompt
    $connected = $false
    if (Get-Command op -ErrorAction SilentlyContinue) {
        try {
            $line   = op item get fa37l7fomndpbk5r6g7bkzgewa --fields label=username,label=password --reveal
            $opUser = $line.Split(',')[0].Trim()
            $opPass = $line.Substring($line.IndexOf(',') + 1).Trim()
            $cred   = New-Object PSCredential(
                $opUser,
                (ConvertTo-SecureString $opPass -AsPlainText -Force)
            )
            Connect-VIServer -Server $VCENTER -Credential $cred | Out-Null
            $connected = $true
        } catch {}
    }
    if (-not $connected) {
        Connect-VIServer -Server $VCENTER -User $VCENTER_USER | Out-Null
    }
    Write-Host "  connected"
}

Write-Host ""
Write-Host "==> Collecting vSphere configuration"

# ── Datacenter ────────────────────────────────────────────────────────────────
Save-Json "datacenter" (
    Get-Datacenter | Select-Object Name, Id
)

# ── Cluster ───────────────────────────────────────────────────────────────────
Save-Json "cluster" (
    Get-Cluster | ForEach-Object {
        $ha  = $_.ExtensionData.Configuration.DasConfig
        $drs = $_.ExtensionData.Configuration.DrsConfig
        [PSCustomObject]@{
            Name                      = $_.Name
            HAEnabled                 = $_.HAEnabled
            HAAdmissionControlEnabled = $ha.AdmissionControlEnabled
            HAFailoverLevel           = $ha.FailoverLevel
            HARestartPriority         = $ha.DefaultVmSettings.RestartPriority
            HAIsolationResponse       = $ha.DefaultVmSettings.IsolationResponse
            DrsEnabled                = $_.DrsEnabled
            DrsAutomationLevel        = $_.DrsAutomationLevel
            EVCMode                   = $_.EVCMode
        }
    }
)

# ── ESXi Hosts ────────────────────────────────────────────────────────────────
Save-Json "hosts" (
    Get-VMHost | Sort-Object Name | ForEach-Object {
        $h   = $_
        $net = $h | Get-VMHostNetwork
        $ntp = $h | Get-VMHostNtpServer
        $svc = $h | Get-VMHostService | Where-Object { $_.Key -eq "ntpd" }
        [PSCustomObject]@{
            Name          = $h.Name
            Version       = $h.Version
            Build         = $h.Build
            ConnectionState = $h.ConnectionState
            Manufacturer  = $h.Manufacturer
            Model         = $h.Model
            NumCpu        = $h.NumCpu
            MemoryTotalGB = [math]::Round($h.MemoryTotalGB, 2)
            DNS = [PSCustomObject]@{
                Hostname     = $net.HostName
                Domain       = $net.DomainName
                SearchDomain = $net.SearchDomain
                Servers      = $net.DnsAddress
            }
            NTP = [PSCustomObject]@{
                Servers        = $ntp
                ServiceRunning = $svc.Running
                ServicePolicy  = $svc.Policy
            }
        }
    }
)

# ── iSCSI ─────────────────────────────────────────────────────────────────────
Save-Json "iscsi" (
    Get-VMHost | Sort-Object Name | ForEach-Object {
        $h = $_
        [PSCustomObject]@{
            Host     = $h.Name
            Adapters = $h | Get-VMHostHba -Type iSCSI | ForEach-Object {
                $hba = $_
                [PSCustomObject]@{
                    Device    = $hba.Device
                    IScsiName = $hba.IScsiName
                    Model     = $hba.Model
                    Targets   = Get-IScsiHbaTarget -IScsiHba $hba | ForEach-Object {
                        [PSCustomObject]@{
                            Address = $_.Address
                            Port    = $_.Port
                            Type    = $_.Type
                        }
                    }
                }
            }
        }
    }
)

# ── Distributed Virtual Switch ────────────────────────────────────────────────
Save-Json "dvs" (
    Get-VDSwitch | ForEach-Object {
        $sw = $_
        [PSCustomObject]@{
            Name                           = $sw.Name
            NumPorts                       = $sw.NumPorts
            NumUplinkPorts                 = $sw.NumUplinkPorts
            Version                        = $sw.Version
            Mtu                            = $sw.Mtu
            LinkDiscoveryProtocol          = $sw.LinkDiscoveryProtocol
            LinkDiscoveryProtocolOperation = $sw.LinkDiscoveryProtocolOperation
            Hosts                          = ($sw | Get-VMHost | Sort-Object Name).Name
            UplinkNames                    = $sw.ExtensionData.Config.UplinkPortPolicy.UplinkPortName
        }
    }
)

# ── Port Groups ───────────────────────────────────────────────────────────────
Save-Json "portgroups" (
    Get-VDPortgroup | Sort-Object Name | ForEach-Object {
        [PSCustomObject]@{
            Name               = $_.Name
            VlanConfiguration  = $_.VlanConfiguration.ToString()
            NumPorts           = $_.NumPorts
            PortBinding        = $_.PortBinding
        }
    }
)

# ── Datastores ────────────────────────────────────────────────────────────────
Save-Json "datastores" (
    Get-Datastore | Sort-Object Name | ForEach-Object {
        [PSCustomObject]@{
            Name              = $_.Name
            Type              = $_.Type
            CapacityGB        = [math]::Round($_.CapacityGB, 2)
            FreeSpaceGB       = [math]::Round($_.FreeSpaceGB, 2)
            FileSystemVersion = $_.FileSystemVersion
        }
    }
)

# ── Resource Pools ────────────────────────────────────────────────────────────
Save-Json "resource-pools" (
    Get-ResourcePool | ForEach-Object {
        [PSCustomObject]@{
            Name              = $_.Name
            Parent            = $_.Parent.Name
            CpuSharesLevel    = $_.CpuSharesLevel
            CpuReservationMHz = $_.CpuReservationMHz
            CpuLimitMHz       = $_.CpuLimitMHz
            MemSharesLevel    = $_.MemSharesLevel
            MemReservationGB  = [math]::Round($_.MemReservationGB, 2)
            MemLimitGB        = if ($_.MemLimitGB -lt 0) { "Unlimited" } else { [math]::Round($_.MemLimitGB, 2) }
        }
    }
)

# ── VM Inventory ─────────────────────────────────────────────────────────────
Save-Json "vms" (
    Get-VM | Sort-Object Name | ForEach-Object {
        $vm = $_
        [PSCustomObject]@{
            Name       = $vm.Name
            GuestId    = $vm.GuestId
            NumCpu     = $vm.NumCpu
            MemoryGB   = $vm.MemoryGB
            PowerState = $vm.PowerState
            Host       = $vm.VMHost.Name
            Folder     = $vm.Folder.Name
            Notes      = $vm.Notes
            Disks      = ($vm | Get-HardDisk | ForEach-Object {
                [PSCustomObject]@{
                    Name          = $_.Name
                    CapacityGB    = [math]::Round($_.CapacityGB, 2)
                    StorageFormat = $_.StorageFormat
                    Datastore     = $_.Filename.Split(']')[0].TrimStart('[')
                }
            })
            Networks   = ($vm | Get-NetworkAdapter | ForEach-Object {
                [PSCustomObject]@{
                    Name             = $_.Name
                    NetworkName      = $_.NetworkName
                    Type             = $_.Type
                    MacAddress       = $_.MacAddress
                    MacAddressType   = $_.MacAddressType
                }
            })
            Tags       = (Get-TagAssignment -Entity $vm |
                Select-Object @{N="Tag";E={$_.Tag.Name}}, @{N="Category";E={$_.Tag.Category.Name}})
        }
    }
)

# ── Host vmkernel Adapters ────────────────────────────────────────────────────
Save-Json "host-vmkernel" (
    Get-VMHost | Sort-Object Name | ForEach-Object {
        $h = $_
        [PSCustomObject]@{
            Host     = $h.Name
            Adapters = Get-VMHostNetworkAdapter -VMHost $h -VMKernel | ForEach-Object {
                [PSCustomObject]@{
                    Name            = $_.Name
                    IP              = $_.IP
                    SubnetMask      = $_.SubnetMask
                    Mac             = $_.Mac
                    PortGroupName   = $_.PortGroupName
                    VMotionEnabled  = $_.VMotionEnabled
                    ManagementTrafficEnabled = $_.ManagementTrafficEnabled
                    FaultToleranceLoggingEnabled = $_.FaultToleranceLoggingEnabled
                    VsanTrafficEnabled = $_.VsanTrafficEnabled
                }
            }
        }
    }
)

# ── DRS Rules ─────────────────────────────────────────────────────────────────
Save-Json "drs-rules" (
    Get-Cluster | ForEach-Object {
        $cl = $_
        [PSCustomObject]@{
            Cluster = $cl.Name
            Rules   = Get-DrsRule -Cluster $cl | ForEach-Object {
                [PSCustomObject]@{
                    Name    = $_.Name
                    Type    = $_.Type
                    Enabled = $_.Enabled
                    VMs     = $_.VMIds | ForEach-Object {
                        (Get-VM -Id $_ -ErrorAction SilentlyContinue).Name
                    }
                }
            }
        }
    }
)

# ── VM Templates ──────────────────────────────────────────────────────────────
Save-Json "templates" (
    Get-Template | Sort-Object Name | ForEach-Object {
        [PSCustomObject]@{
            Name     = $_.Name
            GuestId  = $_.GuestId
            NumCpu   = $_.NumCpu
            MemoryGB = $_.MemoryGB
            Folder   = $_.Folder.Name
        }
    }
)

# ── Content Libraries ─────────────────────────────────────────────────────────
Save-Json "content-libraries" (
    Get-ContentLibrary -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{
            Name        = $_.Name
            Description = $_.Description
            Type        = $_.Type
            Datastore   = $_.Datastore.Name
        }
    }
)

# ── Storage Policies ──────────────────────────────────────────────────────────
Save-Json "storage-policies" (
    Get-SpbmStoragePolicy -ErrorAction SilentlyContinue | Sort-Object Name |
    Where-Object { $_.AnyOfRuleSets -or $_.Description } | ForEach-Object {
        [PSCustomObject]@{
            Name        = $_.Name
            Description = $_.Description
        }
    }
)

# ── Datastore Clusters ────────────────────────────────────────────────────────
Save-Json "datastore-clusters" (
    Get-DatastoreCluster -ErrorAction SilentlyContinue | ForEach-Object {
        [PSCustomObject]@{
            Name        = $_.Name
            CapacityGB  = [math]::Round($_.CapacityGB, 2)
            FreeSpaceGB = [math]::Round($_.FreeSpaceGB, 2)
            Datastores  = ($_ | Get-Datastore | Sort-Object Name).Name
        }
    }
)

# ── Roles ─────────────────────────────────────────────────────────────────────
Save-Json "roles" (
    Get-VIRole | Sort-Object Name | Where-Object { -not $_.IsSystem } | ForEach-Object {
        [PSCustomObject]@{
            Name          = $_.Name
            PrivilegeList = ($_.PrivilegeList | Sort-Object)
        }
    }
)

# ── Permissions ───────────────────────────────────────────────────────────────
Save-Json "permissions" (
    Get-VIPermission | ForEach-Object {
        [PSCustomObject]@{
            Entity     = $_.Entity.Name
            EntityType = $_.EntityType
            Principal  = $_.Principal
            Role       = $_.Role
            IsGroup    = $_.IsGroup
            Propagate  = $_.Propagate
        }
    }
)

# ── Tags ──────────────────────────────────────────────────────────────────────
Save-Json "tag-categories" (
    Get-TagCategory | Sort-Object Name | ForEach-Object {
        [PSCustomObject]@{
            Name        = $_.Name
            Description = $_.Description
            Cardinality = $_.Cardinality
            EntityType  = $_.EntityType
        }
    }
)

Save-Json "tags" (
    Get-Tag | Sort-Object Name | ForEach-Object {
        [PSCustomObject]@{
            Name        = $_.Name
            Category    = $_.Category.Name
            Description = $_.Description
        }
    }
)

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Done. Review before committing:"
Write-Host "  git diff --stat hosts/vsphere/"

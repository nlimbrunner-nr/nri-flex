<#
.SYNOPSIS
    Exchange Server 2016/2019/SE health collector for nri-flex.
.DESCRIPTION
    One script, many checks. Each Flex API calls it with -Check <name> and gets a flat JSON array back
    (one object per row). All rows carry "check" and "server" attributes.
    On failure a single row with an "error" attribute is emitted, so broken checks are visible/alertable in New Relic.
.PARAMETER Check
    ServerInfo | ServiceHealth | Queues | DatabaseCopies | Databases | MailboxCounts | ReplicationHealth |
    HealthReport | ComponentState | Certificates | MessageTracking | PerfCounters
.PARAMETER LookbackMinutes
    Window for MessageTracking. Keep equal to the Flex interval.
.EXAMPLE
    powershell -File nr-exchange.ps1 -Check Queues
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('ServerInfo', 'ServiceHealth', 'Queues', 'DatabaseCopies', 'Databases', 'MailboxCounts', 'ReplicationHealth',
                 'HealthReport', 'ComponentState', 'Certificates', 'MessageTracking', 'PerfCounters')]
    [string] $Check,

    [int] $LookbackMinutes = 5
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$WarningPreference     = 'SilentlyContinue'

$Server  = $env:COMPUTERNAME
$Session = $null

#region Helpers

# Loads Exchange cmdlets. Local snap-in first (fast, works as LocalSystem); falls back to the
# remote PowerShell endpoint, which requires the agent to run as an account with Exchange RBAC rights.
function Import-ExchangeShell {
    if (Get-Command Get-ExchangeServer -ErrorAction SilentlyContinue) { return }
    try {
        Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction Stop
    }
    catch {
        $fqdn = [System.Net.Dns]::GetHostEntry($Server).HostName
        $script:Session = New-PSSession -ConfigurationName Microsoft.Exchange -ConnectionUri "http://$fqdn/PowerShell/" -Authentication Kerberos
        # -Global: otherwise the imported cmdlets only exist inside this function's scope
        Import-Module (Import-PSSession $script:Session -DisableNameChecking -AllowClobber) -Global -DisableNameChecking | Out-Null
    }
}

# ByteQuantifiedSize -> bytes. Handles live objects (snap-in) and deserialized strings (remote session),
# e.g. "1.234 GB (1,325,000,000 bytes)".
function ConvertTo-Bytes($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value.PSObject.Methods['ToBytes']) { return [int64]$Value.ToBytes() }
    if ($Value.Value -and $Value.Value.PSObject.Methods['ToBytes']) { return [int64]$Value.Value.ToBytes() }
    if ("$Value" -match '\(([\d,\.\s]+) bytes\)') { return [int64]($Matches[1] -replace '[^\d]', '') }
    return $null
}

function Get-AgeHours($Date) {
    if ($Date -isnot [datetime]) { return $null }
    return [math]::Round(((Get-Date) - $Date).TotalHours, 2)
}

function Get-UnixTime($Date) {
    if ($Date -isnot [datetime]) { return $null }
    return ([DateTimeOffset]$Date.ToUniversalTime()).ToUnixTimeSeconds()
}

# Free space of the volume (incl. mount points) that holds $Path.
$script:Volumes = $null
function Get-VolumeForPath([string]$Path) {
    if (-not $Path) { return $null }
    if (-not $script:Volumes) {
        $script:Volumes = Get-CimInstance Win32_Volume -Filter 'DriveType = 3' | Where-Object Name | Sort-Object { $_.Name.Length } -Descending
    }
    $script:Volumes | Where-Object { $Path.StartsWith($_.Name, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
}

function New-Row([hashtable]$Data) {
    $Data['check']  = $Check
    $Data['server'] = $Server
    [pscustomobject]$Data
}

#endregion Helpers

#region Checks

$Checks = @{

    # Inventory: Exchange version / role / DAG membership.
    ServerInfo = {
        Import-ExchangeShell
        $ex = Get-ExchangeServer -Identity $Server
        $mbx = Get-MailboxServer -Identity $Server -ErrorAction SilentlyContinue
        New-Row @{
            exchangeVersion           = [string]$ex.AdminDisplayVersion
            edition                   = [string]$ex.Edition
            serverRole                = [string]$ex.ServerRole
            site                      = [string]$ex.Site
            databaseAvailabilityGroup = [string]$mbx.DatabaseAvailabilityGroup
        }
    }

    # Are all required services per Exchange role running?
    ServiceHealth = {
        Import-ExchangeShell
        Test-ServiceHealth -Server $Server | ForEach-Object {
            New-Row @{
                role                    = [string]$_.Role
                requiredServicesRunning = [int][bool]$_.RequiredServicesRunning
                servicesNotRunning      = (@($_.ServicesNotRunning) -join ', ')
                servicesNotRunningCount = @($_.ServicesNotRunning).Count
            }
        }
    }

    # Transport queues on this server.
    Queues = {
        Import-ExchangeShell
        Get-Queue -Server $Server -ResultSize Unlimited | ForEach-Object {
            New-Row @{
                queueIdentity = [string]$_.Identity
                deliveryType  = [string]$_.DeliveryType
                status        = [string]$_.Status
                messageCount  = [int]$_.MessageCount
                nextHopDomain = [string]$_.NextHopDomain
                velocity      = $_.Velocity
                incomingRate  = $_.IncomingRate
                outgoingRate  = $_.OutgoingRate
                lastError     = [string]$_.LastError
            }
        }
    }

    # DAG / database copy health: copy & replay queues, content index.
    DatabaseCopies = {
        Import-ExchangeShell
        Get-MailboxDatabaseCopyStatus -Server $Server | ForEach-Object {
            New-Row @{
                copyName                 = [string]$_.Name
                databaseName             = [string]$_.DatabaseName
                status                   = [string]$_.Status
                isHealthy                = [int]([string]$_.Status -in @('Mounted', 'Healthy'))
                activeCopy               = [int][bool]$_.ActiveCopy
                activationPreference     = $_.ActivationPreference
                copyQueueLength          = [int64]$_.CopyQueueLength
                replayQueueLength        = [int64]$_.ReplayQueueLength
                contentIndexState        = [string]$_.ContentIndexState
                contentIndexHealthy      = [int]([string]$_.ContentIndexState -in @('Healthy', 'NotApplicable'))
                lastInspectedLogAgeHours = Get-AgeHours $_.LastInspectedLogTime
                activeDatabaseCopy       = [string]$_.ActiveDatabaseCopy
            }
        }
    }

    # Mount state, size, white space, backup age, volume free space.
    Databases = {
        Import-ExchangeShell
        Get-MailboxDatabase -Server $Server -Status | ForEach-Object {
            $edbVol = Get-VolumeForPath ([string]$_.EdbFilePath)
            $logVol = Get-VolumeForPath ([string]$_.LogFolderPath)
            New-Row @{
                databaseName                  = $_.Name
                mounted                       = [int][bool]$_.Mounted
                mountedOnServer               = [string]$_.MountedOnServer
                # On DAG members every copy is listed; use this to avoid double-counting sizes.
                mountedOnThisServer           = [int]([string]$_.MountedOnServer -like "$Server.*")
                databaseSizeBytes             = ConvertTo-Bytes $_.DatabaseSize
                availableNewMailboxSpaceBytes = ConvertTo-Bytes $_.AvailableNewMailboxSpace
                circularLoggingEnabled        = [int][bool]$_.CircularLoggingEnabled
                lastFullBackupAgeHours        = Get-AgeHours $_.LastFullBackup
                lastIncrementalBackupAgeHours = Get-AgeHours $_.LastIncrementalBackup
                lastDifferentialBackupAgeHours = Get-AgeHours $_.LastDifferentialBackup
                backupInProgress              = [int][bool]$_.BackupInProgress
                edbFilePath                   = [string]$_.EdbFilePath
                logFolderPath                 = [string]$_.LogFolderPath
                edbVolume                     = $edbVol.Name
                edbVolumeFreeBytes            = $edbVol.FreeSpace
                edbVolumeFreePercent          = if ($edbVol.Capacity) { [math]::Round(100 * $edbVol.FreeSpace / $edbVol.Capacity, 2) } else { $null }
                logVolume                     = $logVol.Name
                logVolumeFreeBytes            = $logVol.FreeSpace
                logVolumeFreePercent          = if ($logVol.Capacity) { [math]::Round(100 * $logVol.FreeSpace / $logVol.Capacity, 2) } else { $null }
            }
        }
    }

    # Mailbox count per active database. Expensive - run hourly or less.
    MailboxCounts = {
        Import-ExchangeShell
        Get-MailboxDatabase -Server $Server -Status |
            Where-Object { [string]$_.MountedOnServer -like "$Server.*" } |
            ForEach-Object {
                $db = $_.Name
                New-Row @{
                    databaseName        = $db
                    mailboxCount        = @(Get-Mailbox -Database $db -ResultSize Unlimited).Count
                    archiveMailboxCount = @(Get-Mailbox -Database $db -Archive -ResultSize Unlimited).Count
                    arbitrationCount    = @(Get-Mailbox -Database $db -Arbitration -ResultSize Unlimited).Count
                }
            }
    }

    # DAG replication checks (ClusterService, ReplayService, QuorumGroup, DatabaseRedundancy, ...).
    ReplicationHealth = {
        Import-ExchangeShell
        # Not a DAG member -> nothing to report
        if (-not (Get-MailboxServer $Server).DatabaseAvailabilityGroup) { return }
        Test-ReplicationHealth -Identity $Server | ForEach-Object {
            New-Row @{
                replicationCheck = [string]$_.Check
                result           = [string]$_.Result
                passed           = [int]([string]$_.Result -eq 'Passed')
                checkDescription = [string]$_.CheckDescription
                errorMessage     = [string]$_.Error
            }
        }
    }

    # Managed Availability health sets - Exchange's own view of itself.
    HealthReport = {
        Import-ExchangeShell
        Get-HealthReport -Identity $Server | ForEach-Object {
            New-Row @{
                healthSet    = [string]$_.HealthSet
                healthGroup  = [string]$_.HealthGroup
                alertValue   = [string]$_.AlertValue
                isHealthy    = [int]([string]$_.AlertValue -in @('Healthy', 'Disabled'))
                state        = [string]$_.State
                monitorCount = [int]$_.MonitorCount
            }
        }
    }

    # Component states - detects maintenance mode / inactive components.
    ComponentState = {
        Import-ExchangeShell
        Get-ServerComponentState -Identity $Server | ForEach-Object {
            New-Row @{
                component = [string]$_.Component
                state     = [string]$_.State
                isActive  = [int]([string]$_.State -eq 'Active')
            }
        }
    }

    # Exchange certificates and days until expiry.
    Certificates = {
        Import-ExchangeShell
        Get-ExchangeCertificate -Server $Server | ForEach-Object {
            New-Row @{
                thumbprint      = [string]$_.Thumbprint
                subject         = [string]$_.Subject
                friendlyName    = [string]$_.FriendlyName
                services        = [string]$_.Services
                status          = [string]$_.Status
                isSelfSigned    = [int][bool]$_.IsSelfSigned
                notAfter        = Get-UnixTime $_.NotAfter
                daysUntilExpiry = if ($_.NotAfter -is [datetime]) { [math]::Floor(($_.NotAfter - (Get-Date)).TotalDays) } else { $null }
            }
        }
    }

    # Message flow: count of tracking events by EventId (RECEIVE, SEND, DELIVER, FAIL, DEFER, ...) in the window.
    MessageTracking = {
        Import-ExchangeShell
        $start = (Get-Date).AddMinutes(-$LookbackMinutes)
        Get-MessageTrackingLog -Server $Server -Start $start -ResultSize Unlimited |
            Group-Object EventId |
            ForEach-Object {
                New-Row @{
                    eventId         = [string]$_.Name
                    messageCount    = $_.Count
                    totalBytes      = [int64](($_.Group | Measure-Object TotalBytes -Sum).Sum)
                    lookbackMinutes = $LookbackMinutes
                }
            }
    }

    # Key Exchange performance counters (no Exchange shell needed). Missing counters are skipped.
    # One row per counter instance - query with: WHERE counter = 'rpc averaged latency'
    PerfCounters = {
        $counters = @(
            '\MSExchange RpcClientAccess\RPC Averaged Latency'
            '\MSExchange RpcClientAccess\RPC Requests'
            '\MSExchange RpcClientAccess\Active User Count'
            '\MSExchange RpcClientAccess\User Count'
            '\MSExchangeIS Store(_total)\RPC Average Latency'
            '\MSExchange Database ==> Instances(*)\I/O Database Reads (Attached) Average Latency'
            '\MSExchange Database ==> Instances(*)\I/O Database Writes (Attached) Average Latency'
            '\MSExchange Database ==> Instances(*)\I/O Log Writes Average Latency'
            '\MSExchangeTransport Queues(_total)\Aggregate Delivery Queue Length (All Queues)'
            '\MSExchangeTransport Queues(_total)\Active Mailbox Delivery Queue Length'
            '\MSExchangeTransport Queues(_total)\Retry Mailbox Delivery Queue Length'
            '\MSExchangeTransport Queues(_total)\Unreachable Queue Length'
            '\MSExchangeTransport Queues(_total)\Poison Queue Length'
            '\MSExchange ADAccess Domain Controllers(*)\LDAP Read Time'
            '\MSExchange ADAccess Domain Controllers(*)\LDAP Search Time'
            '\MSExchange HttpProxy(*)\Average ClientAccess Server Processing Latency'
            '\MSExchange OWA\Current Unique Users'
            '\MSExchange OWA\Requests/sec'
            '\MSExchange ActiveSync\Requests/sec'
            '\MSExchange ActiveSync\Current Requests'
            '\MSExchange ActiveSync\Ping Commands Pending'
            '\MSExchangeWS\Requests/sec'
            '\MSExchangeAutodiscover\Requests/sec'
            '\MSExchange Availability Service\Average Time to Process a Free Busy Request'
            '\Web Service(_Total)\Current Connections'
        )
        (Get-Counter -Counter $counters -SampleInterval 2 -MaxSamples 1 -ErrorAction SilentlyContinue).CounterSamples |
            ForEach-Object {
                # Path: \\host\object(instance)\counter
                $parts = $_.Path.TrimStart('\').Split('\')
                New-Row @{
                    counterObject = ($parts[1] -replace '\(.*\)$', '')
                    counter       = $parts[-1]
                    instance      = [string]$_.InstanceName
                    value         = [math]::Round($_.CookedValue, 4)
                }
            }
    }
}

#endregion Checks

#region Execution

try {
    $rows = @(& $Checks[$Check])
    ConvertTo-Json -InputObject $rows -Depth 3 -Compress
}
catch {
    ConvertTo-Json -InputObject @(New-Row @{ error = $_.Exception.Message }) -Compress
}
finally {
    if ($Session) { Remove-PSSession $Session -ErrorAction SilentlyContinue }
}

#endregion Execution

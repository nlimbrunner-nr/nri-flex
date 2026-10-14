<#
.SYNOPSIS
    Minimal Exchange Management Shell example for nri-flex.
    Emits one JSON object per mailbox database hosted on this server.
#>

# Anything written to stdout besides the JSON breaks parsing - silence progress and warnings.
$ProgressPreference = 'SilentlyContinue'
$WarningPreference  = 'SilentlyContinue'

try {
    # Local snap-in: fast, no WinRM/IIS dependency. Works when running as LocalSystem on an Exchange server.
    Add-PSSnapin Microsoft.Exchange.Management.PowerShell.SnapIn -ErrorAction Stop

    Get-MailboxDatabase -Server $env:COMPUTERNAME -Status | ForEach-Object {
        [pscustomobject]@{
            databaseName      = $_.Name
            mounted           = [int][bool]$_.Mounted
            mountedOnServer   = [string]$_.MountedOnServer
            databaseSizeBytes = if ($_.DatabaseSize) { [int64]$_.DatabaseSize.ToBytes() } else { $null }
        }
    } | ConvertTo-Json
}
catch {
    # Still emit valid JSON so the failure shows up in New Relic as an event with an "error" attribute.
    [pscustomobject]@{ error = $_.Exception.Message } | ConvertTo-Json
}

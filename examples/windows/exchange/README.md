# Exchange Server monitoring with nri-flex

Step-by-step Flex configs for Exchange 2016 / 2019 / SE, from smoke test to full health coverage.
Works on Windows Server 2016 / 2019 / 2022; nothing in the configs is OS-version specific. Note that
Exchange 2016 is not supported on Server 2022 (needs Exchange 2019 CU12+ or SE).

| Step | File | Needs Exchange shell | Event types |
|---|---|---|---|
| 1 | `01-flex-hello-world.yml` | no | `FlexHelloCmdSample`, `FlexHelloPsSample` |
| 2 | `02-exchange-services.yml` | no | `ExchangeServiceSample` |
| 3 | `03-exchange-shell-simple.yml` + `exchange-simple.ps1` | yes | `ExchangeServerSample`, `ExchangeDatabaseSimpleSample` |
| 4 | `04-exchange-monitoring.yml` + `nr-exchange.ps1` | yes | see below |

## Deploy

```powershell
$dir = 'C:\Program Files\New Relic\newrelic-infra\integrations.d'
New-Item -ItemType Directory "$dir\flexAssets" -Force
Copy-Item *.yml $dir
Copy-Item *.ps1 "$dir\flexAssets"
Get-ChildItem "$dir\flexAssets\*.ps1" | Unblock-File   # downloaded files are blocked under RemoteSigned
```

The agent picks up new/changed `.yml` files automatically; no restart needed.

## Test before deploying (dry run)

Run Flex by hand. `nri-flex.exe` reads the agent format (`integrations: - name: nri-flex ... config:`) directly, so the files in `integrations.d` can be tested as-is. The agent runs as **LocalSystem**, so test as SYSTEM too (e.g. `psexec -s -i powershell`); otherwise the snap-in may load under your admin account but fail under the agent.

```powershell
# Location varies by agent version (newrelic-integrations\ or newrelic-integrations\bin\)
$flex = Get-ChildItem 'C:\Program Files\New Relic\newrelic-infra\newrelic-integrations' -Recurse -Filter nri-flex.exe | Select-Object -First 1 -ExpandProperty FullName
$cfg  = 'C:\Program Files\New Relic\newrelic-infra\integrations.d'
```

Dry-run options:

```powershell
# 1. One config, with each command and its raw output
& $flex -config_path "$cfg\01-flex-hello-world.yml" -pretty -verbose

# 2. All step configs, one after the other
Get-ChildItem "$cfg\0*-*.yml" | ForEach-Object {
    "===== $($_.Name) ====="
    & $flex -config_path $_.FullName -pretty
}

# 3. Whole directory in one run (output from all configs is interleaved)
& $flex -config_dir "$cfg\" -pretty

# 4. Script only, and check the output is valid JSON (an error here = broken JSON)
& "$cfg\flexAssets\nr-exchange.ps1" -Check Queues | ConvertFrom-Json
```

What a dry run does and doesn't do:

- **Nothing goes to New Relic.** Events print as JSON to stdout. Check the `"metrics": [...]` blocks for event types and attributes.
- **Commands really run.** `Get-*`/`Test-*` are read-only, but `Test-ReplicationHealth` etc. still take real time.
- **Agent-level keys are ignored.** You'll see `testing agent config, agent features will not be available`: the integration-level `interval`, `timeout` and `env` don't apply. Per-API `timeout` (ms) does. A timeout that only bites under the agent therefore shows up only in the agent log.
- **`-verbose`** shows each command and its raw output. If JSON parsing breaks, look for `Write-Host` output or a banner in stdout.

After deploying, confirm data arrives:

```sql
FROM ExchangeQueueSample, ExchangeServiceSample SELECT count(*) FACET eventType() SINCE 10 minutes ago
```

Problems show up in `C:\Program Files\New Relic\newrelic-infra\newrelic-infra.log` (set `log.level: debug` in `newrelic-infra.yml` while testing).

## Things to know

- **Snap-in vs. remote session.** Scripts load `Microsoft.Exchange.Management.PowerShell.SnapIn` locally: fast, no IIS/WinRM dependency, works as LocalSystem (computer account is in *Exchange Trusted Subsystem*). Microsoft doesn't officially support the snap-in for admin work, but for read-only `Get-*`/`Test-*` it's the common approach. If it fails, `nr-exchange.ps1` falls back to `http://<fqdn>/PowerShell/`. That needs the agent service to run as a domain account with **View-Only Organization Management** plus **Server Management** (for `Test-*`, `Get-Queue`, `Get-HealthReport`).
- **Do not use** `RemoteExchange.ps1` + `Connect-ExchangeServer -auto`. It prints a banner to stdout, which breaks JSON parsing, and it's slow.
- **Windows PowerShell 5.1 only** (`shell: powershell`). The snap-in does not load in pwsh 7.
- **Timeouts.** Flex default is 10s per command; loading the snap-in alone takes 5-15s. Every API sets `timeout` (ms) and every integration sets `timeout` (s) above the sum of its APIs.
- **JSON hygiene.** Only JSON may hit stdout. Enums are cast to `[string]`, booleans to `0/1` (easier alerting), sizes to bytes, dates to age in hours. Output is kept flat because Flex turns nested arrays into separate event types.
- **"Works in Exchange Management Shell, no data via Flex."** The EMS shortcut loads the Exchange cmdlets for you; Flex starts a plain `powershell.exe` where `Get-Queue` etc. don't exist. The script must load them itself (`Import-ExchangeShell` in `nr-exchange.ps1`).
- **Flex reads stdout, nothing else.** Don't push to the Event API or write to a file from the script, and don't use `Write-Host` (it lands in stdout and corrupts the JSON). Don't set `timestamp` yourself; the agent sets it.
- **Valid config keys only.** Commands use `run:`. Keys like `command:`, `parse_json:`, `events:`, `attributes:` don't exist in Flex and are silently ignored.
- **One row per object, not `queue1_*`, `queue2_*`.** Emit an array; each element becomes one event. Totals and "largest queue" are then NRQL (`sum(messageCount)`, `max(messageCount) FACET queueIdentity`).
- **Don't filter in the script** (e.g. `MessageCount -ge $threshold`). No rows = no data, and you can't tell "healthy" from "broken". Emit everything, set thresholds in the alert condition.
- **DAG.** `ExchangeDatabaseSample` lists every copy on every member. Filter with `mountedOnThisServer = 1` for sizes/backups.

## Event types (step 4)

| Event type | Interval | Key attributes |
|---|---|---|
| `ExchangeQueueSample` | 60s | `queueIdentity`, `deliveryType`, `status`, `messageCount`, `lastError` |
| `ExchangeDatabaseCopySample` | 60s | `databaseName`, `status`, `isHealthy`, `copyQueueLength`, `replayQueueLength`, `contentIndexHealthy` |
| `ExchangePerfSample` | 60s | `counterObject`, `counter`, `instance`, `value` |
| `ExchangeServiceHealthSample` | 5m | `role`, `requiredServicesRunning`, `servicesNotRunning` |
| `ExchangeDatabaseSample` | 5m | `mounted`, `databaseSizeBytes`, `availableNewMailboxSpaceBytes`, `lastFullBackupAgeHours`, `edbVolumeFreePercent`, `logVolumeFreePercent` |
| `ExchangeComponentStateSample` | 5m | `component`, `state`, `isActive` (maintenance mode) |
| `ExchangeReplicationSample` | 5m | `replicationCheck`, `result`, `passed`, `errorMessage` (DAG only) |
| `ExchangeMessageTrackingSample` | 5m | `eventId`, `messageCount`, `totalBytes` |
| `ExchangeHealthReportSample` | 5m | `healthSet`, `alertValue`, `isHealthy` |
| `ExchangeServerInfoSample` | 1h | `exchangeVersion`, `edition`, `serverRole`, `site`, `databaseAvailabilityGroup` |
| `ExchangeCertificateSample` | 1h | `subject`, `services`, `daysUntilExpiry` |
| `ExchangeMailboxCountSample` | 1h | `databaseName`, `mailboxCount` |

## Alert conditions (NRQL)

```sql
-- Collector broken
FROM ExchangeQueueSample, ExchangeDatabaseSample, ExchangeHealthReportSample SELECT count(*) WHERE error IS NOT NULL FACET server, check

-- Exchange services down
FROM ExchangeServiceSample SELECT count(*) WHERE startType = 'Automatic' AND isRunning = 0 FACET hostname, serviceName

-- Required role services
FROM ExchangeServiceHealthSample SELECT min(requiredServicesRunning) FACET server, role          -- < 1

-- Transport queue growing
FROM ExchangeQueueSample SELECT max(messageCount) WHERE deliveryType != 'ShadowRedundancy' FACET server, queueIdentity   -- > 100
FROM ExchangePerfSample SELECT max(value) WHERE counter = 'poison queue length' FACET server       -- > 0
FROM ExchangeQueueSample SELECT uniqueCount(queueIdentity) WHERE status = 'Retry' FACET server     -- > 0 (queues in retry)

-- Queue summary per server (replaces script-side totals / largest queue)
FROM ExchangeQueueSample SELECT sum(messageCount) AS 'total', max(messageCount) AS 'largest', filter(uniqueCount(queueIdentity), WHERE status = 'Retry') AS 'retryQueues' WHERE deliveryType != 'ShadowRedundancy' FACET server TIMESERIES

-- Database dismounted / unhealthy copy
FROM ExchangeDatabaseCopySample SELECT min(isHealthy) FACET server, databaseName                  -- < 1
FROM ExchangeDatabaseCopySample SELECT max(copyQueueLength), max(replayQueueLength) FACET server, databaseName
FROM ExchangeDatabaseCopySample SELECT min(contentIndexHealthy) FACET server, databaseName

-- Disk space for EDB / logs
FROM ExchangeDatabaseSample SELECT min(edbVolumeFreePercent), min(logVolumeFreePercent) FACET server, databaseName   -- < 15

-- Backup older than 26h
FROM ExchangeDatabaseSample SELECT max(lastFullBackupAgeHours) WHERE mountedOnThisServer = 1 FACET databaseName

-- Managed Availability unhealthy
FROM ExchangeHealthReportSample SELECT min(isHealthy) FACET server, healthSet

-- Server left in maintenance mode
FROM ExchangeComponentStateSample SELECT min(isActive) WHERE component IN ('ServerWideOffline', 'HubTransport', 'FrontendTransport') FACET server

-- DAG replication
FROM ExchangeReplicationSample SELECT min(passed) FACET server, replicationCheck

-- Certificate expires within 30 days (only certs bound to services)
FROM ExchangeCertificateSample SELECT min(daysUntilExpiry) WHERE services != 'None' FACET server, subject

-- RPC latency (Outlook experience), > 50ms sustained
FROM ExchangePerfSample SELECT average(value) WHERE counter = 'rpc averaged latency' FACET server

-- DB read latency, > 20ms sustained
FROM ExchangePerfSample SELECT average(value) WHERE counter = 'i/o database reads (attached) average latency' FACET server, instance
```

Counter names from `Get-Counter` arrive lowercase; check exact spelling with
`FROM ExchangePerfSample SELECT uniques(counter) SINCE 1 hour ago`.

## Not covered by Flex - use built-ins

- **CPU / memory / disk / network / Windows services**: the infrastructure agent collects these natively (`SystemSample`, `StorageSample`, ...). Windows services can also go through the `nri-winservices` integration.
- **Event logs** (`MSExchange*` sources in Application log): forward with the agent's log forwarder (`logging.d`, `winevtlog`) rather than Flex.
- **OWA / ECP / EWS / Autodiscover availability from the outside**: use New Relic Synthetics.

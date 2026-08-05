param(
  [string]$BridgeLog,
  [string]$AgentLog
)

$ErrorActionPreference = 'Continue'

# Defaults: bridge log lives next to this script; agent log is optional.
$scriptDir = $PSScriptRoot
if (-not $BridgeLog) { $BridgeLog = Join-Path $scriptDir 'bridge.log' }
if (-not $AgentLog) { $AgentLog = '' }

$patterns = 'rate.?limit|quota|insufficient|429|402|payment.?required|token.*exceed|maximum.*context|daily.*cap|usage.*limit'

Write-Output 'Watching for usage/quota errors. Press Ctrl+C to stop.'
Write-Output "bridge.log:   $BridgeLog"
if ($AgentLog) { Write-Output "agent log:    $AgentLog" }

$bridgePos = 0
$agentPos = 0

if (Test-Path $BridgeLog) { $bridgePos = (Get-Item $BridgeLog).Length }
if ($AgentLog -and (Test-Path $AgentLog)) { $agentPos = (Get-Item $AgentLog).Length }

while ($true) {
  Start-Sleep -Seconds 3
  if (Test-Path $BridgeLog) {
    $len = (Get-Item $BridgeLog).Length
    if ($len -gt $bridgePos) {
      Get-Content $BridgeLog | Select-Object -Skip ([Math]::Floor($bridgePos)) -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_ -match $patterns) { Write-Host "[bridge ALERT] $_" -ForegroundColor Yellow }
      }
      $bridgePos = $len
    }
  }
  if ($AgentLog -and (Test-Path $AgentLog)) {
    $len = (Get-Item $AgentLog).Length
    if ($len -gt $agentPos) {
      Get-Content $AgentLog | Select-Object -Skip ([Math]::Floor($agentPos)) -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_ -match $patterns -and $_ -match 'ERROR') { Write-Host "[agent ALERT] $_" -ForegroundColor Yellow }
      }
      $agentPos = $len
    }
  }
}

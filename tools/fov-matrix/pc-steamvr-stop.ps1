$ErrorActionPreference = 'Continue'
# Graceful SteamVR shutdown, then kill only what is left after __SECONDS__ s. run-matrix.sh fills in __SECONDS__ and runs
# this through pcps.sh. A killed vrserver makes SteamVR record a safe-mode event that blocks the ALVR driver on the next launch.
$vr = '^vr(server|monitor|compositor|dashboard|webhelper|startup)$'
function Left { @(Get-Process | Where-Object { $_.ProcessName -match $vr }) }
if ((Left).Count -eq 0) { 'steamvr: nothing running'; exit 0 }
# 1. the ALVR dashboard's own "shutdown SteamVR" request (dashboard API, localhost only)
try {
  $null = Invoke-RestMethod -Method Post -Uri 'http://127.0.0.1:8082/api/dashboard-request' -Headers @{ 'X-ALVR' = 'true' } `
    -ContentType 'application/json' -Body '"ShutdownSteamvr"' -TimeoutSec 3
  'asked the ALVR dashboard to shut SteamVR down'
} catch { 'ALVR dashboard API did not take the shutdown request: ' + $_.Exception.Message }
# 2. close the SteamVR status window: the user-facing quit path of vrmonitor
foreach ($p in @(Get-Process -Name vrmonitor -ErrorAction SilentlyContinue)) { $null = $p.CloseMainWindow() }
# 3. wait
$t0 = Get-Date
while ((Left).Count -gt 0 -and ((Get-Date) - $t0).TotalSeconds -lt __SECONDS__) { Start-Sleep -Milliseconds 500 }
$rest = Left
if ($rest.Count -eq 0) { 'steamvr: graceful stop in ' + [int]((Get-Date) - $t0).TotalSeconds + 's'; exit 0 }
# 4. only what is left
'steamvr: still running after __SECONDS__ s, killing: ' + (($rest | ForEach-Object { $_.ProcessName + ' ' + $_.Id }) -join ', ')
foreach ($p in $rest) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }

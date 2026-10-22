$ErrorActionPreference = 'Stop'
# Poll the ALVR dashboard API (the one pc-alvr-manualip.ps1 talks to) until it answers, for at most __SECONDS__ s.
# Prints "api ok after <n>s" or "api none after <n>s". run-matrix.sh fills in __SECONDS__ and runs this through pcps.sh.
$h = @{ 'X-ALVR' = 'true' }
$u = 'http://127.0.0.1:8082/api/dashboard-request'
$limit = __SECONDS__
$t0 = Get-Date
while ($true) {
  $n = [int]((Get-Date) - $t0).TotalSeconds
  try {
    $null = Invoke-RestMethod -Method Post -Uri $u -Headers $h -ContentType 'application/json' -Body '"GetSession"' -TimeoutSec 3
    "api ok after ${n}s"; break
  } catch { }
  if ($n -ge $limit) { "api none after ${n}s"; break }
  Start-Sleep -Seconds 1
}

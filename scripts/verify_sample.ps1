# verifies a reason,sm_user_id,want csv against live SessionM via GET. writes <csv>_result.txt
param([Parameter(Mandatory=$true)][string]$Sample)
$kv = @{}; Get-Content 'C:\dev\cz_marketing_kb\.env.local.gitignore' | ForEach-Object { if ($_ -match '^\s*([A-Z0-9_]+)\s*=\s*(.*)$') { $kv[$matches[1]] = $matches[2].Trim().Trim('"') } }
$base = "https://api-cafezupas.ent-sessionm.com/priv/v1/apps/$($kv['SESSIONM_API_KEY_V1'])/users/"
$auth = "Authorization: $($kv['SESSIONM_API_V1_AUTH'])"
$out = [IO.Path]::ChangeExtension($Sample, $null).TrimEnd('.') + '_result.txt'
$rows = Import-Csv $Sample
$ok = 0; $bad = @(); $stats = @{}
foreach ($r in $rows) {
  $u = (& curl.exe -s -H $auth ($base + $r.sm_user_id) | ConvertFrom-Json).user
  $got = (($u.phone_numbers | ForEach-Object { $_.phone_number }) | Sort-Object) -join ','
  if (-not $stats.ContainsKey($r.reason)) { $stats[$r.reason] = @{ok=0; bad=0} }
  if ($got -eq $r.want) { $ok++; $stats[$r.reason].ok++ } else { $stats[$r.reason].bad++; $bad += "$($r.reason) $($r.sm_user_id) want=[$($r.want)] got=[$got] updated=$($u.updated_at)" }
}
$lines = @("checked=$($rows.Count) ok=$ok mismatches=$($bad.Count)")
$lines += $stats.GetEnumerator() | Sort-Object Name | ForEach-Object { "  {0,-16} ok={1} bad={2}" -f $_.Key, $_.Value.ok, $_.Value.bad }
$lines += $bad
$lines += "DONE"
$lines | Set-Content $out

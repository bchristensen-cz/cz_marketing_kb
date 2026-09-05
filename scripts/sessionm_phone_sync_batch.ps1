<#
 sessionm_phone_sync_batch.ps1 -- executes one batch of scratch.sessionm_phone_sync_plan rows against the SessionM v1 users API.
 usage: .\scripts\sessionm_phone_sync_batch.ps1 -BatchFile artifacts\phone_sync\batches\batch_001_junk_only_50.json -BatchLabel batch_001 [-DelayMs 200]
 per row: GET current list -> compare to plan's current_phones (skip as 'stale' if SessionM has moved since the BigQuery snapshot)
          -> PUT request_body -> compare echoed phone_numbers to desired_phones -> 'succeeded' | 'mismatch' | 'failed' | 'conflict'
 any non-200 on a PUT stops the batch. results are written next to the batch file as <label>_results.jsonl for loading into scratch.sessionm_phone_sync_log.
 credentials: .env.local.gitignore at the repo root (never printed).
#>
param(
  [Parameter(Mandatory=$true)][string]$BatchFile,
  [Parameter(Mandatory=$true)][string]$BatchLabel,
  [int]$DelayMs = 200,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$raw = Get-Content (Join-Path $repo '.env.local.gitignore') -Raw
$kv = @{}; ($raw -split "`n") | ForEach-Object { if ($_ -match '^\s*([A-Z0-9_]+)\s*=\s*(.*)$') { $kv[$matches[1]] = $matches[2].Trim().Trim('"') } }
$base = "https://api-cafezupas.ent-sessionm.com/priv/v1/apps/$($kv['SESSIONM_API_KEY_V1'])/users/"
$h = @{ Authorization = $kv['SESSIONM_API_V1_AUTH']; 'Content-Type' = 'application/json' }
$rows = Get-Content $BatchFile -Raw | ConvertFrom-Json
$outFile = [System.IO.Path]::ChangeExtension($BatchFile, $null).TrimEnd('.') + "_results.jsonl"
if (Test-Path $outFile) { Remove-Item $outFile }
function Phones($resp) { @(($resp.Content | ConvertFrom-Json).user.phone_numbers | ForEach-Object { $_.phone_number } | Sort-Object) }
$sw = [Diagnostics.Stopwatch]::StartNew(); $n = 0; $ok = 0; $stop = $false
foreach ($r in $rows) {
  if ($stop) { break }
  $n++
  $rec = [ordered]@{ log_id = [guid]::NewGuid().ToString(); action_id = $r.action_id; sm_user_id = $r.sm_user_id; attempt = 1
                     requested_at = (Get-Date).ToUniversalTime().ToString('o'); http_status = $null; request_body = $r.request_body
                     response_body = $null; result = $null; batch_label = $BatchLabel; get_ms = $null; put_ms = $null }
  try {
    $t0 = [Diagnostics.Stopwatch]::StartNew()
    $g = Invoke-WebRequest -Uri ($base + $r.sm_user_id) -Method GET -Headers $h -UseBasicParsing
    $rec.get_ms = $t0.ElapsedMilliseconds
    $cur = Phones $g
    $planCur = @($r.current_phones | Sort-Object)
    if (($cur -join ',') -ne ($planCur -join ',')) {
      $rec.result = 'stale'; $rec.response_body = ($cur -join ','); $rec.http_status = $g.StatusCode
    } elseif ($DryRun) {
      $rec.result = 'dry_run'; $rec.http_status = $g.StatusCode
    } else {
      $t1 = [Diagnostics.Stopwatch]::StartNew()
      $p = Invoke-WebRequest -Uri ($base + $r.sm_user_id) -Method PUT -Headers $h -Body $r.request_body -UseBasicParsing
      $rec.put_ms = $t1.ElapsedMilliseconds
      $rec.http_status = $p.StatusCode
      $got = Phones $p; $want = @($r.desired_phones | Sort-Object)
      $rec.response_body = $p.Content
      if (($got -join ',') -eq ($want -join ',')) { $rec.result = 'succeeded'; $ok++ } else { $rec.result = 'mismatch'; $stop = $true }
    }
  } catch {
    $code = $null; try { $code = $_.Exception.Response.StatusCode.value__ } catch {}
    $rec.http_status = $code; $rec.response_body = "$($_.ErrorDetails.Message) $($_.Exception.Message)"
    $rec.result = if ($code -in 409,422) { 'conflict' } else { 'failed' }
    $stop = $true
  }
  ($rec | ConvertTo-Json -Compress) | Add-Content -Path $outFile
  Start-Sleep -Milliseconds $DelayMs
}
$sw.Stop()
"rows=$n succeeded=$ok stopped=$stop elapsed_s=$([math]::Round($sw.Elapsed.TotalSeconds,1)) results=$outFile"
Get-Content $outFile | ForEach-Object { $_ | ConvertFrom-Json } | Group-Object result | ForEach-Object { "  $($_.Name): $($_.Count)" }

# Stop hook: before Claude finishes, list output/data files sitting anywhere in the repo,
# including gitignored ones (the rule is "never in the folder", not just "never committed").
# Exit 2 sends the list back to Claude so it moves them before stopping.
. "$PSScriptRoot\outputs-rules.ps1"
try { $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { $payload = $null }
if ($payload -and $payload.stop_hook_active) { exit 0 }   # already asked once; don't loop

$root = $env:CLAUDE_PROJECT_DIR
if (-not $root -and $payload) { $root = $payload.cwd }
if (-not $root) { exit 0 }
$root = ConvertTo-CzWinPath $root

$lines = & git -C $root status --porcelain --ignored 2>$null
if ($LASTEXITCODE -ne 0) { exit 0 }
$hits = @()
foreach ($line in $lines) {
    if ($line.Length -lt 4) { continue }
    $rel = $line.Substring(3)
    if ($rel -match ' -> ') { $rel = ($rel -split ' -> ')[-1] }
    $rel = $rel.Trim('"')
    if ($line.StartsWith(' D') -or $line.StartsWith('D ')) { continue }
    $reason = Test-CzOutputPath $rel
    if ($reason) { $hits += "  $rel ($reason)" }
}
# Tracked files never show in status when unchanged, so check the index too.
foreach ($t in (& git -C $root ls-files 2>$null)) {
    $reason = Test-CzOutputPath $t
    if ($reason) { $hits += "  $t ($reason, TRACKED: git rm --cached)" }
}
if ($hits.Count -gt 0) {
    [Console]::Error.WriteLine("Outputs rule (2026-10-07): these output/data files are in the repo folder. Move them to $CzOutputsHome (analysis\, reports\ or scratch\) before finishing; if one is tracked, git rm --cached it too:")
    $hits | ForEach-Object { [Console]::Error.WriteLine($_) }
    exit 2
}
exit 0

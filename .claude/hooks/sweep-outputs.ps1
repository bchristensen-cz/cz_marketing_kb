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
$big = @()
# KB size budget (2026-10-14): user sessions read these whole, and Read truncates at ~25K tokens (~65 KB of this prose).
foreach ($f in (Get-ChildItem -Path (Join-Path $root 'claude_skills'), (Join-Path $root 'data_dictionaries'), (Join-Path $root 'README.md') -Recurse -Filter *.md -File)) {
    $cap = if ($f.Name -eq 'SKILL.md') { 40KB } else { 60KB }
    if ($f.Length -gt $cap) { $big += "  $($f.FullName.Substring($root.Length + 1)) ($([int]($f.Length / 1KB)) KB, over the $($cap / 1KB) KB budget: split it into references/ or companion files)" }
}
if ($big.Count -gt 0) {
    [Console]::Error.WriteLine("KB size budget (2026-10-14): these files are too big for a user session to read in one pass. Split them into references/ before finishing:")
    $big | ForEach-Object { [Console]::Error.WriteLine($_) }
}
if ($hits.Count -gt 0) {
    [Console]::Error.WriteLine("Outputs rule (2026-10-07): these output/data files are in the repo folder. Move them to $CzOutputsHome (analysis\, reports\ or scratch\) before finishing; if one is tracked, git rm --cached it too:")
    $hits | ForEach-Object { [Console]::Error.WriteLine($_) }
}
if ($hits.Count -gt 0 -or $big.Count -gt 0) { exit 2 }
exit 0

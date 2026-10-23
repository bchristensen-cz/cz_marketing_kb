# PreToolUse hook (Bash|PowerShell|mcp__.*): before any `create or replace view`, compare the
# LIVE view definition in BigQuery with the copy committed at HEAD in this repo's sql\ folder.
# If they differ, block: the repo and the deployed view have drifted (it happened three times
# with claude.order_customer). Reconcile first, commit, then redeploy.
# Override for one session: set $env:CZ_SKIP_DRIFT_CHECK = '1' before starting claude.
try { $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }
if ($env:CZ_SKIP_DRIFT_CHECK -eq '1') { exit 0 }

$defaultProject = 'marketing-data-442316'
$root = $env:CLAUDE_PROJECT_DIR
if (-not $root) { $root = $payload.cwd }
$root = $root -replace '^/([a-zA-Z])/', '$1:\'
$cwd = $payload.cwd -replace '^/([a-zA-Z])/', '$1:\'

# Gather every string in tool_input, plus any .sql file a shell command points at.
$text = ''
if ($payload.tool_input) {
    foreach ($prop in $payload.tool_input.PSObject.Properties) {
        if ($prop.Value -is [string]) { $text += "`n" + $prop.Value }
    }
}
$createRx = '(?is)create\s+or\s+replace\s+view\s+([`\w.\-]+)'
foreach ($m in [regex]::Matches($text, '[\w:./\\\-]+\.sql\b')) {
    $f = $m.Value -replace '^/([a-zA-Z])/', '$1:\'
    if (-not [IO.Path]::IsPathRooted($f) -and $cwd) { $f = Join-Path $cwd $f }
    if (Test-Path -LiteralPath $f) { $text += "`n" + (Get-Content -LiteralPath $f -Raw) }
}
$targets = [regex]::Matches($text, $createRx)
if ($targets.Count -eq 0) { exit 0 }

function Get-Norm([string]$sql) {
    $s = [regex]::Replace($sql, '(?s)/\*.*?\*/', ' ')
    $s = [regex]::Replace($s, '--[^\r\n]*', ' ')
    $s = $s.Replace('`', '').ToLowerInvariant()
    $s = [regex]::Replace($s, '\s+', ' ').Trim()
    return $s.TrimEnd(';').Trim()
}
function Get-Body([string]$sql, [string]$ds, [string]$vw) {
    $rx = '(?is)create\s+or\s+replace\s+view\s+[`\w.\-]*?\b' + [regex]::Escape($ds) + '`?\.`?' +
          [regex]::Escape($vw) + '(?![\w])`?\s*(?:\([^)]*\)\s*)?(?:options\s*\((?:[^()]|\([^()]*\))*\)\s*)?as\s+(.*?)(?=;[ \t]*(?:\r?\n|$)|\z)'
    $m = [regex]::Match($sql, $rx)
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# Testing aid: compare against another ref instead of HEAD (e.g. an old commit).
$ref = 'HEAD'
if ($env:CZ_DRIFT_REF) { $ref = $env:CZ_DRIFT_REF }

# 1) Resolve each target view to its committed body (git grep prefilter keeps this fast).
$want = @{}   # "proj.ds" -> list of @{vw; file; body}
$seen = @{}
foreach ($t in $targets) {
    $parts = $t.Groups[1].Value.Replace('`', '').Split('.')
    if ($parts.Count -lt 2) { continue }
    $vw = $parts[-1]; $ds = $parts[-2]
    $proj = $defaultProject
    if ($parts.Count -ge 3) { $proj = $parts[-3] }
    $key = "$proj.$ds.$vw"
    if ($seen[$key]) { continue }
    $seen[$key] = $true

    $pattern = $ds + '`?\.`?' + $vw
    $hits = & git -C $root grep -l -i -E $pattern $ref -- '*.sql' 2>$null
    foreach ($h in $hits) {
        $path = $h.Substring($ref.Length + 1)
        $body = Get-Body ((& git -C $root show "${ref}:$path" 2>$null) -join "`n") $ds $vw
        if ($body) {
            if (-not $want["$proj.$ds"]) { $want["$proj.$ds"] = @() }
            $want["$proj.$ds"] += @{ vw = $vw; file = $path; body = $body }
            break
        }
    }
    # not in the repo yet: nothing to drift from
}

# 2) One INFORMATION_SCHEMA.VIEWS query per dataset for the live definitions.
$problems = @()
foreach ($pd in $want.Keys) {
    $proj, $ds = $pd.Split('.')
    $names = ($want[$pd] | ForEach-Object { "'" + $_.vw + "'" }) -join ','
    $sql = "select table_name, view_definition from ``$proj.$ds``.INFORMATION_SCHEMA.VIEWS where table_name in ($names)"
    $errFile = [IO.Path]::GetTempFileName()
    $out = & bq --quiet --format=json query --nouse_legacy_sql "--project_id=$proj" $sql 2> $errFile
    $code = $LASTEXITCODE
    $errText = (Get-Content -LiteralPath $errFile -Raw); Remove-Item -LiteralPath $errFile -ErrorAction SilentlyContinue
    if ($code -ne 0) {
        $problems += "Could not read live view definitions for $pd with bq ($(($out -join ' ') + ' ' + $errText).Trim()). Fix bq auth or have Brent set CZ_SKIP_DRIFT_CHECK=1 for this session."
        continue
    }
    try { $rows = ($out -join "`n") | ConvertFrom-Json } catch { $rows = @() }
    foreach ($w in $want[$pd]) {
        $row = $rows | Where-Object { $_.table_name -eq $w.vw } | Select-Object -First 1
        if (-not $row) { continue }   # brand-new view
        $a = Get-Norm $row.view_definition; $b = Get-Norm $w.body
        # 2026-10-23 (Brent): a committed-but-undeployed change is not drift. Allow when the DDL being
        # run IS the HEAD copy and live matches some earlier committed revision of the same file.
        if ($a -ne $b) {
            $run = Get-Body $text $ds $w.vw
            if ($run -and (Get-Norm $run) -eq $b) {
                $known = $false
                foreach ($h in (& git -C $root log --format=%H -n 50 $ref -- $w.file 2>$null)) {
                    $old = Get-Body ((& git -C $root show "${h}:$($w.file)" 2>$null) -join "`n") $ds $w.vw
                    if ($old -and (Get-Norm $old) -eq $a) { $known = $true; break }
                }
                if ($known) { continue }
            }
        }
        if ($a -ne $b) {
            $i = 0; $n = [Math]::Min($a.Length, $b.Length)
            while ($i -lt $n -and $a[$i] -eq $b[$i]) { $i++ }
            $s = [Math]::Max(0, $i - 60)
            $liveSnip = $a.Substring([Math]::Min($s, $a.Length), [Math]::Min(160, [Math]::Max(0, $a.Length - $s)))
            $repoSnip = $b.Substring([Math]::Min($s, $b.Length), [Math]::Min(160, [Math]::Max(0, $b.Length - $s)))
            $problems += "LIVE $pd.$($w.vw) differs from the copy committed at $ref in $($w.file) (comments and whitespace ignored). First difference near:`n    live: ...$liveSnip...`n    repo: ...$repoSnip..."
        }
    }
}

if ($problems.Count -gt 0) {
    [Console]::Error.WriteLine("Blocked: diff the live view_definition before every view redeploy.")
    $problems | ForEach-Object { [Console]::Error.WriteLine($_) }
    [Console]::Error.WriteLine("Reconcile first: pull the deployed text into the repo (or confirm the repo is the intended version with Brent), commit, then redeploy.")
    exit 2
}
exit 0

# PreToolUse hook (Write|Edit|MultiEdit|NotebookEdit): refuse to write output or data files
# inside the repo. Exit 2 blocks the call and sends stderr back to Claude.
. "$PSScriptRoot\outputs-rules.ps1"
try { $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }
$path = $payload.tool_input.file_path
if (-not $path) { $path = $payload.tool_input.notebook_path }
if (-not $path) { exit 0 }

$root = $env:CLAUDE_PROJECT_DIR
if (-not $root) { $root = $payload.cwd }
$root = (ConvertTo-CzWinPath $root).TrimEnd('\')
$path = ConvertTo-CzWinPath $path
if (-not [IO.Path]::IsPathRooted($path)) { $path = Join-Path (ConvertTo-CzWinPath $payload.cwd) $path }
$full = [IO.Path]::GetFullPath($path)

if (-not $full.ToLowerInvariant().StartsWith($root.ToLowerInvariant() + '\')) { exit 0 }
$rel = $full.Substring($root.Length + 1)
$reason = Test-CzOutputPath $rel
if ($reason) {
    [Console]::Error.WriteLine("Blocked by the outputs rule (2026-10-07): $rel ($reason). Nothing made from company data goes in this repo. Write it under $CzOutputsHome\analysis, \reports or \scratch instead.")
    exit 2
}
exit 0

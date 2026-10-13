# Shared rule for the outputs-never-in-the-repo policy (rule set 2026-10-07).
# Dot-sourced by guard-outputs.ps1 and sweep-outputs.ps1. ASCII only: Windows PowerShell 5.1
# reads BOM-less scripts as ANSI.

$script:CzOutputsHome = 'C:\dev\cz_outputs'

function ConvertTo-CzWinPath([string]$p) {
    if (-not $p) { return $p }
    if ($p -match '^/([a-zA-Z])/(.*)$') { $p = $Matches[1] + ':\' + $Matches[2] }
    return $p.Replace('/', '\')
}

# Returns a reason string when a repo-relative path is an output/data file, else $null.
function Test-CzOutputPath([string]$rel) {
    $r = (ConvertTo-CzWinPath $rel).Trim('"').TrimStart('.', '\').TrimEnd('\')
    $lower = $r.ToLowerInvariant()
    $top = $lower.Split('\')[0]
    if (@('claude outputs', 'analysis', 'outputs', 'scratch') -contains $top) {
        return "top-level '$top' folder is an output folder"
    }
    $ext = [IO.Path]::GetExtension($lower)
    $dataExt = @('.csv', '.tsv', '.jsonl', '.parquet', '.avro', '.xlsx', '.xlsm', '.xls')
    if ($dataExt -contains $ext) {
        if ($lower -match '^data_dictionaries\\[^\\]+\.xlsx$') { return $null }
        return "'$ext' is a data file type"
    }
    $imgExt = @('.png', '.jpg', '.jpeg', '.gif', '.webp')
    if ($imgExt -contains $ext) {
        if ($lower -match '^(app|artifacts|docs)\\') { return $null }
        return "'$ext' screenshot/image outside app\, artifacts\ or docs\"
    }
    return $null
}

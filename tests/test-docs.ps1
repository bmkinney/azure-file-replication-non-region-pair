$ErrorActionPreference = 'Stop'

# Checks that relative links and heading anchors in the Markdown files resolve, and that no file has internal or
# organization-specific references; no Azure calls are made.

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$failures = [System.Collections.Generic.List[string]]::new()

function Get-HeadingAnchors([string]$Path) {
    $anchors = [System.Collections.Generic.HashSet[string]]::new()
    $counts = @{}
    $inFence = $false
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*```') {
            $inFence = -not $inFence
            continue
        }
        if ($inFence -or $line -notmatch '^#{1,6}\s+(.+?)\s*$') {
            continue
        }
        # GitHub anchors: link text only, lowercase, punctuation removed, spaces as hyphens, duplicates numbered.
        $text = ($Matches[1] -replace '\[([^\]]*)\]\([^)]*\)', '$1').ToLowerInvariant() -replace '`', ''
        $slug = ($text -replace '[^\p{L}\p{Nd}\p{Mn}\p{Pc}\- ]', '') -replace ' ', '-'
        if ($counts.ContainsKey($slug)) {
            $counts[$slug]++
            $slug = "$slug-$($counts[$slug])"
        } else {
            $counts[$slug] = 0
        }
        [void]$anchors.Add($slug)
    }
    return , $anchors
}

# Tracked and untracked files that Git doesn't ignore, so local state, providers, and reports are skipped.
$files = @(git -C $repositoryRoot ls-files --cached --others --exclude-standard | Sort-Object -Unique |
    ForEach-Object { Join-Path $repositoryRoot $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
if ($LASTEXITCODE -ne 0 -or $files.Count -eq 0) {
    throw 'documentation check failed: could not list the repository files with git'
}

$markdownFiles = @($files | Where-Object { $_ -like '*.md' })
$anchorCache = @{}
foreach ($path in $markdownFiles) {
    $relativePath = [IO.Path]::GetRelativePath($repositoryRoot, $path)
    # Links in fenced code blocks are examples, not navigation.
    $prose = [regex]::Replace([IO.File]::ReadAllText($path), '(?ms)^\s*```.*?^\s*```', '')
    foreach ($match in [regex]::Matches($prose, '\]\((?<target>[^)\s]+)\)')) {
        $target = $match.Groups['target'].Value
        if ($target -match '^[a-zA-Z][a-zA-Z0-9+.-]*:' -or $target.StartsWith('/')) {
            continue
        }
        $pathPart, $anchor = $target -split '#', 2
        $targetPath = if ($pathPart) {
            [IO.Path]::GetFullPath((Join-Path (Split-Path $path -Parent) ([Uri]::UnescapeDataString($pathPart))))
        } else {
            $path
        }
        if (-not (Test-Path -LiteralPath $targetPath)) {
            $failures.Add("${relativePath}: link target '$target' doesn't exist")
            continue
        }
        if ($anchor -and $targetPath -like '*.md') {
            if (-not $anchorCache.ContainsKey($targetPath)) {
                $anchorCache[$targetPath] = Get-HeadingAnchors $targetPath
            }
            if (-not $anchorCache[$targetPath].Contains($anchor)) {
                $failures.Add("${relativePath}: anchor '#$anchor' in '$target' doesn't exist")
            }
        }
    }
}

# The project is for public reuse, so no file may depend on internal programs, tenants, or links.
$forbidden = @('MCAPS', 'MngEnvMCAP', 'aka\.ms/', 'sharepoint\.com', 'corp\.microsoft\.com', 'microsoft internal')
foreach ($path in $files) {
    if ($path -eq $PSCommandPath -or $path -match '\.(exe|zip|png|jpg|gif)$') {
        continue
    }
    $text = [IO.File]::ReadAllText($path)
    foreach ($pattern in $forbidden) {
        if ($text -match "(?i)$pattern") {
            $failures.Add("$([IO.Path]::GetRelativePath($repositoryRoot, $path)): contains the internal reference '$($Matches[0])'")
        }
    }
}

if ($failures.Count -gt 0) {
    throw "documentation check failed:`n$($failures -join "`n")"
}
Write-Host "Documentation checks passed: $($markdownFiles.Count) Markdown files, $($files.Count) files scanned."

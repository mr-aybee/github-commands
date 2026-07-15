<#
.SYNOPSIS
    Retention for GitHub Packages: keep only the last N versions of each package,
    delete the rest.

.DESCRIPTION
    For every selected package, keeps the N most-recent versions (by created_at) and
    deletes older ones. DRY-RUN by default: it only prints what it *would* delete.
    Add -Execute to actually delete.

    Requires the GitHub CLI (`gh`) authenticated with scope:
        delete:packages     (plus read:packages)
    Refresh with:  gh auth refresh -h github.com -s read:packages,delete:packages

    Notes / caveats:
      * Public package versions with a large download count may be blocked from
        deletion by GitHub; such failures are reported and skipped.
      * You cannot delete the last remaining version of a package.

.PARAMETER Keep
    Number of most-recent versions to retain per package. Default 5.

.PARAMETER Package
    Restrict to one package by name (case-insensitive). Omit to process all.

.PARAMETER Type
    Package type filter: nuget, npm, or both (default).

.PARAMETER Repo
    Only process packages linked to this repo (name or owner/name). Optional.

.PARAMETER Owner
    Account that owns the packages. Defaults to the authenticated gh user.

.PARAMETER Execute
    Actually delete. Without this flag the script is a dry run.

.PARAMETER NonInteractive
    Skip all prompts and use parameter values / defaults as-is. Handy for CI.

.EXAMPLE
    .\prune-package-versions.ps1                       # prompts for options, then runs
.EXAMPLE
    .\prune-package-versions.ps1 -Repo my-repo         # only my-repo-linked packages
.EXAMPLE
    .\prune-package-versions.ps1 -Package My.Package -Keep 5 -Execute
.EXAMPLE
    .\prune-package-versions.ps1 -NonInteractive       # no prompts, dry run, keep 5
#>
[CmdletBinding()]
param(
    [int]$Keep = 5,
    [string]$Package,
    [ValidateSet('nuget', 'npm', 'both')][string]$Type = 'both',
    [string]$Repo,
    [string]$Owner,
    [switch]$Execute,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

# ---------- interactive prompt helpers -----------------------------------------
$script:Interactive = (-not $NonInteractive) -and [Environment]::UserInteractive

function Read-Default {
    param([string]$Prompt, [string]$Default)
    if (-not $script:Interactive) { return $Default }
    $shown = if ([string]::IsNullOrWhiteSpace($Default)) { '' } else { " [$Default]" }
    $ans = Read-Host ("{0}{1}" -f $Prompt, $shown)
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
    return $ans.Trim()
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    if (-not $script:Interactive) { return $Default }
    $hint = if ($Default) { 'Y/n' } else { 'y/N' }
    $ans = (Read-Host ("{0} [{1}]" -f $Prompt, $hint)).Trim()
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
    return $ans -match '^(y|yes)$'
}

if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    throw "GitHub CLI (gh) not found. Install: https://cli.github.com/"
}
if (-not $Owner) {
    $resolved = (& gh api user --jq .login).Trim()
    if (-not $PSBoundParameters.ContainsKey('Owner')) {
        $Owner = Read-Default "Package owner (account)" $resolved
    } else {
        $Owner = $resolved
    }
}

# Prompt for anything not supplied on the command line.
if (-not $PSBoundParameters.ContainsKey('Type')) {
    $Type = Read-Default "Package type (nuget/npm/both)" $Type
    if ($Type -notin @('nuget', 'npm', 'both')) { throw "Invalid type '$Type'. Use nuget, npm, or both." }
}
if (-not $PSBoundParameters.ContainsKey('Keep')) {
    $Keep = [int](Read-Default "Versions to keep per package" $Keep)
}
if (-not $PSBoundParameters.ContainsKey('Repo')) {
    $Repo = Read-Default "Filter by repo (name or owner/name; blank = all)" ''
}
if (-not $PSBoundParameters.ContainsKey('Package')) {
    $Package = Read-Default "Filter by package name (blank = all)" ''
}
if (-not $PSBoundParameters.ContainsKey('Execute')) {
    $Execute = [switch](Read-YesNo "Actually delete? (No = dry run)" $false)
}

$repoFullFilter = $null
if ($Repo) {
    if ($Repo -match '/') { $repoFullFilter = $Repo } else { $repoFullFilter = "$Owner/$Repo" }
}

$types = if ($Type -eq 'both') { @('nuget', 'npm') } else { @($Type) }

$mode = if ($Execute) { 'EXECUTE (deletions are permanent)' } else { 'DRY RUN (no changes)' }
Write-Host ''
Write-Host "  Package retention  -  keep last $Keep version(s) per package" -ForegroundColor Cyan
Write-Host "  Owner: $Owner   Types: $($types -join ', ')   Mode: $mode" -ForegroundColor DarkGray
if ($repoFullFilter) { Write-Host "  Repo filter: $repoFullFilter" -ForegroundColor DarkGray }
Write-Host ('-' * 62) -ForegroundColor DarkGray

$totalDeleted = 0; $totalKept = 0; $totalFailed = 0

foreach ($t in $types) {
    $listRaw = & gh api "users/$Owner/packages?package_type=$t" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $listRaw) {
        Write-Host "  ! Cannot list $t packages (need read:packages scope?). Skipping." -ForegroundColor Yellow
        continue
    }
    $pkgs = $listRaw | ConvertFrom-Json

    foreach ($p in $pkgs) {
        if ($Package -and ($p.name -ine $Package)) { continue }
        if ($repoFullFilter) {
            $rf = if ($p.repository) { $p.repository.full_name } else { $null }
            if ($rf -ine $repoFullFilter) { continue }
        }

        # All versions, newest first.
        $verRaw = & gh api --paginate "users/$Owner/packages/$t/$($p.name)/versions" 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $verRaw) {
            Write-Host "  ! Cannot read versions for $($p.name). Skipping." -ForegroundColor Yellow
            continue
        }
        # --paginate may concatenate multiple JSON arrays; flatten defensively.
        $versions = @()
        foreach ($chunk in ($verRaw | ConvertFrom-Json)) { $versions += $chunk }
        $versions = $versions | Sort-Object { [datetime]$_.created_at } -Descending

        $keepSet   = $versions | Select-Object -First $Keep
        $deleteSet = $versions | Select-Object -Skip $Keep

        Write-Host ''
        Write-Host ("  {0} [{1}]  total={2}  keep={3}  delete={4}" -f `
            $p.name, $t, $versions.Count, $keepSet.Count, $deleteSet.Count) -ForegroundColor Cyan
        $totalKept += $keepSet.Count

        foreach ($v in $keepSet) {
            Write-Host ("      keep    {0,-12} id={1,-12} {2:yyyy-MM-dd}" -f $v.name, $v.id, ([datetime]$v.created_at)) -ForegroundColor DarkGray
        }

        foreach ($v in $deleteSet) {
            if ($Execute) {
                & gh api -X DELETE "users/$Owner/packages/$t/$($p.name)/versions/$($v.id)" *> $null
                if ($LASTEXITCODE -eq 0) {
                    Write-Host ("      DELETED {0,-12} id={1,-12} {2:yyyy-MM-dd}" -f $v.name, $v.id, ([datetime]$v.created_at)) -ForegroundColor Red
                    $totalDeleted++
                } else {
                    Write-Host ("      FAILED  {0,-12} id={1,-12} (blocked/permission)" -f $v.name, $v.id) -ForegroundColor Yellow
                    $totalFailed++
                }
            } else {
                Write-Host ("      would delete {0,-12} id={1,-12} {2:yyyy-MM-dd}" -f $v.name, $v.id, ([datetime]$v.created_at)) -ForegroundColor Magenta
                $totalDeleted++
            }
        }
    }
}

Write-Host ''
Write-Host ('-' * 62) -ForegroundColor DarkGray
if ($Execute) {
    Write-Host ("  Done. Kept: {0}   Deleted: {1}   Failed: {2}" -f $totalKept, $totalDeleted, $totalFailed) -ForegroundColor Green
} else {
    Write-Host ("  Dry run. Would keep: {0}   Would delete: {1}" -f $totalKept, $totalDeleted) -ForegroundColor Green
    Write-Host "  Re-run with -Execute to apply (add -Repo/-Package to narrow scope)." -ForegroundColor DarkGray
}
Write-Host ''

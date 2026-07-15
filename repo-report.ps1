<#
.SYNOPSIS
    Interactive report for a GitHub repo: package versions, Actions artifact storage,
    runner minutes, releases and general repo health.

.DESCRIPTION
    Prompts for a repo name (case-insensitive) unless -Repo is supplied, resolves it
    against the authenticated account, then prints a consolidated report.

    Requires the GitHub CLI (`gh`) authenticated with scopes:
        repo, read:packages, user      (read:packages + user unlock package + billing data)
    Refresh with:  gh auth refresh -h github.com -s read:packages,user

.PARAMETER Repo
    Repo name (case-insensitive) or full owner/name. If omitted you are prompted.

.PARAMETER Owner
    Account that owns the repo. Defaults to the authenticated gh user.

.PARAMETER Keep
    How many most-recent package versions to list. Default 5.

.PARAMETER NonInteractive
    Skip all prompts and use parameter values / defaults as-is. Handy for CI.

.EXAMPLE
    .\repo-report.ps1
.EXAMPLE
    .\repo-report.ps1 -Repo my-repo
.EXAMPLE
    .\repo-report.ps1 -Repo my-org/web-app -Keep 10
#>
[CmdletBinding()]
param(
    [string]$Repo,
    [string]$Owner,
    [int]$Keep = 5,
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'

$script:Interactive = (-not $NonInteractive) -and [Environment]::UserInteractive

function Read-Default {
    param([string]$Prompt, [string]$Default)
    if (-not $script:Interactive) { return $Default }
    $shown = if ([string]::IsNullOrWhiteSpace($Default)) { '' } else { " [$Default]" }
    $ans = Read-Host ("{0}{1}" -f $Prompt, $shown)
    if ([string]::IsNullOrWhiteSpace($ans)) { return $Default }
    return $ans.Trim()
}

# ---------- helpers ------------------------------------------------------------
function Require-Gh {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        throw "GitHub CLI (gh) not found on PATH. Install: https://cli.github.com/"
    }
    try { gh auth status *> $null } catch { throw "gh is not authenticated. Run: gh auth login" }
}

# Invoke a gh api call and return parsed JSON, or $null on failure (so the report
# degrades gracefully when a scope is missing rather than aborting).
function Gh-Json {
    param([Parameter(Mandatory)][string[]]$Args, [switch]$Quiet)
    try {
        $raw = & gh @Args 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) { return $null }
        return $raw | ConvertFrom-Json
    } catch {
        if (-not $Quiet) { Write-Verbose "gh $($Args -join ' ') failed: $_" }
        return $null
    }
}

function Fmt-Bytes {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return "$([int]$Bytes) B"
}

function Rule { param([string]$Label = '', [int]$Width = 62)
    if ($Label) {
        $l = " $Label "
        $pad = $Width - $l.Length
        if ($pad -lt 0) { $pad = 0 }
        $left = [int]($pad / 2)
        Write-Host (('-' * $left) + $l + ('-' * ($pad - $left))) -ForegroundColor DarkCyan
    } else {
        Write-Host ('-' * $Width) -ForegroundColor DarkGray
    }
}

# ---------- resolve repo -------------------------------------------------------
Require-Gh

if (-not $Owner) {
    $resolved = (& gh api user --jq .login).Trim()
    if (-not $PSBoundParameters.ContainsKey('Owner')) {
        $Owner = Read-Default "Account owner" $resolved
    } else {
        $Owner = $resolved
    }
}

if (-not $Repo) {
    if ($script:Interactive) {
        $Repo = Read-Host "Enter repo name (case-insensitive) or owner/name"
    }
}
if ([string]::IsNullOrWhiteSpace($Repo)) { throw "No repo name provided." }

if (-not $PSBoundParameters.ContainsKey('Keep')) {
    $Keep = [int](Read-Default "How many recent versions/releases/artifacts to list" $Keep)
}

# Allow 'owner/name' form.
if ($Repo -match '/') {
    $parts = $Repo.Split('/', 2)
    $Owner = $parts[0]; $Repo = $parts[1]
}

Write-Host "Resolving '$Repo' under '$Owner'..." -ForegroundColor DarkGray
$allRepos = Gh-Json @('repo', 'list', $Owner, '--limit', '1000', '--json', 'name,nameWithOwner,visibility')
if (-not $allRepos) { throw "Could not list repos for '$Owner'." }

$hit = @($allRepos | Where-Object { $_.name -ieq $Repo })
if ($hit.Count -eq 0) {
    $near = $allRepos | Where-Object { $_.name -ilike "*$Repo*" } | Select-Object -First 8 -ExpandProperty name
    $msg = "No repo named '$Repo' under '$Owner'."
    if ($near) { $msg += "  Did you mean: $($near -join ', ')?" }
    throw $msg
}
$repoName = $hit[0].name
$full     = $hit[0].nameWithOwner
$vis      = $hit[0].visibility

# ---------- gather -------------------------------------------------------------
# Repo metadata
$meta = Gh-Json @('api', "repos/$full")

# Artifacts (paginated) -> name<TAB>bytes<TAB>created_at, one per line
$artRaw = & gh api --paginate "repos/$full/actions/artifacts" `
    --jq '.artifacts[] | [.name, (.size_in_bytes|tostring), .created_at] | @tsv' 2>$null
$artifacts = @()
if ($artRaw) {
    foreach ($line in ($artRaw -split "`n")) {
        if (-not $line.Trim()) { continue }
        $c = $line -split "`t"
        $artifacts += [pscustomobject]@{ Name = $c[0]; Bytes = [int64]$c[1]; Created = [datetime]$c[2] }
    }
}
$artTotalBytes = ($artifacts | Measure-Object Bytes -Sum).Sum
if (-not $artTotalBytes) { $artTotalBytes = 0 }

# Billing usage (runner minutes + Actions/Packages storage) — needs 'user' scope
$usage = Gh-Json @('api', "users/$Owner/settings/billing/usage") -Quiet
$repoMinutes = 0; $actionsStorageGbH = 0; $pkgStorageGbH = 0; $pkgXferGb = 0
$billingAvailable = $false
if ($usage -and $usage.usageItems) {
    $billingAvailable = $true
    foreach ($u in $usage.usageItems) {
        if ($u.product -eq 'actions' -and $u.unitType -eq 'Minutes' -and $u.repositoryName -ieq $repoName) {
            $repoMinutes += $u.quantity
        }
        if ($u.product -eq 'actions' -and $u.sku -like '*storage*' -and $u.repositoryName -ieq $repoName) {
            $actionsStorageGbH += $u.quantity
        }
        if ($u.product -eq 'packages' -and $u.sku -like '*storage*') { $pkgStorageGbH += $u.quantity }
        if ($u.product -eq 'packages' -and $u.sku -like '*transfer*') { $pkgXferGb += $u.quantity }
    }
}

# Packages linked to this repo (nuget + npm) — needs 'read:packages'
$pkgTypes = @('nuget', 'npm')
$linkedPkgs = @()
$pkgScopeOk = $true
foreach ($t in $pkgTypes) {
    $list = Gh-Json @('api', "users/$Owner/packages?package_type=$t") -Quiet
    if ($null -eq $list) { $pkgScopeOk = $false; continue }
    foreach ($p in $list) {
        $repoFull = $null
        if ($p.repository) { $repoFull = $p.repository.full_name }
        if ($repoFull -ieq $full) {
            $linkedPkgs += [pscustomobject]@{ Name = $p.name; Type = $t; Versions = $p.version_count }
        }
    }
}

# Releases (last N)
$releases = Gh-Json @('api', "repos/$full/releases?per_page=$Keep") -Quiet

# Workflow run count
$runs = Gh-Json @('api', "repos/$full/actions/runs?per_page=1") -Quiet

# ---------- render -------------------------------------------------------------
Write-Host ''
Rule $full
Write-Host ("  Visibility        : {0}" -f $vis)
if ($meta) {
    Write-Host ("  Default branch    : {0}" -f $meta.default_branch)
    Write-Host ("  Git repo size     : {0}" -f (Fmt-Bytes ([double]$meta.size * 1KB)))
    Write-Host ("  Last pushed       : {0:yyyy-MM-dd HH:mm} UTC" -f ([datetime]$meta.pushed_at).ToUniversalTime())
    Write-Host ("  Open issues/PRs   : {0}" -f $meta.open_issues_count)
}
Write-Host ''

# ---- Packages / versions ----
Rule 'Package versions'
if (-not $pkgScopeOk) {
    Write-Host "  (read:packages scope missing - run: gh auth refresh -h github.com -s read:packages)" -ForegroundColor Yellow
} elseif ($linkedPkgs.Count -eq 0) {
    Write-Host "  No packages linked to this repo."
} else {
    Write-Host ("  NOTE: GitHub's API does not expose per-version byte size for nuget/npm," ) -ForegroundColor DarkYellow
    Write-Host ("        so version sizes are shown as n/a. 'id' is the version (tag) id." ) -ForegroundColor DarkYellow
    foreach ($pk in $linkedPkgs) {
        Write-Host ''
        Write-Host ("  {0}  [{1}]  total versions: {2}" -f $pk.Name, $pk.Type, $pk.Versions) -ForegroundColor Cyan
        $vers = Gh-Json @('api', "users/$Owner/packages/$($pk.Type)/$($pk.Name)/versions?per_page=$Keep") -Quiet
        if ($vers) {
            $i = 0
            foreach ($v in ($vers | Select-Object -First $Keep)) {
                $i++
                $tag = if ($i -eq 1) { ' <-- latest' } else { '' }
                Write-Host ("    {0,2}. {1,-12} id={2,-12} {3:yyyy-MM-dd}  size=n/a{4}" -f `
                    $i, $v.name, $v.id, ([datetime]$v.created_at), $tag)
            }
        }
    }
}
Write-Host ''

# ---- Artifacts ----
Rule 'Actions artifacts'
Write-Host ("  Artifact count            : {0}" -f $artifacts.Count)
Write-Host ("  Total artifact storage    : {0}" -f (Fmt-Bytes $artTotalBytes))
if ($billingAvailable) {
    Write-Host ("  Actions storage (billed)  : {0:N2} GiB-hours (period to date)" -f $actionsStorageGbH)
}
if ($artifacts.Count -gt 0) {
    $latest = $artifacts | Sort-Object Created -Descending | Select-Object -First 1
    Write-Host ("  Latest artifact           : {0}  ({1})  {2:yyyy-MM-dd HH:mm}" -f `
        $latest.Name, (Fmt-Bytes $latest.Bytes), $latest.Created)
    Write-Host ''
    Write-Host ("  Last {0} artifacts:" -f $Keep)
    $n = 0
    foreach ($a in ($artifacts | Sort-Object Created -Descending | Select-Object -First $Keep)) {
        $n++
        Write-Host ("    {0,2}. {1,-40} {2,10}  {3:yyyy-MM-dd HH:mm}" -f `
            $n, $a.Name, (Fmt-Bytes $a.Bytes), $a.Created)
    }
}
Write-Host ''

# ---- Runner minutes ----
Rule 'Runner minutes'
if ($billingAvailable) {
    Write-Host ("  Runner minutes (this repo, billing period to date): {0:N0} min" -f $repoMinutes)
} else {
    Write-Host "  (user scope missing - run: gh auth refresh -h github.com -s user)" -ForegroundColor Yellow
}
Write-Host ''

# ---- Releases ----
Rule 'Releases'
if ($releases -and $releases.Count -gt 0) {
    $n = 0
    foreach ($r in ($releases | Select-Object -First $Keep)) {
        $n++
        $assetBytes = 0
        if ($r.assets) { $assetBytes = ($r.assets | Measure-Object size -Sum).Sum }
        $pre = if ($r.prerelease) { ' (pre)' } else { '' }
        Write-Host ("    {0,2}. {1,-18} assets: {2,10}  {3:yyyy-MM-dd}{4}" -f `
            $n, $r.tag_name, (Fmt-Bytes $assetBytes), ([datetime]$r.published_at), $pre)
    }
} else {
    Write-Host "  No releases."
}
Write-Host ''

# ---- Account-wide extras ----
Rule 'Account-wide (not repo-scoped)'
if ($runs) { Write-Host ("  Total workflow runs (this repo) : {0}" -f $runs.total_count) }
if ($billingAvailable) {
    Write-Host ("  Packages storage (all packages) : {0:N2} GiB-hours (period to date)" -f $pkgStorageGbH)
    Write-Host ("  Packages data transfer          : {0:N3} GB (period to date)" -f $pkgXferGb)
    Write-Host "  NOTE: package storage/transfer are billed per-ACCOUNT, not per-repo." -ForegroundColor DarkYellow
}
Rule
Write-Host ''

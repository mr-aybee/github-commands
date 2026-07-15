# Repo & Package Scripts

PowerShell helpers for inspecting a GitHub repo's storage/usage and for pruning
old GitHub Packages versions. Both live in this folder (`D:\Repos\Genie\scripts\`).

| Script | Purpose | Changes anything? |
|--------|---------|-------------------|
| `repo-report.ps1` | Interactive report: package versions, artifact storage, runner minutes, releases, repo health | No (read-only) |
| `prune-package-versions.ps1` | Retention: keep the last N package versions, delete older ones | Only with `-Execute` |

---

## Prerequisites

1. **GitHub CLI** (`gh`) installed and on PATH — https://cli.github.com/
2. **Authenticated**: `gh auth login`
3. **Token scopes** — depends on what you run:

   | You want to see / do | Required scope | Refresh command |
   |----------------------|----------------|-----------------|
   | Repo, artifacts, releases | `repo` | (default) |
   | Package versions | `read:packages` | `gh auth refresh -h github.com -s read:packages` |
   | Runner minutes & billing/storage | `user` | `gh auth refresh -h github.com -s user` |
   | **Delete** package versions | `delete:packages` | `gh auth refresh -h github.com -s delete:packages` |

   One-shot for everything:
   ```powershell
   gh auth refresh -h github.com -s read:packages,user,delete:packages
   ```

   Check what you currently have:
   ```powershell
   gh auth status
   ```

> The report degrades gracefully: if a scope is missing, that section prints a
> yellow hint instead of failing the whole run.

### Running scripts (execution policy)

If PowerShell blocks the script, run it for the current process only:
```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```
Or invoke directly without changing policy:
```powershell
powershell -ExecutionPolicy Bypass -File .\repo-report.ps1 -Repo genie
```

---

## `repo-report.ps1`

Prompts for a repo name (case-insensitive) unless you pass `-Repo`, resolves it
against your account, and prints a consolidated report.

### Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `-Repo` | *(prompts)* | Repo name (case-insensitive) or `owner/name` |
| `-Owner` | authenticated gh user | Account that owns the repo |
| `-Keep` | `5` | How many recent versions / artifacts / releases to list |

### Examples

```powershell
# Prompt for the repo name
.\repo-report.ps1

# Named repo (case-insensitive)
.\repo-report.ps1 -Repo genie

# Full owner/name and a longer list
.\repo-report.ps1 -Repo mr-aybee/orbyn-web -Keep 10
```

### What it reports

- **Header** — visibility, default branch, git size, last push, open issues/PRs
- **Package versions** — each package linked to the repo, total version count, and
  the last *N* versions with their version **id** (this is the "tag id") and date
- **Actions artifacts** — count, total storage, latest, and the last *N*
- **Runner minutes** — for this repo, billing period to date
- **Releases** — last *N* tags with total asset size each
- **Account-wide extras** — total workflow runs, package storage & data transfer

### Sample output (Genie)

```
----------------------- mr-aybee/Genie -----------------------
  Visibility        : PRIVATE
  Default branch    : master
  Git repo size     : 7.4 MB
  ...
---------------------- Package versions ----------------------
  Genie.Engine  [nuget]  total versions: 14
     1. 0.0.14       id=1030629454   2026-07-14  size=n/a <-- latest
     ...
---------------------- Actions artifacts ---------------------
  Artifact count            : 0
  Total artifact storage    : 0 B
----------------------- Runner minutes -----------------------
  Runner minutes (this repo, billing period to date): 0 min
```

---

## `prune-package-versions.ps1`

Keeps the **N most-recent** versions of each package and deletes the rest.
**Dry run by default** — you must add `-Execute` for it to delete anything.

### Parameters

| Parameter | Default | Notes |
|-----------|---------|-------|
| `-Keep` | `5` | Versions to retain per package |
| `-Package` | *(all)* | Restrict to one package by name (case-insensitive) |
| `-Type` | `both` | `nuget`, `npm`, or `both` |
| `-Repo` | *(all)* | Only packages linked to this repo (`name` or `owner/name`) |
| `-Owner` | authenticated gh user | Account that owns the packages |
| `-Execute` | *(off)* | **Actually delete.** Without it, dry run only |

### Recommended workflow

```powershell
# 1. Preview — always do this first
.\prune-package-versions.ps1 -Repo genie -Keep 5

# 2. Narrow / verify a single package if unsure
.\prune-package-versions.ps1 -Package Genie.Engine -Keep 5

# 3. Apply once you're happy with the preview
.\prune-package-versions.ps1 -Repo genie -Keep 5 -Execute
```

### Output legend

- `keep` — version retained
- `would delete` — dry-run: would be removed (magenta)
- `DELETED` — removed (red, `-Execute` only)
- `FAILED` — deletion blocked (e.g. permission, or a heavily-downloaded public
  version GitHub protects) — skipped, run continues

---

## Cautions

- **Deletion is permanent.** A deleted package version cannot be restored. Always
  read the dry-run output before using `-Execute`.
- **Check consumers before pruning.** Keeping only the last 5 versions removes
  older ones (e.g. `0.0.9` and below). Make sure nothing still pins an older
  version. Quick check in a consumer repo:
  ```powershell
  Select-String -Path .\**\*.csproj, .\**\package.json -Pattern 'Genie|genie-engine-ui'
  ```
- **Package sizes are `n/a` by design.** GitHub's REST API does not expose
  per-version byte size for nuget/npm, so the report shows version id + date, not
  MB. Sized data is only available for **release assets** and **Actions artifacts**.
- **Package storage is billed per-account**, not per-repo — the account-wide figure
  in the report is shared across all your packages.

---

## Automating retention (optional)

These scripts are manual. To prune on a schedule you have two options:

1. **Windows Task Scheduler** — run the prune script weekly:
   ```powershell
   powershell -ExecutionPolicy Bypass -File "D:\Repos\Genie\scripts\prune-package-versions.ps1" -Keep 5 -Execute
   ```
2. **GitHub Actions** — a scheduled workflow in the Genie repo using
   `actions/delete-package-versions` (keeps the last N automatically, no local
   machine needed). Ask if you want this added.

# GitHub Commands

PowerShell utilities for repository reporting and GitHub Packages retention management.

| Script | Purpose |
| --- | --- |
| `repo-report.ps1` | Read-only repository and package usage reporting |
| `prune-package-versions.ps1` | Retention management for package versions |

## Getting started

Install the [GitHub CLI](https://cli.github.com/) and authenticate with `gh auth login`. Review the [complete command reference](doc.md) for parameters, permissions and examples.

```powershell
.\repo-report.ps1
```

## Safety

Review retention output before executing deletion. The pruning script requires explicit `-Execute` to delete versions according to the existing documentation. Use the minimum necessary token permissions. Never commit access tokens or private report output.

## Verification

Current execution behavior has not been independently tested; validate against a disposable repository or package first.

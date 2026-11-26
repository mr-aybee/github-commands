# Contributing to github-commands

Thanks for taking the time to contribute.

## Workflow

1. Fork the repository and create a branch from the default branch: `git checkout -b feature/short-description`.
2. Make focused changes; keep unrelated refactors in separate pull requests.
3. Build locally before pushing:

   ```shell
   pwsh -c "Invoke-ScriptAnalyzer -Path . -Recurse"
   ```
5. Use clear commit messages in the imperative mood, e.g. `fix: handle empty input`.
6. Open a pull request describing **what** changed and **why**. CI must pass before review.

## Reporting issues

Open an issue with steps to reproduce, the expected and actual behaviour, and your OS and runtime versions.

## Security

Do not report security vulnerabilities in public issues. Use GitHub's [private vulnerability reporting](https://github.com/mr-aybee/github-commands/security/advisories/new) instead.

## Code of Conduct

Participation is governed by the [Code of Conduct](CODE_OF_CONDUCT.md).

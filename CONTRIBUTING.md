# Contributing to IntuneWin32BulkManagement

We welcome contributions! This guide will help you get started.

## Prerequisites
- Windows 10/11 with PowerShell 5.1+ or PowerShell 7.
- Microsoft Graph PowerShell SDK (`Install-Module Microsoft.Graph -Scope CurrentUser`).
- Git installed.

## Fork & Clone
1. Fork the repository on GitHub.
2. Clone your fork locally:
   ```bash
   git clone https://github.com/<your‑username>/IntuneWin32BulkManagement.git
   cd IntuneWin32BulkManagement
   ```

## Development workflow
1. Create a new branch for your change:
   ```bash
   git checkout -b my-feature
   ```
2. Make your edits.  Keep the code style consistent with the existing files.
3. Run the linter to ensure code quality:
   ```powershell
   Install-Module -Name PSScriptAnalyzer -Scope CurrentUser
   Invoke-ScriptAnalyzer -Path . -Recurse
   ```
   Fix any warnings/errors.
4. Commit your changes with a clear message:
   ```bash
   git add .
   git commit -m "feat: brief description of change"
   ```
5. Push to your fork and open a Pull Request against `main`.

## Pull Request checklist
- [ ] Code follows the existing style.
- [ ] Tests (if applicable) pass.
- [ ] Documentation updated (README, comments, etc.).
- [ ] Linting (`PSScriptAnalyzer`) passes without errors.
- [ ] The PR description explains the problem and solution.

## Reporting bugs & suggesting features
- Use the **Issues** tab on GitHub and select the appropriate template.
- Provide steps to reproduce, expected vs actual behavior, and any relevant screenshots.

Thank you for helping make IntuneWin32BulkManagement better! 🎉
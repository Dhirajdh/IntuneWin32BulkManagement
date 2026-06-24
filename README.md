![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)
# IntuneWin32BulkManagement

IntuneWin32BulkManagement is a PowerShell‑based GUI tool that lets you bulk‑manage Win32 applications in Microsoft Intune. It provides a visual interface to:

- Connect to Intune using the Microsoft Graph API.
- List, search, filter and sort all Win32 apps in your tenant.
- Assign groups (required, available, uninstall) in bulk.
- View detailed app information and copy properties to the clipboard.
- Export assignment reports to CSV.
- Backup and restore the current app catalog.
- Log activity and progress with a built‑in logging pane.

The UI is built with WPF/XAML and runs on Windows 10/11 PowerShell 5.1+ (or PowerShell 7). It is completely client‑side – no server component is required.

---

## 📁 Repository layout

```
IntuneWin32BulkManagement/
│   IntuneWin32BulkManagement.ps1   # Main entry point – loads modules & UI
│   README.md                       # This file
│   LICENSE                         # MIT License
│   .gitignore                      # Ignored files/folders
│
├─ Modules/
│   ├─ AppOperations.psm1          # Functions that call Graph (CRUD, assign, delete)
│   ├─ Logging.psm1                # Logging helpers used throughout the UI
│   └─ Graph.psm1                  # Low‑level wrappers around Invoke‑MgGraphRequest
│
├─ XAML/
│   ├─ MainWindow.xaml             # Main UI layout
│   └─ AssignmentWindow.xaml       # Dialog for bulk group assignment
│
└─ .github/
    ├─ ISSUE_TEMPLATE/
    │   └─ bug_report.md           # Template for filing bugs
    └─ PULL_REQUEST_TEMPLATE.md   # Template for PRs
```

### What each folder does
- **Modules/** – PowerShell module files that encapsulate the business logic (Graph, logging, app operations). Keeping them separate makes the script easier to test and maintain.
- **XAML/** – Pure XAML files that describe the user interface. The PowerShell script loads them at runtime and wires the event handlers.
- **.github/** – Optional but recommended GitHub configuration: issue/PR templates, CONTRIBUTING guidelines, and a CODE_OF_CONDUCT.

---

## ✨ Features & highlights
- **Graph‑based Intune integration** – Uses the Microsoft Graph PowerShell SDK (`Invoke‑MgGraphRequest`).
- **Bulk group assignment** – Select multiple apps and assign a list of Azure AD groups with a single click.
- **Live filtering** – Search by name, description, publisher, status, or custom text.
- **Export & backup** – CSV export of assignments, JSON backup of the whole app list.
- **Smart UI** – Double‑click a cell to copy its value, horizontal scrolling with mouse wheel, auto‑resize to the current monitor.
- **Persistent user settings** – Window size/position, last used status/publisher filters are stored under `%APPDATA%\IntuneWin32BulkManagement\settings.json`.
- **Extensible** – All heavy lifting lives in the `Modules/` folder, making it straightforward to add new commands (e.g., bulk uninstall, version bumping).

---

## 👥 Roles & contribution model
| Role | Responsibility |
|------|----------------|
| **Owner** | Repo creator – merges PRs, tags releases, manages Graph API permissions. |
| **Maintainer** | Reviews PRs, triages bugs, updates documentation. |
| **Contributor** | Submits bug reports, feature requests, or code via pull requests. |
| **User** | Runs the script locally; can open issues for bugs or feature ideas. |

We follow the classic **fork‑branch‑pull‑request** workflow. See `CONTRIBUTING.md` for the detailed steps.

---

## 🔐 Permissions required (Intune)
The script needs an Azure AD app registration (or delegated user token) with the following Microsoft Graph permissions:
- `DeviceManagementApps.ReadWrite.All`
- `DeviceManagementManagedDevices.Read.All` (for device status export)
- `User.Read` (to display the signed‑in user)

The least‑privilege approach is to grant **Application** permissions only when the script runs in an automated context (e.g., CI). For interactive use, a delegated token with the same scopes is sufficient.

---

## 📄 Open‑source compliance
- **License:** MIT – a permissive license that allows commercial use, modification, and distribution.
- **NOTICE & attribution:** The `LICENSE` file includes the full text; the README contains a badge linking to the license.
- **Code of Conduct:** Adopted the Contributor Covenant v2.0 to foster an inclusive community.
- **Contribution guidelines:** `CONTRIBUTING.md` outlines how to set up a development environment, run linting (`PSScriptAnalyzer`), and submit PRs.
- **Security policy:** A `SECURITY.md` (optional) can be added later to describe how to report vulnerabilities.

---


## 📸 Screenshots

| Feature | Screenshot |
|---------|------------|
| **Main window** – app list, filters, progress | ![Main window](Screenshots/main-window.png) |
| **Assign dialog** – bulk group selection | ![Assign dialog](Screenshots/assign-dialog.png) |
| **App details popup** – copy‑on‑double‑click fields | ![App details](Screenshots/app-details.png) |
| **Log pane** – activity feed example | ![Log example](Screenshots/log-example.png) |


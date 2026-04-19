# Accord

Accord is a Windows-first Electron desktop app for running the `accord.ps1` cross-model QC pipeline.

## Prerequisites

Install and make sure these commands are available on `PATH`:

- Node.js 18+
- PowerShell 5.1+ (or PowerShell 7+)
- Git
- Claude Code CLI: `npm i -g @anthropic-ai/claude-code`
- Codex CLI: `npm i -g @openai/codex`

## Install From Source

```powershell
# Clone the repo
git clone https://github.com/jivishov/accord.git
cd accord

# Install dependencies
npm install --package-lock=false
```

## Run Accord

```powershell
npm start
```

The app opens the Pipeline Console desktop UI.

## App Screenshots

### Dashboard

![Accord Dashboard](docs/screenshots/dashboard.png)

### Configure Run (Advanced)

![Accord Configure Run](docs/screenshots/configure.png)

### Project Wizard

![Accord Project Wizard](docs/screenshots/wizard.png)

## First-Time Setup In The App

1. Open the **Advanced** tab.
2. Set **Workspace Directory** to your target project.
3. Set **Plan File** to the plan you want to execute.
4. Click **Check Environment** and confirm `powershell`, `git`, `claude`, and `codex` are detected.
5. Click **Start Run**.

## Basic Usage Flow

1. Start a run from **Advanced** or use the **Wizard** flow.
2. Track progress in **Dashboard** and **Events**.
3. Open generated artifacts in **Artifacts**.
4. Resume/cancel from the session controls when needed.

## Verify The App

```powershell
npm run smoke
```

## Generate/Refresh README Screenshots

```powershell
npm run screenshots
```

This command launches Electron in capture mode and writes:

- `docs/screenshots/dashboard.png`
- `docs/screenshots/configure.png`
- `docs/screenshots/wizard.png`

## Build Windows Installer

```powershell
npm run dist
```

Generated installer artifacts are written to `dist/`.

## Troubleshooting

- `claude` or `codex` not found: reinstall globally and reopen terminal.
- PowerShell execution issues: run shell as Administrator and verify execution policy.
- App starts but workflows fail: use **Check Environment** and confirm all required commands resolve.

## Additional Docs

- [Desktop Guide](docs/help/desktop-guide.md)
- [Quick Start](docs/help/quick-start.md)
- [Pipeline and Modes](docs/help/pipeline-and-modes.md)

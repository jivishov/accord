$ErrorActionPreference = "Stop"

function Write-Info {
    param([string]$Message)
    Write-Host "[release] $Message"
}

function Get-Sha256Hex {
    param([string]$Path)

    $getFileHashCmd = Get-Command -Name "Get-FileHash" -ErrorAction SilentlyContinue
    if ($null -ne $getFileHashCmd) {
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    }

    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha.ComputeHash($stream)
            return ([System.BitConverter]::ToString($hashBytes).Replace("-", "").ToLowerInvariant())
        }
        finally {
            $sha.Dispose()
        }
    }
    finally {
        $stream.Dispose()
    }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$packageJsonPath = Join-Path $repoRoot "package.json"
$distDir = Join-Path $repoRoot "dist"
$deployDir = Join-Path $repoRoot "deploy"

if (-not (Test-Path -LiteralPath $packageJsonPath)) {
    throw "package.json not found at $packageJsonPath"
}

$packageJson = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
$version = [string]$packageJson.version
$productName = [string]$packageJson.build.productName
$appId = [string]$packageJson.build.appId

if ([string]::IsNullOrWhiteSpace($version)) {
    throw "package.json version is empty."
}
if ([string]::IsNullOrWhiteSpace($productName)) {
    throw "package.json build.productName is empty."
}

$installerName = "$productName Setup $version.exe"
$installerSourcePath = Join-Path $distDir $installerName

if (-not (Test-Path -LiteralPath $installerSourcePath)) {
    throw "Installer not found: $installerSourcePath. Run 'npm run dist' first."
}

if (Test-Path -LiteralPath $deployDir) {
    Get-ChildItem -LiteralPath $deployDir -Force | Remove-Item -Recurse -Force
} else {
    New-Item -ItemType Directory -Path $deployDir -Force | Out-Null
}

$installerTargetPath = Join-Path $deployDir $installerName
Copy-Item -LiteralPath $installerSourcePath -Destination $installerTargetPath -Force

$installerFile = Get-Item -LiteralPath $installerTargetPath
$sha256 = Get-Sha256Hex -Path $installerTargetPath
$generatedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$shaFilePath = Join-Path $deployDir "SHA256SUMS.txt"
"$sha256 *$installerName" | Set-Content -LiteralPath $shaFilePath -Encoding UTF8

$manifest = [ordered]@{
    productName = $productName
    appId = $appId
    version = $version
    generatedAtUtc = $generatedAtUtc
    installer = [ordered]@{
        fileName = $installerName
        sizeBytes = $installerFile.Length
        sha256 = $sha256
    }
    unsignedInstaller = $true
}

$manifestPath = Join-Path $deployDir "release-manifest.json"
$manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$userReadmePath = Join-Path $deployDir "README.md"
$installerNameQuoted = '"' + $installerName + '"'
$installerRelativeQuoted = '".\' + $installerName + '"'
$userReadmeTemplate = @'
# Accord for Windows

This folder contains the Windows installer package for **Accord**.

## Files in this Folder

- `{0}` - Windows x64 installer
- `SHA256SUMS.txt` - checksum file for installer integrity verification
- `release-manifest.json` - build metadata (version, hash, size, generation time)

## System Requirements

- Windows 10 or Windows 11 (x64)
- Git installed and available on PATH (`git`)
- Claude CLI installed and available on PATH (`claude`)
- Codex CLI installed and available on PATH (`codex`)
- Internet access for model/API calls from those CLIs

Accord bundles Electron, so users do **not** need Node.js separately to run the app.

## Install Accord

1. Download `{0}`.
2. (Recommended) Verify checksum using `SHA256SUMS.txt`.
3. Double-click the installer and complete setup.
4. Launch **Accord** from Start Menu or desktop shortcut.

## Verify Installer Checksum (PowerShell)

From this folder:

```powershell
Get-Content .\SHA256SUMS.txt
Get-FileHash {2} -Algorithm SHA256
```

Confirm the SHA256 hash values match exactly.

If `Get-FileHash` is unavailable in your shell:

```powershell
certutil -hashfile {2} SHA256
```

## Windows SmartScreen (Unsigned Installer)

This installer is currently unsigned. On first launch, Windows may show:
`Windows protected your PC`.

If this appears:

1. Click **More info**
2. Click **Run anyway**

Only do this if you downloaded from the official GitHub release and verified the checksum.

## First Run Checklist

After launching Accord:

1. Open the app.
2. Use **Check Environment** in the Configure panel.
3. Confirm `powershell`, `git`, `claude`, and `codex` are detected.
4. Run a small smoke workflow before production usage.

## Uninstall / Update

- Uninstall: Windows Settings -> Apps -> Installed apps -> Accord -> Uninstall
- Update: install a newer `Accord Setup <version>.exe` from GitHub Releases
'@
$userReadme = $userReadmeTemplate -f $installerName, $installerNameQuoted, $installerRelativeQuoted
$userReadme | Set-Content -LiteralPath $userReadmePath -Encoding UTF8

$releaseGuidePath = Join-Path $deployDir "GITHUB_RELEASE_STEPS.md"
$releaseGuideTemplate = @'
# GitHub Release Steps (Accord)

This is the maintainer checklist for publishing Accord to GitHub Releases.

## 1. Build and Prepare Release Assets

From repo root:

```powershell
npm run smoke
powershell -ExecutionPolicy Bypass -File test/dry_run_test.ps1
npm run release:all
```

This produces a populated `deploy/` folder for upload.

## 2. Commit Source Changes

Commit code/docs/scripts.  
Recommended: do **not** commit installer binaries to git history; upload binaries as release assets.

## 3. Tag the Release

Use package version from `package.json`:

```powershell
git tag v{0}
git push origin v{0}
```

## 4. Create GitHub Release

1. Open repository -> **Releases** -> **Draft a new release**
2. Select tag: `v{0}`
3. Title: `Accord v{0}`
4. Paste release notes (template below)
5. Upload files from `deploy/`:
   - `{1}`
   - `SHA256SUMS.txt`
6. Publish release

## 5. Suggested Release Notes Template

```markdown
## Accord v{0}

### Downloads
- Windows installer: `{1}`
- Checksums: `SHA256SUMS.txt`

### Highlights
- [Add top features/fixes]

### Installation
1. Download installer
2. Verify SHA256 checksum
3. Run installer
4. If SmartScreen appears: More info -> Run anyway
```

## 6. Post-Publish Verification

1. Download installer from published release.
2. Verify SHA256 against `SHA256SUMS.txt`.
3. Install on a clean Windows machine/VM.
4. Launch Accord and run **Check Environment**.
5. Confirm app starts and can run a basic workflow.
'@
$releaseGuide = $releaseGuideTemplate -f $version, $installerName
$releaseGuide | Set-Content -LiteralPath $releaseGuidePath -Encoding UTF8

Write-Info "Prepared deploy assets:"
Write-Info " - $installerName"
Write-Info " - SHA256SUMS.txt"
Write-Info " - release-manifest.json"
Write-Info " - README.md"
Write-Info " - GITHUB_RELEASE_STEPS.md"

<#
.SYNOPSIS
    Installs the Power Platform CLI (pac) from the NuGet package.

.DESCRIPTION
    Ensures the full Windows Power Platform CLI is available by downloading
    the Microsoft.PowerApps.CLI NuGet package and extracting pac.exe from it.

    This installs the .NET Framework build which includes ALL commands:
    pac auth, pac solution, pac data, pac tool, etc.

    The cross-platform dotnet tool (Microsoft.PowerApps.CLI.Tool) and the
    GitHub Action (microsoft/powerplatform-actions/actions-install) both install
    a .NET Core build that excludes Windows-specific commands like 'pac data'.
    This script installs the complete Windows CLI instead.

    Safe to call multiple times — skips installation if pac is already on PATH
    and the 'pac data' command is available.

.NOTES
    Call this script at the beginning of any workflow job that needs pac:

        .\.github\workflows\scripts\Install-PacCli.ps1

    Only works on Windows runners (uses .NET Framework build).
    Does NOT require .NET SDK — downloads a self-contained NuGet package.
#>

$ErrorActionPreference = "Stop"

$pacCliVersion = "2.2.1"
$pacNuGetPackage = "Microsoft.PowerApps.CLI"

# Check if pac is already installed with full capabilities
$pacAvailable = $false
$existingPac = Get-Command pac -ErrorAction SilentlyContinue
if ($existingPac) {
    # Temporarily allow errors from native commands so we can inspect exit codes
    $prevPref = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false
    try {
        $dataCheck = pac data help 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            $pacAvailable = $true
        }
    } finally {
        $PSNativeCommandUseErrorActionPreference = $prevPref
    }
}

if ($pacAvailable) {
    Write-Host "Power Platform CLI already available with 'pac data' support" -ForegroundColor Green
    Write-Host "  Location: $($existingPac.Source)" -ForegroundColor Cyan
    exit 0
}

Write-Host "Installing Power Platform CLI ($pacCliVersion) from NuGet..." -ForegroundColor Yellow

# Determine install location
# On GitHub Actions runners, $env:LOCALAPPDATA resolves to the SYSTEM account profile
# (C:\Windows\system32\config\systemprofile\...) which causes permission issues.
# Use $env:RUNNER_TEMP instead when running in GitHub Actions.
$baseDir = if ($env:GITHUB_ACTIONS -eq 'true' -and $env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:LOCALAPPDATA }
$pacInstallDir = Join-Path $baseDir "Microsoft\PowerApps\CLI\pac-nuget"
$pacToolsDir = Join-Path $pacInstallDir "tools"
$pacExe = Join-Path $pacToolsDir "pac.exe"

# Skip download if already extracted
if (-not (Test-Path $pacExe)) {
    # Create install directory
    if (Test-Path $pacInstallDir) {
        Remove-Item $pacInstallDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $pacInstallDir -Force | Out-Null
    
    # Download NuGet package
    $nugetUrl = "https://www.nuget.org/api/v2/package/$pacNuGetPackage/$pacCliVersion"
    $nupkgPath = Join-Path $pacInstallDir "pac.zip"
    
    Write-Host "  Downloading $pacNuGetPackage v$pacCliVersion..." -ForegroundColor Cyan
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $nugetUrl -OutFile $nupkgPath -UseBasicParsing
    
    # Extract package
    Write-Host "  Extracting..." -ForegroundColor Cyan
    Expand-Archive -Path $nupkgPath -DestinationPath $pacInstallDir -Force
    
    # Clean up zip
    Remove-Item $nupkgPath -Force -ErrorAction SilentlyContinue
    
    # Verify pac.exe exists
    if (-not (Test-Path $pacExe)) {
        Write-Error "pac.exe not found after extraction at: $pacExe"
        exit 1
    }
}

# Add to PATH for current session
if (-not ($env:PATH -split [System.IO.Path]::PathSeparator | Where-Object { $_ -eq $pacToolsDir })) {
    $env:PATH = "$pacToolsDir$([System.IO.Path]::PathSeparator)$env:PATH"
}

# Export to GITHUB_PATH so subsequent steps in the same job pick it up
if ($env:GITHUB_PATH) {
    $pacToolsDir | Out-File -FilePath $env:GITHUB_PATH -Append -Encoding utf8
}

# Verify installation
$pacCheck = Get-Command pac -ErrorAction SilentlyContinue
if (-not $pacCheck) {
    Write-Error "Power Platform CLI installation succeeded but 'pac' not found on PATH"
    exit 1
}

Write-Host "✓ Power Platform CLI installed from NuGet" -ForegroundColor Green
Write-Host "  Location: $pacToolsDir" -ForegroundColor Cyan
exit 0

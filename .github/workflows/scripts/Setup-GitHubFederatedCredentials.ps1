<#
.SYNOPSIS
    Creates federated credentials for GitHub.com environments in an Azure AD App Registration using Azure CLI.

.DESCRIPTION
    This script creates OpenID Connect (OIDC) federated identity credentials for GitHub Actions
    to authenticate to Azure without storing secrets. Each environment gets its own credential.
    
    Uses Azure CLI (az) commands - requires az login first.

.PARAMETER AppRegistrationId
    The Application (Client) ID or Object ID of the existing Azure AD App Registration

.PARAMETER GitHubOrg
    GitHub organization or user name (e.g., "MyOrg")

.PARAMETER RepositoryName
    GitHub repository name (e.g., "MyRepo")

.PARAMETER Environments
    Array of environment names to create credentials for.

.EXAMPLE
    .\Setup-GitHubFederatedCredentials-CLI.ps1 `
        -AppRegistrationId "ecccaf50-4c20-48a7-8eb2-28f7f88c6814" `
        -GitHubOrg "MyOrg" `
        -RepositoryName "my-power-platform" `
        -Environments @("my-env-uat", "my-env-prod", "my-env-dev-base", "my-env-dev-1", "my-env-dev-2", "my-env-3")

.NOTES
    Prerequisites:
    - Azure CLI installed: https://aka.ms/install-az-cli
    - Already logged in: az login
    - Permissions on the App Registration
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$AppRegistrationId,
    
    [Parameter(Mandatory = $true)]
    [string]$GitHubOrg,
    
    [Parameter(Mandatory = $true)]
    [string]$RepositoryName,
    
    [Parameter(Mandatory = $true)]
    [string[]]$Environments
)

$ErrorActionPreference = "Stop"

# Helper function to check if Azure CLI is installed and logged in
function Test-AzureCLI {
    try {
        $null = az account show 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "❌ Not logged into Azure CLI. Please run: az login" -ForegroundColor Red
            return $false
        }
        return $true
    }
    catch {
        Write-Host "❌ Azure CLI not found. Please install from: https://aka.ms/install-az-cli" -ForegroundColor Red
        return $false
    }
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "GitHub Federated Credentials Setup" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Check Azure CLI
if (-not (Test-AzureCLI)) {
    exit 1
}

# Get current account info
Write-Host "Getting Azure account information..." -ForegroundColor Cyan
$account = az account show | ConvertFrom-Json
Write-Host "✓ Logged in as: $($account.user.name)" -ForegroundColor Green
Write-Host "  Tenant:       $($account.tenantId)" -ForegroundColor Gray
Write-Host "  Subscription: $($account.name)" -ForegroundColor Gray

# Get app registration details
Write-Host "`nLooking up App Registration: $AppRegistrationId" -ForegroundColor Cyan
$app = az ad app show --id $AppRegistrationId 2>&1 | ConvertFrom-Json

if (-not $app) {
    Write-Host "❌ App Registration not found: $AppRegistrationId" -ForegroundColor Red
    Write-Host "   Make sure you're using the Application (Client) ID" -ForegroundColor Yellow
    exit 1
}

Write-Host "✓ Found App Registration" -ForegroundColor Green
Write-Host "`nApp Registration Details:" -ForegroundColor Cyan
Write-Host "  Display Name:    $($app.displayName)" -ForegroundColor White
Write-Host "  Application ID:  $($app.appId)" -ForegroundColor White
Write-Host "  Object ID:       $($app.id)" -ForegroundColor White

# GitHub.com OIDC issuer URL (fixed for github.com)
$issuerUrl = "https://token.actions.githubusercontent.com"
Write-Host "`nGitHub Configuration:" -ForegroundColor Cyan
Write-Host "  Organization:    $GitHubOrg" -ForegroundColor White
Write-Host "  Repository:      $RepositoryName" -ForegroundColor White
Write-Host "  Issuer URL:      $issuerUrl" -ForegroundColor White

# List existing federated credentials
Write-Host "`nChecking existing federated credentials..." -ForegroundColor Cyan
$existingCreds = az ad app federated-credential list --id $app.appId 2>&1 | ConvertFrom-Json

if ($existingCreds -and $existingCreds.Count -gt 0) {
    Write-Host "Found $($existingCreds.Count) existing credential(s):" -ForegroundColor Yellow
    foreach ($cred in $existingCreds) {
        Write-Host "  - $($cred.name): $($cred.subject)" -ForegroundColor Gray
    }
}
else {
    Write-Host "No existing credentials found." -ForegroundColor Gray
}

# Show what will be created
Write-Host "`nEnvironments to configure:" -ForegroundColor Cyan
foreach ($env in $Environments) {
    $subject = "repo:$GitHubOrg/$RepositoryName:environment:$env"
    Write-Host "  ✓ $env" -ForegroundColor White
    Write-Host "    Subject: $subject" -ForegroundColor Gray
}

# Confirm
$confirmation = Read-Host "`nProceed with creating federated credentials? (y/N)"
if ($confirmation -notmatch '^[Yy]') {
    Write-Host "Operation cancelled by user." -ForegroundColor Yellow
    exit 0
}

# Create credentials
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Creating Federated Credentials" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

$successCount = 0
$skippedCount = 0
$errorCount = 0

foreach ($env in $Environments) {
    $credentialName = "github-$RepositoryName-$env"
    $subject = "repo:$GitHubOrg/$($RepositoryName):environment:$env"
    $description = "GitHub Actions federated credential for $env environment"
    
    Write-Host "Creating credential: $env" -ForegroundColor Cyan
    Write-Host "  Name:    $credentialName" -ForegroundColor Gray
    Write-Host "  Subject: $subject" -ForegroundColor Gray
    
    # Create JSON in a temp file to avoid PowerShell escaping issues
    $tempFile = [System.IO.Path]::GetTempFileName()
    $jsonContent = @{
        name = $credentialName
        issuer = $issuerUrl
        subject = $subject
        description = $description
        audiences = @("api://AzureADTokenExchange")
    } | ConvertTo-Json -Compress
    
    $jsonContent | Out-File -FilePath $tempFile -Encoding utf8 -NoNewline
    
    # Create the federated credential using Azure CLI with file parameter
    $result = az ad app federated-credential create `
        --id $app.appId `
        --parameters "@$tempFile" 2>&1
    
    # Clean up temp file
    Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
    
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ✓ Created successfully" -ForegroundColor Green
        $successCount++
    }
    elseif ($result -match "already exists") {
        Write-Host "  ⊘ Skipped (already exists)" -ForegroundColor Yellow
        $skippedCount++
    }
    else {
        Write-Host "  ✗ Error: $result" -ForegroundColor Red
        $errorCount++
    }
    
    Write-Host ""
}

# Summary
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "✓ Created:  $successCount" -ForegroundColor Green
Write-Host "⊘ Skipped:  $skippedCount" -ForegroundColor Yellow
Write-Host "✗ Errors:   $errorCount" -ForegroundColor $(if ($errorCount -gt 0) { "Red" } else { "Gray" })

# Output GitHub configuration
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "GitHub Configuration" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

Write-Host "`n📋 Add these SECRETS to your GitHub repository:" -ForegroundColor Yellow
Write-Host "   Settings → Secrets and variables → Actions → New repository secret`n" -ForegroundColor Gray

Write-Host "  AZURE_CLIENT_ID:       $($app.appId)" -ForegroundColor White
Write-Host "  AZURE_TENANT_ID:       $($account.tenantId)" -ForegroundColor White
Write-Host "  AZURE_SUBSCRIPTION_ID: $($account.id)" -ForegroundColor White

Write-Host "`n📋 Create these ENVIRONMENTS in your GitHub repository:" -ForegroundColor Yellow
Write-Host "   Settings → Environments → New environment`n" -ForegroundColor Gray

foreach ($env in $Environments) {
    Write-Host "  - $env" -ForegroundColor White
}

Write-Host "`n✓ Setup complete!" -ForegroundColor Green

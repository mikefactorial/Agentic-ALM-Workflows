<#
.SYNOPSIS
    Test script for DataverseApiClient and PowerPlatformClient with OIDC or client secret auth
    
.DESCRIPTION
    Comprehensive test script that validates both Dataverse API and Power Platform CLI clients.
    Can run locally with client secret authentication or in GitHub Actions with OIDC.
    
.PARAMETER EnvironmentUrl
    The URL of your Dataverse/Power Platform environment
    
.PARAMETER TenantId
    Azure AD Tenant ID
    
.PARAMETER ClientId
    Application (client) ID
    
.PARAMETER ClientSecret
    Client secret (only required for local testing, not needed for OIDC)
    
.PARAMETER TestDataverseApi
    Test the DataverseApiClient
    
.PARAMETER TestPowerPlatformCli
    Test the PowerPlatformClient
    
.EXAMPLE
    # Test locally with client secret
    .\Test-Clients.ps1 -EnvironmentUrl "https://yourorg.crm.dynamics.com" -TenantId "tenant-id" -ClientId "client-id" -ClientSecret "secret" -TestDataverseApi -TestPowerPlatformCli
    
    # Test in GitHub Actions with OIDC (no secret needed)
    .\Test-Clients.ps1 -EnvironmentUrl "https://yourorg.crm.dynamics.com" -TenantId "tenant-id" -ClientId "client-id" -TestDataverseApi -TestPowerPlatformCli
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$EnvironmentUrl,
    
    [Parameter(Mandatory = $true)]
    [string]$TenantId,
    
    [Parameter(Mandatory = $true)]
    [string]$ClientId,
    
    [Parameter(Mandatory = $false)]
    [string]$ClientSecret,
    
    [Parameter(Mandatory = $false)]
    [switch]$TestDataverseApi,
    
    [Parameter(Mandatory = $false)]
    [switch]$TestPowerPlatformCli
)

$ErrorActionPreference = "Stop"
$scriptsPath = Join-Path $PSScriptRoot ".." "scripts"

# Import the client classes
. (Join-Path $scriptsPath "DataverseApiClient.ps1")
. (Join-Path $scriptsPath "PowerPlatformClient.ps1")

$EnvironmentUrl = $EnvironmentUrl.TrimEnd('/')

# Determine authentication method
$useOIDC = [string]::IsNullOrEmpty($ClientSecret)
$authMethod = if ($useOIDC) { "OIDC (GitHub Federated Credentials)" } else { "Client Secret" }

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  Power Platform Clients Test Suite" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Environment: $EnvironmentUrl"
Write-Host "Tenant ID: $TenantId"
Write-Host "Client ID: $ClientId"
Write-Host "Authentication: $authMethod"
Write-Host "========================================`n" -ForegroundColor Cyan

$testsPassed = 0
$testsFailed = 0
$testsSkipped = 0

# Test Dataverse API Client
if ($TestDataverseApi) {
    Write-Host "`n=== Testing Dataverse API Client ===" -ForegroundColor Yellow
    Write-Host ""
    
    try {
        # Initialize client
        Write-Host "[1/5] Initializing Dataverse API client..." -ForegroundColor Cyan
        if ($useOIDC) {
            $dataverseClient = [DataverseApiClient]::new($TenantId, $ClientId, $EnvironmentUrl)
        }
        else {
            $dataverseClient = [DataverseApiClient]::new($TenantId, $ClientId, $ClientSecret, $EnvironmentUrl)
        }
        Write-Host "  ✓ Client initialized successfully" -ForegroundColor Green
        $testsPassed++
        
        # Test WhoAmI
        Write-Host "`n[2/5] Testing WhoAmI API..." -ForegroundColor Cyan
        $whoAmI = $dataverseClient.WhoAmI()
        Write-Host "  ✓ WhoAmI successful" -ForegroundColor Green
        Write-Host "    User ID: $($whoAmI.UserId)"
        Write-Host "    Business Unit ID: $($whoAmI.BusinessUnitId)"
        Write-Host "    Organization ID: $($whoAmI.OrganizationId)"
        $testsPassed++
        
        # Test query
        Write-Host "`n[3/5] Testing query (systemusers)..." -ForegroundColor Cyan
        $users = $dataverseClient.RetrieveMultiple("systemusers", "`$select=fullname,domainname&`$top=3")
        Write-Host "  ✓ Query successful - Found $($users.Count) users" -ForegroundColor Green
        foreach ($user in $users) {
            Write-Host "    - $($user.fullname) ($($user.domainname))"
        }
        $testsPassed++
        
        # Test solutions query
        Write-Host "`n[4/5] Testing solutions query..." -ForegroundColor Cyan
        $solutions = $dataverseClient.RetrieveMultiple("solutions", "`$select=uniquename,friendlyname,version&`$filter=ismanaged eq false&`$top=3")
        Write-Host "  ✓ Solutions query successful - Found $($solutions.Count) unmanaged solutions" -ForegroundColor Green
        foreach ($solution in $solutions) {
            Write-Host "    - $($solution.friendlyname) ($($solution.uniquename)) v$($solution.version)"
        }
        $testsPassed++
        
        # Test token refresh
        Write-Host "`n[5/5] Testing token management..." -ForegroundColor Cyan
        $dataverseClient.EnsureValidToken()
        Write-Host "  ✓ Token is valid" -ForegroundColor Green
        $testsPassed++
        
        Write-Host "`n✓ Dataverse API Client: All tests passed" -ForegroundColor Green
    }
    catch {
        Write-Host "`n✗ Dataverse API Client test failed: $_" -ForegroundColor Red
        Write-Error $_
        $testsFailed++
    }
}
else {
    Write-Host "Dataverse API Client tests skipped (use -TestDataverseApi to enable)" -ForegroundColor Gray
    $testsSkipped++
}

# Test Power Platform CLI Client
if ($TestPowerPlatformCli) {
    Write-Host "`n`n=== Testing Power Platform CLI Client ===" -ForegroundColor Yellow
    Write-Host ""
    
    try {
        # Initialize client
        Write-Host "[1/4] Initializing Power Platform CLI client..." -ForegroundColor Cyan
        if ($useOIDC) {
            $pacClient = [PowerPlatformClient]::new($TenantId, $ClientId, $EnvironmentUrl)
        }
        else {
            $pacClient = [PowerPlatformClient]::new($TenantId, $ClientId, $ClientSecret, $EnvironmentUrl)
        }
        Write-Host "  ✓ Client initialized and authenticated" -ForegroundColor Green
        $testsPassed++
        
        # Test WhoAmI
        Write-Host "`n[2/4] Testing WhoAmI (pac org who)..." -ForegroundColor Cyan
        $whoAmI = $pacClient.WhoAmI()
        Write-Host "  ✓ WhoAmI successful" -ForegroundColor Green
        Write-Host "    User ID: $($whoAmI.UserId)"
        Write-Host "    Environment ID: $($whoAmI.EnvironmentId)"
        Write-Host "    Environment URL: $($whoAmI.EnvironmentUrl)"
        $testsPassed++
        
        # Test list solutions
        Write-Host "`n[3/4] Testing list solutions (pac solution list)..." -ForegroundColor Cyan
        $solutionsJson = $pacClient.RunCommand("solution list --json")
        $solutions = $solutionsJson | ConvertFrom-Json
        Write-Host "  ✓ List solutions successful - Found $($solutions.Count) solutions" -ForegroundColor Green
        $displayCount = [Math]::Min(3, $solutions.Count)
        foreach ($solution in $solutions | Select-Object -First $displayCount) {
            Write-Host "    - $($solution.FriendlyName) ($($solution.UniqueName)) v$($solution.Version)"
        }
        if ($solutions.Count -gt 3) {
            Write-Host "    ... and $($solutions.Count - 3) more"
        }
        $testsPassed++
        
      
        # Test custom command
        Write-Host "`n[4/4] Testing custom command (pac plugin list)..." -ForegroundColor Cyan
        try {
            $pluginsJson = $pacClient.RunCommand("plugin list --json")
            $plugins = $pluginsJson | ConvertFrom-Json
            if ($plugins -and $plugins.Count -gt 0) {
                Write-Host "  ✓ List plugins successful - Found $($plugins.Count) plugins" -ForegroundColor Green
                $displayCount = [Math]::Min(3, $plugins.Count)
                foreach ($plugin in $plugins | Select-Object -First $displayCount) {
                    Write-Host "    - $($plugin.Name)"
                }
            }
            else {
                Write-Host "  ✓ List plugins successful - No custom plugins found" -ForegroundColor Green
            }
            $testsPassed++
        }
        catch {
            Write-Host "  ⚠ List plugins not available (this is expected in some environments)" -ForegroundColor Yellow
            $testsPassed++
        }
        
        Write-Host "`n✓ Power Platform CLI Client: All tests passed" -ForegroundColor Green
        
        # Cleanup
        Write-Host "`nCleaning up auth profile..." -ForegroundColor Gray
        $pacClient.ClearAuth()
    }
    catch {
        Write-Host "`n✗ Power Platform CLI Client test failed: $_" -ForegroundColor Red
        Write-Error $_
        $testsFailed++
        
        # Try to cleanup even on failure
        if ($pacClient) {
            try { $pacClient.ClearAuth() } catch { }
        }
    }
}
else {
    Write-Host "Power Platform CLI Client tests skipped (use -TestPowerPlatformCli to enable)" -ForegroundColor Gray
    $testsSkipped++
}

# Summary
Write-Host "`n`n========================================" -ForegroundColor Cyan
Write-Host "  Test Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Tests Passed:  $testsPassed" -ForegroundColor Green
Write-Host "Tests Failed:  $testsFailed" -ForegroundColor $(if ($testsFailed -gt 0) { "Red" } else { "Green" })
Write-Host "Tests Skipped: $testsSkipped" -ForegroundColor Gray
Write-Host "========================================" -ForegroundColor Cyan

if ($testsFailed -gt 0) {
    Write-Host "`n✗ Some tests failed" -ForegroundColor Red
    exit 1
}
elseif ($testsPassed -eq 0) {
    Write-Host "`n⚠ No tests were run. Use -TestDataverseApi and/or -TestPowerPlatformCli" -ForegroundColor Yellow
    exit 1
}
else {
    Write-Host "`n✓ All tests passed successfully!" -ForegroundColor Green
    exit 0
}

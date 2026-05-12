<#
.SYNOPSIS
    Creates or updates a managed identity linked to a plugin package using pac managed-identity.

.DESCRIPTION
    Dataverse managed identity allows plugin packages to call external services (e.g., Azure,
    Microsoft Graph) using an Azure AD app registration without storing secrets in the plugin.

    This script wraps 'pac managed-identity' commands and is idempotent:
      1. Looks up the plugin package record GUID by unique name.
      2. Calls 'pac managed-identity get' to check whether an identity is already linked.
      3. Calls 'pac managed-identity create' (new) or 'pac managed-identity update' (existing).
      4. Optionally calls 'pac managed-identity configure-fic' to create the federated identity
         credential on the Azure AD app registration (requires Azure permissions).
      5. Optionally calls 'pac managed-identity verify-fic' to confirm the FIC is in place.

    Prerequisites:
      - pac CLI installed and authenticated for the target environment
        (run 'pac auth create --interactive --environment {url}' if needed)
      - Plugin package must already be pushed to the environment (run Register-Plugin.ps1 first)
      - The Azure AD app registration must already exist with the correct Application ID

.PARAMETER EnvironmentUrl
    Dataverse environment URL (e.g., 'https://myorg.crm.dynamics.com').
    If omitted, uses the active pac auth profile's selected environment.

.PARAMETER ApplicationId
    Azure AD app registration Application (client) ID as a GUID.

.PARAMETER AadTenantId
    Azure AD tenant ID as a GUID.

.PARAMETER PluginPackageUniqueName
    Unique name of the plugin package record in Dataverse to link.
    This is the 'uniquename' from the pluginpackage.xml in source control
    (typically publisher-prefixed, e.g., 'pub_Publisher.Plugins.MySolution.Feature').

.PARAMETER PluginPackageId
    Dataverse record GUID of the plugin package. Use this instead of -PluginPackageUniqueName
    if you already know the GUID (avoids the Web API lookup).

.PARAMETER ComponentType
    Dataverse component type string for pac managed-identity. Defaults to 'PluginPackage'.
    Other supported values: 'PluginAssembly', 'ServiceEndpoint', 'CopilotStudio'.

.PARAMETER ConfigureFic
    After creating/updating the managed identity, also run 'pac managed-identity configure-fic'
    to create the federated identity credential on the Azure AD app registration.
    Requires Azure AD permissions (Application.ReadWrite.All or Owner on the app registration).

.PARAMETER VerifyFic
    Run 'pac managed-identity verify-fic' to confirm the federated identity credential exists.

.PARAMETER GetOnly
    Show the managed identity currently linked to the component and exit. No changes made.

.EXAMPLE
    # Create managed identity and link to plugin package
    .\Configure-ManagedIdentity.ps1 `
        -EnvironmentUrl "https://myorg.crm.dynamics.com" `
        -ApplicationId "00000000-0000-0000-0000-000000000001" `
        -AadTenantId "00000000-0000-0000-0000-000000000002" `
        -PluginPackageUniqueName "pub_Publisher.Plugins.MySolution.Feature"

.EXAMPLE
    # Create MI + configure federated identity credential on Azure AD + verify
    .\Configure-ManagedIdentity.ps1 `
        -EnvironmentUrl "https://myorg.crm.dynamics.com" `
        -ApplicationId "00000000-0000-0000-0000-000000000001" `
        -AadTenantId "00000000-0000-0000-0000-000000000002" `
        -PluginPackageUniqueName "pub_Publisher.Plugins.MySolution.Feature" `
        -ConfigureFic -VerifyFic

.EXAMPLE
    # Show the current managed identity for a package (no changes)
    .\Configure-ManagedIdentity.ps1 `
        -EnvironmentUrl "https://myorg.crm.dynamics.com" `
        -PluginPackageId "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" `
        -GetOnly

.EXAMPLE
    # Skip lookup — pass the GUID directly
    .\Configure-ManagedIdentity.ps1 `
        -EnvironmentUrl "https://myorg.crm.dynamics.com" `
        -ApplicationId "00000000-0000-0000-0000-000000000001" `
        -AadTenantId "00000000-0000-0000-0000-000000000002" `
        -PluginPackageId "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
#>
[CmdletBinding(DefaultParameterSetName = 'ByUniqueName')]
param(
    [string]$EnvironmentUrl,

    # Identify the plugin package — by unique name (lookup) or by GUID (direct)
    [Parameter(ParameterSetName = 'ByUniqueName', Mandatory)]
    [string]$PluginPackageUniqueName,

    [Parameter(ParameterSetName = 'ByGuid', Mandatory)]
    [string]$PluginPackageId,

    # Required for create/update (not needed for -GetOnly)
    [Parameter(ParameterSetName = 'ByUniqueName')]
    [Parameter(ParameterSetName = 'ByGuid')]
    [ValidateScript({ [Guid]::TryParse($_, [ref]([Guid]::Empty)) })]
    [string]$ApplicationId,

    [Parameter(ParameterSetName = 'ByUniqueName')]
    [Parameter(ParameterSetName = 'ByGuid')]
    [ValidateScript({ [Guid]::TryParse($_, [ref]([Guid]::Empty)) })]
    [string]$AadTenantId,

    [string]$ComponentType = 'PluginPackage',

    [switch]$ConfigureFic,
    [switch]$VerifyFic,
    [switch]$GetOnly
)

$ErrorActionPreference = 'Stop'

# ─── Verify pac is available ──────────────────────────────────────────────────
if (-not (Get-Command pac -ErrorAction SilentlyContinue)) {
    throw "'pac' CLI not found. Install from https://aka.ms/PowerAppsCLI"
}

# ─── Resolve plugin package GUID if not supplied directly ────────────────────
if ($PSCmdlet.ParameterSetName -eq 'ByUniqueName') {
    Write-Host "Looking up plugin package '$PluginPackageUniqueName'..." -ForegroundColor DarkGray

    # Use the Dataverse API client for the lookup (already a dependency of Register-Plugin.ps1)
    . "$PSScriptRoot/DataverseApiClient.ps1"
    $client = [DataverseApiClient]::new($EnvironmentUrl)

    $encoded = [Uri]::EscapeDataString($PluginPackageUniqueName)
    $results = $client.RetrieveMultiple('pluginpackages',
        "?`$filter=uniquename eq '$encoded'&`$select=pluginpackageid,uniquename")

    if (-not $results -or $results.Count -eq 0) {
        throw "Plugin package '$PluginPackageUniqueName' not found in environment.`nPush the plugin package first via Register-Plugin.ps1."
    }
    $PluginPackageId = $results[0].pluginpackageid
    Write-Host "  Found: $PluginPackageId" -ForegroundColor DarkGray
}

# ─── Header ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Configure Managed Identity" -ForegroundColor Cyan
if ($EnvironmentUrl) {
    Write-Host "  Environment  : $EnvironmentUrl" -ForegroundColor Cyan
}
Write-Host "  Component    : $ComponentType ($PluginPackageId)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# ─── Build common pac args ────────────────────────────────────────────────────
$pacEnvArgs = if ($EnvironmentUrl) { @('--environment', $EnvironmentUrl) } else { @() }

# ─── GetOnly — show current MI and exit ──────────────────────────────────────
if ($GetOnly) {
    Write-Host "Getting current managed identity..." -ForegroundColor DarkGray
    pac managed-identity get @pacEnvArgs --component-type $ComponentType --component-id $PluginPackageId
    exit $LASTEXITCODE
}

# ─── Require ApplicationId and AadTenantId for create/update ─────────────────
if (-not $ApplicationId -or -not $AadTenantId) {
    throw "-ApplicationId and -AadTenantId are required unless using -GetOnly."
}

Write-Host "Application ID : $ApplicationId"
Write-Host "AAD Tenant ID  : $AadTenantId"
Write-Host ""

# ─── Check if a managed identity is already linked ───────────────────────────
Write-Host "Checking for existing managed identity on component..." -ForegroundColor DarkGray
$getOutput = pac managed-identity get @pacEnvArgs --component-type $ComponentType --component-id $PluginPackageId 2>&1
$alreadyLinked = $LASTEXITCODE -eq 0 -and ($getOutput | Select-String -Quiet 'applicationid|application id|managed.identity')

if ($alreadyLinked) {
    Write-Host "Existing managed identity found — updating..." -ForegroundColor DarkGray
    pac managed-identity update @pacEnvArgs `
        --component-type $ComponentType `
        --component-id   $PluginPackageId `
        --tenant-id      $AadTenantId `
        --application-id $ApplicationId
    if ($LASTEXITCODE -ne 0) { throw "pac managed-identity update failed." }
    Write-Host "Managed identity updated." -ForegroundColor Green
}
else {
    Write-Host "No existing managed identity — creating..." -ForegroundColor DarkGray
    pac managed-identity create @pacEnvArgs `
        --component-type $ComponentType `
        --component-id   $PluginPackageId `
        --tenant-id      $AadTenantId `
        --application-id $ApplicationId
    if ($LASTEXITCODE -ne 0) { throw "pac managed-identity create failed." }
    Write-Host "Managed identity created and linked." -ForegroundColor Green
}

# ─── Configure federated identity credential on Azure AD (optional) ───────────
if ($ConfigureFic) {
    Write-Host ""
    Write-Host "Configuring federated identity credential on Azure AD app..." -ForegroundColor DarkGray
    Write-Host "(Requires Application.ReadWrite.All or Owner on the app registration)" -ForegroundColor DarkGray
    pac managed-identity configure-fic @pacEnvArgs --component-type $ComponentType --component-id $PluginPackageId
    if ($LASTEXITCODE -ne 0) { throw "pac managed-identity configure-fic failed." }
    Write-Host "Federated identity credential configured." -ForegroundColor Green
}

# ─── Verify federated identity credential (optional) ─────────────────────────
if ($VerifyFic) {
    Write-Host ""
    Write-Host "Verifying federated identity credential..." -ForegroundColor DarkGray
    pac managed-identity verify-fic @pacEnvArgs --component-type $ComponentType --component-id $PluginPackageId
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "verify-fic reported issues. Review output above."
    }
    else {
        Write-Host "Federated identity credential verified." -ForegroundColor Green
    }
}

# ─── Done ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Managed identity configured successfully" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
if (-not $ConfigureFic) {
    Write-Host "Tip: pass -ConfigureFic to also create the federated identity credential" -ForegroundColor DarkGray
    Write-Host "  on the Azure AD app registration (requires Azure AD permissions)." -ForegroundColor DarkGray
    Write-Host ""
}

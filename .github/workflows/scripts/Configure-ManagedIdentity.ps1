<#
.SYNOPSIS
    Creates or updates a managed identity in Dataverse and links it to a plugin package.

.DESCRIPTION
    Dataverse managed identity allows plugin packages to call external services (e.g., Azure,
    Microsoft Graph) using an Azure AD app registration without storing secrets in the plugin.

    This script:
      1. Creates or updates a 'managedidentity' record in Dataverse (matched by ApplicationId
         + TenantId so it is idempotent).
      2. Links the managed identity to the specified plugin package by setting
         pluginpackage.managedidentityid.

    The managed identity record uses:
      - credentialsource = 2 (Managed — uses Azure AD workload identity, not client secret)
      - subjectscope     = 1 (Environment scope)

    Prerequisites:
      - Plugin package must already be pushed to the environment (run Register-Plugin.ps1 first)
      - The Azure AD app registration must already exist with the correct Application ID
      - pac auth must be configured for the target environment OR provide -TenantId + -ClientId
        for federated (OIDC) authentication

.PARAMETER EnvironmentUrl
    Dataverse environment URL (e.g., 'https://myorg.crm.dynamics.com').

.PARAMETER ManagedIdentityName
    Display name for the managed identity record in Dataverse.

.PARAMETER ApplicationId
    Azure AD app registration Application (client) ID as a GUID.

.PARAMETER AadTenantId
    Azure AD tenant ID as a GUID.

.PARAMETER PluginPackageUniqueName
    Unique name of the plugin package record in Dataverse to link.
    This is the 'uniquename' from the pluginpackage.xml in source control
    (typically publisher-prefixed, e.g., 'pub_Publisher.Plugins.MySolution.Feature').

.PARAMETER TenantId
    (Authentication) Azure AD tenant ID for OIDC / federated auth. If omitted, uses
    the active pac auth profile. Do not confuse with -AadTenantId (the managed identity tenant).

.PARAMETER ClientId
    (Authentication) Service principal client ID for OIDC / federated auth.

.PARAMETER ListOnly
    List existing user-created managed identities and exit without making changes.
    Useful for verifying what is already registered.

.EXAMPLE
    # Create managed identity and link to plugin package
    .\Configure-ManagedIdentity.ps1 `
        -EnvironmentUrl "https://myorg.crm.dynamics.com" `
        -ManagedIdentityName "MyProject Plugin Identity" `
        -ApplicationId "00000000-0000-0000-0000-000000000001" `
        -AadTenantId "00000000-0000-0000-0000-000000000002" `
        -PluginPackageUniqueName "pub_Publisher.Plugins.MySolution.Feature"

.EXAMPLE
    # List existing managed identities (no changes)
    .\Configure-ManagedIdentity.ps1 `
        -EnvironmentUrl "https://myorg.crm.dynamics.com" `
        -ListOnly

.EXAMPLE
    # Federated auth (CI/CD)
    .\Configure-ManagedIdentity.ps1 `
        -EnvironmentUrl "https://myorg.crm.dynamics.com" `
        -ManagedIdentityName "MyProject Plugin Identity" `
        -ApplicationId "00000000-0000-0000-0000-000000000001" `
        -AadTenantId "00000000-0000-0000-0000-000000000002" `
        -PluginPackageUniqueName "pub_Publisher.Plugins.MySolution.Feature" `
        -TenantId "00000000-0000-0000-0000-000000000002" `
        -ClientId "00000000-0000-0000-0000-000000000003"
#>
[CmdletBinding(DefaultParameterSetName = 'Configure')]
param(
    [Parameter(Mandatory)]
    [string]$EnvironmentUrl,

    [Parameter(ParameterSetName = 'Configure', Mandatory)]
    [string]$ManagedIdentityName,

    [Parameter(ParameterSetName = 'Configure', Mandatory)]
    [ValidateScript({ [Guid]::TryParse($_, [ref]([Guid]::Empty)) })]
    [string]$ApplicationId,

    [Parameter(ParameterSetName = 'Configure', Mandatory)]
    [ValidateScript({ [Guid]::TryParse($_, [ref]([Guid]::Empty)) })]
    [string]$AadTenantId,

    [Parameter(ParameterSetName = 'Configure', Mandatory)]
    [string]$PluginPackageUniqueName,

    # Auth (optional — falls back to pac auth profile)
    [string]$TenantId,
    [string]$ClientId,

    [Parameter(ParameterSetName = 'List')]
    [switch]$ListOnly
)

$ErrorActionPreference = 'Stop'

# Source the Dataverse API client (same pattern as Register-Plugin.ps1)
. "$PSScriptRoot/DataverseApiClient.ps1"

#region Helper Functions

function Initialize-ApiClient {
    param([string]$EnvironmentUrl, [string]$TenantId, [string]$ClientId)
    if ($TenantId -and $ClientId) {
        Write-Host "Authenticating with federated credentials..."
        return [DataverseApiClient]::new($TenantId, $ClientId, $EnvironmentUrl)
    }
    elseif ($TenantId) {
        Write-Host "Authenticating interactively (tenant-scoped: $TenantId)..."
        return [DataverseApiClient]::new($EnvironmentUrl, $TenantId)
    }
    else {
        Write-Host "Authenticating with interactive pac auth profile..."
        return [DataverseApiClient]::new($EnvironmentUrl)
    }
}

function Get-OrCreateManagedIdentity {
    <#
    Idempotent create/update of a managedidentity record.
    Matches on ApplicationId + TenantId — the combination is the stable identity key.
    Returns the managed identity GUID.
    #>
    param(
        [DataverseApiClient]$Client,
        [string]$Name,
        [string]$ApplicationId,
        [string]$AadTenantId
    )

    Write-Host "Looking for existing managed identity (appId=$ApplicationId, tenantId=$AadTenantId)..." -ForegroundColor DarkGray

    $filter = "applicationid eq $ApplicationId and tenantid eq $AadTenantId"
    $existing = $Client.RetrieveMultiple('managedidentities',
        "?`$filter=$filter&`$select=managedidentityid,name,applicationid,tenantid,credentialsource,subjectscope")

    if ($existing -and $existing.Count -gt 0) {
        $record = $existing[0]
        $currentName = $record.name
        Write-Host "Found existing managed identity: '$currentName' ($($record.managedidentityid))" -ForegroundColor Cyan

        if ($currentName -ne $Name) {
            Write-Host "  Updating name: '$currentName' -> '$Name'" -ForegroundColor DarkGray
            $Client.Update('managedidentities', $record.managedidentityid, @{ name = $Name })
            Write-Host "  Name updated." -ForegroundColor Green
        }
        else {
            Write-Host "  Name unchanged — no update needed." -ForegroundColor DarkGray
        }

        return $record.managedidentityid
    }

    # Create new record
    Write-Host "Creating managed identity: '$Name'" -ForegroundColor DarkGray
    $body = @{
        name             = $Name
        applicationid    = $ApplicationId
        tenantid         = $AadTenantId
        credentialsource = 2   # Managed (Azure AD workload identity)
        subjectscope     = 1   # Environment scope
    }

    $newId = New-DataverseRecord -Client $Client -EntityName 'managedidentities' -Data $body
    Write-Host "Created managed identity: '$Name' ($newId)" -ForegroundColor Green
    return $newId
}

function New-DataverseRecord {
    param([DataverseApiClient]$Client, [string]$EntityName, [hashtable]$Data)

    $Client.EnsureValidToken()
    $url = "https://$($Client.DataverseHost)/api/data/v9.2/$EntityName"
    $headers = @{
        "Authorization"    = "Bearer $($Client.AccessToken)"
        "Content-Type"     = "application/json"
        "OData-MaxVersion" = "4.0"
        "OData-Version"    = "4.0"
    }
    $body = $Data | ConvertTo-Json -Depth 10

    $response = Invoke-WebRequest -Uri $url -Method Post -Headers $headers -Body $body -UseBasicParsing
    $entityIdHeader = $response.Headers['OData-EntityId']
    if ($entityIdHeader -is [System.Collections.IEnumerable] -and $entityIdHeader -isnot [string]) {
        $entityIdHeader = $entityIdHeader | Select-Object -First 1
    }
    if ([string]$entityIdHeader -match '\(([0-9a-fA-F-]+)\)') {
        return $Matches[1]
    }
    throw "Failed to extract record ID from OData-EntityId header for '$EntityName'"
}

function Set-PluginPackageManagedIdentity {
    <#
    Links (or verifies the link of) a managed identity to a plugin package.
    Idempotent — skips the update if the link is already correct.
    #>
    param(
        [DataverseApiClient]$Client,
        [string]$PluginPackageUniqueName,
        [string]$ManagedIdentityId
    )

    Write-Host "Looking up plugin package '$PluginPackageUniqueName'..." -ForegroundColor DarkGray

    $encoded = [Uri]::EscapeDataString($PluginPackageUniqueName)
    $results = $Client.RetrieveMultiple('pluginpackages',
        "?`$filter=uniquename eq '$encoded'&`$select=pluginpackageid,name,uniquename,_managedidentityid_value")

    if (-not $results -or $results.Count -eq 0) {
        throw "Plugin package '$PluginPackageUniqueName' not found in environment '$($Client.DataverseHost)'.`nPush the plugin package first (Register-Plugin.ps1) before configuring managed identity."
    }

    $pkg = $results[0]
    $pkgId = $pkg.pluginpackageid
    $currentMiId = $pkg.'_managedidentityid_value'

    if ($currentMiId -and $currentMiId -eq $ManagedIdentityId) {
        Write-Host "Plugin package '$($pkg.uniquename)' is already linked to managed identity ($ManagedIdentityId)." -ForegroundColor Cyan
        return
    }

    Write-Host "Linking managed identity to plugin package '$($pkg.uniquename)'..." -ForegroundColor DarkGray
    $Client.Update('pluginpackages', $pkgId, @{
        'managedidentityid@odata.bind' = "/managedidentities($ManagedIdentityId)"
    })
    Write-Host "Plugin package linked to managed identity." -ForegroundColor Green
}

function Show-ManagedIdentities {
    <# Lists all user-created managed identities for diagnostics. #>
    param([DataverseApiClient]$Client)

    Write-Host ""
    Write-Host "Listing managed identities (user-created)..." -ForegroundColor DarkGray

    # Filter out SYSTEM-created identities via linked entity
    $odata = "?`$select=managedidentityid,name,applicationid,tenantid,credentialsource" +
             "&`$expand=createdby(`$select=fullname)" +
             "&`$filter=createdby/fullname ne 'SYSTEM'"

    $identities = $Client.RetrieveMultiple('managedidentities', $odata)

    if (-not $identities -or $identities.Count -eq 0) {
        Write-Host "No user-created managed identities found." -ForegroundColor Yellow
        return
    }

    $credSourceNames = @{ 0 = 'ClientSecret'; 1 = 'KeyVault'; 2 = 'Managed'; 3 = 'MSFirstPartyCert' }

    Write-Host "Found $($identities.Count) managed identities:" -ForegroundColor Cyan
    foreach ($id in $identities) {
        $credName = $credSourceNames[[int]$id.credentialsource] ?? "Unknown($($id.credentialsource))"
        Write-Host ""
        Write-Host "  Name             : $($id.name)"
        Write-Host "  ID               : $($id.managedidentityid)"
        Write-Host "  Application ID   : $($id.applicationid)"
        Write-Host "  Tenant ID        : $($id.tenantid)"
        Write-Host "  Credential source: $credName"
    }
    Write-Host ""
}

#endregion

#region Main

Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Configure Managed Identity" -ForegroundColor Cyan
Write-Host "  Environment: $EnvironmentUrl" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

$client = Initialize-ApiClient -EnvironmentUrl $EnvironmentUrl -TenantId $TenantId -ClientId $ClientId

if ($ListOnly) {
    Show-ManagedIdentities -Client $client
    exit 0
}

Write-Host "Managed Identity Name : $ManagedIdentityName"
Write-Host "Application ID        : $ApplicationId"
Write-Host "AAD Tenant ID         : $AadTenantId"
Write-Host "Plugin Package        : $PluginPackageUniqueName"
Write-Host ""

# Step 1 — Create or update the managed identity record
$managedIdentityId = Get-OrCreateManagedIdentity `
    -Client $client `
    -Name $ManagedIdentityName `
    -ApplicationId $ApplicationId `
    -AadTenantId $AadTenantId

# Step 2 — Link managed identity to the plugin package
Set-PluginPackageManagedIdentity `
    -Client $client `
    -PluginPackageUniqueName $PluginPackageUniqueName `
    -ManagedIdentityId $managedIdentityId

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Managed identity configured successfully" -ForegroundColor Green
Write-Host "  ID: $managedIdentityId" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next: ensure the Azure AD app registration has the correct" -ForegroundColor DarkGray
Write-Host "  API permissions and federated credentials for this environment." -ForegroundColor DarkGray
Write-Host ""

#endregion

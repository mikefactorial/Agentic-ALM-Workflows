---
name: configure-managed-identity
description: 'Configure a Dataverse managed identity for a plugin package. Use when: a plugin needs to call external services (Azure, Graph, etc.) using a managed identity; signing a plugin NuGet package; creating or linking a managedidentity record in Dataverse; configuring an Azure AD app registration for plugin use.'
---

# Configure Managed Identity for a Plugin Package

Set up a Dataverse managed identity so plugin packages can call external services (Azure, Microsoft Graph, custom APIs) using an Azure AD app registration — no secrets stored in plugin code.

## When to Use

- A plugin needs to use `localPluginContext.ManagedIdentityService` to acquire tokens
- You are registering a plugin package and need it linked to an Azure AD identity
- After pushing a plugin package, to create/update the `managedidentity` record and link it
- To list existing managed identities in an environment for verification

## Skill boundaries

| Need | Use instead |
|------|-------------|
| Push the plugin binary / register steps | `register-plugin` (use `-ManagedIdentity*` params for combined flow) |
| Set up OIDC federated credentials for GitHub Actions → Dataverse auth | `setup-oidc` |
| Scaffold a new plugin project | `scaffold-plugin` |

## Prerequisites

Before running this workflow:
1. **Plugin package is already pushed** to the environment (via `register-plugin`). The `pluginpackage` record must exist.
2. **Azure AD app registration exists** with the correct Application ID.
3. **pac auth profile** is configured for the target environment, OR `-TenantId` + `-ClientId` are provided for federated auth.

## Required Information — Gather Before Proceeding

| Item | Source |
|------|--------|
| Environment URL | `innerLoopEnvironments[].url` from `environment-config.json` |
| Managed identity display name | User — descriptive name (e.g., `"MyProject Plugin Identity"`) |
| Azure AD Application (client) ID | User — from Azure AD app registration |
| Azure AD Tenant ID | User — from Azure AD (or read from `environment-config.json` if stored) |
| Plugin package unique name | Solution XML at `src/solutions/{solution}/src/pluginpackages/{name}/pluginpackage.xml` → `uniquename` field |
| Code-signing certificate | User — PFX file path + password, or Windows store fingerprint |

---

## Procedure

### 1. Locate the Plugin Package Unique Name

Read from the solution XML to get the exact `uniquename` (not `name`) of the plugin package:

```powershell
# Path: src/solutions/{solution}/src/pluginpackages/{PackageName}/pluginpackage.xml
[xml]$xml = Get-Content "src/solutions/{solution}/src/pluginpackages/{PackageName}/pluginpackage.xml" -Raw
$xml.pluginpackage.uniquename   # Use this as -PluginPackageUniqueName
```

### 2. Obtain a Code-Signing Certificate

Plugin packages linked to managed identities must be signed. Choose one:

**Option A — Dev / self-signed (Windows only):**
```powershell
# Generate a self-signed code-signing certificate valid for 1 year
$cert = New-SelfSignedCertificate `
    -Type CodeSigning `
    -Subject "CN={ProjectName}PluginSigning" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -NotAfter (Get-Date).AddYears(1)

# Get the fingerprint (use with -SignCertificateFingerprint)
$cert.Thumbprint
```

**Option B — PFX file (CI/CD or team-shared):**
Obtain from your PKI / Azure Key Vault and save locally. Never commit to source control.

### 3. Sign the Plugin Package

Run before pushing if the package is not yet signed, or use the combined flow in Step 4.

```powershell
# Using Windows certificate store (dev)
.platform/.github/workflows/scripts/Sign-PluginPackage.ps1 `
    -PackagePath "src/plugins/{solutionFolder}/{ProjectDir}/bin/Debug/{PackageName}.{version}.nupkg" `
    -CertificateFingerprint "{cert_thumbprint}"

# Using PFX file (CI/CD)
.platform/.github/workflows/scripts/Sign-PluginPackage.ps1 `
    -PackagePath "path/to/plugin.nupkg" `
    -CertificatePath "path/to/signing.pfx" `
    -CertificatePassword "{password}" `
    -Timestamper "http://timestamp.digicert.com"
```

### 4. Push + Sign + Configure Managed Identity (Combined — Recommended)

The `register-plugin` script handles signing and managed identity configuration as part of the standard push flow when you pass the additional parameters:

```powershell
.platform/.github/workflows/scripts/Register-Plugin.ps1 `
    -EnvironmentUrl "{devEnv_url}" `
    -SolutionPath "src/solutions/{solution}" `
    -PluginName "{PluginPackageName}" `
    -RegisterSteps `
    -SolutionName "{featureSolution}" `
    -SignPackage `
    -SignCertificateFingerprint "{cert_thumbprint}" `
    -ManagedIdentityName "{display name}" `
    -ManagedIdentityApplicationId "{azure_app_id_guid}" `
    -ManagedIdentityTenantId "{azure_tenant_id_guid}"
```

For PFX-based signing:
```powershell
.platform/.github/workflows/scripts/Register-Plugin.ps1 `
    -EnvironmentUrl "{devEnv_url}" `
    -SolutionPath "src/solutions/{solution}" `
    -PluginName "{PluginPackageName}" `
    -RegisterSteps `
    -SolutionName "{featureSolution}" `
    -SignPackage `
    -SignCertificatePath "certs/signing.pfx" `
    -SignCertificatePassword "{password}" `
    -SignTimestamper "http://timestamp.digicert.com" `
    -ManagedIdentityName "{display name}" `
    -ManagedIdentityApplicationId "{azure_app_id_guid}" `
    -ManagedIdentityTenantId "{azure_tenant_id_guid}"
```

Execution order: sign → push → create/update `managedidentity` record → link to `pluginpackage`.

### 5. Configure Managed Identity Only (Already Pushed)

If the package is already in the environment and only the managed identity link is missing:

```powershell
.platform/.github/workflows/scripts/Configure-ManagedIdentity.ps1 `
    -EnvironmentUrl "{devEnv_url}" `
    -ManagedIdentityName "{display name}" `
    -ApplicationId "{azure_app_id_guid}" `
    -AadTenantId "{azure_tenant_id_guid}" `
    -PluginPackageUniqueName "{uniquename from pluginpackage.xml}"
```

### 6. Verify

```powershell
# List all user-created managed identities
.platform/.github/workflows/scripts/Configure-ManagedIdentity.ps1 `
    -EnvironmentUrl "{devEnv_url}" `
    -ListOnly
```

Check in the environment:
- **make.powerapps.com → Settings → Managed identities** — confirm the record exists
- **Plugin Registration Tool** or solution XML — confirm `managedidentityid` is set on the package

### 7. Azure AD Configuration

After creating the managed identity record, ensure the Azure AD app registration is configured:

- **API permissions**: Grant the permissions the plugin needs (e.g., `https://service.crm.dynamics.com/user_impersonation` for Dataverse, or Graph API scopes)
- **Federated credentials** (optional, for CI/CD): Add a federated credential if the plugin needs to authenticate from GitHub Actions as well

---

## How It Works

```
Plugin code calls:
  localPluginContext.ManagedIdentityService.AcquireToken(resource)

Dataverse checks:
  pluginpackage.managedidentityid → managedidentity.applicationid + tenantid

Dataverse issues:
  Token for the app registration on behalf of the plugin package
```

The `credentialsource = 2` (Managed) means Dataverse uses Azure AD workload identity — no client secrets or certificates are stored in Dataverse. The package signing is how Dataverse verifies the .nupkg hasn't been tampered with.

---

## Parameter Reference

### `Sign-PluginPackage.ps1`

| Parameter | Description |
|---|---|
| `-PackagePath` | Path to the .nupkg to sign |
| `-CertificatePath` | PFX file path (PFX mode) |
| `-CertificatePassword` | PFX password (PFX mode) |
| `-CertificateFingerprint` | Certificate thumbprint in Windows store (Store mode) |
| `-CertificateStoreLocation` | `CurrentUser` or `LocalMachine` (default: `CurrentUser`) |
| `-CertificateStoreName` | Store name (default: `My`) |
| `-Timestamper` | RFC 3161 TSA URL (recommended for production) |
| `-Overwrite` | Overwrite existing signature |

### `Configure-ManagedIdentity.ps1`

| Parameter | Description |
|---|---|
| `-EnvironmentUrl` | Dataverse environment URL |
| `-ManagedIdentityName` | Display name for the managed identity record |
| `-ApplicationId` | Azure AD app registration Application (client) ID |
| `-AadTenantId` | Azure AD tenant ID |
| `-PluginPackageUniqueName` | `uniquename` from `pluginpackage.xml` |
| `-TenantId` | Auth: AAD tenant for OIDC/federated auth |
| `-ClientId` | Auth: Service principal client ID for OIDC/federated auth |
| `-ListOnly` | List existing managed identities and exit |

### `Register-Plugin.ps1` — Additional Managed Identity Parameters

| Parameter | Description |
|---|---|
| `-SignPackage` | Sign the .nupkg before pushing |
| `-SignCertificatePath` | PFX certificate path for signing |
| `-SignCertificatePassword` | PFX password for signing |
| `-SignCertificateFingerprint` | Windows store certificate fingerprint for signing |
| `-SignCertificateStoreLocation` | Store location (default: `CurrentUser`) |
| `-SignCertificateStoreName` | Store name (default: `My`) |
| `-SignTimestamper` | TSA URL for package timestamping |
| `-ManagedIdentityName` | Display name for managed identity |
| `-ManagedIdentityApplicationId` | Azure AD Application ID for the managed identity |
| `-ManagedIdentityTenantId` | Azure AD Tenant ID (defaults to `-TenantId` auth param) |

---

## Troubleshooting

- **"Plugin package not found"**: Push the package first via `Register-Plugin.ps1` (without `-ManagedIdentityName`) before configuring managed identity
- **"dotnet nuget sign failed"**: Ensure the .NET SDK is installed (`dotnet --version`) and the certificate is valid for code signing (Key Usage must include Digital Signature)
- **Token acquisition fails at runtime**: Verify the Azure AD app has the correct API permissions and the `managedidentity` record in Dataverse has the right `applicationid` and `tenantid`
- **Self-signed cert not trusted**: Self-signed certs work for dev environments; production requires a CA-issued certificate or `dotnet nuget verify` will warn

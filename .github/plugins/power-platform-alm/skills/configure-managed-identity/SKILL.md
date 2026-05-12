---
name: configure-managed-identity
description: 'Configure a Dataverse managed identity for a plugin package. Use when: a plugin needs to call external services (Azure, Graph, etc.) using a managed identity; signing a plugin NuGet package; creating or linking a managedidentity record in Dataverse via pac managed-identity; configuring or verifying federated identity credentials on an Azure AD app registration.'
---

# Configure Managed Identity for a Plugin Package

Set up a Dataverse managed identity so plugin packages can call external services (Azure, Microsoft Graph, custom APIs) using an Azure AD app registration — no secrets stored in plugin code.

## When to Use

- A plugin needs to use `localPluginContext.ManagedIdentityService` to acquire tokens
- You are registering a plugin package and need it linked to an Azure AD identity
- After pushing a plugin package, to create/update the managed identity link
- To configure or verify the federated identity credential (FIC) on the Azure AD app registration
- To inspect the current managed identity linked to a component (`pac managed-identity get`)

## Skill boundaries

| Need | Use instead |
|------|-------------|
| Push the plugin binary / register steps | `register-plugin` (use `-ManagedIdentity*` params for combined flow) |
| Set up OIDC federated credentials for GitHub Actions → Dataverse auth | `setup-oidc` |
| Scaffold a new plugin project | `scaffold-plugin` |
| Deploy a release package to test/prod with managed identity patched per environment | `deploy-package` — populate `managedIdentities[]` in `environment-config.json` |

> **Inner loop vs outer loop:** The scripts in this skill (`Configure-ManagedIdentity.ps1`, `Register-Plugin.ps1`) handle the **inner loop** — linking a managed identity to a plugin package in a dev environment. For **outer-loop** deployments (test/prod via `pac package deploy`), the correct `applicationId` and `tenantId` are injected at deploy time by `Deploy-Package.ps1` reading `packageGroups[].managedIdentities` from `environment-config.json`. You must populate that config for each environment where the package will be deployed, otherwise the solution retains the dev identity baked in at sync time.

## Prerequisites

Before running this workflow:
1. **Plugin package is already pushed** to the environment (via `register-plugin`). The `pluginpackage` record must exist.
2. **Azure AD app registration exists** with the correct Application ID.
3. **pac auth profile** is configured for the target environment (`pac auth create --interactive --environment {url}`).

## Required Information — Gather Before Proceeding

| Item | Source |
|------|--------|
| Environment URL | `innerLoopEnvironments[].url` from `environment-config.json` |
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

The `register-plugin` script handles signing and managed identity configuration as part of the standard push flow:

```powershell
.platform/.github/workflows/scripts/Register-Plugin.ps1 `
    -EnvironmentUrl "{devEnv_url}" `
    -SolutionPath "src/solutions/{solution}" `
    -PluginName "{PluginPackageName}" `
    -RegisterSteps `
    -SolutionName "{featureSolution}" `
    -SignPackage `
    -SignCertificateFingerprint "{cert_thumbprint}" `
    -ManagedIdentityApplicationId "{azure_app_id_guid}" `
    -ManagedIdentityTenantId "{azure_tenant_id_guid}" `
    -ConfigureFic `
    -VerifyFic
```

Execution order: sign → push → `pac managed-identity create/update` → (optionally) `pac managed-identity configure-fic` → `pac managed-identity verify-fic`.

### 5. Configure Managed Identity Only (Already Pushed)

If the package is already in the environment and only the managed identity link is missing:

```powershell
.platform/.github/workflows/scripts/Configure-ManagedIdentity.ps1 `
    -EnvironmentUrl "{devEnv_url}" `
    -ApplicationId "{azure_app_id_guid}" `
    -AadTenantId "{azure_tenant_id_guid}" `
    -PluginPackageUniqueName "{uniquename from pluginpackage.xml}"
```

To also configure + verify the federated identity credential on the Azure AD app:
```powershell
.platform/.github/workflows/scripts/Configure-ManagedIdentity.ps1 `
    -EnvironmentUrl "{devEnv_url}" `
    -ApplicationId "{azure_app_id_guid}" `
    -AadTenantId "{azure_tenant_id_guid}" `
    -PluginPackageUniqueName "{uniquename from pluginpackage.xml}" `
    -ConfigureFic -VerifyFic
```

### 6. Inspect / Verify

```powershell
# Show current managed identity for a component
.platform/.github/workflows/scripts/Configure-ManagedIdentity.ps1 `
    -EnvironmentUrl "{devEnv_url}" `
    -PluginPackageId "{pluginpackage_guid}" `
    -GetOnly

# Or call pac directly
pac managed-identity get --environment "{devEnv_url}" --component-type PluginPackage --component-id "{guid}"
pac managed-identity show-fic --environment "{devEnv_url}" --component-type PluginPackage --component-id "{guid}"
pac managed-identity verify-fic --environment "{devEnv_url}" --component-type PluginPackage --component-id "{guid}"
```

---

## How pac managed-identity Works

```
pac managed-identity create
  --component-type PluginPackage
  --component-id   {pluginpackage record GUID}
  --tenant-id      {azure_tenant_id}
  --application-id {azure_app_id}
```

Internally this creates the `managedidentity` record in Dataverse and links it to the plugin package in one operation. `update` can change the tenant/app IDs later.

`configure-fic` then creates the federated identity credential on the Azure AD app registration so Dataverse can issue tokens on behalf of the plugin. `verify-fic` confirms the credential is in place.

```
Plugin code calls:
  localPluginContext.ManagedIdentityService.AcquireToken(resource)

Dataverse checks:
  pluginpackage.managedidentityid → managed identity → applicationid + tenantid → FIC

Dataverse issues:
  Token for the app registration on behalf of the plugin package
```

The package signing is how Dataverse verifies the .nupkg hasn't been tampered with before allowing managed identity token acquisition.

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
| `-EnvironmentUrl` | Dataverse environment URL (optional — uses active pac auth if omitted) |
| `-PluginPackageUniqueName` | `uniquename` from `pluginpackage.xml` (script looks up the GUID) |
| `-PluginPackageId` | Plugin package GUID (use instead of unique name if you already have it) |
| `-ApplicationId` | Azure AD app registration Application (client) ID |
| `-AadTenantId` | Azure AD tenant ID |
| `-ComponentType` | pac component type (default: `PluginPackage`) |
| `-ConfigureFic` | Also run `pac managed-identity configure-fic` after create/update |
| `-VerifyFic` | Also run `pac managed-identity verify-fic` |
| `-GetOnly` | Show current MI and exit — no changes |

### `Register-Plugin.ps1` — Managed Identity Parameters

| Parameter | Description |
|---|---|
| `-SignPackage` | Sign the .nupkg before pushing |
| `-SignCertificatePath` | PFX certificate path for signing |
| `-SignCertificatePassword` | PFX password for signing |
| `-SignCertificateFingerprint` | Windows store certificate fingerprint for signing |
| `-SignCertificateStoreLocation` | Store location (default: `CurrentUser`) |
| `-SignCertificateStoreName` | Store name (default: `My`) |
| `-SignTimestamper` | TSA URL for package timestamping |
| `-ManagedIdentityApplicationId` | Azure AD Application ID for the managed identity |
| `-ManagedIdentityTenantId` | Azure AD Tenant ID (defaults to `-TenantId` auth param) |
| `-ConfigureFic` | Also configure FIC on Azure AD app after linking |
| `-VerifyFic` | Verify FIC after configure |

---

## Troubleshooting

- **"Plugin package not found"**: Push the package first via `Register-Plugin.ps1` before configuring managed identity
- **"dotnet nuget sign failed"**: Ensure the .NET SDK is installed (`dotnet --version`) and the certificate is valid for code signing (Key Usage must include Digital Signature)
- **`pac managed-identity create` fails**: Ensure pac is authenticated for the correct environment (`pac auth list`); verify the plugin package GUID is correct
- **`configure-fic` fails**: Requires `Application.ReadWrite.All` or Owner on the Azure AD app registration — may need an admin to run this step
- **Token acquisition fails at runtime**: Run `pac managed-identity verify-fic` to confirm the FIC exists; check Azure AD app API permissions
- **Self-signed cert not trusted**: Self-signed certs work for dev environments; production requires a CA-issued certificate

---
name: setup-client-repo
description: 'Set up a new client repository from the Agentic-ALM-Template. Use when: onboarding a new client, configuring the template repo for first use, filling in environment-config.json, setting up GitHub environments and secrets, configuring the Package Deployer project, or running through SETUP.md steps.'
---

# Set Up a New Client Repository

Walk through the full first-time configuration of a repository created from `Agentic-ALM-Template`. Setup means filling in `deployments/settings/environment-config.json` (the single source of truth for all project config) and configuring GitHub environments and secrets. No search-and-replace across files is required.

## When to Use

- A new client repository was just created from the template
- `environment-config.json` still contains `{{PLACEHOLDER}}` values
- Running through `SETUP.md` for the first time

## Step 0: Verify Prerequisites

Before anything else, confirm `.platform` is initialized. Check whether `.platform/.github/workflows/scripts/` contains files:

```powershell
Test-Path ".platform/.github/workflows/scripts"
```

If it returns `False` or the directory is empty, the submodule is not initialized. Tell the user to run:

```powershell
.\Initialize-Repo.ps1
```

Do not proceed until `.platform` is populated — all subsequent skills depend on those scripts.

## Skill boundaries

| Need | Use instead |
|------|-------------|
| Start feature development in a configured repo | `start-feature` |
| Scaffold a plugin or PCF control | `scaffold-plugin` or `scaffold-pcf-control` |
| Deploy a solution after setup is complete | `deploy-solution` |
| Cut a release in an already-configured repo | `create-release` |

## Agent Intake

Before proceeding, gather the following. Ask only for what is missing — do not ask for values that can be inferred or that have clear defaults.

### Core Identity

| # | What to ask | Key | Example |
|---|-------------|-----|---------|
| 1 | Name for this project or organization | `clientName` | `Acme Corp Platform` |
| 2 | One-line project or solution description | `productDescription` | `Power Platform solution for Acme Corp` |
| 3 | Company or organization name (PascalCase, no spaces) — becomes the Dataverse publisher name and prefixes your plugin `.sln` file | `publisher` | `AcmeCorp` |
| 4 | Primary solution name (PascalCase, no spaces) — additional solutions can be added to `solutionAreas[]` after setup | `solutionName` | `AcmePlatform` |
| 5 | Dataverse publisher prefix (lowercase, 3–5 chars) — the short prefix Dataverse prepends to all schema names for this publisher | `solutionPrefix` | `acm` |
| 6 | GitHub organization name | `githubOrg` | `AcmeCorp` |
| 7 | GitHub repository name | `repoName` | `AcmeCorp-Platform` |
| 8 | Short slug for GitHub environment names (lowercase) — used to name environments like `{slug}-dev`, `{slug}-test`, `{slug}-prod` | `envPrefix` | `acme` |
| 9 | Release tag suffix — appended to GitHub Release tags like `v2026.05.01.1-{tag}` (default: same as solution name) | `packageTag` | `AcmePlatform` |

### Environment URLs

Walk through these in order. Dev, Test, and Prod are required; Integration and Dev Test are optional.

1. **Dev** *(required)* — "What is the URL of your dev environment?"
2. **Integration** *(optional)* — "Do you have a shared integration environment where features are assembled and staged before release? *(Skip this if developers work directly from dev to test.)*" → if yes: "What is the URL?"
3. **Dev Test** *(optional)* — "Do you have a dev-test environment for validating individual features before they reach integration or UAT?" → if yes: "What is the URL?"
4. **Test / UAT** *(required)* — "What is the URL of your test or UAT environment?"
5. **Production** *(required)* — "What is the URL of your production environment?"

If an optional environment is declined:
- **Integration** skipped: remove it from `innerLoopEnvironments[]` and set `solutionAreas[].integrationEnv` to the same slug as `devEnv`
- **Dev Test** skipped: remove it from `environments[]` and from `packageGroups[].environments`

---

## Procedure

### 1. Fill in `environment-config.json`

Open `deployments/settings/environment-config.json` and replace every `{{PLACEHOLDER}}` value with the values gathered above. This is the **only file** that needs editing for the core configuration.

After filling in, it should look like:

```json
{
  "clientName": "Acme Corp Platform",
  "productDescription": "Power Platform solution for Acme Corp",
  "githubOrg": "AcmeCorp",
  "repoName": "AcmeCorp-Platform",
  "publisher": "AcmeCorp",
  "packageTag": "AcmePlatform",
  "packageProjectPath": "deployments/package/Deployer/PlatformPackage.csproj",
  "solutionAreas": [
    {
      "name": "AcmePlatform",
      "prefix": "acm",
      "role": "Power Platform solution for Acme Corp",
      "mainSolution": "acm_AcmePlatform",
      "cdsproj": "src/solutions/acm_AcmePlatform/acm_AcmePlatform.cdsproj",
      "pluginsPath": "src/plugins/acm_AcmePlatform",
      "pluginsSln": "src/plugins/acm_AcmePlatform/AcmeCorp.AcmePlatform.Plugins.sln",
      "corePluginRef": null,
      "controlPreBuildPaths": [],
      "devEnv": "acme-dev",
      "integrationEnv": "acme-integration"
    }
  ],
  "innerLoopEnvironments": [
    { "slug": "acme-dev",         "url": "https://org-dev12345.crm.dynamics.com/" },
    { "slug": "acme-integration", "url": "https://org-int67890.crm.dynamics.com/" }
  ],
  "environments": [
    { "slug": "acme-dev-test", "url": "https://org-dvt11111.crm.dynamics.com/" },
    { "slug": "acme-test",     "url": "https://org-tst22222.crm.dynamics.com/" },
    { "slug": "acme-prod",     "url": "https://org-prd33333.crm.dynamics.com/" }
  ],
  "packageGroups": [
    {
      "name": "AcmePlatform",
      "solutions": ["acm_AcmePlatform"],
      "dataSolution": "acm_AcmePlatform",
      "environments": ["acme-dev-test", "acme-test", "acme-prod"]
    }
  ]
}
```

Notes:
- `role` is set to the same value as `productDescription` — it is a documentation field only, not consumed by scripts
- For multi-solution repos, add additional entries to `solutionAreas[]`, `innerLoopEnvironments[]`, and `packageGroups[]`
- If Integration or Dev Test were skipped, omit those entries (see optional environment rules in Agent Intake)

---

### 2. Verify No Stray Placeholders

After filling in `environment-config.json`, verify it is the only file with unreplaced tokens (skills, instructions, and workflows read from it at runtime — they contain no placeholders themselves):

```powershell
# Only environment-config.json should appear in results
Select-String -Recurse -Include "*.md","*.json","*.cs","*.csproj","*.sln","*.yml" `
    -Pattern "\{\{[A-Z_]+\}\}" | Select-Object Path, Line | Format-Table -AutoSize
```

---

### 3. Add Solution References to the Package .csproj

Open `deployments/package/Deployer/PlatformPackage.csproj`. Find the `<!-- SETUP: Add one ProjectReference per solution -->` comment and add an `<ItemGroup>` with one `<ProjectReference>` per solution that belongs in this package.

**Single-solution example:**
```xml
<ItemGroup>
  <ProjectReference Include="../../../src/solutions/acm_AcmePlatform/acm_AcmePlatform.cdsproj"
                    ReferenceOutputAssembly="false" ImportOrder="1" ImportMode="async" />
</ItemGroup>
```

**Multi-solution example (core solution first, lowest ImportOrder):**
```xml
<ItemGroup>
  <ProjectReference Include="../../../src/solutions/acm_CoreSolution/acm_CoreSolution.cdsproj"
                    ReferenceOutputAssembly="false" ImportOrder="1" ImportMode="async" />
  <ProjectReference Include="../../../src/solutions/acm_AddOn/acm_AddOn.cdsproj"
                    ReferenceOutputAssembly="false" ImportOrder="2" ImportMode="async" />
</ItemGroup>
```

> The paths are relative from the `.csproj` location (`deployments/package/Deployer/`). Repo root is `../../../`.

No renaming of any files or folders is needed — the package project uses a fixed generic name.

---

### 4. Set Up GitHub Environments

For each slug in `environments[]` in `environment-config.json`, create a GitHub Environment:

1. Go to **Settings → Environments → New environment** in the repository
2. Name it exactly as the slug (e.g. `acme-test`)
3. Add these variables:

| Variable | Value |
|----------|-------|
| `DATAVERSE_URL` | Full Dataverse environment URL (with trailing `/`) |
| `DATAVERSE_CLIENT_ID` | App registration client ID for this environment |

4. Add `AZURE_TENANT_ID` as a **repository-level** variable (same for all environments)
5. Configure approval gates on test and prod tier environments

---

### 5. Configure OIDC Federated Credentials

For each environment's app registration, add a federated credential:

```
Audience: api://AzureADTokenExchange
Subject:  repo:<githubOrg>/<repoName>:environment:<env-slug>
```

Test using `test-oidc-auth.yml` workflow after completing this step.

---

### 6. Set Up Repository Secrets and Variables

**Repository secrets** — none required. Authentication uses OIDC federated credentials (no stored secrets).

**Repository variables** (Settings → Secrets and variables → Actions → Variables):

| Variable | Description | Example |
|----------|-------------|---------|
| `AZURE_TENANT_ID` | Azure AD tenant ID | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `DEPLOYMENT_ENVIRONMENTS` | Default deploy targets for `workflow_run` trigger | `acme-test` |
| `PR_VALIDATION_INTEGRATION_ENV` | Integration env slug for PR validation builds | `acme-integration` |

---

### 7. Initialize Submodules

```powershell
.\Initialize-Repo.ps1
# Verify scripts are present
Get-ChildItem ".platform/.github/workflows/scripts/*.ps1" | Select-Object Name
```

This initializes the `.platform` submodule to the latest `Agentic-ALM-Workflows`. It is idempotent — safe to re-run at any time.

---

### 8. Set Up Branch Protection

In GitHub → Settings → Branches, add rules:

- **`main`**: Require PR, restrict to `develop` or `hotfix/*` source (enforced by `check-source-branch.yml`)
- **`develop`**: Require PR review; no force push; no direct push for non-admins

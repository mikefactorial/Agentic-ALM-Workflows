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

### Check Required Tools

Run this to verify all required CLIs are installed:

```powershell
$missing = @()
if (-not (Get-Command pac    -ErrorAction SilentlyContinue)) { $missing += 'pac (Power Platform CLI) — https://aka.ms/PowerAppsCLI' }
if (-not (Get-Command gh     -ErrorAction SilentlyContinue)) { $missing += 'gh (GitHub CLI) — https://cli.github.com' }
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) { $missing += 'dotnet (.NET SDK) — https://dot.net' }
if ($missing) {
    Write-Warning "Missing required tools — install before continuing:"
    $missing | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "All required tools found." -ForegroundColor Green
}
```

Do not proceed until all three tools are available. Also verify `gh` is authenticated:

```powershell
gh auth status
```

If not authenticated, run `gh auth login` and follow the prompts.

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
| 4 | What is the name of your main Power Platform solution? (PascalCase, no spaces — more solutions can be added later) | `solutionName` | `AcmePlatform` |
| 5 | Dataverse publisher prefix (lowercase, 3–5 chars) — the short prefix Dataverse prepends to all schema names for this publisher | `solutionPrefix` | `acm` |
| 6 | GitHub organization or personal account name (use the exact org name or your GitHub username for personal accounts) | `githubOrg` | `AcmeCorp` or `johndoe` |
| 7 | GitHub repository name | `repoName` | `AcmeCorp-Platform` |
| 8 | What short lowercase name should identify your deployment environments? (e.g., `acme` creates environments named `acme-dev`, `acme-test`, `acme-prod`) | `envPrefix` | `acme` |
| 9 | Release tag suffix — appended to GitHub Release tags like `v2026.05.01.1-{tag}` (default: same as solution name) | `packageTag` | `AcmePlatform` |
| 10 | Which work item tracking system do you use? | `trackingSystem` | `azureBoards` or `github` |

### Environment URLs

Walk through these in order. Dev, Test, and Prod are required; Integration and Dev Test are optional.

1. **Dev** *(required)* — "What is the URL of your dev environment? (e.g., `https://org-dev12345.crm.dynamics.com/`)"
2. **Integration** *(optional)* — "Do you have a shared integration environment where features are assembled and staged before release? *(Skip this if developers work directly from dev to test.)*" → if yes: "What is the URL? (e.g., `https://org-int67890.crm.dynamics.com/`)"
3. **Dev Test** *(optional)* — "Do you have a dev-test environment for validating individual features before they reach integration or UAT?" → if yes: "What is the URL? (e.g., `https://org-dvt11111.crm.dynamics.com/`)"
4. **Test / UAT** *(required)* — "What is the URL of your test or UAT environment? (e.g., `https://org-tst22222.crm.dynamics.com/`)"
5. **Production** *(required)* — "What is the URL of your production environment? (e.g., `https://org-prd33333.crm.dynamics.com/`)"

If an optional environment is declined:
- **Integration** skipped: remove it from `innerLoopEnvironments[]` and set `solutionAreas[].integrationEnv` to the same slug as `devEnv`
- **Dev Test** skipped: remove it from `environments[]` and from `packageGroups[].environments`

> **Minimum viable topology**: Dev + Test + Production is the smallest supported configuration. Any combination of optional environments (Integration, Dev Test) can be omitted.

> **Adding environments later**: If the user wants to enable a skipped environment after initial setup, they add its entry back to `environments[]` (with the real URL) and to any relevant `packageGroups[].environments`. Any attempt to use an environment whose URL is still a `{{PLACEHOLDER}}` value will fail with a clear error message pointing back to `environment-config.json`.

### GitHub & Azure Credentials

Gather these before running the GitHub environment setup commands in Step 4.

| # | What to ask | Key | Example |
|---|-------------|-----|---------|
| 10 | Azure AD tenant ID — the same for all environments | `azureTenantId` | `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| 11 | *(Optional — can be added to GitHub later)* For each deployment environment (dev-test, test, prod), what is the app registration (service principal) client ID? Ask per environment. If the user doesn't have these yet, skip and note they must be set in GitHub before deployments will work. | `clientId` per env | `yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy` |

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
  "trackingSystem": "azureBoards",
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

Use the GitHub CLI to create each environment and set its variables. You need to do this for **all** environments — both inner loop (`innerLoopEnvironments[]`) and deployment (`environments[]`).

Generate one block per environment using the values collected in the intake. Replace each placeholder with the actual slug, URL, and client ID for that environment:

```powershell
$org = "<githubOrg>"
$repo = "<repoName>"

# --- <env-slug-1> (e.g. acme-dev) ---
gh api --method PUT /repos/$org/$repo/environments/<env-slug-1>
gh variable set DATAVERSE_URL       --env <env-slug-1> --repo "$org/$repo" --body "<dataverse-url-1>"
gh variable set DATAVERSE_CLIENT_ID --env <env-slug-1> --repo "$org/$repo" --body "<client-id-1>"

# --- <env-slug-2> (e.g. acme-integration) ---
gh api --method PUT /repos/$org/$repo/environments/<env-slug-2>
gh variable set DATAVERSE_URL       --env <env-slug-2> --repo "$org/$repo" --body "<dataverse-url-2>"
gh variable set DATAVERSE_CLIENT_ID --env <env-slug-2> --repo "$org/$repo" --body "<client-id-2>"

# ... repeat for each remaining environment (acme-dev-test, acme-test, acme-prod, etc.)
```

> **All environments need a GitHub Environment** — including dev and integration. Inner loop workflows (`sync-solution`, `Stage-Solution`, `build-deploy-solution`) authenticate against dev and integration using OIDC, which requires a matching GitHub Environment with `DATAVERSE_URL` and `DATAVERSE_CLIENT_ID` variables.

> **Client ID not ready yet?** You can omit `DATAVERSE_CLIENT_ID` for any environment now and set it later — but the variable must be present before any CI workflow targets that environment.

> **Approval gates** — after creating test and prod environments, go to **Settings → Environments → \<slug\>** in GitHub to add required reviewers. The `gh` CLI does not yet support configuring approval gates.

---

### 5. Configure OIDC Federated Credentials

This step requires an Azure AD app registration (service principal) per deployment environment, and permission to add federated credentials to it. There are two common paths:

#### Option A — Power Platform Admin creates the service principal

A Power Platform Admin can create an app registration and grant it the Dataverse service role in one command:

```powershell
# Run as a Power Platform Admin
pac admin create-service-principal --environment <dataverse-env-url>
```

This outputs the **Application (Client) ID** and **Tenant ID** to use in Steps 4 and 6. Repeat for each deployment environment.

> If the user is not a Power Platform Admin, share this command with whoever manages your Power Platform tenant.

#### Option B — Azure AD Admin creates the app registration manually

If the service principal already exists or is managed by an Azure AD admin, they need to add a federated credential with:

```
Audience: api://AzureADTokenExchange
Subject:  repo:<githubOrg>/<repoName>:environment:<env-slug>
```

#### Automate federated credential creation (requires Azure CLI + app registration permissions)

Once the app registration exists, use the helper script from `.platform` to add federated credentials for all environments in one pass:

```powershell
# Requires: az login, and permission to modify the app registration
.platform/.github/workflows/scripts/Setup-GitHubFederatedCredentials.ps1 `
    -AppRegistrationId "<client-id>" `
    -GitHubOrg "<githubOrg>" `
    -RepositoryName "<repoName>" `
    -Environments @("<env-slug-1>", "<env-slug-2>", "<env-slug-3>")
```

Run once per app registration (i.e., once per environment if each has its own, or once if they share one).

Test the full auth chain using the `test-oidc-auth.yml` workflow after completing this step.

---

### 6. Set Up Repository-Level Variables and Secrets

Run the following to set all required repository-level variables and secrets:

```powershell
$org  = "<githubOrg>"
$repo = "<repoName>"

# Azure tenant ID — shared across all environments
gh variable set AZURE_TENANT_ID --repo "$org/$repo" --body "<tenantId>"

# Default environment(s) targeted by automatic deploys on push to main
# Derive from environments[]: use the test-tier slug (e.g. acme-test)
gh variable set DEPLOYMENT_ENVIRONMENTS --repo "$org/$repo" --body "<test-slug>"

# Integration environment used for PR validation builds
# Derive from solutionAreas[].integrationEnv in environment-config.json
gh variable set PR_VALIDATION_INTEGRATION_ENV --repo "$org/$repo" --body "<integration-slug>"

# Pipeline hook variables and secrets — empty JSON objects by default.
# Hooks read from these at runtime; populate later if you add custom hooks.
gh variable set HOOK_VARIABLES --repo "$org/$repo" --body "{}"
gh secret  set HOOK_SECRETS   --repo "$org/$repo" --body "{}"
```

---

### 7. Initialize Submodules

```powershell
.\Initialize-Repo.ps1
# Verify scripts are present
Get-ChildItem ".platform/.github/workflows/scripts/*.ps1" | Select-Object Name
```

This initializes the `.platform` submodule to the latest `Agentic-ALM-Workflows`. It is idempotent — safe to re-run at any time.

---

### 8. Commit Setup Changes and Create Develop Branch

With all config files updated, commit everything to `main` and create the `develop` branch:

```powershell
$org  = "<githubOrg>"
$repo = "<repoName>"

# Stage and commit all setup changes
git add -A
git commit -m "chore: initial repo setup — environment-config, package project, GitHub environments"
git push origin main

# Create develop branch from main if it doesn't exist
$developExists = git ls-remote --heads origin develop
if (-not $developExists) {
    git checkout -b develop
    git push origin develop
    git checkout main
    Write-Host "✓ develop branch created" -ForegroundColor Green
} else {
    Write-Host "  develop branch already exists — skipping" -ForegroundColor Yellow
}
```

---

### 9. Set Up Branch Protection

Use the GitHub CLI to configure branch protection rules for both `main` and `develop`:

```powershell
$org  = "<githubOrg>"
$repo = "<repoName>"

# Protect main — require PR, no direct pushes, no force push
gh api --method PUT /repos/$org/$repo/branches/main/protection `
    --field required_status_checks=null `
    --field enforce_admins=false `
    --field "required_pull_request_reviews[dismiss_stale_reviews]=true" `
    --field "required_pull_request_reviews[required_approving_review_count]=1" `
    --field "restrictions=null" `
    --field allow_force_pushes=false `
    --field allow_deletions=false

# Protect develop — require PR review, no direct pushes, no force push
gh api --method PUT /repos/$org/$repo/branches/develop/protection `
    --field required_status_checks=null `
    --field enforce_admins=false `
    --field "required_pull_request_reviews[dismiss_stale_reviews]=true" `
    --field "required_pull_request_reviews[required_approving_review_count]=1" `
    --field "restrictions=null" `
    --field allow_force_pushes=false `
    --field allow_deletions=false

Write-Host "✓ Branch protection configured for main and develop" -ForegroundColor Green
```

> **Source branch enforcement for `main`**: The `check-source-branch.yml` workflow enforces that PRs to `main` only come from `develop` or `hotfix/*`. The GitHub API does not support branch name pattern restrictions at the branch protection level — this is enforced at the workflow level instead.

> **Admins bypass by default** (`enforce_admins=false`). Set to `true` to enforce for admins as well, but be aware this will block you from bypassing during incidents.

> **Review count**: `required_approving_review_count=1` is a sensible default. Set to `0` if the team works solo (no reviewer available), or increase for larger teams.

## Next Steps

Once setup is complete, you're ready to start development. Use the `start-feature` skill to kick off your first feature — it handles authenticating to your dev environment, creating the feature solution in Dataverse, branching, and wiring everything together:

> "Start a new feature" — or describe the feature you want to build and the agent will use `start-feature` automatically.

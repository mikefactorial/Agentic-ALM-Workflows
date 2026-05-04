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
2. **Integration** *(optional)* — "Do you have a shared integration environment where features are assembled and promoted before release? *(Skip this if developers work directly from dev to test.)*" → if yes: "What is the URL? (e.g., `https://org-int67890.crm.dynamics.com/`)"
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

> **Azure AD tenant ID**: You do not need to look this up now. We will derive it automatically from your authentication in Step 5 using `az account show --query tenantId -o tsv`.

| # | What to ask | Key | Example |
|---|-------------|-----|---------|
| 10 | GitHub Actions authenticates to each Dataverse environment using an **Azure AD app registration** (also called a service principal) that has been granted the **System Administrator** security role in that environment. Do you already have one of these set up for any of your environments? If so, provide the **Application (Client) ID** for each — you can find this in the Azure Portal under **Azure Active Directory → App registrations → [your app] → Application (client) ID**, or it was printed when `pac admin create-service-principal` was last run. **If you don't have any yet, that's fine** — Step 5 will walk through creating them with a single command. Provide only the IDs you already have; we'll create the rest. | `clientId` per env | `yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy` |

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

> **All environments need a GitHub Environment** — including dev and integration. Inner loop workflows (`sync-solution`, `Promote-Solution`, `build-deploy-solution`) authenticate against dev and integration using OIDC, which requires a matching GitHub Environment with `DATAVERSE_URL` and `DATAVERSE_CLIENT_ID` variables.

> **Client ID not ready yet?** You can omit `DATAVERSE_CLIENT_ID` for any environment now and set it later — but the variable must be present before any CI workflow targets that environment.

> **Approval gates** — after creating test and prod environments, go to **Settings → Environments → \<slug\>** in GitHub to add required reviewers. The `gh` CLI does not yet support configuring approval gates.

---

### 5. Configure OIDC Federated Credentials

GitHub Actions authenticates to Dataverse using OIDC — no stored passwords or secrets. Every environment (including dev and integration) needs two things:

1. An **Azure AD app registration** (service principal) added as an App User to the Dataverse environment
2. A **federated identity credential** on that app registration, scoped to the matching GitHub Environment

Two roles are typically required (may be the same person in smaller organizations):
- **Power Platform Admin** — needed to create a Dataverse App User via `pac admin create-service-principal`
- **Azure AD App Owner** or **Privileged Role Admin** — needed to add federated credentials via the helper script or `az ad app federated-credential create`

> **This step is not optional.** Nothing will work — no CI deployments, no solution sync, no promote — until OIDC is configured for at least the dev environment. If you don't have the required permissions yourself, continue below to generate a ready-to-share hand-off document for your admin.

> **Already have client IDs from the intake?** Skip Step 5a entirely for those environments — the app registration already exists and is registered in Dataverse. You only need to add federated credentials (Step 5b).

---

#### Step 5a — Create the service principal *(skip for environments where you already have a client ID)*

This step requires **Power Platform Admin** permissions in the target Dataverse environment. It creates an Azure AD app registration and grants it the System Administrator role in Dataverse — all in one command.

```powershell
# Authenticate once per tenant — this works for all environments in the same tenant.
# Use any environment URL in your tenant — it's just used to identify the tenant.
pac auth create --environment <any-dataverse-env-url>

# Create a unique app registration and Dataverse App User for each environment.
# Run once per environment that does NOT already have a client ID.
pac admin create-service-principal --environment <dataverse-env-url-1>
pac admin create-service-principal --environment <dataverse-env-url-2>
# ... repeat for each remaining environment without an existing client ID
```

Each `pac admin create-service-principal` call outputs:
- **Application (Client) ID** — unique per environment; save each one
- **Tenant ID** — your Azure AD tenant; same for all environments

Save all client IDs — you need them for Steps 5b, 5c, and Step 6.

> **Not a Power Platform Admin?** See the **Admin Hand-Off** section below. Generate the filled-in instructions and share with your admin before continuing — you can finish Steps 6–9 while you wait for the admin to complete Step 5.

---

#### Step 5b — Add federated identity credentials

This step requires being an **Owner of the app registration** in Azure AD (or a Privileged Role Admin).

For environments where you provided a client ID during intake, use that ID. For environments where you just ran Step 5a, use the client ID from that output.

**Prerequisite:** Azure CLI installed and logged in.
```powershell
winget install Microsoft.AzureCLI   # if not already installed
az login
```

Run the helper script from `.platform` once per environment:

```powershell
# Repeat for each environment — use the client ID for THAT specific environment
.platform/.github/workflows/scripts/Setup-GitHubFederatedCredentials.ps1 `
    -AppRegistrationId "<client-id-for-env-1>" `
    -GitHubOrg "<githubOrg>" `
    -RepositoryName "<repoName>" `
    -Environments @("<env-slug-1>")

.platform/.github/workflows/scripts/Setup-GitHubFederatedCredentials.ps1 `
    -AppRegistrationId "<client-id-for-env-2>" `
    -GitHubOrg "<githubOrg>" `
    -RepositoryName "<repoName>" `
    -Environments @("<env-slug-2>")
# ... repeat for each remaining environment
```

The script creates a federated credential with subject `repo:<githubOrg>/<repoName>:environment:<env-slug>` for each slug. It skips credentials that already exist and prints a created / skipped / error summary.

---

#### Step 5c — Set `DATAVERSE_CLIENT_ID` for any environments not already set in Step 4

If you ran Step 5a and got new client IDs that weren't available when you ran Step 4:

```powershell
# Set the client ID for each environment where it was missing in Step 4
gh variable set DATAVERSE_CLIENT_ID --env <env-slug> --repo "<githubOrg>/<repoName>" --body "<client-id>"
```

---

#### Step 5d — Verify

Run `test-oidc-auth.yml` to confirm the full authentication chain works for each environment:

```powershell
gh workflow run test-oidc-auth.yml --repo "<githubOrg>/<repoName>"
gh run watch --repo "<githubOrg>/<repoName>"
```

A green run confirms GitHub Actions can authenticate to Dataverse using OIDC. If it fails, check:
- The federated credential subject matches exactly: `repo:<githubOrg>/<repoName>:environment:<env-slug>` (case-sensitive)
- The app registration has the System Administrator role in the target Dataverse environment
- `az ad app federated-credential list --id <client-id>` shows the credential

---

#### Admin Hand-Off

If you do not have Power Platform Admin or Azure AD permissions, use the `setup-oidc` skill to generate a ready-to-share document with all environment URLs and GitHub details pre-filled:

> "Generate OIDC hand-off instructions for my admin"

You can continue with Steps 6–9 while waiting for the admin to complete Step 5a. Come back to Step 5b once you have the client IDs.


---

### 6. Set Up Repository-Level Variables and Secrets

Run the following to set all required repository-level variables and secrets:

```powershell
$org  = "<githubOrg>"
$repo = "<repoName>"

# Azure tenant ID — shared across all environments
# Derive automatically from your Azure CLI or pac authentication:
$tenantId = az account show --query tenantId -o tsv
# If az CLI is not available, use: (pac auth list | Select-String 'TenantId').ToString().Split(':')[-1].Trim()
gh variable set AZURE_TENANT_ID --repo "$org/$repo" --body "$tenantId"

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

### 10. Validate Main Solution and Create Initial Sync PR

After OIDC is verified, check whether the main solution already exists in the dev environment. If it does not exist, it needs to be created before any inner-loop work can begin.

**Check if the solution exists:**
```powershell
pac auth create --environment <devEnvUrl>   # if not already authenticated
pac solution list --environment <devEnvUrl> | Select-String "<mainSolution>"
```

If the solution **is not found**:
> "Your main solution `{mainSolution}` does not exist yet in the dev environment. Let's create it:
> 1. Open the [Power Apps maker portal](<devEnvUrl>) and sign in
> 2. Go to **Solutions** → **New solution**
> 3. Set the display name to `{mainSolution}`, choose your publisher (`{publisher}` / prefix `{solutionPrefix}`)
> 4. Click **Create**
> Once created, come back and I'll sync it to the repository."

Wait for the user to confirm the solution exists, then sync it to the repository and create the first PR to `develop`:

```powershell
$syncBranch = "sync/{mainSolution}-initial"
git checkout develop
git pull
git checkout -b $syncBranch

.platform/.github/workflows/scripts/Sync-Solution.ps1 `
    -solutionName "{mainSolution}" `
    -environmentUrl "{devEnvUrl}" `
    -commitMessage "chore({mainSolution}): initial solution sync" `
    -branchName $syncBranch

git push origin $syncBranch

gh pr create `
    --base develop `
    --head $syncBranch `
    --title "chore({mainSolution}): initial solution sync" `
    --body "Initial sync of ``{mainSolution}`` from dev environment. Merge this to establish the baseline solution metadata on develop."
```

Tell the user the PR link and ask them to review and merge it. Once merged, `develop` has the initial solution metadata and the repo is ready for feature development.

---

## Next Steps

Once setup is complete and the initial sync PR is merged, you're ready to start development. Use the `start-feature` skill to kick off your first feature:

> "Start a new feature" — or describe the feature you want to build and the agent will use `start-feature` automatically.

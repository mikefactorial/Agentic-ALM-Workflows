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
| 3 | Your company or organization name in PascalCase (no spaces, no special characters). This becomes: (1) the Dataverse publisher name embedded in all solutions, (2) the namespace prefix for plugin code (e.g., `AcmeCorp.Plugins`), and (3) the prefix for your plugin `.sln` filename. Choose something that represents your org — this is embedded in solution and code artifacts and is not easy to change later. | `publisher` | `AcmeCorp` |
| 4 | What is the name of your main Power Platform solution? (PascalCase, no spaces — more solutions can be added later) | `solutionName` | `AcmePlatform` |
| 5 | The short publisher prefix used by Dataverse (lowercase, 3–5 characters). Dataverse prepends this to every schema name you create — tables, columns, relationships, flows, etc. (e.g., prefix `acm` → table `acm_MyTable`). **This is permanent** — it is baked into all solution component names and cannot be changed without breaking existing data and solutions. Choose carefully. | `solutionPrefix` | `acm` |
| 6 | GitHub organization or personal account name (use the exact org name or your GitHub username for personal accounts) | `githubOrg` | `AcmeCorp` or `johndoe` |
| 7 | GitHub repository name | `repoName` | `AcmeCorp-Platform` |
| 8 | A short lowercase identifier used to name your deployment environments. This creates GitHub Environment slugs like `{prefix}-dev`, `{prefix}-integration`, `{prefix}-test`, `{prefix}-prod`. These must be unique within your GitHub repository. Typically matches your client abbreviation or project codename. | `envPrefix` | `acme` |
| 9 | Release tag suffix — appended to GitHub Release tags (e.g., `v2026.05.01.1-AcmePlatform`). Defaults to the same value as your solution name. Only change this if you want a release tag identifier that differs from the solution name — for example, a project codename or abbreviation. | `packageTag` | `AcmePlatform` |
| 10 | Which work item tracking system does your team use? This controls how work item IDs are formatted in commit messages and branch names. `azureBoards` uses `AB#12345` commit trailers and `AB12345` branch tags (links to Azure Boards). `github` uses `Closes #12345` trailers and `GH12345` branch tags (links to and closes GitHub Issues). | `trackingSystem` | `azureBoards` or `github` |

### Environment URLs

Walk through these in order. Dev, Test, and Prod are required; Integration and Dev Test are optional.

1. **Dev** *(required)* — Each developer has their own dev environment where they build and iterate on features as unmanaged solutions. Ask: "What is the URL of your dev environment? (e.g., `https://org-dev12345.crm.dynamics.com/`)"

2. **Integration** *(optional)* — A shared integration environment is where all developers' feature solutions are assembled together and validated as a combined unit before the release goes to test/UAT. In multi-developer teams this catches conflicts between features early — problems that only appear when multiple features coexist in the same environment. In the inner loop, developers promote their completed features here before a release is cut. Ask: "Do you have a shared integration environment where all in-progress features are assembled before a release? Provide its URL, or leave blank to skip. (e.g., `https://org-int67890.crm.dynamics.com/` — skip if developers go directly from dev to test)"

3. **Dev Test** *(optional)* — A dev-test environment receives individual feature solutions deployed as **managed** solutions, mirroring how the solution will behave in test and production. This lets teams catch deployment errors, missing dependencies, and solution layering issues before features reach UAT. Ask: "Do you have a dev-test environment for validating individual feature deployments as managed solutions before they reach integration or UAT? Provide its URL, or leave blank to skip. (e.g., `https://org-dvt11111.crm.dynamics.com/`)"

4. **Test / UAT** *(required)* — The test or UAT environment is where stakeholders validate the combined solution before it goes to production. Ask: "What is the URL of your test or UAT environment? (e.g., `https://org-tst22222.crm.dynamics.com/`)"

5. **Production** *(required)* — Ask: "What is the URL of your production environment? (e.g., `https://org-prd33333.crm.dynamics.com/`)"

If an optional environment is declined:
- **Integration** skipped: remove it from `innerLoopEnvironments[]` and set `solutionAreas[].integrationEnv` to the same slug as `devEnv`
- **Dev Test** skipped: remove it from `environments[]` and from `packageGroups[].environments`

> **Minimum viable topology**: Dev + Test + Production is the smallest supported configuration. Any combination of optional environments (Integration, Dev Test) can be omitted.

> **Adding environments later**: If the user wants to enable a skipped environment after initial setup, they add its entry back to `environments[]` (with the real URL) and to any relevant `packageGroups[].environments`. Any attempt to use an environment whose URL is still a `{{PLACEHOLDER}}` value will fail with a clear error message pointing back to `environment-config.json`.

### GitHub & Azure Credentials

Gather these before running the GitHub environment setup commands in Step 4.

> **Azure AD tenant ID**: You do not need to look this up in advance. In Step 6 we derive it directly from the pac CLI auth profile established in Step 5a — no Azure CLI login required.

| # | What to ask | Key | Example |
|---|-------------|-----|---------|
| 10 | GitHub Actions authenticates to each Dataverse environment using an **Azure AD app registration** (also called a service principal) that has been granted the **System Administrator** security role in that environment. Do you already have one of these set up for any of your environments? If so, provide the **Application (Client) ID** for each — you can find this in the Azure Portal under **Azure Active Directory → App registrations → [your app] → Application (client) ID**, or it was printed when `pac admin create-service-principal` was last run. **If you don't have any yet, that's fine** — Step 5 will walk through creating them with a single command. Provide only the IDs you already have; we'll create the rest. | `clientId` per env | `yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy` |

---

## Procedure

> **Execute all steps sequentially without pausing to ask "shall I continue?" between steps.** Only stop if a step fails, a required value is missing, or the user explicitly asks to pause. When an async operation (e.g., `gh run watch`) completes successfully, proceed immediately to the next step.

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

### 3b. Initialize Solution Structures Locally

> **This step is required before committing to main.** The `ProjectReference` added in Step 3 expects a `.cdsproj` file to exist at build time. Without it, the release package build fails immediately after the first commit. This step creates the local solution scaffolding using `pac solution init` — no Dataverse connection is needed. The full solution metadata sync from Dataverse happens in Step 10 after OIDC is configured.

For each solution area, run from the **repo root**:

```powershell
# Repeat for each solution area — substitute {mainSolution}, {publisher}, {solutionPrefix}
$solutionDir = "src/solutions/{mainSolution}"
New-Item -ItemType Directory -Path $solutionDir -Force | Out-Null
Push-Location $solutionDir
pac solution init --publisher-name {publisher} --publisher-prefix {solutionPrefix}
Pop-Location
Write-Host "✓ Solution structure initialized at $solutionDir" -ForegroundColor Green
```

Verify the `.cdsproj` was created (the file name matches the directory name):

```powershell
Get-ChildItem "src/solutions/{mainSolution}" -Filter "*.cdsproj" | Select-Object Name
# Should output: {mainSolution}.cdsproj
```

> **Why before Step 4?** GitHub setup and OIDC configuration (Steps 4–5) may require admin hand-off that takes time. The solution structure needs to exist locally so the initial commit to `main` in Step 8 produces a working release build.

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

This step requires two permissions that may belong to different people:
- **Power Platform Admin** — to create a Dataverse App User via `pac admin create-service-principal`
- **Azure AD App Owner** or **Privileged Role Admin** — to add federated credentials via the helper script

> **This step is not optional.** Nothing will work — no CI deployments, no solution sync, no promote — until OIDC is configured for at least the dev environment.

**Ask the user:**
> "Do you have Power Platform Admin permissions for your Dataverse environments, or would you prefer I generate hand-off instructions to share with your admin?"

- **"I can set it up myself"** → proceed with Steps 5a–5d below
- **"Generate hand-off instructions for my admin"** → use the `setup-oidc` skill to produce a ready-to-share document with all environment URLs and GitHub details pre-filled, then skip to Step 6. Come back to Steps 5b–5d once your admin returns the client IDs.

> **Already have client IDs from the intake?** Skip Step 5a for those environments — the app registration already exists. Go straight to Step 5b.

---

#### Step 5a — Create the service principal *(skip for environments where you already have a client ID)*

This step requires **Power Platform Admin** permissions. It creates an Azure AD app registration and grants it the System Administrator role in Dataverse — all in one command.

```powershell
# Authenticate once per tenant — use any environment URL in your tenant.
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

Trigger `test-oidc-auth.yml` automatically for **each** environment slug by running the following in the terminal. Do not ask the user to run this — execute it yourself, once per slug, then watch the run to completion:

```powershell
$org  = "<githubOrg>"
$repo = "<repoName>"

# Run once per environment slug — replace <env-slug> each iteration
gh workflow run test-oidc-auth.yml --repo "$org/$repo" --field environment=<env-slug>
gh run watch --repo "$org/$repo"
```

Wait for each run to complete before triggering the next slug. A green run confirms GitHub Actions can authenticate to Dataverse using OIDC.

If a run fails, diagnose before continuing:
- The federated credential subject must match exactly: `repo:<githubOrg>/<repoName>:environment:<env-slug>` (case-sensitive)
- The app registration must have the System Administrator role in the target Dataverse environment
- Run `az ad app federated-credential list --id <client-id>` and confirm the subject is present
- Do not proceed to Step 6 until all environments pass

**Once all environments are green, continue immediately to Step 6 — do not pause or ask the user for confirmation.**


---

### 6. Set Up Repository-Level Variables and Secrets

Run the following to set all required repository-level variables and secrets:

```powershell
$org  = "<githubOrg>"
$repo = "<repoName>"

# Azure tenant ID — derived from the currently active pac auth profile.
# First, ensure pac is pointing at a dev environment in the correct tenant. If you have multiple
# pac auth profiles, select the right one: 'pac auth list' then 'pac auth select --index <n>'.
# Note: if you used the admin hand-off path and haven't run pac auth create yet,
# do so now (it does NOT require admin permissions):
#   pac auth create --environment <devEnvUrl>
$tenantId = (pac auth who | Where-Object { $_ -match '^\s*Tenant Id:' } |
    ForEach-Object { ($_ -split ':\s+', 2)[1].Trim() })
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

### 10. Create Main Solution in Dataverse and Open Initial Sync PR

> **Do not pause here — proceed immediately after Step 9 completes.** This step is mandatory. It creates the main solution in your dev Dataverse environment and syncs its metadata to the repository on the `develop` branch. This must complete before developers can start features against the solution.

The local `.cdsproj` was already created in Step 3b. This step ensures the solution exists in Dataverse, then pulls its metadata into the repo.

**Check if the solution exists in Dataverse:**
```powershell
pac solution list --environment {devEnvUrl} | Select-String '{mainSolution}'
```

If the solution **is not found** in that output, create it in Dataverse now:
```powershell
# The local structure (from Step 3b) is already in place — just pack and import it
$solutionDir = "src/solutions/{mainSolution}"
$tempZip = Join-Path ([System.IO.Path]::GetTempPath()) "{mainSolution}.zip"
pac solution pack --zipfile $tempZip --folder "$solutionDir/src" --packagetype Unmanaged --errorlevel Warning
pac solution import --path $tempZip --environment {devEnvUrl} --activate-plugins --publish-changes
Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
Write-Host "✓ Solution '{mainSolution}' imported into dev environment" -ForegroundColor Green
```

Once the solution exists in Dataverse (either pre-existing or just imported), sync it and open the initial PR:

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
    --body "Initial sync of \`{mainSolution}\` from dev environment. Merge this to establish the baseline solution metadata on develop."
```

Share the PR link with the user and ask them to review and merge it. Once merged, `develop` has the initial solution metadata and the repo is ready for feature development.

---

## Next Steps

Once setup is complete and the initial sync PR is merged, you're ready to start development. Use the `start-feature` skill to kick off your first feature:

> "Start a new feature" — or describe the feature you want to build and the agent will use `start-feature` automatically.

If OIDC hasn't been configured yet, do that now before any CI workflow can run:

> "Set up OIDC" — the `setup-oidc` skill will generate the service principals and federated credentials for all environments.

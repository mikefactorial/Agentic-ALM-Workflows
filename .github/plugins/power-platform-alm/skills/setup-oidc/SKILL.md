---
name: setup-oidc
description: 'Set up OIDC federated credentials for GitHub Actions to authenticate to Dataverse environments. Use when: configuring a new environment, adding a service principal to a Dataverse environment, running the federated credentials script, generating admin hand-off instructions, or OIDC auth is failing and needs to be reconfigured.'
---

# Set Up OIDC Federated Credentials

Configure GitHub Actions to authenticate to Dataverse environments using OpenID Connect (OIDC) — no stored passwords or secrets. GitHub issues short-lived tokens that Azure AD validates against a federated identity credential on an app registration.

## When to Use

- You deferred OIDC setup during `setup-client-repo` and are now ready to complete it
- A new environment is being added to an existing repo
- OIDC auth is failing and needs to be diagnosed or reconfigured
- An Azure AD admin or Power Platform Admin needs to handle this and you need to hand off instructions
- You want to understand what the `Setup-GitHubFederatedCredentials.ps1` script does and verify it ran correctly

## Skill Boundaries

| Need | Use instead |
|------|-------------|
| Full first-time repo setup | `setup-client-repo` |
| Deploy a solution after OIDC is working | `deploy-solution` |
| Cut a release | `create-release` |

---

## What Is Required

Each GitHub Environment → Dataverse connection requires three things:

| # | What | Who sets it up |
|---|------|----------------|
| 1 | Azure AD **app registration** (service principal) added as an App User in the Dataverse environment | Power Platform Admin — `pac admin create-service-principal` |
| 2 | **Federated identity credential** on that app registration, scoped to the GitHub Environment | Azure AD App Owner — `az ad app federated-credential create` (or the helper script) |
| 3 | `DATAVERSE_CLIENT_ID` variable set in the GitHub Environment | GitHub repo admin — `gh variable set` |

These roles are often the same person, but in larger organizations they may be separate. This skill handles all three paths.

---

## Agent Intake

Before proceeding, gather what is not already known:

| # | What to ask | Notes |
|---|-------------|-------|
| 1 | GitHub org or username | e.g., `AcmeCorp` |
| 2 | GitHub repository name | e.g., `AcmeCorp-Platform` |
| 3 | Which environments to configure? | List of slugs: `acme-dev`, `acme-test`, `acme-prod`, etc. |
| 4 | Dataverse URL for each environment | e.g., `https://org-dev12345.crm.dynamics.com/` |
| 5 | Do you already have app registration (client) IDs for any of these environments? | If yes, note which ones — skip Step 1 for those |
| 6 | Do you need to hand this off to an admin, or can you run the steps yourself? | If hand-off: generate the Admin Instructions document below |

---

## Step 1 — Create the Service Principal

> **Skip this step entirely** for any environment where you already have a client ID from an existing service principal that is registered as a Dataverse App User. If you provided client IDs during `setup-client-repo`, go directly to Step 2 — do NOT run `pac admin create-service-principal` for those environments, as it would create a new, unnecessary app registration.

Run as a **Power Platform Admin** — one command creates the Azure AD app registration and registers it as a Dataverse App User in the target environment:

```powershell
# Authenticate once — pac auth is per-tenant, not per-environment.
# Any environment URL in the target tenant works here.
pac auth create --environment <any-dataverse-env-url>

# Create the service principal and Dataverse App User — repeat for each environment
pac admin create-service-principal --environment <dataverse-env-url-1>
pac admin create-service-principal --environment <dataverse-env-url-2>
# ... etc
```

The output includes:
- **Application (Client) ID** — save this; needed for Step 2 and the GitHub Environment variable
- **Tenant ID** — your Azure AD tenant ID (same for all environments in your tenant)

Repeat `pac admin create-service-principal` for each environment. Each run creates a unique app registration — you will get a different client ID per environment. You only need to run `pac auth create` once.

> **`pac` not installed?** Run `winget install Microsoft.PowerPlatform.CLI` (Windows) or follow [https://aka.ms/PowerAppsCLI](https://aka.ms/PowerAppsCLI).

---

## Step 2 — Add Federated Credentials

This creates the OIDC trust relationship. When a GitHub Actions job runs inside a GitHub Environment, GitHub issues a token whose `sub` (subject) claim is `repo:<org>/<repo>:environment:<env-slug>`. Azure AD matches this against the federated credential to issue an access token.

**Prerequisites:**
- Azure CLI installed: `winget install Microsoft.AzureCLI`
- Logged in: `az login`
- Owner on the app registration (or Privileged Role Admin in Azure AD)

**Run the helper script from `.platform` — once per environment:**

```powershell
# Run once per environment (each has its own app registration from Step 1)
.platform/.github/workflows/scripts/Setup-GitHubFederatedCredentials.ps1 `
    -AppRegistrationId "<env-1-client-id>" `
    -GitHubOrg "<githubOrg>" `
    -RepositoryName "<repoName>" `
    -Environments @("<env-slug-1>")

.platform/.github/workflows/scripts/Setup-GitHubFederatedCredentials.ps1 `
    -AppRegistrationId "<env-2-client-id>" `
    -GitHubOrg "<githubOrg>" `
    -RepositoryName "<repoName>" `
    -Environments @("<env-slug-2>")
# ... etc
```

The script:
1. Looks up the app registration by client ID
2. For each slug, creates a federated credential: `{ subject: "repo:<org>/<repo>:environment:<slug>", audience: "api://AzureADTokenExchange" }`
3. Skips any credential that already exists
4. Prints a created / skipped / error summary

**Running without the repo?** The equivalent bare Azure CLI commands are:

```powershell
az login

# Run once per environment slug
az ad app federated-credential create `
    --id "<client-id>" `
    --parameters '{
        "name": "github-<repoName>-<env-slug>",
        "issuer": "https://token.actions.githubusercontent.com",
        "subject": "repo:<githubOrg>/<repoName>:environment:<env-slug>",
        "description": "GitHub Actions OIDC for <env-slug>",
        "audiences": ["api://AzureADTokenExchange"]
    }'
```

---

## Step 3 — Set GitHub Environment Variables

Set `DATAVERSE_CLIENT_ID` for each environment in the GitHub repository. Also ensure the shared `AZURE_TENANT_ID` repo variable is set.

```powershell
$org  = "<githubOrg>"
$repo = "<repoName>"

# Per-environment — repeat for each slug
gh variable set DATAVERSE_CLIENT_ID --env <env-slug-1> --repo "$org/$repo" --body "<client-id-1>"
gh variable set DATAVERSE_CLIENT_ID --env <env-slug-2> --repo "$org/$repo" --body "<client-id-2>"

# Repository-level — Azure AD tenant (same for all environments)
# Derive automatically from your authentication rather than asking the user:
$tenantId = az account show --query tenantId -o tsv
# If az CLI is not available: (pac auth list | Select-String 'TenantId').ToString().Split(':')[-1].Trim()
gh variable set AZURE_TENANT_ID --repo "$org/$repo" --body "$tenantId"
```

---

## Step 4 — Verify

Trigger the `test-oidc-auth.yml` workflow for each environment:

```powershell
gh workflow run test-oidc-auth.yml --repo "$org/$repo"
gh run watch --repo "$org/$repo"
```

A green run confirms the full auth chain works. If it fails, check:
- The federated credential subject matches exactly: `repo:<org>/<repo>:environment:<env-slug>` (case-sensitive)
- The GitHub Environment slug in the workflow matches the slug in the credential
- The app registration has not been deleted or its client ID changed
- `az ad app federated-credential list --id <client-id>` shows the credential

---

## Admin Hand-Off Instructions

When the person setting up the repo is **not** the Power Platform Admin or Azure AD admin, generate this document filled in with the actual project values and share it with the appropriate admin.

---

**Subject: OIDC Setup Needed for GitHub Actions → Dataverse Authentication**

We are configuring GitHub Actions to deploy Power Platform solutions to Dataverse without storing passwords. This requires two one-time setup steps.

### Your environment details

| GitHub Environment Slug | Dataverse URL |
|-------------------------|---------------|
| `<env-slug-1>` | `<dataverse-url-1>` |
| `<env-slug-2>` | `<dataverse-url-2>` |
| `<env-slug-3>` | `<dataverse-url-3>` |

GitHub repo: `https://github.com/<githubOrg>/<repoName>`

---

### Task A — Create Service Principals *(Power Platform Admin)*

For each environment in the table above, run the following in PowerShell:

```powershell
# Install pac CLI if not already installed
winget install Microsoft.PowerPlatform.CLI

# Authenticate once — pac auth is per-tenant, not per-environment.
# Any environment URL in the target tenant works here.
pac auth create --environment <any-dataverse-env-url>

# Create the service principal and Dataverse App User — repeat for each environment
pac admin create-service-principal --environment <dataverse-env-url-1>
pac admin create-service-principal --environment <dataverse-env-url-2>
# ... etc
```

**Please send me** the **Application (Client) ID** and **Tenant ID** printed in the output for each environment. I will use these to complete the GitHub setup.

---

### Task B — Add Federated Credentials *(Azure AD App Owner)*

After Task A is complete, for each Application (Client) ID, run the following in PowerShell (Azure CLI required):

```powershell
# Install Azure CLI if not already installed
winget install Microsoft.AzureCLI

# Log in
az login

# For each environment — replace <client-id> and <env-slug> with the actual values
az ad app federated-credential create `
    --id "<client-id>" `
    --parameters '{
        "name": "github-<repoName>-<env-slug>",
        "issuer": "https://token.actions.githubusercontent.com",
        "subject": "repo:<githubOrg>/<repoName>:environment:<env-slug>",
        "description": "GitHub Actions OIDC for <env-slug>",
        "audiences": ["api://AzureADTokenExchange"]
    }'
```

Run this command once per environment slug, using the client ID for that environment's app registration.

Once done, please confirm — I will verify the authentication chain using a test workflow.

---

*(End of hand-off document)*

# Agentic-ALM-Workflows

Shared GitHub Actions workflows, PowerShell scripts, and Copilot agent skills for Power Platform ALM repos built from [Agentic-ALM-Template](https://github.com/mikefactorial/Agentic-ALM-Template).

## Purpose

This repo is the **single source of execution logic** for all ALM workflows. Solution repos contain only **thin callers** that pass inputs through to these callable workflows, and reference this repo as the `.platform` git submodule for local script access.

## Architecture

```
Your-Solution-Repo (caller repo)
  └── .github/workflows/sync-solution.yml  (thin caller)
        └── uses: mikefactorial/Agentic-ALM-Workflows/.github/workflows/sync-solution.yml@main
              └── Checks out caller repo + .platform (this repo's scripts)
              └── Runs .platform/.github/workflows/scripts/Sync-Solution.ps1
```

## How Script Access Works

Each callable workflow does **two checkouts**:

1. `actions/checkout@v4` (no path) → caller's repo (solution files, `deployments/`, `src/`)
2. `actions/checkout@v4` with `path: .platform` → this repo (scripts)

All script invocations use `.platform/.github/workflows/scripts/<Script>.ps1`.

## Authentication

All callable workflows authenticate using **OIDC (OpenID Connect)** — no stored passwords or secrets. Each GitHub Environment needs:

| Name | Type | Scope | Purpose |
|------|------|-------|---------|
| `DATAVERSE_URL` | variable | per GitHub Environment | Dataverse environment URL |
| `DATAVERSE_CLIENT_ID` | variable | per GitHub Environment | Azure AD app registration client ID |
| `AZURE_TENANT_ID` | variable | repository | Azure AD tenant ID (shared across environments) |
| `HOOK_VARIABLES` | variable | repository | Non-secret hook parameters (JSON object — initialize to `{}`) |
| `HOOK_SECRETS` | secret | repository | Hook context secrets (JSON object — initialize to `{}`) |

The Azure AD app registration must be added as a Dataverse App User and have a federated identity credential for each GitHub Environment. Use the `setup-oidc` skill or run `Setup-GitHubFederatedCredentials.ps1` to configure this.

## Callable Workflows

| Workflow | Description |
|----------|-------------|
| `sync-solution.yml` | Export and unpack a solution from a Dataverse environment to the repo |
| `build-deploy-solution.yml` | Build solution from branch and deploy to a target environment |
| `sync-build-deploy-solution.yml` | Sync from environment, build, and deploy in one pass |
| `promote-solution.yml` | Promote solution components from dev to integration (optional — inner loop can also run fully locally) |
| `create-release-package.yml` | Build all packages and create a versioned GitHub Release |
| `deploy-package.yml` | Outer-loop package deployment via `pac package deploy` |
| `validate-pull-request.yml` | Validate PR changes — detect changed components, build, run solution checker |

## PowerShell Scripts

Scripts live in `.github/workflows/scripts/` and are used both by callable workflows and directly for local inner-loop development.

| Script | Purpose |
|--------|---------|
| `Promote-Solution.ps1` | Export feature solution from dev, import to integration. Supports `-Phase All/Export/Import` |
| `Sync-Solution.ps1` | Export and unpack a solution from an environment to the repo (used by `sync-solution.yml` and locally) |
| `Build-Solutions.ps1` | Outer-loop CI build — builds all solution ZIPs from source |
| `Build-Plugins.ps1` | Build plugin assemblies |
| `Build-Controls.ps1` | Build PCF controls |
| `Build-Package.ps1` | Build Package Deployer package |
| `Deploy-Solutions.ps1` | Import solution(s) into a target environment |
| `Deploy-Package.ps1` | Run `pac package deploy` against a target environment |
| `Generate-DeploymentSettings.ps1` | Generate deployment settings files from templates |
| `Initialize-FeatureSolution.ps1` | Create a feature solution in Dataverse and set it as preferred |
| `Register-Plugin.ps1` | Register or update a plugin assembly and steps in Dataverse |
| `Setup-GitHubFederatedCredentials.ps1` | Add OIDC federated credentials to an Azure AD app registration for one or more GitHub Environments (requires Azure CLI) |
| `Validate-FeaturePromotion.ps1` | Pre-promote validation — check environment variables and connection references |
| `Validate-DeploymentSettings.ps1` | Validate deployment settings files before deploy |
| `Validate-EnvironmentReadiness.ps1` | Confirm a Dataverse environment is reachable and configured |
| `Create-FeatureCodePR.ps1` | Open a PR for code-first solution changes |
| `Detect-ChangedComponents.ps1` | Identify which solution components changed in a PR |
| `Detect-ChangedSolutions.ps1` | Identify which solutions changed in a PR |
| `Get-NextVersion.ps1` | Calculate the next date-based version (`YYYY.MM.DD.N`) from git tags |
| `Export-Configuration-Data.ps1` | Export config data records via `pac data export` |
| `Add-ToFeatureSolution.ps1` | Add components to the active feature solution |
| `Copy-Components.ps1` | Copy solution components between solutions |
| `Run-SolutionChecker.ps1` | Run the Power Platform solution checker |
| `Invoke-WebResourceLinting.ps1` | Lint web resources |

### Pipeline Hooks

Every major workflow stage exposes **pre/post hooks** — PowerShell scripts in the caller repo's `.github/workflows/scripts/hooks/` folder that run without modifying core pipeline logic. This is the primary extensibility point for project-specific steps: custom notifications, backup snapshots, external system integrations, additional validation, etc.

| Stage | Hook files |
|-------|-----------|
| Solution export | `Pre-Export-Hook.ps1`, `Post-Export-Hook.ps1` |
| Solution unpack | `Pre-Unpack-Hook.ps1`, `Post-Unpack-Hook.ps1` |
| Git commit | `Pre-Commit-Hook.ps1`, `Post-Commit-Hook.ps1` |
| Solution build | `Pre-Build-Hook.ps1`, `Post-Build-Hook.ps1` |
| Solution import/deploy | `Pre-Import-Hook.ps1`, `Post-Import-Hook.ps1`, `Pre-Deploy-Hook.ps1`, `Post-Deploy-Hook.ps1` |

Hook scripts receive a context object with relevant parameters for their stage (environment URL, solution name, commit message, etc.). They read shared configuration from two repo-level variables:

- `HOOK_VARIABLES` — non-secret JSON object (e.g. webhook URLs, environment identifiers)
- `HOOK_SECRETS` — secret JSON object (e.g. API keys, subscription keys)

Hooks fail silently by default (`ContinueOnError = $true`) — a failing hook does not stop the pipeline unless it explicitly throws. See `.github/workflows/scripts/hooks/README.md` for the full hook contract and `EXAMPLES.md` for common patterns.



ALM tasks are automated through the `power-platform-alm` Copilot plugin. Skills cover the full inner and outer loop — describing a task in plain English is enough; the `alm-overview` router picks the right specialist automatically.

| Skill | When to use |
|-------|-------------|
| `alm-overview` | Entry point — routes any ALM request to the right skill |
| `setup-client-repo` | First-time repo setup: fill `environment-config.json`, GitHub environments, secrets, branch protection |
| `setup-oidc` | Configure OIDC federated credentials; create service principals; generate admin hand-off instructions |
| `start-feature` | Create a feature branch and feature solution in Dataverse; set preferred solution |
| `build-solution` | Build solution ZIPs locally; validate plugins and PCF controls compile |
| `deploy-solution` | Deploy unmanaged to dev or managed to dev-test; import with deployment settings |
| `sync-solution` | Export solution from Dataverse and commit to source control |
| `manage-config-data` | Create config data schema; export records; import data via `pac data` |
| `register-plugin` | Push plugin binary to dev; register or update message processing steps |
| `scaffold-plugin` | Scaffold a new Dataverse plugin project and wire into the solution |
| `scaffold-pcf-control` | Scaffold a new PCF control and wire into the solution |
| `promote-solution` | Promote a validated feature from dev to integration via local scripts + sync PR |
| `create-release` | Merge develop → main; build release packages; create a GitHub Release |
| `deploy-package` | Deploy a release package to test or production via `pac package deploy` |

**Install in VS Code:**
- Extensions view (`Ctrl+Shift+X`) → search `@agentPlugins power-platform-alm`, **or**
- Command Palette → `Chat: Install Plugin From Source` → `https://github.com/mikefactorial/Agentic-ALM-Workflows`

**Already installed? Pull latest skills:**
- Command Palette → `Chat: Update Plugins (Force)`

## ALM Flow

```
Developer works in dev environment
         ↓
sync-solution.yml  (or Sync-Solution.ps1 locally)
  Exports + unpacks solution to feature branch
         ↓
PR → validate-pull-request.yml
  Detects changed plugins/controls/solutions
  Builds changed components + runs solution checker
         ↓
Promote-Solution.ps1 + Sync-Solution.ps1  (local inner loop)
  Promotes feature to integration via sync branch PR
         ↓
Merge develop → main
         ↓
create-release-package.yml
  Builds all solution packages
  Creates GitHub Release with versioned ZIPs + settings
         ↓
deploy-package.yml (manual dispatch)
  Downloads release assets
  Deploys via pac package deploy to target environment
```

## Using as a Submodule

Caller repos reference this repo as the `.platform` submodule. The [Agentic-ALM-Template](https://github.com/mikefactorial/Agentic-ALM-Template) repo provides the full setup — see its `SETUP.md` for onboarding instructions.

To initialize or update `.platform` in a caller repo:

```powershell
.\Initialize-Repo.ps1
```

## Versioning

Callers reference `@main` for latest, or a specific release tag (e.g. `@v2026.04.17.1`) for pinned stability.
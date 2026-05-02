---
name: deploy-solution
description: 'Deploy a feature solution to a dev or dev-test environment for inner loop testing. Use when: deploying to dev (unmanaged), deploying to dev-test (managed), preparing deployment settings, exporting config data, running pac solution import. Different from deploy-package (which is outer loop production deployment).'
---

# Deploy Solution

Inner-loop deployment covering two scenarios:
- **Scenario A: Unmanaged to dev** — push changes from source control back to the dev environment
- **Scenario B: Managed to dev-test** — full validated deployment with settings and data

## Skill boundaries

| Need | Use instead |
|------|-------------|
| Outer-loop deployment to test or production | `deploy-package` |
| Registering a plugin step (not deploying the full solution) | `register-plugin` |
| Syncing a solution from Dataverse to source control | `sync-solution` |
| Building a release package | `create-release` |

## Configuration

> Before proceeding, read `deployments/settings/environment-config.json`. Resolve dev and dev-test environment slugs and URLs from `solutionAreas[x].devEnv`, `innerLoopEnvironments[].url`, and `environments[]` (slugs ending in `-dev-test`). Do not use hardcoded values.

## Environment Reference

Read from `environment-config.json`:
- **dev** (unmanaged): `solutionAreas[x].devEnv` slug → `innerLoopEnvironments[].url`
- **dev-test** (managed): `environments[]` where slug ends in `-dev-test` → `.url`

> **Optional dev-test environment**: Before running Scenario B, check whether any entry in `environments[]` has a slug ending in `-dev-test` with a non-placeholder URL. If all matching entries have `{{PLACEHOLDER}}` URLs (or none exist), this repo was configured without a dev-test environment. Ask the user:
> *"Your repo doesn't have a dev-test environment configured. Which environment should be used for managed deployment testing? (e.g. your test environment slug)"*
> Resolve the URL from `environments[]` for the user-provided slug. If that URL is also a placeholder, fail with a message explaining the environment needs to be configured in `environment-config.json` first.

---

## Scenario A: Deploy Unmanaged to dev

Push source-controlled changes back to the dev environment. Use this after low-code changes (tables, forms, views) have been built locally and need to be reflected in Dataverse, or to refresh a colleague's dev.

```powershell
# Build solution ZIP directly from the cdsproj — no need for Build-Solutions.ps1 for dev
cd src/solutions/{solution}
dotnet build --configuration Debug

# Import unmanaged into dev
pac solution import `
    --path "bin/Debug/{solution}.zip" `
    --environment "https://{dev_url}" `
    --force-overwrite --publish-changes --activate-plugins
```

For code-first-only changes (plugins, PCF), push directly via `register-plugin` — no full solution deploy needed.

---

## Scenario B: Deploy Managed to dev-test

This is a multi-step process. Work through each step in order. Ask the user for input at each step where values are needed.

### Step 1 — Build and Deploy Unmanaged to dev

Always build from the current branch and push to dev first to ensure the environment reflects the latest source. This captures any local code-first changes (PCF builds, plugin binaries) before the sync.

```powershell
# Build solution ZIP directly from the cdsproj (produces both unmanaged + managed in bin/Debug)
cd src/solutions/{solution}
dotnet build --configuration Debug

# Import unmanaged into dev
pac solution import `
    --path "bin/Debug/{solution}.zip" `
    --environment "https://{dev_url}" `
    --force-overwrite --publish-changes --activate-plugins
```

### Step 2 — Sync from dev

Sync the solution from dev to capture the current state (including any low-code changes made in Dataverse) and regenerate the deployment settings template:

```powershell
.platform/.github/workflows/scripts/Sync-Solution.ps1 `
    -solutionName "{solution}" `
    -environmentUrl "https://{dev_url}" `
    -skipGitCommit
```

This generates (or updates) `deployments/settings/templates/{solution}_template.json`.

### Step 3 — Rebuild After Sync

The sync may have pulled down low-code changes from Dataverse (tables, forms, views, env vars) that weren't in the previous build. Rebuild now to produce ZIPs that include everything:

```powershell
# Rebuild solution from synced source (overwrites ZIPs from Step 1)
cd src/solutions/{solution}
dotnet build --configuration Debug
```

### Step 4 — Configure Deployment Settings

Check whether the solution has any connection references or environment variables to configure.

**4a. Read the template:**
```powershell
$template = Get-Content "deployments/settings/templates/{solution}_template.json" | ConvertFrom-Json
$connRefs = $template.ConnectionReferences
$envVars  = $template.EnvironmentVariables
```

If the template doesn't exist (solution has no connection refs or env vars), skip to Step 5.

**4b. Check for missing connection IDs** in `deployments/settings/connection-mappings.json` under the `{dev_test_environment}` key. For each connector type in the template that has no value or an empty string for the target environment:

- Show the connector type (e.g. `/providers/Microsoft.PowerApps/apis/shared_office365`)
- Ask the user: *"What is the connection ID for [connector] in {dev_test_environment}?"*
- Run `pac connection list --environment https://{dev_test_url}` to help them find it
- Update `connection-mappings.json` with the provided value

**4c. Check for missing environment variable values** in `deployments/settings/environment-variables.json` under the `{dev_test_environment}` key. For each variable required by the template that is missing, empty, or `<unset>`:

- Look up the variable's `type` from the `metadata` section of `environment-variables.json`
- Show the variable schema name, type, and current value
- Ask the user for the value
- Validate the provided value against the type before writing:
  - `String` — any value accepted
  - `Number` — must be parseable as a decimal number (`[double]::TryParse(...)`)
  - `Boolean` — must be `true` or `false`
  - `JSON` — must be valid JSON (`ConvertFrom-Json` without error)
  - `Secret` — any value accepted (stored as-is)
- If validation fails, tell the user the expected format and ask again
- Update `environment-variables.json` with the validated value

**4d. Generate the settings file:**
```powershell
.platform/.github/workflows/scripts/Generate-DeploymentSettings.ps1 `
    -solutionName "{solution}" `
    -targetEnvironment "{dev_test_environment}" `
    -templatePath "deployments/settings/templates/{solution}_template.json" `
    -outputPath "artifacts/{solution}_settings.json"
```

### Step 5 — Config Data (Optional)

Ask the user:
> "Does this feature require any configuration data to be imported into dev-test? (e.g. reference/lookup records, option set data)"

If **yes**:
- Config data always belongs to the **primary solution** (read `solutionAreas[x].mainSolution` from `environment-config.json`), not the feature solution.
  Check whether `deployments/data/{mainSolution}/ConfigData.xml` exists.
- If it exists, export the latest data from dev using the **primary solution name**:
  ```powershell
  .platform/.github/workflows/scripts/Export-Configuration-Data.ps1 `
      -SolutionName "{mainSolution}" `
      -EnvironmentUrl "https://{dev_url}"
  ```
  > **Important**: Always pass the primary solution name (i.e. `solutionAreas[x].mainSolution`) to `-SolutionName`, not the feature solution name.
  > Feature solutions have no config data folder.
- If `ConfigData.xml` does not exist yet, invoke the `manage-config-data` skill to create the schema and initial data before continuing here.

### Step 6 — Deploy Managed to dev-test

**Option A — Via Workflow Dispatch (recommended; auto-imports config data)**

Trigger `build-deploy-solution.yml` from GitHub Actions:
- **solution_name**: `{solution}`
- **target_environments**: `{dev_test_environment}`
- **data_solution_name**: `{mainSolution}` (read `solutionAreas[x].mainSolution` from `environment-config.json`; omit or leave blank if no config data in Step 5)

The workflow builds, deploys, and — when `data_solution_name` is provided — automatically runs `pac data import` via the Post-Deploy-ImportConfigData hook.

**Option B — Direct CLI**

```powershell
# Without settings (if no connection refs / env vars)
pac solution import `
    --path "src/solutions/{solution}/bin/Debug/{solution}_managed.zip" `
    --environment "https://{dev_test_url}" `
    --force-overwrite --publish-changes --activate-plugins

# With settings file (if Step 4 produced a settings file)
pac solution import `
    --path "src/solutions/{solution}/bin/Debug/{solution}_managed.zip" `
    --environment "https://{dev_test_url}" `
    --force-overwrite --publish-changes --activate-plugins `
    --settings-file "artifacts/{solution}_settings.json"
```

If you used Option B and exported config data in Step 5, continue to Step 7.

### Step 7 — Import Config Data (CLI path only)

*Skip this step if you used Option A (workflow dispatch) in Step 6 — config data was imported automatically.*

If you used Option B (direct CLI) and exported config data in Step 5:

```powershell
pac data import `
    --data "deployments/data/{mainSolution}/config-data" `
    --environment "https://{dev_test_url}"
```

---

## Verify

- Check Power Platform admin center → Solution History for successful import
- Test the feature in the target environment
- If issues: fix in dev → re-sync (Step 2) → rebuild (Step 3) → re-deploy (Step 6)

## After Validation in dev-test

Transport the feature to dev using the `transport-solution` skill.

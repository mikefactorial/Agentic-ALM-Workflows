---
name: deploy-package
description: 'Deploy a release package to a target environment. Use when: deploying to test or production, running outer-loop deployment, importing a release to an environment, promoting a release through environments. Uses pac package deploy.'
---

# Deploy Package

Deploy a package group from a GitHub Release to a target environment using `pac package deploy` (outer-loop deployment).

## Skill boundaries

| Need | Use instead |
|------|-------------|
| Inner-loop deployment to dev or dev-test | `deploy-solution` |
| Building the release package before deploying | `create-release` |
| Deploying only a solution (not a full package) | `deploy-solution` |

## Configuration

> Before proceeding, read `deployments/settings/environment-config.json`. Use `packageGroups[]` for valid package names and their solutions, and `environments[]` for valid deployment target slugs. Do not use hardcoded values.

## When to Use

- Deploying a release to test or production environments
- Running the outer-loop deployment after a release has been built
- Promoting validated changes through environment tiers

## Procedure

### 1. Validate Package-Environment Match

Read from `environment-config.json`:
- Valid package groups: `packageGroups[].name`
- Solutions in each package: `packageGroups[x].solutions`
- Valid environments for each package: `packageGroups[x].environments`

Confirm the chosen environment slug appears in `packageGroups[x].environments` for the selected package. If not, warn the user before proceeding.

### 2. Trigger via GitHub Actions

> **Do NOT run `pac package deploy` locally.** Developers typically do not have direct access to test or production Dataverse environments. All outer-loop deployments must go through the GitHub Actions workflow, which uses OIDC federated credentials configured for those environments.

Read `githubOrg` and `repoName` from `environment-config.json`, then trigger the workflow:

```powershell
gh workflow run deploy-package.yml `
    --repo "{githubOrg}/{repoName}" `
    --field environment="{environment}" `
    --field package="{package_group}" `
    --field release_tag="{release_tag}"
```

If deploying the latest release, omit `--field release_tag` or pass an empty string.

After triggering, get the run URL so the user can monitor progress:

```powershell
Start-Sleep -Seconds 3
$run = gh run list `
    --repo "{githubOrg}/{repoName}" `
    --workflow deploy-package.yml `
    --limit 1 `
    --json databaseId,url,status | ConvertFrom-Json | Select-Object -First 1

Write-Host "Deployment triggered. Monitor progress:"
Write-Host "  $($run.url)"
```

Tell the user:
> "The deployment has been triggered. You can monitor its progress here: {run.url}
> If the environment has an approval gate, reviewers will be notified to approve before the deploy proceeds."

### 3. What Happens

1. Downloads release artifacts (package ZIP + settings files) from GitHub Release
2. Looks up solutions for the package group from `environment-config.json`
3. Merges deployment settings into pipe-delimited format (connection references + environment variables)
4. If `packageGroups[x].managedIdentities` is configured, patches `applicationId` and `tenantId` inside the solution ZIP(s) for the target environment before import — see [Managed Identity Configuration](#managed-identity-configuration) below
5. Runs `pac package deploy --package <zip> --settings "<merged settings>"`
6. Post-deploy hooks activate flows and import configuration data

### Managed Identity Configuration

If any solution in the package uses `ManagedIdentityService.AcquireToken` (i.e., a plugin with a managed identity), each deployment environment needs its own Azure AD `applicationId` and `tenantId`. The deployer patches these values into `customizations.xml` inside the solution ZIP before import so the correct identity is used per environment.

Populate `managedIdentities[]` on the package group in `environment-config.json`:

```json
"managedIdentities": [
  {
    "name": "My Plugin Identity",
    "$comment_name": "Matches <name> in src/solutions/{solution}/ManagedIdentities/{name}/managedidentity.xml",
    "solutionName": "{solutionPrefix}_{solutionName}",
    "perEnvironment": {
      "{envPrefix}-dev-test": { "applicationId": "...", "tenantId": "..." },
      "{envPrefix}-test":     { "applicationId": "...", "tenantId": "..." },
      "{envPrefix}-prod":     { "applicationId": "...", "tenantId": "..." }
    }
  }
]
```

- `name` — the managed identity's internal `name` from Dataverse. Find it in `src/solutions/{solution}/ManagedIdentities/{name}/managedidentity.xml` → `<name>` element, or run `pac managed-identity get --component-type PluginPackage --component-id {guid}`
- Without this config, the managed identity retains the `applicationId`/`tenantId` baked in at sync time (the dev environment's identity), which will fail token acquisition in test/prod

### 4. Recommended Deployment Order

1. Deploy to test environments first (read target slugs from `packageGroups[x].environments` in `environment-config.json`)
2. Validate in test
3. Deploy to production environments (slugs ending in `-prod`) — requires approval

## Approval Gates

Production and test environments may have approval gates in GitHub environment settings. The workflow pauses and notifies reviewers before deploying.

## Troubleshooting

- **Auth errors**: Verify GitHub environment has `DATAVERSE_CLIENT_ID` and `DATAVERSE_URL`
- **Settings failures**: Run `Validate-DeploymentSettings.ps1` to check for missing values
- **Import conflicts**: Check Power Platform admin center → Solution History for running imports

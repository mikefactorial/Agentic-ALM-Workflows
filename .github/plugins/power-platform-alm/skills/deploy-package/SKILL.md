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

### 2. Execute via GitHub Actions

1. **Actions** → **Deploy Package** → **Run workflow**
2. Select environment: `{environment}`
3. Select package: `{package_group}`
4. Optionally enter release tag (blank = latest)

### 3. What Happens

1. Downloads release artifacts (package ZIP + settings files) from GitHub Release
2. Looks up solutions for the package group from `environment-config.json`
3. Merges deployment settings into pipe-delimited format
4. Runs `pac package deploy --package <zip> --settings "<merged settings>"`
5. Post-deploy hooks activate flows and import configuration data

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

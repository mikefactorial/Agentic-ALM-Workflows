---
name: create-release
description: 'Create a release by merging develop to main and deploying. Use when: cutting a release, promoting develop to production, building release packages, creating a GitHub release, preparing for production deployment.'
---

# Create Release

Guide the outer-loop release process: merge `develop` → `main`, trigger the automatic release build, then deploy to target environments.

## Skill boundaries

| Need | Use instead |
|------|-------------|
| Deploy a built release package to a specific environment | `deploy-package` |
| Inner-loop deployment to dev or dev-test | `deploy-solution` |
| Validate deployment settings without cutting a release | `deploy-solution` (Step 4) |

## Configuration

> Before proceeding, read `deployments/settings/environment-config.json`. Use `solutionAreas[].mainSolution` for the solution list, `environments[].slug` for the environment list, and `packageGroups[]` for the package group reference table. Do not use hardcoded values.

## When to Use

- All features for a release are staged and merged to `develop`
- Ready to promote to test/production environments
- Need to create versioned release packages

## Procedure

### 1. Prerequisites Check

Verify before proceeding:
- All features staged from dev → integration environments
- All feature branches merged to `develop`
- `develop` branch passing PR validation checks
- Deployment settings complete for all target environments

### 2. Validate Deployment Settings (Strict)

Run with `-StrictMode` — this treats **all** unconfigured environment variables and connection references as errors, not just placeholder/missing ones. The release must not proceed if any EVs or connection refs are unset.

```powershell
# SolutionList: comma-separated solutionAreas[].mainSolution values from environment-config.json
# TargetEnvironmentList: comma-separated environments[].slug values from environment-config.json
.platform/.github/workflows/scripts/Validate-DeploymentSettings.ps1 `
    -SolutionList "{all mainSolution values, comma-separated}" `
    -TargetEnvironmentList "{all environment slugs, comma-separated}" `
    -StrictMode
```

If the script reports errors, fill in the missing values before continuing:
- **Environment variables**: edit `deployments/settings/environment-variables.json` — add the value under the solution → environment key
- **Connection references**: edit `deployments/settings/connection-mappings.json` — run `pac connection list --environment <url>` to get the connection ID

Re-run until the script exits clean.

### 3. Create Pull Request: develop → main

1. GitHub → **Pull Requests** → **New Pull Request**
2. Base: `main` ← Compare: `develop`
3. Title: `release: <summary of changes>`
4. Request reviewers and wait for PR validation to pass

### 4. Merge the PR

After approval and checks pass, merge. This triggers `create-release-package.yml` automatically.

### 5. Monitor Build

1. **Actions** → **Build and Release Solutions**
2. Verify build completes with:
   - Package ZIPs (one managed + one unmanaged per package group from `environment-config.json`)
   - Deployment settings files for all environments
   - Version tag: `v{YYYY.MM.DD.N}`

### 6. Deploy to Environments

Deploy using `deploy-package` workflow:

**Recommended order:**
1. Test environments first (read from `packageGroups[x].environments` in `environment-config.json`)
2. Validate in test
3. Production environments (slugs ending in `-prod`) — requires approval

### 7. Verify Deployment

For each deployed environment:
- Check Power Platform admin center → Solution History
- Verify Cloud Flows are activated (post-deploy hook)
- Spot-check key functionality

## Package Group Reference

Read from `environment-config.json` `packageGroups[]`:

| Field | Description |
|---|---|
| `packageGroups[x].name` | Package group name (used as workflow input) |
| `packageGroups[x].solutions` | Solutions included in this package |
| `packageGroups[x].environments` | Valid deployment target slugs for this package |

## Versioning

Date-based: `YYYY.MM.DD.N` (e.g., `2026.04.06.1`). Auto-calculated from git tags by `Get-NextVersion.ps1`.

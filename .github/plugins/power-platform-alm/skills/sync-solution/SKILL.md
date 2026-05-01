---
name: sync-solution
description: 'Sync a Dataverse solution from an environment to the Git repository. Use when: exporting solution metadata, updating source control after Dataverse changes, capturing form/view/flow changes, refreshing deployment settings templates. Runs pac solution export and unpack.'
---

# Sync Solution

Export a solution from a Dataverse environment, unpack it, and commit the metadata to source control.

## When to Use

- After making low-code changes in Dataverse (forms, views, flows, tables) that need to be captured in source control
- To refresh deployment settings templates after adding environment variables or connection references

## Skill boundaries

| Need | Use instead |
|------|-------------|
| Transport a validated feature from preview to dev | `transport-solution` |
| Deploy a solution to preview or preview-test | `deploy-solution` |
| Build a solution ZIP | `build-solution` |
| Create and run a full preview-test deployment | `deploy-solution` |

## Configuration

> Before proceeding, read `deployments/settings/environment-config.json`. Use `solutionAreas[].devEnv` and `innerLoopEnvironments[].url` to determine dev/preview environment slugs and URLs. Do not use hardcoded values.

## Two Sync Contexts

There are two distinct reasons to sync — use the right one:

### Context A: Inner Loop (preview → feature branch)

Sync your feature solution FROM preview TO your feature branch during active development. Use the combined **Sync, Build, and Deploy** workflow:

1. **Actions** → **Sync, Build and Deploy Solution** → **Run workflow**
2. Select source environment: the preview environment slug for your solution area (read `solutionAreas[x].previewEnv` from `environment-config.json`)
3. Enter solution name: your feature solution (e.g., `AB12345_CreateInvoicingApp`)
4. Enter target environments: the preview-test environment slug for your solution area (read from `environments[]` in `environment-config.json`, slug ending in `-preview-test`)
5. Enter branch: your feature branch (e.g., `feat/AB12345_CreateInvoicingApp`)

This syncs the feature solution metadata, commits to your feature branch, then builds and deploys to preview-test in one step.

Alternatively, sync only (without build/deploy):

```powershell
.platform/.github/workflows/scripts/Sync-Solution.ps1 `
    -solutionName "{feature_solution}" `
    -environmentUrl "https://{preview_env}.crm.dynamics.com" `
    -skipGitCommit
```

### Context B: Post-Transport (dev → develop branch)

After a feature has been transported to dev, sync the main solution FROM dev TO the `develop` branch:

1. **Actions** → **Sync Solution** → **Run workflow**
2. Select environment: the dev environment slug for your solution area (read `solutionAreas[x].devEnv` from `environment-config.json`)
3. Enter solution name: main solution (e.g., `{solutionPrefix}_{solutionName}` — read from `solutionAreas[x].mainSolution`)
4. Enter commit message: `chore: sync {solution} from {environment} AB#{WorkItemNumber}` (include `AB#` only when sync is part of a tracked work item; omit for routine post-transport syncs to `develop`)
5. Enter branch: `develop`

#### Dev environment mapping:

Read from `environment-config.json`: for each solution area, `solutionAreas[x].devEnv` is the slug → look up `innerLoopEnvironments[].url` where slug matches.

#### Preview environment mapping:

Read from `environment-config.json`: for each solution area, `solutionAreas[x].previewEnv` is the slug → look up `innerLoopEnvironments[].url` where slug matches.

## After Sync

- Review changes in `src/solutions/{solution}/` — verify expected components were updated
- Check `deployments/settings/templates/{solution}_template.json` — if regenerated, update `connection-mappings.json` and/or `environment-variables.json` with values for any new entries

## Key Rules

- Templates in `deployments/settings/templates/` are auto-generated — never edit them directly
- If new environment variables or connection references appear in the template, add their values to `environment-variables.json` and `connection-mappings.json`

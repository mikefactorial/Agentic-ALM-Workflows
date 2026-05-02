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
| Transport a validated feature from dev to dev | `transport-solution` |
| Deploy a solution to dev or dev-test | `deploy-solution` |
| Build a solution ZIP | `build-solution` |
| Create and run a full dev-test deployment | `deploy-solution` |

## Configuration

> Before proceeding, read `deployments/settings/environment-config.json`. Use `solutionAreas[].integrationEnv` and `innerLoopEnvironments[].url` to determine dev/dev environment slugs and URLs. Do not use hardcoded values.

## Two Sync Contexts

There are two distinct reasons to sync — use the right one:

### Context A: Inner Loop (dev → feature branch)

Sync your feature solution FROM dev TO your feature branch during active development. Use the combined **Sync, Build, and Deploy** workflow:

1. **Actions** → **Sync, Build and Deploy Solution** → **Run workflow**
2. Select source environment: the dev environment slug for your solution area (read `solutionAreas[x].devEnv` from `environment-config.json`)
3. Enter solution name: your feature solution (e.g., `AB12345_CreateInvoicingApp`)
4. Enter target environments: the dev-test environment slug for your solution area (read from `environments[]` in `environment-config.json`, slug ending in `-dev-test`). If no dev-test entry exists with a real URL, ask the user which environment to deploy to instead.
5. Enter branch: your feature branch (e.g., `feat/AB12345_CreateInvoicingApp`)

This syncs the feature solution metadata, commits to your feature branch, then builds and deploys to dev-test in one step.

Alternatively, sync only (without build/deploy):

```powershell
.platform/.github/workflows/scripts/Sync-Solution.ps1 `
    -solutionName "{feature_solution}" `
    -environmentUrl "https://{dev_env}.crm.dynamics.com" `
    -skipGitCommit
```

### Context B: Post-Transport (integration → develop branch)

After a feature has been transported, sync the main solution FROM the integration (or equivalent) environment TO the `develop` branch.

**First, determine the source environment:** Read `solutionAreas[x].integrationEnv` from `environment-config.json` and look up its URL in `innerLoopEnvironments[]`. If the URL is a `{{PLACEHOLDER}}`, this repo has no dedicated integration environment — ask the user:
> *"Your repo doesn't have an integration environment configured. Which environment should be synced from after transport? (e.g. your dev or test environment slug)"*
Use the user-provided slug and resolve its URL from `innerLoopEnvironments[]` or `environments[]`.

1. **Actions** → **Sync Solution** → **Run workflow**
2. Select environment: the resolved integration (or alternative) environment slug
3. Enter solution name: main solution (e.g., `{solutionPrefix}_{solutionName}` — read from `solutionAreas[x].mainSolution`)
4. Enter commit message: `chore: sync {solution} from {environment} {trailer}` (include the trailer only when sync is part of a tracked work item; omit for routine post-transport syncs to `develop`)
5. Enter branch: `develop`

#### integration environment mapping:

Read from `environment-config.json`: for each solution area, `solutionAreas[x].integrationEnv` is the slug → look up `innerLoopEnvironments[].url` where slug matches. If the URL is a placeholder, use the user-chosen alternative.

#### dev environment mapping:

Read from `environment-config.json`: for each solution area, `solutionAreas[x].devEnv` is the slug → look up `innerLoopEnvironments[].url` where slug matches.

## After Sync

- Review changes in `src/solutions/{solution}/` — verify expected components were updated
- Check `deployments/settings/templates/{solution}_template.json` — if regenerated, update `connection-mappings.json` and/or `environment-variables.json` with values for any new entries

## Key Rules

- Templates in `deployments/settings/templates/` are auto-generated — never edit them directly
- If new environment variables or connection references appear in the template, add their values to `environment-variables.json` and `connection-mappings.json`

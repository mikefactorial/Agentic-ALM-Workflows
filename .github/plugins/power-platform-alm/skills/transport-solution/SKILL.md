---
name: transport-solution
description: 'Transport solution components from a dev environment to dev. Use when: promoting a feature from dev to integration, completing inner-loop development, handing off a validated feature, moving components from a feature solution to the main solution.'
---

# Transport Solution (Move to Dev)

Move a validated feature from dev/dev-test into the dev integration environment and the `develop` branch. This is the final inner-loop step before a release.

## When to Use

- A feature has been developed and tested in dev-test and is ready for integration
- Components need to move from a feature solution to the main solution in the integration environment
- Completing inner-loop development and merging changes to `develop`

## Skill boundaries

| Need | Use instead |
|------|-------------|
| Sync the solution from a dev environment to source control | `sync-solution` |
| Deploy to dev or dev-test for testing | `deploy-solution` |
| Cut a release and build release packages | `create-release` |
| Deploy a release package to test or production | `deploy-package` |

---

## Configuration

> Before proceeding, read `deployments/settings/environment-config.json`. Use `solutionAreas[x].devEnv` and `solutionAreas[x].integrationEnv` slugs, and resolve URLs from `innerLoopEnvironments[].url`. Do not use hardcoded values.

---

## How Changes Flow to Dev

A feature can contain two independent types of changes that travel via **different paths**. Understanding this is critical:

| Change type | Examples | Path to `develop` |
|-------------|----------|-------------------|
| **Solution components** | Tables, forms, views, flows, EVs, choices | Transport workflow → committed directly to `develop` |
| **Code-first components** | PCF controls, plugins | Clean code PR → feature branch → `develop` |

**The feature branch is never merged directly to `develop`.**
- Solution metadata from the feature branch went to `develop` via the transport sync commit.
- Code-first changes go to `develop` via a separate clean PR (branched off `develop` after transport).
- The feature solution (`src/solutions/{feature}/`) and its settings template never belong in `develop`.

```
feature branch ──────────────────────────────── (abandoned after extraction)
      │                                  │
      ├─ Transport ──────────────────► develop  ({mainSolution} sync commit)
      │
      └─ clean code PR (from develop) ─► develop  (PCF/plugin source + EV values)
```

---

## Environment Mapping

Read from `environment-config.json`: for each solution area, `solutionAreas[x].devEnv` is the source slug and `solutionAreas[x].integrationEnv` is the target slug. Resolve both URLs from `innerLoopEnvironments[].url`.

> **Optional integration environment**: Before running transport, check whether `solutionAreas[x].integrationEnv` resolves to a real URL in `innerLoopEnvironments[]`. If the URL value is a `{{PLACEHOLDER}}` or the slug maps to nothing, this repo was configured without a dedicated integration environment. In that case, ask the user:
> *"Your repo doesn't have an integration environment configured. Which environment should be used as the transport target? (e.g. your test or UAT environment slug)"*
> Use the user-provided slug and resolve its URL from `environments[]` instead. If the user-provided URL is also a placeholder, fail with a clear message explaining the environment is not yet configured in `environment-config.json`.

---

## Definition of Done

A feature is **not complete** until every applicable step below is finished:

| Feature type | Required steps | Complete when |
|---|---|---|
| Solution-only | Steps 2a → 2b → 2c | Transport sync commit is on `develop` |
| Code-first-only | Step 3 | Code PR is merged to `develop` |
| **Mixed (PCF and/or plugins + Dataverse components)** | **Steps 2a → 2b → 2c → 3** | **Transport sync commit AND code PR are both merged** |

> **Do not stop after transport.** Transport moves solution metadata only. PCF controls and plugins never travel via transport — they require a separate code PR (Step 3). If you stop after transport on a mixed feature, the code-first changes are permanently orphaned on the feature branch.

---

## Procedure

### Step 1 — Identify What This Feature Contains

Before starting, classify the changes:

- **Solution-only feature** (no PCF, no plugin changes): Steps 2a → 2b → 2c only, then done.
- **Code-first-only feature** (no Dataverse component changes): Step 3 only, then done.
- **Mixed feature** (both): Steps 2a → 2b → 2c → **then immediately Step 3** — the feature is not done until the code PR is merged.

Also identify any **new environment variables** added by this feature — these need values populated for all target environments before transport (Step 2a).

### Step 2 — Validate and Transport Solution Components

#### 2a. Validate EVs and Connection References (required before transport)

Run the pre-transport validation script to confirm that all environment variables and connection references in the feature template have values populated for every deployment environment:

```powershell
.platform/.github/workflows/scripts/Validate-FeatureTransport.ps1 `
    -FeatureSolutionName "{feature_solution}" `
    -MainSolutionName "{main_solution}"
```

The script checks **every environment** that deploys the main solution (all 9 in `environment-config.json`) and reports:
- `✗ KEY MISSING` — Add the EV key to `deployments/settings/environment-variables.json` for that environment section
- `✗ CONNECTOR MAPPING MISSING` — Add the connector type + connection ID to `deployments/settings/connection-mappings.json`
- `⚠ empty value` — Verify this is intentional; use `"<unset>"` to explicitly mark as not applicable

Fix all `✗` errors before proceeding. Commit any changes to the feature branch.

> **EV type rules**: Number → decimal string (`"42"`), Boolean → `"true"`/`"false"`, JSON → valid JSON string, String → any value

#### 2b. Execute Transport

##### Via GitHub Actions Workflow (required)

Actions → **Transport Solution** → Run workflow

Inputs:
- `source_solution_name`: Feature solution name (e.g., `AB9999_HelloWorldPCF`)
- `target_solution_name`: Main solution (e.g., `{solutionPrefix}_{solutionName}` from environment-config.json)
- `source_environment_url`: dev environment URL (from `innerLoopEnvironments[]` in environment-config.json)
- `target_environment_url`: integration environment URL — or the user-chosen alternative if integration is not configured (see Environment Mapping above)
- `sync_target_solution`: `true`
- `sync_commit_message`: `chore({mainSolution}): transport {tag} to integration {trailer}`
- `sync_branch_name`: `develop`

##### Via Local Script — NOT SUPPORTED

> **⛔ Do not run `Transport-Solution.ps1` locally and then commit to `develop`.** The transport script calls `Sync-Solution.ps1 -branchName develop`, which pushes a commit directly to the `develop` branch. Only repository admins can bypass branch protection rules — all other contributors will be blocked. Even for admins, doing this locally skips the branch protection in spirit and makes the commit history harder to trace.
>
> **Always use the `transport-solution.yml` GitHub Actions workflow** (see above). This is the only supported path.

#### 2c. Verify Transport

After transport + sync:
- `develop` has a new commit with updated `src/solutions/{mainSolution}/` and `deployments/settings/templates/{mainSolution}_template.json`
- The main solution in the integration environment contains the transported components
- If new EVs were added, `{mainSolution}_template.json` on `develop` will now include them

> **If this is a mixed feature (has PCF controls or plugins): do not stop here. Proceed immediately to Step 3.** Transport only moved solution metadata. The code-first components are still only on the feature branch.

### Step 3 — Create the Clean Code PR

> **Required for any feature that includes PCF controls or plugins, or that changes deployment settings or config data.** This is not optional — skipping it leaves code-first changes permanently orphaned on the feature branch.

Run the automated code PR script from the repo root:

```powershell
.platform/.github/workflows/scripts/Create-FeatureCodePR.ps1 `
    -FeatureBranch "feat/{tag}_{Description}" `
    -WorkItemNumber "{tag}" `
    -Description "{short description}"
```

The script uses a **branch-inversion strategy** to carry settings and config data forward without clobbering other features:

1. Creates `chore/{tag}_code` from `origin/{FeatureBranch}` — the feature branch is the starting point, so all code-first changes and deployment configuration added during development are already present
2. Strips the feature solution folder (`src/solutions/{featureSolution}/`) and its settings template via `git rm` — these never belong in `develop`
3. Merges `origin/develop` (3-way merge) — any conflicts between this feature's settings/data and other features already merged to `develop` are surfaced explicitly rather than silently overwritten
4. If no conflicts: pushes the branch and opens a PR
5. If no code-first changes were found (solution-only feature): exits cleanly — no PR is needed

**If there are merge conflicts** (typically in `connection-mappings.json`, `environment-variables.json`, or `deployments/data/`):

The script prints conflict resolution instructions and exits without pushing. Resolve the conflicts locally in the `chore/AB{####}_code` branch:
- For JSON settings files: keep entries from **both sides** — never drop entries added by another feature
- For `data.xml` conflicts: preserve records from both sides; if unsure, coordinate with the other developer

After resolving all conflicts:
```powershell
git add .
git commit --no-edit
```

Then re-run with `-OpenPROnly` to push the resolved branch and open the PR without redoing the merge:
```powershell
.platform/.github/workflows/scripts/Create-FeatureCodePR.ps1 `
    -FeatureBranch "feat/{tag}_{Description}" `
    -WorkItemNumber "{tag}" `
    -Description "{short description}" `
    -OpenPROnly
```

Use `-DraftPR` on either call if you want to review the PR before it is merge-ready.

### Step 4 — Clean Up

After the clean code PR is merged:

- The feature branch (`feat/AB{####}_{Description}`) can be deleted — it served its purpose
- The feature solution in the dev environment can be deleted from Dataverse (optional but recommended to keep environment tidy)
- `src/solutions/{feature_solution}/` and `deployments/settings/templates/{feature_solution}_template.json` should **not** be merged anywhere; they remain only on the feature branch which is now deleted

---

## What Gets Committed Where (Summary)

| Artifact | Destination | How |
|----------|------------|-----|
| Updated `src/solutions/{mainSolution}/` | `develop` | Transport sync commit |
| Updated `{mainSolution}_template.json` | `develop` | Transport sync commit |
| `src/controls/{solution}/{Control}/` | `develop` | Clean code PR |
| `src/plugins/{solution}/{Plugin}/` | `develop` | Clean code PR |
| `deployments/data/{mainSolution}/` | `develop` | Clean code PR (merge-based) |
| `deployments/settings/connection-mappings.json` | `develop` | Clean code PR (merge-based) |
| `deployments/settings/environment-variables.json` | `develop` | Clean code PR (merge-based) |
| `src/solutions/{featureSolution}/` | nowhere | Stays on feature branch (deleted) |
| `{featureSolution}_template.json` | nowhere | Stays on feature branch (deleted) |

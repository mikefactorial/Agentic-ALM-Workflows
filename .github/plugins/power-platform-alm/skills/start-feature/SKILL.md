---
name: start-feature
description: 'Start a new feature with a branch and feature solution. Use when: beginning a new work item, creating a feature solution in Dataverse, setting up a preferred solution, starting development on an AB#### work item, creating a feature branch, initializing a new capability or app.'
---

# Start a Feature

Create a feature branch and initialise a corresponding feature solution in Dataverse and locally, ready for development and inner-loop build/deploy.

## When to Use

- Starting work on a new work item (AB####)
- Beginning development of a new capability, table, form, flow, or app
- Before creating any new Dataverse components so they are auto-tracked

## Skill boundaries

| Need | Use instead |
|------|-------------|
| Scaffold a net-new plugin project | `scaffold-plugin` |
| Scaffold a net-new PCF control | `scaffold-pcf-control` |
| Deploy a feature solution to preview or preview-test | `deploy-solution` |
| Sync solution changes back to source control | `sync-solution` |

## Agent Intake

Before proceeding, gather the following from the user. Ask only for what is missing:

1. **Work item number** — Ask: *"What is the number of the Azure DevOps Feature, Story or Task for this feature?"* (This becomes the `AB####` prefix in the branch and solution name.)
2. **Brief description** — A short slug used in the branch and solution name (e.g. `AddCustomerValidation`).
3. **Branch type** — `feat` (default), `fix`, `chore`, `refactor`, `docs`, or `test`.
4. **Solution area** — Read `solutionAreas[].name` from `environment-config.json` and present those as options.

## Configuration

> Before proceeding, read `deployments/settings/environment-config.json`. Use it to determine valid solution area names (`solutionAreas[].name`), preview environment slugs (`solutionAreas[].previewEnv`), preview-test environment slugs (`environments[]` where slug ends in `-preview-test`), and environment URLs. Do not use hardcoded values.

## Prerequisites

- `pac` CLI installed and authenticated (`pac auth list` shows an active profile for the target tenant)
- `git` configured and `develop` checked out

---

## Procedure

### 1. Create the Feature Branch

Branch from `develop` using the naming convention `<type>/AB<WorkItemNumber>_BriefDescription`:

```powershell
git checkout develop
git pull origin develop
git checkout -b feat/AB{####}_{BriefDescription}
# e.g. feat/AB12345_CreateInvoicingApp
git push -u origin feat/AB{####}_{BriefDescription}
```

Types: `feat/`, `fix/`, `chore/`, `refactor/`, `docs/`, `test/`

> **Work item linking**: All commits on a feature branch must include `AB#{WorkItemNumber}` at the end of the commit message. This links the commit to the Azure DevOps work item automatically.
> Format: `<type>(<scope>): <description> AB#<WorkItemNumber>`
> Example: `feat({solutionPrefix}_{solutionName}): add customer validation plugin AB#12345`
> (Derive `solutionPrefix` and `solutionName` from `solutionAreas[]` in `environment-config.json`)

### 2. Initialize the Feature Solution

Run `Initialize-FeatureSolution.ps1` from the repo root. The script will:

- Check whether the feature solution already exists in the preview environment
- **If it does NOT exist**: run `pac solution init` locally and create it in Dataverse
- **If it already exists**: run `pac solution clone` to pull it locally
- The feature solution `.cdsproj` starts **empty** — only the components that change or are net-new in this feature are added (see Step 4)

```powershell
# From repo root — run from .platform/.github/workflows/scripts/
.platform/.github/workflows/scripts/Initialize-FeatureSolution.ps1 `
    -featureSolutionName "AB{####}_{BriefDescription}" `
    -solutionArea "{solutionName}" `
    -environmentUrl "{previewEnvUrl}"
```

**Solution Area ↔ Environment URL:**

- `-solutionArea`: the chosen `solutionAreas[x].name` from `environment-config.json`
- `-environmentUrl`: look up `solutionAreas[x].previewEnv` → find the matching entry in `innerLoopEnvironments[]` → use `.url`

The feature solution `.cdsproj` will be created at:
```
src/solutions/{featureSolutionName}/{featureSolutionName}.cdsproj
```

### 3. Set as Preferred Solution

This ensures all new components you create in Dataverse are automatically tracked in your feature solution:

1. Open [make.powerapps.com](https://make.powerapps.com) → select the preview environment
2. In the **Solutions** list, find your feature solution
3. Click the **...** menu → **Set as preferred solution**
4. Verify the banner at the top of make.powerapps.com shows your solution name

> **CRITICAL**: If you skip this step, new components will not be tracked and you will need to add them manually later.

### 4. Begin Development

As you create components in Dataverse (tables, forms, views, flows, choices), they are auto-tracked in your feature solution.

For code-first components, only add what changes in this feature:

#### Net-new plugin or PCF control

Use the `scaffold-plugin` or `scaffold-pcf-control` skill. Those skills wire the new project into **both** the parent solution `.cdsproj` (permanent home) and the feature solution `.cdsproj` automatically.

#### Modified existing plugin or PCF control

If you are changing an existing component, add it to the feature solution so it gets bundled in the feature build:

```powershell
.platform/.github/workflows/scripts/Add-ToFeatureSolution.ps1 `
    -featureSolutionName "AB{####}_{BriefDescription}" `
    -componentPath "src\plugins\{solutionPrefix}_{solutionName}\{publisher}.Plugins.{solutionName}.{Name}\{publisher}.Plugins.{solutionName}.{Name}.csproj"

# or for a PCF control:
.platform/.github/workflows/scripts/Add-ToFeatureSolution.ps1 `
    -featureSolutionName "AB{####}_{BriefDescription}" `
    -componentPath "src\controls\{solutionPrefix}_{solutionName}\PCF-{ControlName}\PCF-{ControlName}.pcfproj"
```

> Derive `solutionPrefix`, `solutionName`, and `publisher` from `environment-config.json`.

> The parent solution `.cdsproj` does **not** need to change for modified components — it already references them.

> **IMPORTANT**: The feature solution `.cdsproj` uses `Sdk="AlbanianXrm.CDSProj.Sdk/1.0.9"` — this is required for plugin packages (projects with a `<PackageId>`) to be included in the solution ZIP. Without it, plugin package projects are silently ignored during build and the assembly never lands in Dataverse. `Initialize-FeatureSolution.ps1` sets this automatically; if you create a `.cdsproj` manually, ensure the `Sdk` attribute is present and all `<ProjectReference>` entries include `PrivateAssets="All"`.

### 5. Build and Deploy to Preview (inner loop)

The feature solution `.cdsproj` contains only the plugins and PCF controls relevant to this feature. Build the feature solution directly from the `.cdsproj`, then import the unmanaged ZIP to preview:

```powershell
# From repo root
# 1. Build the feature solution ZIP
cd src/solutions/AB{####}_{BriefDescription}
dotnet build --configuration Debug --no-incremental

# 2. Deploy as unmanaged to the preview environment
# (slug and URL from environment-config.json: solutionAreas[x].previewEnv + innerLoopEnvironments[].url)
pac solution import `
    --path "bin/Debug/AB{####}_{BriefDescription}.zip" `
    --environment "{previewEnv_url}" `
    --force-overwrite --publish-changes --activate-plugins
```

For preview-test validation (before transporting to dev):

```powershell
# Use the deploy-solution skill/workflow path so the required sequence is followed:
# preview unmanaged import -> sync from preview -> rebuild -> preview-test managed import
```

Or trigger the `build-deploy-solution` GitHub Actions workflow (no sync required — builds from current branch).

---

## Development Iteration Loop

```
1. Make changes in preview (Dataverse + code-first)
2. Sync feature solution to feature branch  → sync-solution skill
3. Build + deploy to preview-test           → deploy-solution skill
4. Test in preview-test
5. Repeat until validated
6. Transport to dev                         → transport-solution skill
7. Merge feature branch → develop (PR)
```

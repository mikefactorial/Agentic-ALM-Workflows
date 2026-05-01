---
name: build-solution
description: 'Build a Dataverse solution locally or via GitHub Actions. Use when: building a solution ZIP, testing a build, validating code-first changes compile, deploying to preview-test, running the inner loop build step. Handles plugin pre-builds, PCF control pre-builds, and solution packaging.'
---

# Build Solution

Build a Dataverse solution from the current branch, producing managed and unmanaged ZIPs from the solution `.cdsproj`.

## Skill boundaries

| Need | Use instead |
|------|-------------|
| Full preview-test deployment (managed, with settings and data) | `deploy-solution` |
| Outer-loop release build and package creation | `create-release` |
| Deploying a release package to test or production | `deploy-package` |
| Registering a plugin step in a preview environment | `register-plugin` |

## Configuration

> Before proceeding, read `deployments/settings/environment-config.json`. Use `solutionAreas[].mainSolution` for solution names and resolve preview-test environment slugs/URLs from `environments[]` (slugs ending in `-preview-test`). Do not use hardcoded values.

## When to Use

- After making code-first changes (plugins, PCF controls, web resources) and needing to verify they compile
- To produce solution ZIPs from the current source before an unmanaged preview import or a later preview-test deployment
- To validate that solution metadata + code-first components integrate correctly

> For inner-loop preview or preview-test work, do **not** use `Build-Solutions.ps1`. In this repo the correct build path is `dotnet build` on the target `.cdsproj`. If the user wants preview-test validation, use the `deploy-solution` skill so the required preview → sync → rebuild → preview-test sequence is followed.

## Procedure

### 1. Determine What to Build

Identify the solution from `solutionAreas[].mainSolution` in `environment-config.json`, or a feature solution name provided by the user.

Check if code-first components changed:

```powershell
git status -- src/plugins/ src/controls/
```

### 2. Pre-Build Code-First Components (if changed)

If plugins changed:

```powershell
.platform/.github/workflows/scripts/Build-Plugins.ps1 -skipTests -artifactsPath ./artifacts
```

If PCF controls changed:

```powershell
.platform/.github/workflows/scripts/Build-Controls.ps1 -skipTests -artifactsPath ./artifacts
```

### 3. Build the Solution

```powershell
cd src/solutions/{solution}
dotnet build --configuration Debug --no-incremental
```

This writes the solution ZIPs to `src/solutions/{solution}/bin/Debug/`.

If the user wants to build a feature solution instead of a main solution, run the same command against that feature solution `.cdsproj`.

### 4. Verify Build Output

Expect in `bin/Debug/`:
- `{solution}_managed.zip`
- `{solution}.zip` (unmanaged)

### 5. Deploy (Optional)

For **preview** deployment, import the unmanaged ZIP directly:

```powershell
pac solution import `
    --path "bin/Debug/{solution}.zip" `
    --environment "{preview_url}" `
    --force-overwrite --publish-changes --activate-plugins
```

For **preview-test** deployment, do not deploy straight from this skill. Use `deploy-solution` so the repo-required sequence is followed:

1. Build and import unmanaged to preview
2. Sync from preview
3. Rebuild from synced source
4. Deploy managed to preview-test with settings/data if needed

## Environment Mapping

Read from `environment-config.json`: preview-test environments are in `environments[]` where `slug` ends in `-preview-test`. Resolve the URL from the same entry's `url` field.

## Inner Loop Context

```
1. Develop in preview environment
2. Sync solution to feature branch (sync-solution)
3. Use deploy-solution for preview-test validation
4. Test in preview-test
5. If validated: transport to dev, merge feature branch → develop
```

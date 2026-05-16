---
name: alm-overview
description: 'Tool routing for Power Platform ALM tasks — which skill handles which request. Use when the user mentions features, solutions, plugins, PCF controls, deployments, releases, or any ALM workflow task in a Power Platform project using the Agentic-ALM-Template.'
---

# Power Platform ALM — Skill Router

This skill routes requests to the correct specialist skill. Read this first, then invoke the right skill.

## Skill Index

| Skill | Handles |
|-------|---------|
| `alm-overview` | Routing and cross-cutting rules (this skill) |
| `setup-client-repo` | First-time repo setup from template; filling `environment-config.json`; GitHub environments, secrets, branch protection |
| `setup-oidc` | Configure OIDC federated credentials for one or more environments; create service principals via `pac admin create-service-principal`; run `Setup-GitHubFederatedCredentials.ps1`; generate admin hand-off instructions |
| `start-feature` | Create feature branch and feature solution; set preferred solution; begin inner-loop development |
| `build-solution` | Build solution ZIPs locally; validate code-first changes compile; pre-build plugins or PCF controls |
| `deploy-solution` | Deploy unmanaged to dev; deploy managed to dev-test with settings and data; full inner-loop deployment sequence |
| `sync-solution` | Export solution from Dataverse and commit to source control; refresh deployment settings templates |
| `manage-config-data` | Create config data schema; export records from dev to source control; import data into any environment via `pac data` |
| `register-plugin` | Push plugin binary to dev; register or update message processing steps; register custom APIs |
| `scaffold-plugin` | Create a new plugin project; wire into solution; register the first step |
| `scaffold-pcf-control` | Create a new PCF control; wire into solution; push to dev |
| `scaffold-web-resource` | Create a new TypeScript web resource; configure Vite IIFE build; wire map.xml into cdsproj |
| `scaffold-code-app` | Create a new Power Apps Code App (React+Vite); initialize with pac CLI; wire map.xml into cdsproj |
| `configure-managed-identity` | Sign plugin NuGet package; create/update managed identity record in Dataverse; link managed identity to plugin package |
| `promote-solution` | Promote validated feature from dev to integration; create clean code PR; complete inner-loop handoff |
| `create-release` | Merge develop → main; build release packages; create GitHub Release |
| `deploy-package` | Deploy a release package to test or production via `pac package deploy` |

## Routing Rules

### Always read `environment-config.json` first

Every ALM task depends on values from `deployments/settings/environment-config.json`. Read it at the start of any skill invocation to resolve:
- `solutionAreas[].name`, `.prefix`, `.mainSolution` — solution identifiers
- `solutionAreas[].devEnv`, `.integrationEnv` — inner-loop environment slugs
- `innerLoopEnvironments[].url` — resolve URLs from slugs
- `environments[]` — outer-loop deployment targets
- `publisher` — namespace prefix for plugins
- `packageGroups[]` — package-to-environment mapping for releases

### Inner loop vs outer loop

| Loop | Covers | Skills |
|------|--------|--------|
| **Inner loop** | Feature dev → dev → dev-test → promote to integration | `start-feature`, `build-solution`, `deploy-solution`, `sync-solution`, `register-plugin`, `scaffold-plugin`, `scaffold-pcf-control`, `promote-solution` |
| **Outer loop** | develop → main → release package → test/prod | `create-release`, `deploy-package` |

Never mix the two loops — `pac package deploy` (outer) is not interchangeable with `pac solution import` (inner).

### Solution import vs package deploy

- `pac solution import` — inner loop only; imports a single solution ZIP directly
- `pac package deploy` — outer loop only; deploys a versioned release package with all solutions and settings

### Script path convention

All PowerShell scripts are at `.platform/.github/workflows/scripts/` in the client repo. The `.platform/` directory is a git submodule pointing to `Agentic-ALM-Workflows`. If `.platform/` is empty, the user must run `.\Initialize-Submodules.ps1` first.

### Promotion runs locally

The promotion process (`promote-solution` skill) runs fully locally using `Promote-Solution.ps1` and `Sync-Solution.ps1`. It no longer requires the `promote-solution.yml` GitHub Actions workflow. The sync to `develop` is done via a PR from a local sync branch — not a direct push — so branch protection is respected without elevated permissions.

### PCF controls are never auto-tracked

After `pac pcf push`, the control must be manually added to the feature solution in make.powerapps.com. Remind the user of this step.

### dotnet build, not Build-Solutions.ps1, for inner loop

`Build-Solutions.ps1` is outer-loop CI only. Inner-loop builds always use `dotnet build` on the target `.cdsproj`.

### Uniform JS component toolchain (PCF controls, web resources, code apps)

All three JavaScript/TypeScript component types share the same pipeline pattern:

| Component | Source dir | Build cmd | cdsproj wiring | Quick inner-loop push |
|---|---|---|---|---|
| PCF control | `src/controls/{area}/PCF-{Name}/` | `npm run build` | `<ProjectReference>` to `.pcfproj` | `pac pcf push` |
| Web resource | `src/webresources/{area}/WR-{Name}/` | `npm run build` (Vite IIFE) | `map.xml` → `WebResources/{prefix}_/scripts/` | `pac solution import` |
| Code app | `src/codeapps/{area}/{AppName}/` | `npm run build` (Vite, hash disabled) | `map.xml` → `CanvasApps/{logicalName}_CodeAppPackages/` | `pac code push --solutionName` |

All three are pre-built by CI before `dotnet build` runs on the `.cdsproj`. The pre-build paths are registered in `environment-config.json` under `solutionAreas[x].controlPreBuildPaths`, `webResourcePreBuildPaths`, and `codeAppPreBuildPaths` respectively.

For code apps, content hashing must be disabled in `vite.config.ts` so that `map.xml` and `meta.xml` filenames remain stable across builds. Use `pac solution sync` after the first `pac code push` to capture the app's `meta.xml` and `_CodeAppPackages` folder into the solution source.

## When to Use Each Skill

| User says | Invoke |
|-----------|--------|
| "start a new feature", "create a feature branch", "begin work on AB#### or GitHub issue" | `start-feature` |
| "scaffold a plugin", "create a new plugin", "add server-side logic" | `scaffold-plugin` |
| "scaffold a PCF control", "create a UI component", "build a custom control" | `scaffold-pcf-control` |
| "scaffold a web resource", "create a form script", "create a ribbon script", "TypeScript web resource", "add client-side logic to a form" | `scaffold-web-resource` |
| "scaffold a code app", "create a standalone web app", "build a React app for Power Platform", "Power Apps code app" | `scaffold-code-app` |
| "register a plugin step", "push plugin to dev", "update plugin binary" | `register-plugin` |
| "managed identity", "sign plugin package", "link managed identity", "plugin needs to call Azure", "ManagedIdentityService" | `configure-managed-identity` |
| "build the solution", "compile", "validate the build" | `build-solution` |
| "deploy to dev", "deploy to dev-test", "import to test environment" | `deploy-solution` |
| "sync the solution", "export from Dataverse", "capture changes from environment" | `sync-solution` |
| "config data", "create schema", "export records", "import data", "seed data", "pac data" | `manage-config-data` |
| "promote to integration", "promote feature", "promote feature", "complete inner loop", "move to develop" | `promote-solution` |
| "cut a release", "merge develop to main", "create release package" | `create-release` |
| "deploy to test", "deploy to prod", "run outer-loop deployment" | `deploy-package` |
| "set up the repo", "configure for new client", "fill in environment-config" | `setup-client-repo` |
| "set up OIDC", "federated credentials", "service principal", "OIDC auth is failing", "generate admin instructions for Azure" | `setup-oidc` |

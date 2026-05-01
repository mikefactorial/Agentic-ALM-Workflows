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
| `start-feature` | Create feature branch and feature solution; set preferred solution; begin inner-loop development |
| `build-solution` | Build solution ZIPs locally; validate code-first changes compile; pre-build plugins or PCF controls |
| `deploy-solution` | Deploy unmanaged to dev; deploy managed to dev-test with settings and data; full inner-loop deployment sequence |
| `sync-solution` | Export solution from Dataverse and commit to source control; refresh deployment settings templates |
| `register-plugin` | Push plugin binary to dev; register or update message processing steps; register custom APIs |
| `scaffold-plugin` | Create a new plugin project; wire into solution; register the first step |
| `scaffold-pcf-control` | Create a new PCF control; wire into solution; push to dev |
| `transport-solution` | Move validated feature from dev to dev; create clean code PR; complete inner-loop handoff |
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
| **Inner loop** | Feature dev → dev → dev-test → dev transport | `start-feature`, `build-solution`, `deploy-solution`, `sync-solution`, `register-plugin`, `scaffold-plugin`, `scaffold-pcf-control`, `transport-solution` |
| **Outer loop** | develop → main → release package → test/prod | `create-release`, `deploy-package` |

Never mix the two loops — `pac package deploy` (outer) is not interchangeable with `pac solution import` (inner).

### Solution import vs package deploy

- `pac solution import` — inner loop only; imports a single solution ZIP directly
- `pac package deploy` — outer loop only; deploys a versioned release package with all solutions and settings

### Script path convention

All PowerShell scripts are at `.platform/.github/workflows/scripts/` in the client repo. The `.platform/` directory is a git submodule pointing to `Agentic-ALM-Workflows`. If `.platform/` is empty, the user must run `.\Initialize-Submodules.ps1` first.

### Transport goes through GitHub Actions

Never run transport locally and push to `develop`. The `transport-solution.yml` workflow is the only supported transport path — branch protection blocks direct pushes to `develop` for non-admins.

### PCF controls are never auto-tracked

After `pac pcf push`, the control must be manually added to the feature solution in make.powerapps.com. Remind the user of this step.

### dotnet build, not Build-Solutions.ps1, for inner loop

`Build-Solutions.ps1` is outer-loop CI only. Inner-loop builds always use `dotnet build` on the target `.cdsproj`.

## When to Use Each Skill

| User says | Invoke |
|-----------|--------|
| "start a new feature", "create a feature branch", "begin work on AB####" | `start-feature` |
| "scaffold a plugin", "create a new plugin", "add server-side logic" | `scaffold-plugin` |
| "scaffold a PCF control", "create a UI component", "build a custom control" | `scaffold-pcf-control` |
| "register a plugin step", "push plugin to dev", "update plugin binary" | `register-plugin` |
| "build the solution", "compile", "validate the build" | `build-solution` |
| "deploy to dev", "deploy to dev-test", "import to test environment" | `deploy-solution` |
| "sync the solution", "export from Dataverse", "capture changes from environment" | `sync-solution` |
| "transport to dev", "promote feature", "complete inner loop", "move to develop" | `transport-solution` |
| "cut a release", "merge develop to main", "create release package" | `create-release` |
| "deploy to test", "deploy to prod", "run outer-loop deployment" | `deploy-package` |
| "set up the repo", "configure for new client", "fill in environment-config" | `setup-client-repo` |

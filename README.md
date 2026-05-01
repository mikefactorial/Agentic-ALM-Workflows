# Agentic-ALM-Workflows

Shared GitHub Actions workflows and PowerShell scripts for Power Platform ALM repos.

## Purpose

This repo is the **single source of execution logic** for all ALM workflows. Solution repos contain only **thin callers** that pass inputs through to these callable workflows.

## Architecture

```
Your-Solution-Repo (caller repo)
  └── .github/workflows/sync-solution.yml  (thin caller)
        └── uses: mikefactorial/Agentic-ALM-Workflows/.github/workflows/sync-solution.yml@main
              └── Checks out caller repo + .platform (this repo's scripts)
              └── Runs .platform/.github/workflows/scripts/Sync-Solution.ps1
```

## How Script Access Works

Each callable workflow does **two checkouts**:

1. `actions/checkout@v4` (no path) → caller's repo (solution files, `deployments/`, `src/`)
2. `actions/checkout@v4` with `path: .platform` → this repo (scripts)

All script invocations use `.platform/.github/workflows/scripts/<Script>.ps1`.

## Authentication Requirements

All callable workflows require the following secrets (passed via `secrets: inherit` from callers):

| Secret | Required By | Purpose |
|--------|------------|---------|
| `APP_ID` | All workflows | GitHub App ID for cross-repo checkout + git push |
| `APP_PRIVATE_KEY` | All workflows | GitHub App private key |
| `HOOK_SECRETS` | Workflows using hooks | Hook context secrets |

The GitHub App must be installed on both the caller repo and this repo (`Agentic-ALM-Workflows`).

The App token is generated with `owner: ${{ github.repository_owner }}` scope so it can checkout this repo from within any caller repo's workflow run.

## Callable Workflows

| Workflow | Purpose |
|----------|---------|
| `sync-solution.yml` | Export + unpack solution from dev environment to repo |
| `build-deploy-solution.yml` | Build from branch + deploy to target environments |
| `deploy-package.yml` | Outer-loop package deployment via pac package deploy |
| `create-release-package.yml` | Build all packages + create GitHub Release |
| `pr-validation.yml` | Validate PR changes (build + solution checker) |

## ALM Flow

```
Developer works in dev environment
         ↓
sync-solution.yml
  Exports + unpacks solution to feature branch
         ↓
PR → pr-validation.yml
  Detects changed plugins/controls/solutions
  Builds changed components + runs solution checker
         ↓
Merge to develop / main
         ↓
create-release-package.yml
  Builds all solution packages
  Creates GitHub Release with versioned ZIPs + settings
         ↓
deploy-package.yml (manual)
  Downloads release assets
  Deploys via pac package deploy to target environment
```

## Using as a Submodule

Caller repos reference this repo as `.platform` submodule. The `Agentic-ALM-Template` repo provides the full setup — see its `SETUP.md` for onboarding instructions.

| `deploy-package.yml` | Outer-loop package deployment |
| `create-release-package.yml` | Build all packages + create GitHub Release |
| `pr-validation.yml` | Validate plugin/PCF/settings in PRs |

## Versioning

Callers reference `@main` for latest, or a specific release tag (e.g. `@v2026.04.17.1`) for pinned stability.

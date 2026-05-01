---
name: scaffold-pcf-control
description: 'Scaffold a new PCF (PowerApps Component Framework) control. Use when: creating a UI component, building a custom field control, building a dataset grid, adding a React component to a model-driven app form, creating a virtual control. Runs pac pcf init, wires into .cdsproj, sets up manifest and testing.'
---

# Scaffold a New PCF Control

Create a new PowerApps Component Framework control and wire it into the solution.

## When to Use

- A work item requires a custom UI component on a form
- A new field control, grid, or interactive widget is needed
- A React-based virtual control is needed for model-driven apps

## Skill boundaries

| Need | Use instead |
|------|-------------|
| Scaffold a plugin project | `scaffold-plugin` |
| Add an existing control to a feature solution | `start-feature` then `register-plugin` |
| Deploy the built control to preview | `deploy-solution` |
| Register plugin steps (not PCF) | `register-plugin` |

## Configuration

> Before proceeding, read `deployments/settings/environment-config.json`. Use `publisher`, `solutionAreas[x].prefix`, `solutionAreas[x].cdsproj`, and `solutionAreas[x].controlPreBuildPaths` to determine namespace, paths, and wiring. Do not use hardcoded values.

## Procedure

### 1. Determine Location

Read `deployments/settings/environment-config.json` for the chosen solution area:

| Config field | Used for |
|---|---|
| `solutionAreas[x].prefix` | PCF namespace (the `--namespace` argument to `pac pcf init`) |
| `solutionAreas[x].cdsproj` | Parent solution `.cdsproj` to wire the control into |
| `solutionAreas[x].controlPreBuildPaths` | List of existing control paths already registered (for reference) |

Control directory convention: `src/controls/{solutionAreaFolder}/PCF-{ControlName}/`

### 2. Initialize the Control

```powershell
cd src/controls/{solutionAreaFolder}
mkdir PCF-{ControlName}
cd PCF-{ControlName}

# --namespace: solutionAreas[x].prefix from environment-config.json
pac pcf init --namespace {prefix} --name {ControlName} --template {field|dataset} --run-npm-install
```

### 3. Wire into Solution .cdsproj

A net-new PCF control must be added to **two** `.cdsproj` files:

**Parent solution** (permanent home — use `solutionAreas[x].cdsproj` from `environment-config.json`):
```powershell
cd src/solutions/{solutionAreaFolder}
pac solution add-reference --path ../../controls/{solutionAreaFolder}/PCF-{ControlName}/PCF-{ControlName}.pcfproj
```

**Feature solution** (so the feature build includes it):
```powershell
cd src/solutions/{featureSolutionName}
pac solution add-reference --path ../../controls/{solutionAreaFolder}/PCF-{ControlName}/PCF-{ControlName}.pcfproj
```

Or use the helper script from repo root:
```powershell
.platform/.github/workflows/scripts/Add-ToFeatureSolution.ps1 `
    -featureSolutionName "{featureSolutionName}" `
    -componentPath "src\controls\{solution_folder}\PCF-{ControlName}\PCF-{ControlName}.pcfproj"
```

### 4. Configure the Control Manifest

For a React virtual control, update `ControlManifest.Input.xml`:

```xml
<?xml version="1.0" encoding="utf-8" ?>
<manifest>
  <control namespace="{prefix}" constructor="{ControlName}" version="0.0.1"
           display-name-key="{ControlName}" description-key="{ControlName} description"
           control-type="virtual">
    <!-- Add properties here -->
    <resources>
      <code path="index.ts" order="1"/>
      <platform-library name="React" version="16.8.6" />
      <platform-library name="Fluent" version="8.29.0" />
    </resources>
    <feature-usage>
      <uses-feature name="Utility" required="true" />
      <uses-feature name="WebAPI" required="true" />
    </feature-usage>
  </control>
</manifest>
```

### 5. Set Up Testing (recommended)

Create `jest.config.js`:

```javascript
module.exports = {
  preset: 'ts-jest',
  testEnvironment: 'jsdom',
  roots: ['<rootDir>/tests/'],
  transform: { '^.+\\.[t|j]sx?$': 'babel-jest' },
  setupFilesAfterEnv: ['./jest.setup.js'],
};
```

### 6. Register in Dataverse

**CRITICAL**: PCF controls are NOT auto-tracked by the preferred solution. After building:

1. `npm run build` in the control directory
2. `pac pcf push --publisher-prefix {prefix}` to push to preview environment
3. Manually add the control to your feature solution in make.powerapps.com

### 7. Verify

```powershell
cd src/controls/{solution_folder}/PCF-{ControlName}
npm run build

# Build the parent solution directly from its cdsproj
cd ../../../../solutions/{solution}
dotnet build --configuration Debug --no-incremental
```

## Key Rules

- Namespace must match the solution area prefix from `solutionAreas[x].prefix` in `environment-config.json`
- Use `import * as React from 'react'` (not `require('react')`)
- For `@fluentui/react@8.29.0`, use `@types/react@^16.14.0` (not ^18)
- If this control depends on shared packages, use `file:` references in `package.json`
- After development, sync the solution to capture the control's registration metadata

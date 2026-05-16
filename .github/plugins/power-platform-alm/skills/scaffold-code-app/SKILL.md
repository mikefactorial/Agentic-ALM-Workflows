---
name: scaffold-code-app
description: 'Scaffold a new Power Apps Code App. Use when: building a standalone web app hosted in Power Platform, creating a React/TypeScript app with Power Platform connectors, building a line-of-business web app that needs Dataverse data or Power Platform connectors. Scaffolds a Vite+React TypeScript project, initializes with pac CLI, configures map.xml in the cdsproj for solution packaging, and wires the pre-build path into environment-config.json.'
---

# Scaffold a New Code App

Create a new Power Apps Code App and wire it into the solution build pipeline. Code Apps are full single-page applications (React+Vite) that run hosted in Power Platform and have access to Power Platform connectors and Dataverse data. They compile from TypeScript/React to static assets and are integrated into the solution ZIP through a `map.xml` mapping in the `.cdsproj`.

## When to Use

- A work item requires a standalone web app hosted in Power Apps (not embedded on a form)
- The app needs Power Platform connectors (Dataverse, SharePoint, custom APIs, etc.)
- A rich React UI is needed that goes beyond what a PCF control can provide

## Skill boundaries

| Need | Use instead |
|------|-------------|
| UI component embedded on a model-driven form | `scaffold-pcf-control` |
| Form/ribbon script logic | `scaffold-web-resource` |
| Deploy the built solution to dev | `deploy-solution` |

## Prerequisites

- Code apps must be enabled on the target Power Platform environment by an admin (Settings > Product > Features > Power Apps code apps)
- End users need a Power Apps Premium license to run code apps
- Node.js LTS and Power Platform CLI (`pac`) must be installed

## Configuration

> Before proceeding, read `deployments/settings/environment-config.json`. Use `solutionAreas[x].prefix`, `solutionAreas[x].cdsproj`, `solutionAreas[x].mainSolution`, `solutionAreas[x].devEnv`, `innerLoopEnvironments`, and `solutionAreas[x].codeAppPreBuildPaths`. Do not hardcode values.

## Procedure

### 1. Determine Location

Read `deployments/settings/environment-config.json` for the chosen solution area:

| Config field | Used for |
|---|---|
| `solutionAreas[x].prefix` | Dataverse publisher prefix |
| `solutionAreas[x].cdsproj` | Solution `.cdsproj` to wire the app into |
| `solutionAreas[x].mainSolution` | Solution name for `pac code push --solutionName` |
| `solutionAreas[x].devEnv` | Slug for the dev inner-loop environment |
| `innerLoopEnvironments[].url` | Resolve dev env URL from the slug |
| `solutionAreas[x].codeAppPreBuildPaths` | Existing paths already registered (append here) |

Directory convention: `src/codeapps/{solutionAreaFolder}/{AppName}/`

### 2. Scaffold the Vite + React Project

```powershell
cd src/codeapps/{solutionAreaFolder}

# Scaffold from the official Microsoft Code Apps React+Vite template
npx degit github:microsoft/PowerAppsCodeApps/templates/react-vite {AppName}
cd {AppName}
npm install
```

> If the user prefers a framework-agnostic bare Vite template, use `github:microsoft/PowerAppsCodeApps/templates/vite` instead.

### 3. Disable Vite Content Hashing

Code Apps must have predictable output filenames so the `map.xml` paths are stable across builds. Open `vite.config.ts` and add `rollupOptions.output` to disable hashing:

```typescript
import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: {
      output: {
        entryFileNames: 'assets/index.js',      // no content hash
        chunkFileNames: 'assets/[name].js',
        assetFileNames: 'assets/[name][extname]',
      },
    },
  },
});
```

### 4. Initialize the Code App in the Dev Environment

This step registers the app in Dataverse, generates the `power.config.json` file that links the local project to the live app, and assigns the app a Dataverse logical name (used in step 6).

Resolve the dev environment URL from `innerLoopEnvironments` using `solutionAreas[x].devEnv` as the slug.

```powershell
# Run from inside the project directory
pac code init `
  --displayName "{AppName}" `
  --environment "{devEnvironmentUrl}"
```

`pac code init` creates `power.config.json` and registers the app in Dataverse without requiring a build first. After initialization, add it to the feature solution and push the built assets:

```powershell
npm run build

pac code push `
  --solutionName "{featureSolutionName}" `
  --environment "{devEnvironmentUrl}"
```

> `pac code init` is the correct initialization command. Do not use `pac code push --displayName` to initialize — that pattern may silently omit the solution association on first run.

### 5. Sync the Solution to Capture the App Metadata

After the first push, the app has a Dataverse logical name (e.g. `{prefix}_{appname}_{hash}`). Run `pac solution sync` to pull the solution source — including the Code App's `meta.xml` and `_CodeAppPackages` folder — into the local solution source tree.

```powershell
# From the solution directory
pac solution sync --solution-folder src/solutions/{mainSolution}/src --environment {devEnvironmentUrl}
```

Or invoke the `sync-solution` skill, which runs `Sync-Solution.ps1`.

After sync, the solution source will contain:
```
src/solutions/{mainSolution}/src/CanvasApps/
  {logicalName}.meta.xml
  {logicalName}_CodeAppPackages/
    index.html
    assets/
      index.js
      index.css
```

Note the `{logicalName}` — you need it for the map.xml in the next step.

### 6. Add map.xml to the cdsproj

In the solution directory (where `solutionAreas[x].cdsproj` lives), create or update `map.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<Mapping>
  <!-- {AppName}: Code App — reads compiled dist/ output during solution pack -->
  <Folder
    map="CanvasApps\{logicalName}_CodeAppPackages"
    to="..\..\..\codeapps\{solutionAreaFolder}\{AppName}\dist" />
</Mapping>
```

> **Path note**: Paths in map.xml are relative to the solution source folder (`src/solutions/{mainSolution}/src/`), **not** the `.cdsproj` file. `..\..\..\` navigates up three levels to `src/`, then into `codeapps/`. The `<Folder>` element maps the entire directory tree — the hierarchy of `dist/` must exactly match the `_CodeAppPackages/` folder structure (which it does when Vite content hashing is disabled). The `{logicalName}` is the value captured from the sync in step 5 (e.g. `acm_myapp_4a3f2`).

Reference the map file in the `.cdsproj` `PropertyGroup`:

```xml
<PropertyGroup>
  <!-- existing properties ... -->
  <SolutionPackagerSwitches>/map:map.xml</SolutionPackagerSwitches>
</PropertyGroup>
```

If `SolutionPackagerSwitches` already exists (e.g., from a prior component), append a new `<Folder>` element to the existing `map.xml` rather than creating a second `SolutionPackagerSwitches` entry.

### 7. Commit the meta.xml with Static Filenames

Open the synced `{logicalName}.meta.xml` and verify the `<CodeAppPackageUris>` block references the static (non-hashed) filenames configured in step 3:

```xml
<CodeAppPackageUris>
  <CodeAppPackageUri>/CanvasApps/{logicalName}_CodeAppPackages/index.html_ContentType_text/html</CodeAppPackageUri>
  <CodeAppPackageUri>/CanvasApps/{logicalName}_CodeAppPackages/assets/index.js_ContentType_application/javascript</CodeAppPackageUri>
  <CodeAppPackageUri>/CanvasApps/{logicalName}_CodeAppPackages/assets/index.css_ContentType_text/css</CodeAppPackageUri>
</CodeAppPackageUris>
```

If the filenames in `meta.xml` still contain Vite content hashes (from before step 3 was applied), update them to match the static names. Commit this file — it only needs to be updated when asset filenames change (which they won't, since hashing is disabled).

### 8. Update environment-config.json

Add the code app project path to `solutionAreas[x].codeAppPreBuildPaths`:

```json
{
  "solutionAreas": [
    {
      "codeAppPreBuildPaths": [
        "src/codeapps/{solutionAreaFolder}/{AppName}"
      ]
    }
  ]
}
```

This path is read by `Build-CodeApps.ps1` during CI outer-loop pre-builds.

### 9. Verify

```powershell
# Build the app
cd src/codeapps/{solutionAreaFolder}/{AppName}
npm run build
# Expect: dist/index.html, dist/assets/index.js, dist/assets/index.css (no hashes)

# Build the solution (map.xml copies dist/ into the solution CanvasApps package folder)
cd src/solutions/{mainSolution}
dotnet build --configuration Debug --no-incremental
```

## Inner Loop Development

### Local development server
```powershell
cd src/codeapps/{solutionAreaFolder}/{AppName}
npm run dev   # starts Vite dev server with Power Platform connection proxy
```

Open the `Local Play` URL shown in the output (must be the same browser profile as your Power Platform tenant).

### Quick push to dev (mirrors `pac pcf push`)
```powershell
npm run build
pac code push --solutionName "{featureSolutionName}" --environment "{devEnvironmentUrl}"
```

> `pac code push` (without `--displayName`) requires `power.config.json` to already exist from the initial `pac code init` step. This is the rapid inner-loop command — do not use `pac code init` again after setup.

### Full build (for solution import / PR validation)
```powershell
cd src/codeapps/{solutionAreaFolder}/{AppName}
npm run build

cd src/solutions/{mainSolution}
dotnet build --configuration Debug --no-incremental
pac solution import --path bin/Debug/{mainSolution}.zip --environment "{devEnvironmentUrl}"
```

### Adding data sources / connectors
```powershell
pac code add-data-source --apiId {connectorApiId} --environment "{devEnvironmentUrl}"
```

After adding a connector, run `pac solution sync` to capture the new connection reference in the solution source.

## Key Rules

- Content hashing **must be disabled** in `vite.config.ts` — static filenames are required for stable `map.xml` and `meta.xml` references across builds
- The `_CodeAppPackages` folder name is derived from the app's Dataverse logical name, which is set on first push — do not rename the folder after committing
- The `meta.xml` `<CodeAppPackageUris>` must exactly match the files produced by `npm run build`; update it if you add new entry points or change asset names
- Do not commit the `dist/` folder — it is built by CI via `Build-CodeApps.ps1`
- Code apps require **Power Apps Premium** licenses for end users
- Code apps do **not** support Power Platform Git integration — source control is managed through this repo only
- If this app shares utility code with web resources or other code apps, use `file:` references in `package.json` (same pattern as PCF controls)

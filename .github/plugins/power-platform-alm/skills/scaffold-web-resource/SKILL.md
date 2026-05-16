---
name: scaffold-web-resource
description: 'Scaffold a new TypeScript Web Resource project. Use when: creating a form script, creating a ribbon command script, building custom JavaScript/TypeScript logic for model-driven apps, adding a web resource to a Dataverse solution. Scaffolds a Vite library-mode TypeScript project, configures map.xml in the cdsproj, and wires the pre-build path into environment-config.json.'
---

# Scaffold a New Web Resource

Create a new TypeScript web resource project and wire it into the solution build pipeline. Web resources compile from TypeScript to a single JS bundle via Vite and are integrated into the solution ZIP through a `map.xml` mapping in the `.cdsproj`.

## When to Use

- A work item requires form script logic (OnLoad, OnChange, OnSave handlers)
- A ribbon command action needs a JavaScript handler
- Custom client-side logic for a model-driven app is needed that doesn't warrant a full PCF control

## Skill boundaries

| Need | Use instead |
|------|-------------|
| Interactive UI component on a form | `scaffold-pcf-control` |
| Standalone web app hosted in Power Apps | `scaffold-code-app` |
| Deploy the built solution to dev | `deploy-solution` |

## Configuration

> Before proceeding, read `deployments/settings/environment-config.json`. Use `solutionAreas[x].prefix`, `solutionAreas[x].cdsproj`, `solutionAreas[x].mainSolution`, and `solutionAreas[x].webResourcePreBuildPaths` to determine paths, naming, and wiring. Do not hardcode values.

## Procedure

### 1. Determine Location

Read `deployments/settings/environment-config.json` for the chosen solution area:

| Config field | Used for |
|---|---|
| `solutionAreas[x].prefix` | Dataverse web resource logical name prefix (e.g. `acm`) |
| `solutionAreas[x].cdsproj` | Solution `.cdsproj` to wire the web resource map into |
| `solutionAreas[x].mainSolution` | Solution folder name for map.xml path resolution |
| `solutionAreas[x].webResourcePreBuildPaths` | Existing paths already registered (append here) |

Directory convention: `src/webresources/{solutionAreaFolder}/WR-{Name}/`

Logical name convention: `{prefix}_/scripts/{Name}.js` (e.g. `acm_/scripts/AccountForm.js`)

### 2. Scaffold the Vite TypeScript Project

```powershell
cd src/webresources/{solutionAreaFolder}
mkdir WR-{Name}
cd WR-{Name}

# Scaffold with Vite vanilla-ts template then configure for library/IIFE mode
npm create vite@latest . -- --template vanilla-ts
npm install
```

### 3. Configure vite.config.ts for Library/IIFE Mode

Replace the generated `vite.config.ts` with a library-mode config that:
- Compiles to a single IIFE bundle (no ES module chunks)
- Disables content hashing so filenames are predictable for map.xml
- Sets output to `dist/`

```typescript
import { defineConfig } from 'vite';
import { resolve } from 'path';

export default defineConfig({
  build: {
    lib: {
      entry: resolve(__dirname, 'src/main.ts'),
      name: '{Name}',        // global var name for IIFE
      formats: ['iife'],
      fileName: () => '{Name}.js',  // predictable filename — no hash
    },
    outDir: 'dist',
    emptyOutDir: true,
    rollupOptions: {
      output: {
        // No content hash in asset filenames
        assetFileNames: '[name][extname]',
      },
    },
  },
});
```

Update `package.json` scripts:
```json
{
  "scripts": {
    "dev": "vite",
    "build": "tsc -b && vite build",
    "lint": "eslint . --ext ts",
    "preview": "vite preview"
  }
}
```

### 4. Configure tsconfig.json

Ensure `tsconfig.json` references the Dataverse types for form/ribbon scripting:

```json
{
  "compilerOptions": {
    "target": "ES2018",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "strict": true,
    "outDir": "./dist",
    "rootDir": "./src"
  }
}
```

Install Dataverse typings if the web resource uses the Xrm API:
```powershell
npm install --save-dev @types/xrm
```

### 5. Write the Entry Point

`src/main.ts` should export the namespace object that Dataverse will call. For a form script:

```typescript
export namespace {Name} {
  export function onLoad(executionContext: Xrm.Events.EventContext): void {
    const formContext = executionContext.getFormContext();
    // your logic here
  }

  export function onChange(executionContext: Xrm.Events.EventContext): void {
    const formContext = executionContext.getFormContext();
    // your logic here
  }
}
```

For an IIFE build, the `{Name}` export becomes `window.{Name}` at runtime — the function name registered in the form designer must match (e.g. `{Name}.onLoad`).

### 6. Add map.xml to the cdsproj

In the solution directory (where `solutionAreas[x].cdsproj` lives), create or update `map.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<Mapping>
  <!-- {Name}: TypeScript web resource — reads compiled output from dist/ during solution pack -->
  <FileToPath
    map="WebResources\{prefix}_\scripts\{Name}.js"
    to="..\..\..\webresources\{solutionAreaFolder}\WR-{Name}\dist" />
</Mapping>
```

> **Path note**: Paths in map.xml are relative to the solution source folder (`src/solutions/{mainSolution}/src/`), **not** the `.cdsproj` file. `..\..\..\` navigates up three levels to `src/`, then into `webresources/`. The `map` attribute is the path SolutionPackager expects inside the solution source; `to` is where it should actually read the file from.

Then reference the map file in the `.cdsproj`. Open the `.cdsproj` and add `SolutionPackagerSwitches` to the `PropertyGroup` if not already present:

```xml
<PropertyGroup>
  <!-- existing properties ... -->
  <SolutionPackagerSwitches>/map:map.xml</SolutionPackagerSwitches>
</PropertyGroup>
```

If `SolutionPackagerSwitches` already exists (e.g., from a prior component), append a new `<FileToPath>` element to the existing `map.xml` file rather than creating a second `SolutionPackagerSwitches` entry.

### 7. Register the Web Resource in the Solution Source

After building (`npm run build`), the compiled `dist/{Name}.js` must exist in the solution's `WebResources/{prefix}_/scripts/` folder so the solution packager can find it. This happens automatically when `dotnet build` runs (the map.xml instructs the packager where to copy from).

For the **first time** only, you must also add the web resource metadata to the solution source so it appears in `customizations.xml`. Do this by:

1. Create the resource in Dataverse via make.powerapps.com (add it to your feature solution), then run `pac solution sync` to pull the metadata into `src/`.
2. Or manually add the `<WebResource>` entry to `customizations.xml` (follow the existing pattern for any web resources already present).

### 8. Update environment-config.json

Add the web resource project path to `solutionAreas[x].webResourcePreBuildPaths`:

```json
{
  "solutionAreas": [
    {
      "webResourcePreBuildPaths": [
        "src/webresources/{solutionAreaFolder}/WR-{Name}"
      ]
    }
  ]
}
```

This path is read by `Build-WebResources.ps1` during CI outer-loop pre-builds.

### 9. Verify

```powershell
# Build the TypeScript project
cd src/webresources/{solutionAreaFolder}/WR-{Name}
npm run build
# Expect: dist/{Name}.js

# Build the solution (map.xml copies the file in during pack)
cd src/solutions/{mainSolution}
dotnet build --configuration Debug --no-incremental
```

## Inner Loop Development

For iterative development:

1. Edit TypeScript source in `src/`
2. `npm run build` to compile
3. `dotnet build` on the `.cdsproj` to pack the solution ZIP
4. `pac solution import` (unmanaged) to push to dev environment

For type-checking without a full build:
```powershell
npx tsc --noEmit
```

## Key Rules

- Vite must be configured in **library/IIFE mode** — not the default SPA mode — so the output is a single JS file suitable for a form script
- Content hashing **must be disabled** (`fileName: () => '{Name}.js'`) so map.xml paths are stable across builds
- Logical name convention: `{prefix}_/scripts/{Name}.js` — must match the web resource name registered in Dataverse
- If this web resource shares utility code with others, use `file:` references in `package.json` to a shared package (same pattern as PCF controls)
- Do not commit the `dist/` folder — it is built by CI via `Build-WebResources.ps1`
- After making changes to the web resource, sync the solution if any Dataverse-side registration changes were made (`pac solution sync`)

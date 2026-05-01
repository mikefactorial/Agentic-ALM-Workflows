---
name: register-plugin
description: 'Register a plugin package or assembly in a Dataverse dev environment. Use when: pushing plugin code to an environment, registering message processing steps, updating plugin binaries, registering custom APIs, testing plugin changes in the inner loop. Replaces Plugin Registration Tool (PRT).'
---

# Register Plugin

Push a plugin binary and register steps/images in a Dataverse dev environment using `Register-Plugin.ps1`.

## When to Use

- After building a plugin and needing to push it to a dev environment for testing
- When adding a new message processing step (Create/Update/Delete handler)
- When registering a custom API
- During inner-loop development: edit C# → build → register → test

## Skill boundaries

| Need | Use instead |
|------|-------------|
| Scaffold a net-new plugin project (create .csproj, class, wire into solution) | `scaffold-plugin` |
| Deploy a full solution ZIP to dev or dev-test | `deploy-solution` |
| Sync registered steps back to source control | `sync-solution` |

## Configuration

> Before proceeding, read `deployments/settings/environment-config.json`. Use `solutionAreas[x].devEnv` and `innerLoopEnvironments[].url` to resolve dev environment URLs. Do not use hardcoded values.

## Scenarios

### Scenario A — Updating an existing plugin (step already registered)

The plugin package already exists in the environment with registered steps. You only need to push the updated binary.

Go to **Procedure → Step 2**.

### Scenario B — Adding a new step to an existing plugin project

The plugin project already ships in the parent solution, but you are adding a brand-new plugin class (and therefore a brand-new step) as part of a feature. The package does not yet contain this type in the environment.

**Required sequence:**

1. Add the plugin project to the feature solution `.cdsproj` (so the feature build includes it)
2. Build the feature solution `dotnet build` .cdsproj and deploy it **unmanaged** to the dev environment (this creates/updates the plugin package record in Dataverse, making the new type available)
3. Register the new step, scoping it to the feature solution

See **Procedure → Steps 1, 2, and 4** in that order.

### Scenario C — Net-new plugin project (never existed in environment)

Use the `scaffold-plugin` skill first (it covers project creation, solution wiring, build, **and** step registration via Steps 7a–7d). If you have already scaffolded the plugin but skipped step registration, follow **Steps 1 and 4** of this skill in that order:

1. **Step 1** — add to feature solution, build, and deploy unmanaged to dev (makes the plugin type available)
2. **Step 4** — register the new step and sync the feature solution

Do not skip to Step 2 — there are no pre-existing steps to update for a net-new plugin.

---

## Procedure

### 1. Add Plugin to Feature Solution and Deploy to dev

**Required for Scenario B** — before step registration the new plugin type must exist in the environment. Deploy the feature solution unmanaged to dev:

```powershell
# Step 1a — ensure the plugin project is in the feature solution .cdsproj
.platform/.github/workflows/scripts/Add-ToFeatureSolution.ps1 `
    -featureSolutionName "{featureSolution}" `
    -componentPath "src\plugins\{solutionFolder}\{PluginProjectDir}\{PluginProject}.csproj"

# Step 1b — build the feature solution ZIP directly from the cdsproj
# (Use dotnet build on the cdsproj — no need for Build-Solutions.ps1 for dev)
cd src/solutions/{featureSolution}
dotnet build --configuration Debug

# Step 1c — deploy unmanaged to the dev environment
pac solution import `
    --path "bin/Debug/{featureSolution}.zip" `
    --environment "{devEnv_url from innerLoopEnvironments}" `
    --force-overwrite --publish-changes --activate-plugins
```

This creates the plugin package record in Dataverse and registers all plugin types, making them available for step registration.

### 2. Push + Register from Solution XML (Existing Plugin)

Most common scenario — plugin already exists in the environment with steps defined in `SdkMessageProcessingSteps/*.xml`:

```powershell
.platform/.github/workflows/scripts/Register-Plugin.ps1 `
    -EnvironmentUrl "{environment_url}" `
    -SolutionPath "src/solutions/{solution}" `
    -PluginName "{plugin_package_name}" `
    -RegisterSteps `
    -SolutionName "{feature_solution}"
```

The script will:
1. Find plugin metadata in `pluginpackages/` or `PluginAssemblies/`
2. Locate the built artifact
3. Push the binary via `pac plugin push`
4. Parse `SdkMessageProcessingSteps/*.xml` for matching steps
5. Create/update each step and its images via Dataverse Web API
6. Add steps to the feature solution (if `-SolutionName` provided)

### 3. Push Only (No Step Registration)

Update plugin code without re-registering steps:

```powershell
.platform/.github/workflows/scripts/Register-Plugin.ps1 `
    -EnvironmentUrl "{environment_url}" `
    -SolutionPath "src/solutions/{solution}" `
    -PluginName "{plugin_package_name}"
```

### 4. Register a New Step

For a brand-new step not yet in solution XML. **Prerequisite for Scenario B**: complete Step 1 first so the plugin type exists in the environment.

```powershell
.platform/.github/workflows/scripts/Register-Plugin.ps1 `
    -EnvironmentUrl "{environment_url}" `
    -PluginType "{Namespace.ClassName}" `
    -Message "{Create|Update|Delete|...}" `
    -PrimaryEntity "{entity_logical_name}" `
    -Stage {10|20|40} `
    -StepMode {0|1} `
    -FilteringAttributes "{attr1,attr2}" `
    -PreImageAttributes "{attr1,attr2}" `
    -PostImageAttributes "{attr1,attr2}" `
    -SolutionName "{feature_solution}"
```

Stage values: `10` = PreValidation, `20` = PreOperation, `40` = PostOperation
Mode values: `0` = Synchronous, `1` = Asynchronous

After the step is registered, sync the feature solution to capture the new `SdkMessageProcessingSteps/*.xml` entry in source control:

```powershell
.platform/.github/workflows/scripts/Sync-Solution.ps1 `
    -solutionName "{featureSolution}" `
    -environmentUrl "{devEnv_url from innerLoopEnvironments}"
```

### 5. Register Custom APIs

```powershell
.platform/.github/workflows/scripts/Register-Plugin.ps1 `
    -EnvironmentUrl "{environment_url}" `
    -CustomApiPath "src/solutions/{solution}/src/customapis/{api_name}" `
    -SolutionName "{feature_solution}"
```

## Environment Mapping

Read from `environment-config.json`: `solutionAreas[x].devEnv` slug → `innerLoopEnvironments[].url` where slug matches.

## Plugin Package Reference

Look up registered plugin package names in the solution XML at `src/solutions/{solution}/pluginpackages/` — the directory names correspond to the package IDs registered in Dataverse.

## Troubleshooting

- **"Plugin not found in environment"**: Deploy the solution first to create the plugin record, then use this script for subsequent updates
- **"Plugin type not found"**: After pushing, wait briefly for Dataverse to process the package
- **pac auth errors**: Run `pac auth list` to verify active profile, or `pac auth create --interactive --environment {url}`

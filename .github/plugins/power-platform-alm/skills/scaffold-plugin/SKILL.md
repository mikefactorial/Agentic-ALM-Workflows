---
name: scaffold-plugin
description: 'Scaffold a new Dataverse plugin project. Use when: creating a new plugin, adding server-side business logic, handling entity events (Create/Update/Delete), implementing custom API logic, adding post-operation processing. Creates SDK-style .csproj targeting net462 with Microsoft.PowerApps.MSBuild.Plugin, derives from {Publisher}.Plugins.{CoreSolutionAreaName}.Core.PluginBase, wires into .sln and .cdsproj.'
---

# Scaffold a New Plugin Project

Create a new Dataverse plugin project with correct structure, base class, and solution wiring.

## When to Use

- A work item requires server-side business logic (Create/Update/Delete handlers)
- Custom API implementation is needed
- Post-operation processing, validation, or data transformation on entity events
- Any Dataverse plugin development task

## Skill boundaries

| Need | Use instead |
|------|-------------|
| Scaffold a PCF control | `scaffold-pcf-control` |
| Register a step on an existing plugin project | `register-plugin` |
| Deploy an already-scaffolded plugin to dev | `deploy-solution` |
| Start a feature branch and feature solution first | `start-feature` |

## Required Information — Gather Before Proceeding

Before starting, confirm you have all of the following. If anything is missing, ask the user:

| Item | Source |
|------|--------|
| Plugin name | User — descriptive name for the feature (e.g., `ContactCreate`) |
| Solution area | User — which solution area (read from solutionAreas[] in environment-config.json) |
| Feature solution name | User — the active feature solution in the dev env (e.g., `AB12727_HelloPlugin`) |
| Plugin class description | User — one-line summary of what the plugin does |
| **Step: Message** | User — `Create`, `Update`, `Delete`, or other SDK message |
| **Step: Primary entity** | User — logical name of the entity (e.g., `contact`, `slp_sample`) |
| **Step: Stage** | User — `PreValidation` (10), `PreOperation` (20), or `PostOperation` (40) |
| **Step: Execution mode** | User — `Synchronous` (0) or `Asynchronous` (1) |
| **Step: Filtering attributes** | User — comma-separated list (Update only; empty = all attributes) |
| **Step: Pre-image attributes** | User — comma-separated list, or empty if not needed |

> You must have the step parameters before proceeding — Step 7 registers the step and these values are required. Do not scaffold the plugin and stop; scaffolding is incomplete without step registration.

## Configuration

> Before proceeding, read `deployments/settings/environment-config.json`. Use `publisher`, `solutionAreas[x].pluginsPath`, `solutionAreas[x].pluginsSln`, `solutionAreas[x].corePluginRef`, and `solutionAreas[x].cdsproj` to determine paths and naming. Do not use hardcoded values.

## Procedure

### 1. Determine Project Location

Read `deployments/settings/environment-config.json` for the chosen solution area. Only work with solution areas where `pluginsSln` is not null.

| Config field | Used for |
|---|---|
| `publisher` | Assembly namespace prefix and package metadata |
| `solutionAreas[x].pluginsPath` | Plugin project root directory |
| `solutionAreas[x].pluginsSln` | `.sln` file to add the new project to |
| `solutionAreas[x].corePluginRef` | Relative path to Core library `ProjectReference` (`null` = no Core dependency) |
| `solutionAreas[x].cdsproj` | Parent solution `.cdsproj` to wire the plugin into |

> **Cross-solution Core reference**: If `corePluginRef` starts with `../../`, the Core library lives in a different solution area's plugin folder. Use the path exactly as specified — do not create a private `PluginBase.cs` in the project.
### 2. Create the .csproj

**Critical**: Use SDK-style csproj with `Microsoft.PowerApps.MSBuild.Plugin`. This is required — it produces a plugin package (registered in `pluginpackages/` in the solution, NOT `PluginAssemblies/`). Do NOT use old-style `ToolsVersion` csproj format.

Create `{solutionAreas[x].pluginsPath}/{Publisher}.Plugins.{SolutionAreaName}.{Name}/{Publisher}.Plugins.{SolutionAreaName}.{Name}.csproj`:

- `{Publisher}` — from `environment-config.json .publisher`
- `{SolutionAreaName}` — from `solutionAreas[x].name`
- `{Name}` — the new plugin name (from the user)
- `{corePluginRef}` — from `solutionAreas[x].corePluginRef` (omit the `ItemGroup` entirely if `null`)

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <TargetFramework>net462</TargetFramework>
    <PowerAppsTargetsPath>$(MSBuildExtensionsPath)\Microsoft\VisualStudio\v$(VisualStudioVersion)\PowerApps</PowerAppsTargetsPath>
    <AssemblyVersion>1.0.0</AssemblyVersion>
    <FileVersion>1.0.0</FileVersion>
    <ProjectTypeGuids>{4C25E9B5-9FA6-436c-8E19-B395D2A65FAF};{FAE04EC0-301F-11D3-BF4B-00C04F79EFBC}</ProjectTypeGuids>
    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>
  </PropertyGroup>

  <Import Project="$(PowerAppsTargetsPath)\Microsoft.PowerApps.VisualStudio.Plugin.props" Condition="Exists('$(PowerAppsTargetsPath)\Microsoft.PowerApps.VisualStudio.Plugin.props')" />

  <PropertyGroup>
    <PackageId>{Publisher}.Plugins.{SolutionAreaName}.{Name}</PackageId>
    <Version>$(FileVersion)</Version>
    <Authors>{Publisher}</Authors>
    <Company>$(Authors)</Company>
    <Description>{Description}</Description>
    <GenerateAssemblyInfo>false</GenerateAssemblyInfo>
    <GenerateDocumentationFile>True</GenerateDocumentationFile>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="Microsoft.CrmSdk.CoreAssemblies" Version="9.0.2.*" PrivateAssets="All" />
    <PackageReference Include="Microsoft.PowerApps.MSBuild.Plugin" Version="1.*" PrivateAssets="All" />
    <PackageReference Include="Microsoft.NETFramework.ReferenceAssemblies" Version="1.0.*" PrivateAssets="All" />
  </ItemGroup>

  <!-- Include only if solutionAreas[x].corePluginRef is not null -->
  <ItemGroup>
    <ProjectReference Include="{corePluginRef}" />
  </ItemGroup>

  <Import Project="$(PowerAppsTargetsPath)\Microsoft.PowerApps.VisualStudio.Plugin.targets" Condition="Exists('$(PowerAppsTargetsPath)\Microsoft.PowerApps.VisualStudio.Plugin.targets')" />

</Project>
```

### 3. Create the Plugin Class

Every plugin class must:
- Inherit from `{Publisher}.Plugins.{CoreSolutionAreaName}.Core.PluginBase` (the Core library from `corePluginRef`)
- Accept `(string unsecureConfiguration, string secureConfiguration)` constructor
- Call `base(typeof(ClassName))` in the constructor
- Override `ExecuteDataversePlugin(ILocalPluginContext localPluginContext)`

Do NOT implement `IPlugin` directly.

```csharp
using Microsoft.Xrm.Sdk;
using {CoreNamespace}.Core;  // namespace of the Core library from corePluginRef

namespace {Publisher}.Plugins.{SolutionAreaName}.{Name}
{
    public class {PluginClassName} : PluginBase
    {
        public {PluginClassName}(string unsecureConfiguration, string secureConfiguration)
            : base(typeof({PluginClassName}))
        {
        }

        protected override void ExecuteDataversePlugin(ILocalPluginContext localPluginContext)
        {
            var context = localPluginContext.PluginExecutionContext;
            localPluginContext.Trace($"Entered {nameof({PluginClassName})}");

            // ILocalPluginContext provides:
            // localPluginContext.PluginUserService      — IOrganizationService (plugin registration user)
            // localPluginContext.InitiatingUserService   — IOrganizationService (triggering user)
            // localPluginContext.TargetEntity            — Entity from InputParameters["Target"]
            // localPluginContext.PreImageEntity           — Pre-image entity (if registered)
            // localPluginContext.CurrentEntity            — Merged pre-image + target attributes
            // localPluginContext.EnvironmentVariableService — Read Dataverse environment variables
            // localPluginContext.HttpClient              — HttpClientWrapper for external calls
            // localPluginContext.ManagedIdentityService  — Azure Managed Identity

            // TODO: Implement plugin logic

            localPluginContext.Trace($"Exiting {nameof({PluginClassName})}");
        }
    }
}
```

### 4. Add to Solution File

Use `solutionAreas[x].pluginsSln` from `environment-config.json`:

> **Important — always use `.sln` format, not `.slnx`.** The `nuget.exe restore` command used by `Build-Plugins.ps1` does not support the newer `.slnx` format. .NET SDK 9+ defaults to `.slnx` when creating a new solution, so you must pass `--format sln` explicitly.

```powershell
cd {solutionAreas[x].pluginsPath}

# If the .sln file does not exist yet, create it first:
dotnet new sln --name {SolutionFileName} --format sln

# Then add the project
dotnet sln {SolutionFileName}.sln add {Publisher}.Plugins.{SolutionAreaName}.{Name}/{Publisher}.Plugins.{SolutionAreaName}.{Name}.csproj
```

### 5. Add ProjectReference to .cdsproj

A net-new plugin must be added to **two** `.cdsproj` files:

**Parent solution** (permanent home — use `solutionAreas[x].cdsproj` from `environment-config.json`):
```xml
<!-- Add to the .cdsproj at solutionAreas[x].cdsproj -->
<!-- Include path is relative from that .cdsproj to the plugin .csproj -->
<ProjectReference Include="..\..\plugins\{solutionAreaFolder}\{Publisher}.Plugins.{SolutionAreaName}.{Name}\{Publisher}.Plugins.{SolutionAreaName}.{Name}.csproj" PrivateAssets="All">
</ProjectReference>
```

**Feature solution** (so the feature build includes it):
```xml
<!-- In src/solutions/{featureSolution}/{featureSolution}.cdsproj -->
<ProjectReference Include="..\..\plugins\{solutionAreaFolder}\{Publisher}.Plugins.{SolutionAreaName}.{Name}\{Publisher}.Plugins.{SolutionAreaName}.{Name}.csproj" PrivateAssets="All">
</ProjectReference>
```

### 6. Verify Build

```powershell
# pluginsPath from environment-config.json solutionAreas[x].pluginsPath
cd {solutionAreas[x].pluginsPath}/{Publisher}.Plugins.{SolutionAreaName}.{Name}
dotnet build --configuration Release
```

### 7. Deploy to dev and Register the Plugin Step

**This step is mandatory — a plugin with no registered step has no effect in Dataverse.**

#### 7a. Add to feature solution .cdsproj and build

Add the plugin project reference to the **feature solution** `.cdsproj` (in addition to the parent solution .cdsproj done in Step 5), then build:

```powershell
# Build the feature solution ZIP from its cdsproj
cd src/solutions/{featureSolution}
dotnet build --configuration Debug --no-incremental
```

#### 7b. Deploy unmanaged to dev

This creates the plugin package record in Dataverse, making the plugin type available for step registration:

```powershell
pac solution import `
    --path "bin/Debug/{featureSolution}.zip" `
    --environment "{devEnv_url}" `
    --force-overwrite --publish-changes --activate-plugins
```

Resolve `{devEnv_url}` from `innerLoopEnvironments[].url` in `environment-config.json` using the `devEnv` slug for this solution area.

#### 7c. Register the step

Use the parameters collected in **Required Information** above:

```powershell
.platform/.github/workflows/scripts/Register-Plugin.ps1 `
    -EnvironmentUrl "{devEnv_url}" `
    -PluginType "{Publisher}.Plugins.{SolutionAreaName}.{Name}.{PluginClassName}" `
    -Message "{Create|Update|Delete|...}" `
    -PrimaryEntity "{entity_logical_name}" `
    -Stage {10|20|40} `
    -StepMode {0|1} `
    -FilteringAttributes "{attr1,attr2}" `
    -PreImageAttributes "{attr1,attr2}" `
    -SolutionName "{featureSolution}"
```

Omit `-FilteringAttributes` and `-PreImageAttributes` if not applicable.

Stage values: `10` = PreValidation, `20` = PreOperation, `40` = PostOperation  
Mode values: `0` = Synchronous, `1` = Asynchronous

#### 7d. Sync the feature solution to capture the step in source control

After registration, the new `SdkMessageProcessingSteps/*.xml` entry must be synced back to the feature branch:

```powershell
.platform/.github/workflows/scripts/Sync-Solution.ps1 `
    -solutionName "{featureSolution}" `
    -environmentUrl "{devEnv_url}" `
    -skipGitCommit
```

Then commit the updated feature solution files to the feature branch:

```powershell
git add src/solutions/{featureSolution}/
git commit -m "chore({featureSolution}): register step for {PluginClassName} {trailer}"
git push
```

> The scaffolding is not complete until the step is registered and synced. Verify by opening the feature solution in [make.powerapps.com](https://make.powerapps.com) and confirming the plugin step appears under **Plugin Packages**.

## Key Rules

- **SDK-style csproj required**: Always use `<Project Sdk="Microsoft.NET.Sdk">` with `Microsoft.PowerApps.MSBuild.Plugin`. This produces a plugin package stored in `pluginpackages/` in the solution. **Never use old-style `ToolsVersion` csproj for new plugins** — it produces a plain DLL registered in `PluginAssemblies/`, which pac solution sync will rename (stripping dots) and break the build
- **PluginBase required**: All plugins must inherit from `{Publisher}.Plugins.{CoreSolutionAreaName}.Core.PluginBase`. Do NOT implement `IPlugin` directly
- **Cross-solution Core reference**: When `solutionAreas[x].corePluginRef` starts with `../../`, the Core library lives in another solution area. Use the exact path from config — do not create a private PluginBase in the project
- **Sandbox isolation**: No file system access, limited network — use `HttpClient` from context for external calls
- **Recursion guard**: Check `context.Depth > 1` if your plugin triggers updates that could re-fire
- **PluginMessage constants**: Use `PluginMessage.Create`, `PluginMessage.Update`, etc. from Core
- **PluginStage enum**: `PreValidation = 10`, `PreOperation = 20`, `PostOperation = 40`

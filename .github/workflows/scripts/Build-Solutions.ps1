<#
.SYNOPSIS
    Build Power Platform solutions and generate deployment settings
    
.DESCRIPTION
    Builds .cdsproj solution projects, updates version numbers, generates deployment
    settings from templates, and outputs solution ZIPs with deployment configuration files.
    
.PARAMETER solutionList
    Comma-separated list of solution names to build
    
.PARAMETER targetEnvironmentList
    Comma-separated list of target environment names (used for deployment settings generation)
    
.PARAMETER artifactsPath
    Directory where solution ZIPs and settings will be copied (default: ./artifacts/solutions)
    
.PARAMETER sourceFolder
    Root folder containing solution directories (default: ./src/solutions)
    
.PARAMETER configuration
    Build configuration (default: Release)
    
.PARAMETER tenantId
    Azure AD tenant ID (for federated auth). Leave blank for interactive authentication.
    
.PARAMETER clientId
    Service principal client ID (for federated auth). Leave blank for interactive authentication.
    
.NOTES
    Authentication modes:
    - Federated: When both tenantId and clientId are provided (GitHub Actions OIDC)
    - Interactive: When both tenantId and clientId are blank (local development)
    
.EXAMPLE
    # Build single solution with interactive auth (local development)
    .\Build-Solutions.ps1 `
        -solutionList "MySolution" `
        -targetEnvironmentList "my-env-dev"
    
.EXAMPLE
    # Build multiple solutions with federated auth (GitHub Actions)
    .\Build-Solutions.ps1 `
        -solutionList "MySolution,MyCoreSolution" `
        -targetEnvironmentList "my-env-validation,my-env-test,my-env-prod" `
        -tenantId "..." `
        -clientId "..."
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$solutionList,
    
    [Parameter(Mandatory=$false)]
    [string]$targetEnvironmentList = "",
    
    [Parameter(Mandatory=$false)]
    [string]$artifactsPath = "./artifacts/solutions",

    [Parameter(Mandatory=$false)]
    [string]$pluginArtifactsPath = "./artifacts/plugins",
    
    [Parameter(Mandatory=$false)]
    [string]$sourceFolder = "./src/solutions",
    
    [Parameter(Mandatory=$false)]
    [string]$configuration = "Release",
    
    [Parameter(Mandatory=$false)]
    [string]$tenantId = "",
    
    [Parameter(Mandatory=$false)]
    [string]$clientId = ""
)

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Build Power Platform Solutions" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$ErrorActionPreference = "Stop"

# Import hook manager
. "$PSScriptRoot\Invoke-PipelineHooks.ps1"

# Resolve repo root for shared paths
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..") | Select-Object -ExpandProperty Path

# Resolve all paths - convert relative defaults to absolute based on repo root
if (-not [System.IO.Path]::IsPathRooted($artifactsPath)) {
    $artifactsPath = Join-Path $repoRoot $artifactsPath
}
if (-not [System.IO.Path]::IsPathRooted($pluginArtifactsPath)) {
    $pluginArtifactsPath = Join-Path $repoRoot $pluginArtifactsPath
}
if (-not [System.IO.Path]::IsPathRooted($sourceFolder)) {
    $sourceFolder = Join-Path $repoRoot $sourceFolder
}

# Ensure artifacts directory exists
if (-not (Test-Path $artifactsPath)) {
    New-Item -ItemType Directory -Path $artifactsPath -Force | Out-Null
}

# Restore NuGet packages for plugin projects (packages.config)
$pluginsRoot = Join-Path $repoRoot "src\plugins"
$pluginSolutions = @(Get-ChildItem -Path $pluginsRoot -Filter "*.sln" -Recurse -ErrorAction SilentlyContinue)

if ($pluginSolutions.Count -gt 0) {
    Write-Host "Restoring plugin NuGet packages..." -ForegroundColor Cyan

    $nugetExe = Get-Command nuget -ErrorAction SilentlyContinue
    if (-not $nugetExe) {
        Write-Warning "nuget.exe not found in PATH. Attempting to install..."
        $nugetPath = Join-Path $env:TEMP "nuget.exe"
        Invoke-WebRequest -Uri "https://dist.nuget.org/win-x86-commandline/latest/nuget.exe" -OutFile $nugetPath
        $nugetExe = $nugetPath
    }
    else {
        $nugetExe = $nugetExe.Path
    }

    foreach ($pluginsSolution in $pluginSolutions) {
        Write-Host "  Solution: $($pluginsSolution.FullName)" -ForegroundColor Gray
        & $nugetExe restore "$($pluginsSolution.FullName)"

        if ($LASTEXITCODE -ne 0) {
            Write-Warning "NuGet restore returned exit code $LASTEXITCODE for $($pluginsSolution.Name)"
        }
        else {
            Write-Host "  ✓ NuGet packages restored" -ForegroundColor Green
        }
    }

    Write-Host ""
}

# Resolve plugin artifacts path if it exists
$resolvedPluginArtifactsPath = Resolve-Path -Path $pluginArtifactsPath -ErrorAction SilentlyContinue
if ($resolvedPluginArtifactsPath) {
    $pluginArtifactsPath = $resolvedPluginArtifactsPath.Path
}

# Pre-build PCF library packages so dotnet build can find their dist/ output.
# When MSBuild PCF targets run 'npm install' on a PCF control with file: deps,
# npm copies those source packages into node_modules. If dist/ doesn't exist in
# the source package, webpack fails with "Module not found". This can happen when
# the solution build runs on a different CI runner from the controls build job.
# We build all library packages (non-.pcfproj packages that have a build script)
# in dependency order (leaf-first) before any solution build starts.
$controlsRoot = Join-Path $repoRoot "src\controls"
if (Test-Path $controlsRoot) {
    Write-Host "Pre-building PCF library packages..." -ForegroundColor Cyan

    # Collect all non-pcfproj packages that have a build script
    $libCandidateDirs = Get-ChildItem -Path $controlsRoot -Recurse -Filter "package.json" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch "\\node_modules\\" } |
        Where-Object {
            $hasPcfProj = (Get-ChildItem -Path $_.Directory.FullName -Filter "*.pcfproj" -ErrorAction SilentlyContinue).Count -gt 0
            if ($hasPcfProj) { return $false }
            $pkg = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $pkg.PSObject.Properties.Name -contains "scripts" -and
            $pkg.scripts.PSObject.Properties.Name -contains "build"
        } |
        Select-Object -ExpandProperty Directory

    if ($libCandidateDirs.Count -gt 0) {
        # Build in leaf-first dependency order using DFS
        $libVisited = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $libOrdered = [System.Collections.Generic.List[string]]::new()

        function Visit-LibPkg ([string]$dir) {
            if (-not $libVisited.Add($dir)) { return }
            $pkgPath = Join-Path $dir "package.json"
            if (-not (Test-Path $pkgPath)) { return }
            $pkg = Get-Content $pkgPath -Raw | ConvertFrom-Json
            if ($pkg.PSObject.Properties.Name -contains "dependencies") {
                foreach ($dep in $pkg.dependencies.PSObject.Properties) {
                    if ($dep.Value -notmatch '^file:') { continue }
                    $depDir = [System.IO.Path]::GetFullPath((Join-Path $dir ($dep.Value -replace '^file:', '')))
                    if (Test-Path (Join-Path $depDir "package.json")) { Visit-LibPkg $depDir }
                }
            }
            $libOrdered.Add($dir)
        }

        foreach ($d in $libCandidateDirs) { Visit-LibPkg $d.FullName }

        $builtCount = 0
        foreach ($libDir in $libOrdered) {
            $libPkg = Get-Content (Join-Path $libDir "package.json") -Raw | ConvertFrom-Json
            $hasBuild = $libPkg.PSObject.Properties.Name -contains "scripts" -and
                        $libPkg.scripts.PSObject.Properties.Name -contains "build"
            if (-not $hasBuild) { continue }

            Write-Host "  ► $($libPkg.name)" -ForegroundColor Gray
            Push-Location $libDir
            try {
                npm install --ignore-scripts
                if ($LASTEXITCODE -ne 0) { throw "npm install failed for '$($libPkg.name)' (exit $LASTEXITCODE)" }
                npm run build
                if ($LASTEXITCODE -ne 0) { throw "npm run build failed for '$($libPkg.name)' (exit $LASTEXITCODE)" }
                # Only delete node_modules for packages with peerDependencies.
                # When a package has peerDependencies (e.g., react, @fluentui/react), npm v7+
                # installs devDependencies such as @types/react into the package's own node_modules
                # during the pre-build 'npm install'. If that node_modules persists when the
                # consuming PCF control is compiled, TypeScript sees two separate @types/react
                # instances (one from the library, one from the consuming control), which causes
                # TS2322/TS2717 "incompatible types" errors.
                #
                # For packages with react-dom in regular 'dependencies' (not peerDependencies),
                # we keep node_modules intact. pcf-scripts does NOT externalize react-dom when
                # building PCF controls (only 'react' is in its externals). So webpack must
                # resolve react-dom from the file system. Because file: deps create OS junctions
                # that may point to a different directory branch, walking up from the library's
                # path may never reach the consuming control's node_modules/react-dom. Keeping
                # the library's own node_modules provides the only accessible react-dom path.
                $hasPeerDeps = $libPkg.PSObject.Properties.Name -contains "peerDependencies" -and
                               ($libPkg.peerDependencies.PSObject.Properties | Measure-Object).Count -gt 0
                if ($hasPeerDeps) {
                    $libNodeModules = Join-Path $libDir "node_modules"
                    if (Test-Path $libNodeModules) {
                        Remove-Item $libNodeModules -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    Write-Host "    (cleaned node_modules — peerDependencies present)" -ForegroundColor DarkGray
                }
                Write-Host "    ✓ Built" -ForegroundColor Green
                $builtCount++
            }
            finally { Pop-Location }
        }

        Write-Host "  Pre-built $builtCount library package(s)" -ForegroundColor Green
    }
    else {
        Write-Host "  No PCF library packages found" -ForegroundColor Gray
    }

    Write-Host ""
}

# Get version number
Write-Host "Calculating build version..." -ForegroundColor Cyan
$version = & "$PSScriptRoot\Get-NextVersion.ps1"

if (-not $version) {
    Write-Error "Failed to get version number"
    exit 1
}

Write-Host "Build version: $version" -ForegroundColor Green
Write-Host ""

# Split solution list
$solutions = $solutionList -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

# Split environment list
$targetEnvironments = $targetEnvironmentList -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

if ($solutions.Count -eq 0) {
    Write-Error "No solutions specified in solution list"
    exit 1
}

Write-Host "Solutions to build: $($solutions.Count)" -ForegroundColor White
$solutions | ForEach-Object { Write-Host "  • $_" -ForegroundColor Gray }
Write-Host ""

if ($targetEnvironments.Count -eq 0) {
    Write-Warning "No target environments specified — deployment settings files will not be generated."
} else {
    Write-Host "Target environments: $($targetEnvironments.Count)" -ForegroundColor White
    $targetEnvironments | ForEach-Object { Write-Host "  • $_" -ForegroundColor Gray }
}
Write-Host ""

# Build results tracking
$buildResults = @()

# Build each solution
foreach ($solutionName in $solutions) {
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Building: $solutionName" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    
    $solutionPath = Join-Path $sourceFolder $solutionName
    
    if (-not (Test-Path $solutionPath)) {
        Write-Error "Solution directory not found: $solutionPath"
        $buildResults += @{
            Solution = $solutionName
            Status = "Failed"
            Error = "Directory not found"
        }
        continue
    }
    
    # Find .cdsproj file
    $cdsprojFiles = Get-ChildItem -Path $solutionPath -Filter "*.cdsproj" -ErrorAction SilentlyContinue
    
    if ($cdsprojFiles.Count -eq 0) {
        Write-Error "No .cdsproj file found in $solutionPath"
        $buildResults += @{
            Solution = $solutionName
            Status = "Failed"
            Error = "No .cdsproj file found"
        }
        continue
    }
    
    if ($cdsprojFiles.Count -gt 1) {
        Write-Warning "Multiple .cdsproj files found. Using first: $($cdsprojFiles[0].Name)"
    }
    
    $cdsprojFile = $cdsprojFiles[0]
    $cdsprojPath = $cdsprojFile.FullName
    
    Write-Host "Project file: $($cdsprojFile.Name)" -ForegroundColor White
    Write-Host ""

    # Stage plugin assembly binaries from artifacts
    $pluginAssembliesRoot = Join-Path $solutionPath "src\PluginAssemblies"
    $pluginMetadataFiles = Get-ChildItem -Path $pluginAssembliesRoot -Filter "*.dll.data.xml" -Recurse -ErrorAction SilentlyContinue

    if ($pluginMetadataFiles.Count -gt 0) {
        Write-Host "Staging plugin assembly binaries..." -ForegroundColor Cyan

        foreach ($metadataFile in $pluginMetadataFiles) {
            [xml]$pluginXml = Get-Content $metadataFile.FullName
            $assemblyFullName = $pluginXml.PluginAssembly.FullName

            if ([string]::IsNullOrWhiteSpace($assemblyFullName)) {
                throw "Plugin assembly metadata missing FullName: $($metadataFile.FullName)"
            }

            $assemblyName = $assemblyFullName.Split(',')[0].Trim()
            $sourceDll = Join-Path $pluginArtifactsPath "${assemblyName}.dll"

            if (-not (Test-Path $sourceDll)) {
                Write-Warning "  Plugin assembly binary not found in artifacts (may not have been built): $assemblyName.dll"
                continue
            }

            $fileName = $pluginXml.PluginAssembly.FileName
            if ([string]::IsNullOrWhiteSpace($fileName)) {
                Write-Warning "  Plugin assembly metadata missing FileName: $($metadataFile.FullName)"
                continue
            }

            $relativeFilePath = $fileName.TrimStart('/') -replace '/', '\\'
            $destinationPath = Join-Path (Join-Path $solutionPath "src") $relativeFilePath
            $destinationDir = Split-Path $destinationPath -Parent

            if (-not (Test-Path $destinationDir)) {
                New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
            }

            Copy-Item -Path $sourceDll -Destination $destinationPath -Force
            Write-Host "  ✓ Staged: $(Split-Path $destinationPath -Leaf)" -ForegroundColor Green
        }

        Write-Host ""
    }
    
    try {
        # Update solution version
        Write-Host "Updating solution version to $version..." -ForegroundColor Cyan
        
        $solutionXmlPath = Join-Path $solutionPath "src\Other\Solution.xml"
        
        if (Test-Path $solutionXmlPath) {
            [xml]$solutionXml = Get-Content $solutionXmlPath
            $versionNode = $solutionXml.SelectSingleNode("//Version")
            
            if ($versionNode) {
                $oldVersion = $versionNode.InnerText
                $versionNode.InnerText = $version
                $solutionXml.Save($solutionXmlPath)
                Write-Host "  Version updated: $oldVersion → $version" -ForegroundColor Green
            }
            else {
                Write-Warning "  Could not find Version element in Solution.xml"
            }
        }
        else {
            Write-Warning "  Solution.xml not found at expected path"
        }
        
        Write-Host ""
        
        # Execute pre-build hooks
        $hookContext = @{
            solutionName = $solutionName
            solutionPath = $solutionPath
            cdsprojPath = $cdsprojPath
            artifactsPath = $artifactsPath
            targetEnvironments = $targetEnvironments
            configuration = $configuration
            version = $version
        }
        
        Write-Host "Executing pre-build hooks..." -ForegroundColor Cyan
        Invoke-PipelineHooks -Stage "pre-build" -Context $hookContext -ContinueOnError $true
        Write-Host ""
        
        # Lint JavaScript web resources
        Write-Host "Linting web resources..." -ForegroundColor Cyan
        $lintingResultsPath = Join-Path $artifactsPath "..\linting"
        $lintingOutputFile = Join-Path $lintingResultsPath "lint-$solutionName.json"
        & "$PSScriptRoot\Invoke-WebResourceLinting.ps1" -solutionPath $solutionPath -failOnError $false -outputFile $lintingOutputFile
        
        # Build the solution
        Write-Host "Building solution with dotnet build..." -ForegroundColor Cyan
        
        $originalLocation = Get-Location
        try {
            Set-Location $cdsprojFile.Directory.FullName
            
            # Record timestamp before build so we can detect stale ZIPs from previous runs
            $buildStartTime = Get-Date
            
            $buildCommand = "dotnet build `"$($cdsprojFile.Name)`" --configuration $configuration"
            Write-Host "Command: $buildCommand" -ForegroundColor Gray
            Write-Host ""
            
            Invoke-Expression $buildCommand
            
            if ($LASTEXITCODE -ne 0) {
                # Check if the solution ZIP was produced despite the non-zero exit code.
                # On Windows, MSBuild can fail in the post-build cleanup phase (MSB3231) due to
                # file locks from AV/indexing software, while the ZIP artifact is already written.
                # In that case, warn but continue — on CI (Linux) this never occurs.
                $binPathCheck = Join-Path $cdsprojFile.Directory "bin\$configuration"
                $zipCheck = Get-ChildItem -Path $binPathCheck -Filter "*.zip" -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -ge $buildStartTime }
                if ($zipCheck.Count -eq 0) {
                    throw "Build failed with exit code $LASTEXITCODE (no solution ZIPs produced by this build; any ZIPs in bin/ are stale from a previous run)"
                }
                Write-Warning "dotnet build exited $LASTEXITCODE but solution ZIP was produced; treating as success (likely post-build cleanup lock on Windows)."
            }
        }
        finally {
            Set-Location $originalLocation
        }
        
        Write-Host ""
        Write-Host "✓ Solution built successfully" -ForegroundColor Green
        Write-Host ""
        
        # Find built ZIP files
        $binPath = Join-Path $cdsprojFile.Directory "bin\$configuration"
        $builtZipFiles = Get-ChildItem -Path $binPath -Filter "*.zip" -ErrorAction SilentlyContinue
        
        if ($builtZipFiles.Count -eq 0) {
            throw "No ZIP files found in build output: $binPath"
        }
        
        Write-Host "Found $($builtZipFiles.Count) solution package(s):" -ForegroundColor Cyan
        $builtZipFiles | ForEach-Object { Write-Host "  • $($_.Name)" -ForegroundColor Gray }
        Write-Host ""
        
        # Copy ZIP files to artifacts with version naming
        $copiedFiles = @()
        foreach ($zipFile in $builtZipFiles) {
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($zipFile.Name)
            $isManagedSuffix = if ($baseName -like "*_managed") { "_managed" } else { "" }
            $cleanBaseName = $baseName -replace "_managed$", ""
            
            $newFileName = "${cleanBaseName}_${version}${isManagedSuffix}.zip"
            $destinationPath = Join-Path $artifactsPath $newFileName
            
            Copy-Item -Path $zipFile.FullName -Destination $destinationPath -Force
            Write-Host "  ✓ Copied: $newFileName" -ForegroundColor Green
            
            $copiedFiles += $destinationPath
        }
        
        Write-Host ""
        
        # Generate deployment settings for each target environment
        Write-Host "Generating deployment settings for environments..." -ForegroundColor Cyan
        $settingsFiles = @()
        
        foreach ($targetEnvironment in $targetEnvironments) {
            Write-Host "  Environment: $targetEnvironment" -ForegroundColor Yellow
            
            $templatePath = Join-Path $repoRoot "deployments\settings\templates\${solutionName}_template.json"
            $settingsFileName = "${solutionName}_${version}_${targetEnvironment}_settings.json"
            $settingsPath = Join-Path $artifactsPath $settingsFileName
            
            if (Test-Path $templatePath) {
                try {
                    & "$PSScriptRoot\Generate-DeploymentSettings.ps1" `
                        -solutionName $solutionName `
                        -targetEnvironment $targetEnvironment `
                        -templatePath $templatePath `
                        -outputPath $settingsPath `
                        -configPath (Join-Path $repoRoot "deployments\settings")
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-Host "    ✓ Settings file: $settingsFileName" -ForegroundColor Green
                        $settingsFiles += $settingsPath
                    }
                    else {
                        throw "Generate-DeploymentSettings.ps1 failed with exit code $LASTEXITCODE"
                    }
                }
                catch {
                    # Deployment settings failures are non-fatal: the solution ZIP was already produced.
                    # Missing env vars for environments where a solution is not deployed (e.g. solution-specific
                    # vars absent from other solution environments) should warn, not fail the build.
                    Write-Warning "    ⚠ Could not generate settings for '${targetEnvironment}': $($_.Exception.Message)"
                }
            }
            else {
                Write-Warning "    No deployment settings template found at: $templatePath"
                Write-Warning "    Run Sync-Solution.ps1 to generate templates during solution sync"
            }
        }
        
        Write-Host "  Generated $($settingsFiles.Count) deployment settings files" -ForegroundColor Green
        
        Write-Host ""
        
        # Execute post-build hooks
        $hookContext.buildOutputPath = $binPath
        $hookContext.builtZipFiles = $copiedFiles
        $hookContext.settingsFiles = $settingsFiles
        
        Write-Host "Executing post-build hooks..." -ForegroundColor Cyan
        Invoke-PipelineHooks -Stage "post-build" -Context $hookContext -ContinueOnError $true
        Write-Host ""
        
        $buildResults += @{
            Solution = $solutionName
            Status = "Success"
            Version = $version
            Artifacts = $copiedFiles
            SettingsFiles = $settingsFiles
        }
    }
    catch {
        Write-Host ""
        Write-Error "Build failed for ${solutionName}: $($_.Exception.Message)"
        Write-Host ""
        
        $buildResults += @{
            Solution = $solutionName
            Status = "Failed"
            Error = $_.Exception.Message
        }
    }
}

# Build summary
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Build Summary" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

foreach ($result in $buildResults) {
    if ($result.Status -eq "Success") {
        Write-Host "✓ $($result.Solution) (v$($result.Version))" -ForegroundColor Green
        Write-Host "  Artifacts:" -ForegroundColor Gray
        foreach ($artifact in $result.Artifacts) {
            $fileName = Split-Path $artifact -Leaf
            Write-Host "    • $fileName" -ForegroundColor Gray
        }
        if ($result.SettingsFiles -and $result.SettingsFiles.Count -gt 0) {
            foreach ($settingsFile in $result.SettingsFiles) {
                $settingsFileName = Split-Path $settingsFile -Leaf
                Write-Host "    • $settingsFileName" -ForegroundColor Gray
            }
        }
    }
    else {
        Write-Host "❌ $($result.Solution): Failed" -ForegroundColor Red
        if ($result.Error) {
            Write-Host "  Error: $($result.Error)" -ForegroundColor Red
        }
    }
    Write-Host ""
}

Write-Host "Artifacts directory: $artifactsPath" -ForegroundColor Cyan
Write-Host "Build version: $version" -ForegroundColor Cyan
Write-Host ""

# Fail if any builds failed
$failedBuilds = $buildResults | Where-Object { $_.Status -ne "Success" }
if ($failedBuilds.Count -gt 0) {
    Write-Error "One or more solution builds failed"
    exit 1
}

Write-Host "✓ All solutions built successfully" -ForegroundColor Green
Write-Host ""

# Output version for GitHub Actions
if ($env:GITHUB_OUTPUT) {
    "version=$version" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    Write-Host "Version written to GITHUB_OUTPUT" -ForegroundColor Gray
}

exit 0

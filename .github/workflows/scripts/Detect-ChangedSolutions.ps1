param(
    [Parameter(Mandatory = $true)]
    [string]$BaseBranch,

    [Parameter(Mandatory = $true)]
    [string]$HeadBranch,

    [Parameter(Mandatory = $false)]
    [string]$SolutionsRoot = "src/solutions",

    [Parameter(Mandatory = $false)]
    [string]$ControlsRoot = "src/controls",

    [Parameter(Mandatory = $false)]
    [string]$PluginsRoot = "src/plugins"
)

# Function to check if a ref is a commit SHA
function Test-IsSHA {
    param([string]$ref)
    return $ref -match '^[0-9a-f]{7,40}$'
}

# Normalize base ref
$baseRef = $BaseBranch
if (Test-IsSHA $BaseBranch) {
    Write-Host "Base is commit SHA: $BaseBranch"
    $baseRef = $BaseBranch
} else {
    $normalizedBase = $BaseBranch
    if ($normalizedBase -match "^origin/") {
        $normalizedBase = $normalizedBase.Substring(7)
    }
    $baseRef = "origin/$normalizedBase"
    Write-Host "Fetching base branch: $normalizedBase"
    git fetch origin $normalizedBase 2>&1 | Out-Null
}

# Normalize head ref
$headRef = $HeadBranch
if ([string]::IsNullOrWhiteSpace($HeadBranch) -or $HeadBranch -eq "HEAD") {
    $headRef = "HEAD"
} elseif (Test-IsSHA $HeadBranch) {
    Write-Host "Head is commit SHA: $HeadBranch"
    $headRef = $HeadBranch
} else {
    $normalizedHead = $HeadBranch
    if ($normalizedHead -match "^origin/") {
        $normalizedHead = $normalizedHead.Substring(7)
    }
    
    Write-Host "Fetching head branch: $normalizedHead"
    git fetch origin $normalizedHead 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $headRef = "origin/$normalizedHead"
    } else {
        Write-Host "Warning: Could not fetch origin/$normalizedHead. Falling back to HEAD."
        $headRef = "HEAD"
    }
}

Write-Host "Comparing $baseRef...$headRef"

$baseExists = git rev-parse --verify $baseRef 2>$null
$headExists = git rev-parse --verify $headRef 2>$null

if (-not $baseExists -or -not $headExists) {
    throw "Cannot resolve refs for diff. Base: $baseRef (found: $([bool]$baseExists)), Head: $headRef (found: $([bool]$headExists))"
}

$changedFiles = git diff --name-only "$baseRef...$headRef"

Write-Host "Changed files:"
$changedFiles | ForEach-Object { Write-Host "  $_" }

$changedSolutions = @()
$solutionDirs = Get-ChildItem -Path $SolutionsRoot -Filter "*.cdsproj" -Recurse |
    Select-Object -ExpandProperty Directory |
    Select-Object -Unique

# Detect directly changed solutions
foreach ($dir in $solutionDirs) {
    $relativePath = $dir.FullName.Replace((Get-Location).Path, "").TrimStart("\", "/").Replace("\", "/")
    $hasChanges = $changedFiles | Where-Object { $_.StartsWith($relativePath) }

    if ($hasChanges) {
        $cdsproj = Get-ChildItem -Path $dir.FullName -Filter "*.cdsproj" | Select-Object -First 1
        if ($cdsproj) {
            $changedSolutions += $cdsproj.BaseName
            Write-Host "✓ Solution '$($cdsproj.BaseName)' has direct changes"
        }
    }
}

# Detect controls that changed
$changedControls = @()
$controlChanges = $changedFiles | Where-Object { $_.StartsWith($ControlsRoot) }
if ($controlChanges) {
    Write-Host ""
    Write-Host "Changed controls detected:"
    foreach ($change in $controlChanges) {
        # Extract the control project name (pcfproj)
        $parts = $change -split "/"
        for ($i = 0; $i -lt $parts.Count; $i++) {
            if ($parts[$i] -match "\.pcfproj$") {
                $controlPath = $change.Substring(0, $change.LastIndexOf($parts[$i])).TrimEnd("/")
                if ($controlPath -notin $changedControls) {
                    $changedControls += $controlPath
                    Write-Host "  - $controlPath"
                }
                break
            }
        }
    }
}

# Detect plugins that changed (including shared libraries)
$changedPluginProjects = @()
$pluginChanges = $changedFiles | Where-Object { $_.StartsWith($PluginsRoot) }
if ($pluginChanges) {
    Write-Host ""
    Write-Host "Changed plugin projects detected:"
    foreach ($change in $pluginChanges) {
        # Extract the project folder path
        $parts = $change -split "/"
        # Plugin projects are typically at depth: src/plugins/ProjectName/...
        if ($parts.Count -ge 3) {
            $projectFolder = "$($parts[0])/$($parts[1])/$($parts[2])"
            if ($projectFolder -notin $changedPluginProjects) {
                $changedPluginProjects += $projectFolder
                Write-Host "  - $projectFolder"
            }
        }
    }
}

# Build dependency graph to find affected plugin assemblies
$affectedPluginAssemblies = @()
if ($changedPluginProjects.Count -gt 0) {
    Write-Host ""
    Write-Host "Analyzing plugin dependencies..."
    
    # Get all plugin .csproj files
    $allPluginProjects = Get-ChildItem -Path $PluginsRoot -Filter "*.csproj" -Recurse
    
    # Build a dependency map
    $dependencyMap = @{}
    foreach ($proj in $allPluginProjects) {
        $projectPath = $proj.Directory.FullName.Replace((Get-Location).Path, "").TrimStart("\", "/").Replace("\", "/")
        $content = Get-Content -Path $proj.FullName -Raw
        
        # Extract ProjectReference elements
        $refs = [regex]::Matches($content, '<ProjectReference\s+Include="([^"]+)"')
        $dependencies = @()
        foreach ($match in $refs) {
            $refPath = $match.Groups[1].Value.Replace("\", "/")
            # Resolve relative path
            $refPath = [System.IO.Path]::GetFullPath((Join-Path $proj.Directory.FullName $refPath))
            $refPath = $refPath.Replace((Get-Location).Path, "").TrimStart("\", "/").Replace("\", "/")
            $refFolder = [System.IO.Path]::GetDirectoryName($refPath).Replace("\", "/")
            $dependencies += $refFolder
        }
        $dependencyMap[$projectPath] = @{
            Dependencies = $dependencies
            ProjectName = $proj.BaseName
        }
    }
    
    # Find all projects affected by changes (including transitive dependencies)
    $toProcess = [System.Collections.Queue]::new()
    foreach ($changed in $changedPluginProjects) {
        $toProcess.Enqueue($changed)
    }
    
    $processed = @{}
    while ($toProcess.Count -gt 0) {
        $current = $toProcess.Dequeue()
        if ($processed.ContainsKey($current)) {
            continue
        }
        $processed[$current] = $true
        
        # Find projects that depend on this one
        foreach ($proj in $dependencyMap.Keys) {
            $info = $dependencyMap[$proj]
            if ($info.Dependencies -contains $current) {
                $toProcess.Enqueue($proj)
            }
        }
    }
    
    # Filter to only actual plugin assemblies (not shared libraries)
    # Plugin assemblies typically have "Plugins" in their name: Plugins.Service, Plugins.Base, etc.
    foreach ($projPath in $processed.Keys) {
        if ($dependencyMap.ContainsKey($projPath)) {
            $projectName = $dependencyMap[$projPath].ProjectName
            if ($projectName -match "Plugins\." -or $projectName -match "WorkflowAssemblies") {
                if ($projectName -notin $affectedPluginAssemblies) {
                    $affectedPluginAssemblies += $projectName
                    Write-Host "  ✓ Affected plugin assembly: $projectName"
                }
            }
        }
    }
}

# Find solutions that reference changed controls or plugins
if ($changedControls.Count -gt 0 -or $affectedPluginAssemblies.Count -gt 0) {
    Write-Host ""
    Write-Host "Searching for solutions that reference changed components..."
    
    foreach ($dir in $solutionDirs) {
        $cdsproject = Get-ChildItem -Path $dir.FullName -Filter "*.cdsproj" | Select-Object -First 1
        if ($cdsproject) {
            $projectContent = Get-Content -Path $cdsproject.FullName -Raw
            $foundReference = $false

            # Check for control references
            foreach ($controlPath in $changedControls) {
                if ($projectContent -match [regex]::Escape($controlPath)) {
                    if ($cdsproject.BaseName -notin $changedSolutions) {
                        $changedSolutions += $cdsproject.BaseName
                        Write-Host "✓ Solution '$($cdsproject.BaseName)' references changed control: $controlPath"
                    }
                    $foundReference = $true
                    break
                }
            }

            # Check for plugin references if no control reference found
            if (-not $foundReference) {
                foreach ($pluginName in $affectedPluginAssemblies) {
                    if ($projectContent -match [regex]::Escape($pluginName)) {
                        if ($cdsproject.BaseName -notin $changedSolutions) {
                            $changedSolutions += $cdsproject.BaseName
                            Write-Host "✓ Solution '$($cdsproject.BaseName)' references affected plugin: $pluginName"
                        }
                        break
                    }
                }
            }
        }
    }
}

if ($changedSolutions.Count -eq 0) {
    Write-Host ""
    Write-Host "No solution changes detected"
    "has_changes=false" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}
else {
    Write-Host ""
    Write-Host "Building $($changedSolutions.Count) solution(s):"
    $changedSolutions | Sort-Object | ForEach-Object { Write-Host "  • $_" }

    $solutionList = $changedSolutions -join ","
    "has_changes=true" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
    "solution_list=$solutionList" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
}

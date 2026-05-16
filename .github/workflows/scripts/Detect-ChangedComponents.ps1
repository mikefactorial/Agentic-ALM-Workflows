param(
    [Parameter(Mandatory = $true)]
    [string]$BaseBranch,

    [Parameter(Mandatory = $true)]
    [string]$HeadBranch,

    [Parameter(Mandatory = $false)]
    [string]$ControlsRoot = "src/controls",

    [Parameter(Mandatory = $false)]
    [string]$PluginsRoot = "src/plugins",

    [Parameter(Mandatory = $false)]
    [string]$WebResourcesRoot = "src/webresources",

    [Parameter(Mandatory = $false)]
    [string]$CodeAppsRoot = "src/codeapps"
)

function Test-IsSHA {
    param([string]$ref)
    return $ref -match '^[0-9a-f]{7,40}$'
}

$baseRef = $BaseBranch
if (Test-IsSHA $BaseBranch) {
    Write-Host "Base is commit SHA: $BaseBranch"
}
else {
    $normalizedBase = $BaseBranch
    if ($normalizedBase -match "^origin/") {
        $normalizedBase = $normalizedBase.Substring(7)
    }
    $baseRef = "origin/$normalizedBase"
    Write-Host "Fetching base branch: $normalizedBase"
    git fetch origin $normalizedBase 2>&1 | Out-Null
}

$headRef = $HeadBranch
if ([string]::IsNullOrWhiteSpace($HeadBranch) -or $HeadBranch -eq "HEAD") {
    $headRef = "HEAD"
}
elseif (Test-IsSHA $HeadBranch) {
    Write-Host "Head is commit SHA: $HeadBranch"
}
else {
    $normalizedHead = $HeadBranch
    if ($normalizedHead -match "^origin/") {
        $normalizedHead = $normalizedHead.Substring(7)
    }
    Write-Host "Fetching head branch: $normalizedHead"
    git fetch origin $normalizedHead 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $headRef = "origin/$normalizedHead"
    }
    else {
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

# Subdirectory existence = actual projects present (root-level files like READMEs don't count)
$pluginProjects      = @(Get-ChildItem -Path $PluginsRoot      -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Sort-Object)
$controlProjects     = @(Get-ChildItem -Path $ControlsRoot     -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Sort-Object)
$webResourceProjects = @(Get-ChildItem -Path $WebResourcesRoot -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Sort-Object)
$codeAppProjects     = @(Get-ChildItem -Path $CodeAppsRoot     -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name | Sort-Object)

$pluginsExist        = $pluginProjects.Count -gt 0
$controlsExist       = $controlProjects.Count -gt 0
$webResourcesExist   = $webResourceProjects.Count -gt 0
$codeAppsExist       = $codeAppProjects.Count -gt 0
$solutionsExist      = (Get-ChildItem -Path "src/solutions" -Filter "*.cdsproj" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1) -ne $null

$hasPluginChanges      = $false
$hasControlChanges     = $false
$hasWebResourceChanges = $false
$hasCodeAppChanges     = $false

if ($changedFiles) {
    # Only count changes inside a project subdirectory (e.g. src/plugins/MyPlugin/...), not root-level files
    $hasPluginChanges      = $pluginsExist      -and (@($changedFiles | Where-Object { $_ -match "^$([regex]::Escape($PluginsRoot))/"      -and $_ -notmatch "^$([regex]::Escape($PluginsRoot))/[^/]+$" }).Count -gt 0)
    $hasControlChanges     = $controlsExist     -and (@($changedFiles | Where-Object { $_ -match "^$([regex]::Escape($ControlsRoot))/"     -and $_ -notmatch "^$([regex]::Escape($ControlsRoot))/[^/]+$" }).Count -gt 0)
    $hasWebResourceChanges = $webResourcesExist -and (@($changedFiles | Where-Object { $_ -match "^$([regex]::Escape($WebResourcesRoot))/" -and $_ -notmatch "^$([regex]::Escape($WebResourcesRoot))/[^/]+$" }).Count -gt 0)
    $hasCodeAppChanges     = $codeAppsExist     -and (@($changedFiles | Where-Object { $_ -match "^$([regex]::Escape($CodeAppsRoot))/"     -and $_ -notmatch "^$([regex]::Escape($CodeAppsRoot))/[^/]+$" }).Count -gt 0)
}

Write-Host "Plugin changes detected: $hasPluginChanges"
Write-Host "Control changes detected: $hasControlChanges"
Write-Host "Web resource changes detected: $hasWebResourceChanges"
Write-Host "Code app changes detected: $hasCodeAppChanges"
Write-Host "Plugins directory exists: $pluginsExist"
Write-Host "Controls directory exists: $controlsExist"
Write-Host "Web resources directory exists: $webResourcesExist"
Write-Host "Code apps directory exists: $codeAppsExist"
Write-Host "Solutions directory exists: $solutionsExist"

"plugins_changed=$($hasPluginChanges.ToString().ToLowerInvariant())"           | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"controls_changed=$($hasControlChanges.ToString().ToLowerInvariant())"         | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"webresources_changed=$($hasWebResourceChanges.ToString().ToLowerInvariant())" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"codeapps_changed=$($hasCodeAppChanges.ToString().ToLowerInvariant())"         | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"plugins_exist=$($pluginsExist.ToString().ToLowerInvariant())"                 | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"controls_exist=$($controlsExist.ToString().ToLowerInvariant())"               | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"webresources_exist=$($webResourcesExist.ToString().ToLowerInvariant())"       | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"codeapps_exist=$($codeAppsExist.ToString().ToLowerInvariant())"               | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
"solutions_exist=$($solutionsExist.ToString().ToLowerInvariant())"             | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8

# Emit group subdirectory lists as JSON arrays for matrix builds
$controlGroupsJson = if ($controlProjects.Count -gt 0) { $controlProjects | ConvertTo-Json -Compress } else { '[]' }
if ($controlGroupsJson -notmatch '^\[') { $controlGroupsJson = "[$controlGroupsJson]" }
"control_groups=$controlGroupsJson" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
Write-Host "Control groups: $controlGroupsJson"

$webResourceGroupsJson = if ($webResourceProjects.Count -gt 0) { $webResourceProjects | ConvertTo-Json -Compress } else { '[]' }
if ($webResourceGroupsJson -notmatch '^\[') { $webResourceGroupsJson = "[$webResourceGroupsJson]" }
"webresource_groups=$webResourceGroupsJson" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
Write-Host "Web resource groups: $webResourceGroupsJson"

$codeAppGroupsJson = if ($codeAppProjects.Count -gt 0) { $codeAppProjects | ConvertTo-Json -Compress } else { '[]' }
if ($codeAppGroupsJson -notmatch '^\[') { $codeAppGroupsJson = "[$codeAppGroupsJson]" }
"codeapp_groups=$codeAppGroupsJson" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8
Write-Host "Code app groups: $codeAppGroupsJson"

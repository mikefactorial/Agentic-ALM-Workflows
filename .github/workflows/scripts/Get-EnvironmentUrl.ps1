<#
.SYNOPSIS
    Returns the Dataverse URL for an environment slug from environment-config.json.

.PARAMETER Slug
    The environment slug to look up (e.g., 'myapp-dev', 'myapp-test').

.PARAMETER RepoRoot
    Path to the repository root. Defaults to the root relative to this script's location.

.OUTPUTS
    [string] The Dataverse URL for the given slug, including trailing slash.

.EXAMPLE
    $url = & .\.github\workflows\scripts\Get-EnvironmentUrl.ps1 -Slug "myapp-dev"

    .\.github\workflows\scripts\Sync-Solution.ps1 `
        -solutionName "pub_MySolution" `
        -environmentUrl (& .\.github\workflows\scripts\Get-EnvironmentUrl.ps1 -Slug "myapp-dev") `
        -skipGitCommit
#>
param(
    [Parameter(Mandatory)]
    [string]$Slug,

    [string]$RepoRoot = ""
)

if (-not $RepoRoot) {
    # Script lives at .platform/.github/workflows/scripts/ — repo root is 4 levels up
    $RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "../../../..") | Select-Object -ExpandProperty Path
}

$configPath = Join-Path $RepoRoot "deployments\settings\environment-config.json"

if (-not (Test-Path $configPath)) {
    Write-Error "environment-config.json not found at: $configPath"
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json

# Search environments[] then innerLoopEnvironments[]
$match = $config.environments | Where-Object { $_.slug -eq $Slug }
if (-not $match) {
    $match = $config.innerLoopEnvironments | Where-Object { $_.slug -eq $Slug }
}

if (-not $match) {
    $allSlugs = @(
        $config.environments         | Select-Object -ExpandProperty slug
        $config.innerLoopEnvironments | Select-Object -ExpandProperty slug
    ) -join ', '
    Write-Error "Environment slug '$Slug' not found in environment-config.json.`nAvailable slugs: $allSlugs"
    exit 1
}

$match.url

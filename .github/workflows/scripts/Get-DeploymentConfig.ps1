<#
.SYNOPSIS
    Reads environment-config.json and outputs GitHub Actions matrix JSON for each deployment stage.

.DESCRIPTION
    Parses the package-to-environment mapping in environment-config.json and produces two matrix
    outputs (test_matrix, production_matrix) for use by the deploy-package workflow.
    Also resolves the release tag to deploy — uses the latest GitHub release when not specified.

    Each matrix entry carries:
      packageGroup  — name of the package group (e.g. "MySolution_Package")
      solutions     — comma-separated solution names within the group
      environment   — GitHub environment name to deploy to

.PARAMETER releaseTag
    Specific release tag to deploy (e.g. "v2026.04.04.1"). Leave blank to resolve the latest release.

.PARAMETER packageGroupFilter
    Comma-separated list of package groups to include. Leave blank to include all groups.

.PARAMETER startStage
    Earliest stage to include: "test" or "production".
    Stages earlier than this are excluded from all matrices.

.PARAMETER configPath
    Path to environment-config.json.

.PARAMETER outputFile
    Path to the GITHUB_OUTPUT file.

.EXAMPLE
    .\Get-DeploymentConfig.ps1 -startStage "test" -outputFile $env:GITHUB_OUTPUT
#>
param(
    [string] $releaseTag         = "",
    [string] $packageGroupFilter = "",
    [string] $startStage         = "test",
    [string] $configPath         = "deployments/settings/environment-config.json",
    [string] $outputFile         = $env:GITHUB_OUTPUT
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Get Deployment Configuration" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ── Load config ─────────────────────────────────────────────────────────────
if (-not (Test-Path $configPath)) {
    Write-Error "Environment config not found: $configPath"
    exit 1
}

$config = Get-Content $configPath -Raw | ConvertFrom-Json
Write-Host "Config loaded: $configPath" -ForegroundColor Green
Write-Host "Package groups: $($config.packageGroups.name -join ', ')" -ForegroundColor Gray

# ── Resolve release tag ──────────────────────────────────────────────────────
if ([string]::IsNullOrWhiteSpace($releaseTag)) {
    Write-Host ""
    Write-Host "Resolving latest release from GitHub API..." -ForegroundColor Cyan

    $apiUrl     = if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { "https://api.github.com" }
    $repository = $env:GITHUB_REPOSITORY
    $token      = $env:GH_TOKEN

    if ([string]::IsNullOrWhiteSpace($repository) -or [string]::IsNullOrWhiteSpace($token)) {
        Write-Error "GITHUB_REPOSITORY and GH_TOKEN must be set when resolving the latest release."
        exit 1
    }

    $headers  = @{ Authorization = "Bearer $token"; Accept = "application/vnd.github+json" }
    $response = Invoke-RestMethod `
        -Uri     "$apiUrl/repos/$repository/releases?per_page=1" `
        -Headers $headers

    if ($response.Count -eq 0) {
        Write-Error "No releases found in repository '$repository'."
        exit 1
    }

    $releaseTag = $response[0].tag_name
    Write-Host "  Resolved: $releaseTag" -ForegroundColor Green
}
else {
    Write-Host "Using specified release: $releaseTag" -ForegroundColor Green
}

# ── Filter package groups ────────────────────────────────────────────────────
$groups = $config.packageGroups

if (-not [string]::IsNullOrWhiteSpace($packageGroupFilter)) {
    $filterList = $packageGroupFilter -split ',' `
        | ForEach-Object { $_.Trim() } `
        | Where-Object   { $_ }
    $groups = $groups | Where-Object { $filterList -contains $_.name }
    Write-Host ""
    Write-Host "Package group filter applied: $($groups.name -join ', ')" -ForegroundColor Yellow
}

# ── Stage ordering ────────────────────────────────────────────────────────────
$stageOrder = @("test", "production")
$startIdx   = $stageOrder.IndexOf($startStage.ToLower())
if ($startIdx -lt 0) {
    Write-Warning "Unknown start stage '$startStage' — defaulting to 'test'."
    $startIdx = 0
}
$activeStages = $stageOrder[$startIdx..($stageOrder.Count - 1)]

Write-Host ""
Write-Host "Active stages: $($activeStages -join ' → ')" -ForegroundColor White
Write-Host ""

# ── Build matrices ────────────────────────────────────────────────────────────
$stageMatrices = @{}
foreach ($stage in $stageOrder) { $stageMatrices[$stage] = [System.Collections.Generic.List[object]]::new() }

foreach ($group in $groups) {
    foreach ($stage in $activeStages) {
        # PSCustomObject property access for dynamic stage name
        $stageEnvs = $group.stages.$stage
        if ($null -eq $stageEnvs) { continue }

        foreach ($envName in @($stageEnvs)) {
            if ([string]::IsNullOrWhiteSpace($envName)) { continue }
            $stageMatrices[$stage].Add([PSCustomObject]@{
                packageGroup = $group.name
                solutions    = ($group.solutions -join ',')
                environment  = $envName
            })
        }
    }
}

# ── Emit outputs ──────────────────────────────────────────────────────────────
"release_tag=$releaseTag" | Out-File -FilePath $outputFile -Append -Encoding utf8

foreach ($stage in $stageOrder) {
    $entries    = $stageMatrices[$stage]
    $hasEntries = $entries.Count -gt 0

    if ($hasEntries) {
        $matrixObj  = @{ include = @($entries) }
        $matrixJson = $matrixObj | ConvertTo-Json -Compress -Depth 10
    }
    else {
        $matrixJson = '{"include":[]}'
    }

    Write-Host "Stage '$stage': $($entries.Count) target(s)" -ForegroundColor $(if ($hasEntries) { "Green" } else { "Gray" })
    foreach ($e in $entries) {
        Write-Host "  [$($e.packageGroup)] → $($e.environment)" -ForegroundColor Gray
    }

    "${stage}_matrix=$matrixJson"                      | Out-File -FilePath $outputFile -Append -Encoding utf8
    "has_${stage}=$($hasEntries.ToString().ToLower())" | Out-File -FilePath $outputFile -Append -Encoding utf8
}

Write-Host ""
Write-Host "Configuration resolved successfully." -ForegroundColor Green

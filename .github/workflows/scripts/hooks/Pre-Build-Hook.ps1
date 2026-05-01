#
# Pre-Build Solution Version
# Updates the version in the Solution.xml prior to building the solution based on version information stored in the DCM
#

param(
    [Parameter()] [String]$solutionName = "",
    [Parameter()] [String]$solutionPath = "",
    [Parameter()] [String]$cdsprojPath = "",
    [Parameter()] [String]$artifactsPath = "",
    [Parameter()] [String]$targetEnvironmentUrl = "",
    [Parameter()] [String]$configuration = "Release",
    [Parameter()] [String]$stage = "pre-build"
)

Write-Host "Executing pre-build solution versioning hook for solution: $solutionName"

try {
    Write-Host "✓ Executed hook"
    exit 0
} catch {
    Write-Error "Notification hook failed: $($_.Exception.Message)"
    exit 1
}

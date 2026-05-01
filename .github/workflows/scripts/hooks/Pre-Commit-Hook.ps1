# Pre-commit hook: Modify source code before committing
param (
    [Parameter()] [String]$environmentUrl = "",
    [Parameter()] [String]$solutionName = "",
    [Parameter()] [String]$commitMessage = "",
    [Parameter()] [String]$branchName = "integration",
    [Parameter()] [String]$tagName = "PROMOTE",
    [Parameter()] [String]$unpackFolder = "./solutions",
    [Parameter()] [Boolean]$skipGitCommit = $false,
    [Parameter()] [Boolean]$isManualCopy = $false,
    [Parameter()] [String[]]$solutionsToUnpack = @(),
    [Parameter()] [String]$stage = "pre-commit"
)

Write-Host "Executing pre-commit hook for solution: $solutionName"

try {
    Write-Host "✓ Executed hook"
    exit 0
} catch {
    Write-Error "Notification hook failed: $($_.Exception.Message)"
    exit 1
}
param (
    [Parameter()] [String]$environmentUrl = "",
    [Parameter()] [String]$solutionName = "",
    [Parameter()] [String]$commitMessage = "",
    [Parameter()] [String]$branchName = "integration",
    [Parameter()] [String]$tagName = "PROMOTE",
    [Parameter()] [String]$unpackFolder = "./solutions",
    [Parameter()] [Boolean]$skipGitCommit = $false,
    [Parameter()] [Boolean]$isManualCopy = $false,
    [Parameter()] [String[]]$solutionsToUnpack = @()
)

Write-Host "Executing post-unpack hook for solution: $solutionName"

try {
    Write-Host "✓ Executed hook"
    exit 0
} catch {
    Write-Error "Notification hook failed: $($_.Exception.Message)"
    exit 1
}

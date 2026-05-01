# Pre-unpack hook: Log the start of solution unpacking operation
param (
    [Parameter()] [String]$environmentUrl = "",
    [Parameter()] [String]$solutionName = "",
    [Parameter()] [String]$commitMessage = "",
    [Parameter()] [String]$branchName = "",
    [Parameter()] [String]$tagName = "",
    [Parameter()] [String]$unpackFolder = "",
    [Parameter()] [Boolean]$skipGitCommit = $false,
    [Parameter()] [Boolean]$isManualCopy = $false,
    [Parameter()] [String[]]$solutionsToUnpack = @()
)


Write-Host "Executing pre-unpack hook for solution: $solutionName"

try {
    Write-Host "✓ Executed hook"
    exit 0
} catch {
    Write-Error "Notification hook failed: $($_.Exception.Message)"
    exit 1
}

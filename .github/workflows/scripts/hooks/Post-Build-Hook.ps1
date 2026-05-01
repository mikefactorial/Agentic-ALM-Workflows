#
# Post-Build Hook
# Example hook that executes after a solution has been built
#
# Context properties passed from Build-Solutions.ps1:
# - solutionName: Name of the solution being built
# - solutionPath: Path to the solution source folder
# - cdsprojPath: Path to the .cdsproj file
# - artifactsPath: Path where build artifacts are stored
# - targetEnvironmentUrl: URL of the target environment
# - configuration: Build configuration (e.g., Release, Debug)
# - buildOutputPath: Path to the build output (bin folder)
# - builtZipFiles: Array of paths to the built ZIP files
# - targetEnvironmentName: Name of the target environment
# - stage: "post-build"
#

param(
    [Parameter(Mandatory=$false)]
    [hashtable]$Context = @{}
)

Write-Host "Executing post-build hook for solution: $($Context.solutionName)"
Write-Host "Build output path: $($Context.buildOutputPath)"
Write-Host "Built ZIP files: $($Context.builtZipFiles -join ', ')"
Write-Host "Target environment: $($Context.targetEnvironmentName)"

try {
    # Add your post-build logic here
    # Examples:
    # - Upload artifacts to a storage location
    # - Send notifications about successful builds
    # - Run additional validation on built packages
    # - Update build tracking systems
    
    Write-Host "✓ Post-build hook executed successfully"
    exit 0
} catch {
    Write-Error "Post-build hook failed: $($_.Exception.Message)"
    exit 1
}

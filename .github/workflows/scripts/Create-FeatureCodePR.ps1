<#
.SYNOPSIS
    After feature promote, creates a clean code PR on develop containing only
    PCF control and plugin changes from the feature branch.

.DESCRIPTION
    Automates the post-promote clean code PR workflow:
      1. Detects which src/controls/ and src/plugins/ directories changed on
         the feature branch vs develop (using git diff on remote branches).
      2. Creates a new branch chore/{WorkItemNumber}_code from develop.
      3. Extracts only those directories from the feature branch.
      4. Commits and pushes the branch.
      5. Opens a GitHub PR using 'gh pr create'.

    This ensures only code-first artifacts reach develop — feature solution
    metadata and settings templates stay on the feature branch and are deleted
    when the branch is cleaned up.

    Prerequisites:
      - 'gh' CLI installed and authenticated (run 'gh auth status' to verify)
      - Feature branch has been pushed to origin
      - promote workflow has already completed successfully

.PARAMETER FeatureBranch
    Full feature branch name (e.g., feat/AB34567_StatusBadge).

.PARAMETER WorkItemNumber
    Work item identifier, with or without the 'AB' prefix (e.g., '34567' or 'AB34567').

.PARAMETER Description
    Short description used in the PR title and commit message
    (e.g., 'StatusBadge PCF control'). Defaults to the feature branch name.

.PARAMETER BaseBranch
    Branch to merge into. Defaults to 'develop'.

.PARAMETER DraftPR
    Open the PR as a draft instead of ready for review.
    Useful when you still need to populate EV values before merging.

.EXAMPLE
    # Standard usage after promote:
    .\Create-FeatureCodePR.ps1 -FeatureBranch "feat/AB34567_StatusBadge" -WorkItemNumber "AB34567" -Description "StatusBadge PCF control"

.EXAMPLE
    # Draft PR (e.g., still need to fill in EV values):
    .\Create-FeatureCodePR.ps1 -FeatureBranch "feat/AB34567_StatusBadge" -WorkItemNumber "AB34567" -Description "StatusBadge PCF control" -DraftPR
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$FeatureBranch,

    [Parameter(Mandatory)]
    [string]$WorkItemNumber,

    [string]$Description = "",

    [string]$BaseBranch = "develop",

    [switch]$DraftPR
)

$ErrorActionPreference = "Stop"

# ─── Read trackingSystem from environment-config.json ────────────────────────
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..\") -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty Path
if (-not $repoRoot) {
    # Fallback: walk up from script location looking for environment-config.json
    $repoRoot = $PSScriptRoot
    while ($repoRoot -and -not (Test-Path (Join-Path $repoRoot "deployments\settings\environment-config.json"))) {
        $repoRoot = Split-Path $repoRoot -Parent
    }
}
$envConfigPath = Join-Path $repoRoot "deployments\settings\environment-config.json"
$trackingSystem = "azureBoards"  # default
if (Test-Path $envConfigPath) {
    $envConfig = Get-Content $envConfigPath -Raw | ConvertFrom-Json
    if ($envConfig.trackingSystem) { $trackingSystem = $envConfig.trackingSystem }
}

# ─── Normalize identifiers based on trackingSystem ───────────────────────────
if ($trackingSystem -eq "github") {
    # GitHub Issues: strip any GH/AB prefix, produce GH{n} for branch names and Closes #{n} for trailers
    $workItem     = $WorkItemNumber -replace '^(GH|AB|#)', ''
    $workItemFull = "GH$workItem"          # used in branch names (no # — not valid in branch names)
    $workItemRef  = "Closes #$workItem"    # used in commit messages, PR titles, and PR body for GitHub linking
} else {
    # Azure Boards (default): strip any AB prefix, produce AB{n} for branch names and AB#{n} for trailers
    $workItem     = $WorkItemNumber -replace '^AB', ''
    $workItemFull = "AB$workItem"          # used in branch names (no # — not valid in branch names)
    $workItemRef  = "AB#$workItem"         # used in commit messages, PR titles, and PR body for ADO linking
}
$codeBranch = "chore/${workItemFull}_code"

if (-not $Description) {
    # Default to the part of the branch name after the work item number
    $Description = $FeatureBranch -replace '^feat/(AB|GH)\d+_?', '' -replace '_', ' '
}

# ─── Verify prerequisites ─────────────────────────────────────────────────────
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
    Write-Error "'gh' CLI not found. Install it from https://cli.github.com/ and authenticate with 'gh auth login'."
}

$ghStatus = gh auth status 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "GitHub CLI is not authenticated. Run 'gh auth login' first."
}

# ─── Verify working tree is clean ────────────────────────────────────────────
$dirty = git status --porcelain
if ($dirty) {
    Write-Error "Working tree has uncommitted changes. Stash or commit them first:`n$dirty"
}

# ─── Header ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Create Feature Code PR" -ForegroundColor Cyan
Write-Host "  Feature branch : $FeatureBranch" -ForegroundColor Cyan
Write-Host "  Work item      : $workItemFull" -ForegroundColor Cyan
Write-Host "  Code branch    : $codeBranch" -ForegroundColor Cyan
Write-Host "  Base branch    : $BaseBranch" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# ─── Fetch latest remote state ────────────────────────────────────────────────
Write-Host "Fetching from origin..." -ForegroundColor DarkGray
git fetch origin --quiet

# ─── Guard: local commits not yet pushed to origin ──────────────────────────
# If the user committed changes locally but forgot to push,
# git diff against origin/$FeatureBranch would silently miss them.
$unpushedCodeChanges = git log --oneline "origin/$FeatureBranch..HEAD" 2>$null
if ($unpushedCodeChanges) {
    Write-Error @"
Your local branch has commits that have NOT been pushed to origin/$FeatureBranch.
These would be silently missing from the code PR.

Push them first:
  git push origin HEAD:$FeatureBranch

Unpushed commits:
$unpushedCodeChanges
"@
}

# Verify the feature branch exists on origin
$remoteBranchCheck = git ls-remote --heads origin $FeatureBranch
if (-not $remoteBranchCheck) {
    Write-Error "Branch '$FeatureBranch' not found on origin. Push it first:`n  git push -u origin $FeatureBranch"
}

# ─── Detect changes — exclude feature solution metadata and generated files ──
# Exclude:
#   src/solutions/   — feature solution metadata (handled by promote/sync)
#   deployments/settings/templates/ — auto-generated from sync, not hand-authored
Write-Host "Detecting changes (excluding src/solutions/ and deployments/settings/templates/)..." -ForegroundColor DarkGray

$excludePatterns = @(
    '^src/solutions/',
    '^deployments/settings/templates/'
)

$allChangedFiles = git diff --name-only "origin/$BaseBranch...origin/$FeatureBranch"

if ($LASTEXITCODE -ne 0) {
    Write-Error "git diff failed. Ensure both branches exist on origin."
}

$changedFiles = $allChangedFiles | Where-Object {
    $file = $_
    $excluded = $false
    foreach ($pattern in $excludePatterns) {
        if ($file -match $pattern) { $excluded = $true; break }
    }
    -not $excluded
}

if (-not $changedFiles) {
    Write-Host ""
    Write-Host "No includable changes found on '$FeatureBranch' after excluding feature solution files." -ForegroundColor Yellow
    Write-Host "Nothing to include in a code PR." -ForegroundColor Yellow
    Write-Host ""
    exit 0
}

# Group files into checkout targets.
# For src/controls/ and src/plugins/ paths: group at project level (depth 4)
#   e.g. src/controls/pub_MySolution/PCF-MyControl
# For everything else: check out the individual file.
$checkoutTargets = $changedFiles | ForEach-Object {
    $parts = $_ -split '/'
    if ($parts.Count -ge 4 -and $parts[0] -eq 'src' -and $parts[1] -in @('controls', 'plugins')) {
        ($parts[0..3] -join '/')
    } else {
        $_
    }
} | Where-Object { $_ } | Sort-Object | Select-Object -Unique

# Alias for backwards-compatible naming used later in the script
$changedDirs = $checkoutTargets

Write-Host ""
Write-Host "Paths to include in PR:" -ForegroundColor White
$changedDirs | ForEach-Object { Write-Host "  + $_" -ForegroundColor Cyan }
Write-Host ""

# ─── Check code branch does not already exist ────────────────────────────────
$localExists  = git branch --list $codeBranch
$remoteExists = git ls-remote --heads origin $codeBranch

if ($localExists -or $remoteExists) {
    Write-Error "Branch '$codeBranch' already exists. Delete it before re-running:`n  git branch -D $codeBranch`n  git push origin --delete $codeBranch"
}

# ─── Create clean branch from base ───────────────────────────────────────────
Write-Host "Creating '$codeBranch' from origin/$BaseBranch..." -ForegroundColor DarkGray
git checkout $BaseBranch --quiet
git pull origin $BaseBranch --quiet
git checkout -b $codeBranch --quiet

# ─── Extract files from feature branch ──────────────────────────────────────
Write-Host "Extracting files from origin/$FeatureBranch..." -ForegroundColor DarkGray
foreach ($target in $changedDirs) {
    Write-Host "  Checking out $target" -ForegroundColor DarkGray
    git checkout "origin/$FeatureBranch" -- $target
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to check out '$target' from 'origin/$FeatureBranch'."
    }
}

# ─── Stage and commit ────────────────────────────────────────────────────────
git add -A 2>$null

$staged = git diff --cached --name-only
if (-not $staged) {
    Write-Error "Nothing staged after extraction — unexpected. Check branch names and paths."
}

# Determine commit scope from code-first solution folder names (e.g., pub_MySolution)
# Only consider src/controls/ and src/plugins/ paths for the scope label
$solutionFolders = $changedDirs |
    Where-Object { $_ -match '^src/(controls|plugins)/' } |
    ForEach-Object { ($_ -split '/')[2] } |
    Where-Object { $_ } |
    Sort-Object |
    Select-Object -Unique

if (-not $solutionFolders) {
    # Fallback: use top-level directory names if no controls/plugins paths
    $solutionFolders = $changedDirs |
        ForEach-Object { ($_ -split '/')[0] } |
        Where-Object { $_ } |
        Sort-Object |
        Select-Object -Unique
}

$scope     = $solutionFolders -join ','
$descSuffix = if ($Description) { " $Description" } else { "" }
$commitMsg = "feat(${scope}):${descSuffix} ${workItemRef}"

Write-Host ""
Write-Host "Committing: $commitMsg" -ForegroundColor DarkGray
git commit -m $commitMsg

# ─── Push ────────────────────────────────────────────────────────────────────
Write-Host "Pushing branch to origin..." -ForegroundColor DarkGray
git push -u origin $codeBranch

# ─── Open GitHub PR ───────────────────────────────────────────────────────────
$prTitle = "feat(${scope}):${descSuffix} ${workItemRef}"

$includedList = ($changedDirs | ForEach-Object { "- ``$_``" }) -join "`n"
$prBody = @"
## Code-First Changes — $workItemRef

This PR contains code-first changes extracted from \`$FeatureBranch\`.

Feature solution metadata (\`src/solutions/\`) and auto-generated settings templates (\`deployments/settings/templates/\`) are intentionally excluded — those travel with the feature branch lifecycle.

**Solution components** (tables, forms, flows, etc.) were already committed to \`$BaseBranch\` by the promote workflow sync commit.

### Included
$includedList

### Checklist
- [ ] Code reviewed
- [ ] Build passes (validated by the PR validation workflow)
- [ ] Any new environment variables have values in \`deployments/settings/environment-variables.json\`
- [ ] Any new connection references have IDs in \`deployments/settings/connection-mappings.json\`

### Cleanup (after merge)
```
git push origin --delete $FeatureBranch
```
"@

$prArgs = @("pr", "create", "--title", $prTitle, "--body", $prBody, "--base", $BaseBranch, "--head", $codeBranch)
if ($DraftPR) { $prArgs += "--draft" }

Write-Host ""
Write-Host "Opening GitHub PR..." -ForegroundColor DarkGray
& gh @prArgs

if ($LASTEXITCODE -ne 0) {
    Write-Error "Failed to create PR. Check the output above for details."
}

# ─── Done ────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  PR created successfully" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Next steps:" -ForegroundColor White
Write-Host "  1. Review and merge the PR: $codeBranch -> $BaseBranch" -ForegroundColor White
Write-Host "  2. After merge, delete the feature branch:" -ForegroundColor White
Write-Host "       git push origin --delete $FeatureBranch" -ForegroundColor White

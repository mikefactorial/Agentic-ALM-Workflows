# Hook Manager - Executes pipeline hooks at specific lifecycle points
# This script provides a centralized way to execute hooks with proper error handling and logging

function Invoke-PipelineHook {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$HookName,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $false)]
        [string]$HooksDirectory = "$PSScriptRoot\hooks",
        
        [Parameter(Mandatory = $false)]
        [bool]$ContinueOnError = $false,
        
        [Parameter(Mandatory = $false)]
        [bool]$ShowDetails = $false
    )
    
    $hookPath = Join-Path $HooksDirectory $HookName
    
    # Check if hook exists
    if (-not (Test-Path $hookPath)) {
        if ($ShowDetails) {
            Write-Host "Hook '$HookName' not found at '$hookPath' - skipping" -ForegroundColor Yellow
        }
        return $true
    }
    
    # Make sure it's a valid PowerShell script otherwise don't try to execute (could be disabled or an executable but not supported currently)
    $isScript = $hookPath.EndsWith('.ps1')
    
    try {
        Write-Host "Executing hook: $HookName"
        
        if ($isScript) {
            # Get hook's parameters to filter context appropriately
            $hookParams = @{}
            try {
                $hookAst = [System.Management.Automation.Language.Parser]::ParseFile($hookPath, [ref]$null, [ref]$null)
                $paramBlock = $hookAst.ParamBlock
                if ($paramBlock) {
                    foreach ($param in $paramBlock.Parameters) {
                        $paramName = $param.Name.VariablePath.UserPath
                        if ($Context.ContainsKey($paramName)) {
                            $hookParams[$paramName] = $Context[$paramName]
                        }
                    }
                }
            } catch {
                Write-Warning "Failed to parse hook parameters for '$HookName', using full context: $($_.Exception.Message)"
                $hookParams = $Context
            }
            
            # Execute PowerShell script with filtered context parameters
            & $hookPath @hookParams | Out-Null

            if ($LASTEXITCODE -eq 0) {
                Write-Host "✓ Hook '$HookName' completed successfully" -ForegroundColor Green
                return $true
            } else {
                Write-Warning "✗ Hook '$HookName' failed with exit code: $LASTEXITCODE"
                if (-not $ContinueOnError) {
                    throw "Hook '$HookName' failed with exit code: $LASTEXITCODE"
                }
                return $false
            }
        } 
        else {
            Write-Warning "✗ Hook '$HookName' not a valid powershell script: Skipping"
            return $true
        }
        
    } catch {
        Write-Error "Hook '$HookName' execution failed: $($_.Exception.Message)"
        if (-not $ContinueOnError) {
            throw
        }
        return $false
    }
}

function Invoke-PipelineHooks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Stage,
        
        [Parameter(Mandatory = $true)]
        [hashtable]$Context,
        
        [Parameter(Mandatory = $false)]
        [string]$HooksDirectory = "$PSScriptRoot\hooks",
        
        [Parameter(Mandatory = $false)]
        [bool]$ContinueOnError = $false,

        [Parameter(Mandatory = $false)]
        [System.Collections.Generic.List[object]]$Results
    )
    
    Write-Host "Executing hooks for stage: $Stage" -ForegroundColor Magenta
    
    # Get all hooks for this stage (pattern: {stage}-*.ps1 or {stage}-*)
    $hookPattern = Join-Path $HooksDirectory "$Stage-*"
    $hooks = Get-ChildItem -Path $hookPattern -ErrorAction SilentlyContinue | Sort-Object Name
    
    if ($hooks.Count -eq 0) {
        Write-Host "No hooks found for stage '$Stage'" -ForegroundColor Yellow
        return $true
    }
    
    $successCount = 0
    $failureCount = 0
    
    foreach ($hook in $hooks) {
        $hookName = $hook.Name
        $success = $false
        $errorMessage = $null
        try {
            $success = Invoke-PipelineHook -HookName $hookName -Context $Context -HooksDirectory $HooksDirectory -ContinueOnError:$ContinueOnError
        } catch {
            $errorMessage = $_.Exception.Message
            if (-not $ContinueOnError) {
                if ($null -ne $Results) {
                    $hookResult = [PSCustomObject]@{
                        Stage = $Stage
                        Hook = $hookName
                        Status = "Failed"
                        Error = $errorMessage
                    }

                    if ($Context.ContainsKey("solutionName")) {
                        $hookResult | Add-Member -NotePropertyName Solution -NotePropertyValue $Context.solutionName
                    }

                    if ($Context.ContainsKey("targetEnvironment")) {
                        $hookResult | Add-Member -NotePropertyName Environment -NotePropertyValue $Context.targetEnvironment
                    }

                    $Results.Add($hookResult)
                }

                throw
            }
        }

        if ($null -ne $Results) {
            $hookResult = [PSCustomObject]@{
                Stage = $Stage
                Hook = $hookName
                Status = $(if ($success) { "Success" } else { "Failed" })
                Error = $errorMessage
            }

            if ($Context.ContainsKey("solutionName")) {
                $hookResult | Add-Member -NotePropertyName Solution -NotePropertyValue $Context.solutionName
            }

            if ($Context.ContainsKey("targetEnvironment")) {
                $hookResult | Add-Member -NotePropertyName Environment -NotePropertyValue $Context.targetEnvironment
            }

            $Results.Add($hookResult)
        }
        
        if ($success) {
            $successCount++
        } else {
            $failureCount++
        }
    }
    
    Write-Host "Hook execution summary for '$Stage': $successCount succeeded, $failureCount failed"
    
    # Return overall success status
    return $failureCount -eq 0 -or $ContinueOnError
}

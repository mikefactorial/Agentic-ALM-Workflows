# Helper functions for reading HOOK_VARIABLES and HOOK_SECRETS JSON

$script:HookVariablesCache = $null
$script:HookSecretsCache = $null

function Get-HookVariables {
    if ($null -ne $script:HookVariablesCache) {
        return $script:HookVariablesCache
    }

    if ([string]::IsNullOrWhiteSpace($env:HOOK_VARIABLES)) {
        $script:HookVariablesCache = @{}
        return $script:HookVariablesCache
    }

    try {
        $script:HookVariablesCache = $env:HOOK_VARIABLES | ConvertFrom-Json -AsHashtable
    } catch {
        Write-Warning "HOOK_VARIABLES is not valid JSON."
        $script:HookVariablesCache = @{}
    }

    return $script:HookVariablesCache
}

function Get-HookSecrets {
    if ($null -ne $script:HookSecretsCache) {
        return $script:HookSecretsCache
    }

    if ([string]::IsNullOrWhiteSpace($env:HOOK_SECRETS)) {
        $script:HookSecretsCache = @{}
        return $script:HookSecretsCache
    }

    try {
        $script:HookSecretsCache = $env:HOOK_SECRETS | ConvertFrom-Json -AsHashtable
    } catch {
        Write-Warning "HOOK_SECRETS is not valid JSON."
        $script:HookSecretsCache = @{}
    }

    return $script:HookSecretsCache
}

function Get-HookVariable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [string]$Default = ""
    )

    $variables = Get-HookVariables
    if ($variables.ContainsKey($Name)) {
        return [string]$variables[$Name]
    }

    return $Default
}

function Get-HookSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $false)]
        [string]$Default = ""
    )

    $secrets = Get-HookSecrets
    if ($secrets.ContainsKey($Name)) {
        return [string]$secrets[$Name]
    }

    return $Default
}

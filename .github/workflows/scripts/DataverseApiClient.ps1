<#
.SYNOPSIS
    Dataverse Web API PowerShell Client with Federated and Interactive Authentication Support
    
.DESCRIPTION
    A PowerShell class-based client for interacting with Dataverse Web API.
    Supports federated authentication (GitHub OIDC) and interactive authentication
    for secure authentication in CI/CD pipelines and local development.
    
.NOTES
    Based on CoE ALM Accelerator patterns
#>

class DataverseApiClient {
    [string]$DataverseHost
    [string]$AccessToken
    [hashtable]$Headers
    [datetime]$TokenExpiry
    [string]$TenantId
    [string]$ClientId
    [string]$AadHost
    [bool]$UseFederated
    [bool]$UseInteractive

    # Constructor for federated authentication (GitHub Actions OIDC)
    DataverseApiClient([string]$tenantId, [string]$clientId, [string]$environmentUrl) {
        # Extract dataverse host from environment URL
        $environmentUri = [System.Uri]$environmentUrl
        $this.DataverseHost = $environmentUri.Host
        
        # Determine AAD host based on environment URL pattern
        $this.AadHost = $this.DetermineAadHost($environmentUri.Host)
        
        $this.TenantId = $tenantId
        $this.ClientId = $clientId
        $this.UseFederated = $true
        
        Write-Verbose "DataverseApiClient initialized with OIDC authentication"
        Write-Verbose "Environment URL: $environmentUrl"
        Write-Verbose "Dataverse Host: $($this.DataverseHost)"
        Write-Verbose "AAD Host: $($this.AadHost)"
        
        # Get initial token using OIDC
        $this.RefreshToken()
    }

    # Constructor for interactive authentication (local development)
    DataverseApiClient([string]$environmentUrl) {
        # Extract dataverse host from environment URL
        $environmentUri = [System.Uri]$environmentUrl
        $this.DataverseHost = $environmentUri.Host
        
        # Determine AAD host based on environment URL pattern
        $this.AadHost = $this.DetermineAadHost($environmentUri.Host)
        
        $this.UseFederated = $false
        $this.UseInteractive = $true
        
        Write-Verbose "DataverseApiClient initialized with interactive authentication"
        Write-Verbose "Environment URL: $environmentUrl"
        Write-Verbose "Dataverse Host: $($this.DataverseHost)"
        Write-Verbose "AAD Host: $($this.AadHost)"
        Write-Host "Note: Interactive authentication uses pac CLI auth profile for API calls" -ForegroundColor Yellow
        
        # Get token from pac CLI
        $this.GetTokenFromPacAuth()
    }

    # Constructor for interactive authentication with explicit tenant (guest-account safe)
    # Use when you are a guest in the target tenant and Connect-AzAccount may pick the wrong one.
    # Example: Connect-AzAccount -TenantId <id>; [DataverseApiClient]::new($url, $tenantId)
    DataverseApiClient([string]$environmentUrl, [string]$tenantId) {
        $environmentUri = [System.Uri]$environmentUrl
        $this.DataverseHost = $environmentUri.Host
        $this.AadHost       = $this.DetermineAadHost($environmentUri.Host)
        $this.TenantId      = $tenantId
        $this.UseFederated  = $false
        $this.UseInteractive = $true

        Write-Verbose "DataverseApiClient initialized with interactive authentication (tenant-scoped)"
        Write-Verbose "Environment URL: $environmentUrl"
        Write-Verbose "TenantId: $tenantId"
        Write-Host "Note: Interactive authentication uses pac CLI auth profile for API calls" -ForegroundColor Yellow

        $this.GetTokenFromPacAuth()
    }

    # Helper method to determine AAD host based on Dataverse host
    [string] DetermineAadHost([string]$dataverseHost) {
        if ($dataverseHost -like "*.crm.microsoftdynamics.us") {
            return "login.microsoftonline.us"
        } elseif ($dataverseHost -like "*.crm.dynamics.com") {
            return "login.microsoftonline.com"
        } else {
            # Default to commercial cloud
            return "login.microsoftonline.com"
        }
    }

    # Get GitHub OIDC Token
    [string] GetGitHubOidcToken() {
        $tokenRequestUrl = $env:ACTIONS_ID_TOKEN_REQUEST_URL
        $tokenRequestToken = $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN

        if ([string]::IsNullOrEmpty($tokenRequestUrl) -or [string]::IsNullOrEmpty($tokenRequestToken)) {
            throw "GitHub OIDC environment variables not found. This must run in GitHub Actions with id-token: write permission."
        }

        try {
            $oidcTokenResponse = Invoke-RestMethod -Uri "$tokenRequestUrl&audience=api://AzureADTokenExchange" `
                -Headers @{"Authorization" = "Bearer $tokenRequestToken"} `
                -Method Get
            
            return $oidcTokenResponse.value
        }
        catch {
            throw "Failed to get GitHub OIDC token: $($_.Exception.Message)"
        }
    }

    # Refresh token (supports federated authentication only)
    [void] RefreshToken() {
        $tokenUrl = "https://$($this.AadHost)/$($this.TenantId)/oauth2/v2.0/token"
        $scope = "https://$($this.DataverseHost)/.default"
        
        try {
            if ($this.UseFederated) {
                # Get GitHub OIDC token and exchange for Azure AD token
                Write-Verbose "Refreshing token using federated authentication (OIDC)..."
                $githubToken = $this.GetGitHubOidcToken()
                
                $body = @{
                    client_id             = $this.ClientId
                    client_assertion      = $githubToken
                    client_assertion_type = "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"
                    scope                 = $scope
                    grant_type            = "client_credentials"
                }
            }
            elseif ($this.UseInteractive) {
                # For interactive auth, get token from pac CLI
                Write-Verbose "Refreshing token from pac CLI auth profile..."
                $this.GetTokenFromPacAuth()
                return
            }
            else {
                throw "No authentication method configured"
            }
            
            Write-Verbose "Requesting token from: $tokenUrl"
            Write-Verbose "Scope: $scope"
            
            $OAuthReq = Invoke-RestMethod -Method Post -Uri $tokenUrl -Body $body -ContentType "application/x-www-form-urlencoded"
            $this.AccessToken = $OAuthReq.access_token
            
            # Calculate token expiry (refresh 5 minutes early to be safe)
            $expirySeconds = if ($OAuthReq.expires_in) { $OAuthReq.expires_in - 300 } else { 3300 }
            $this.TokenExpiry = (Get-Date).AddSeconds($expirySeconds)
            
            # Update headers with new token
            $this.Headers = $this.SetDefaultHeaders($this.AccessToken)
            
            Write-Verbose "Token refreshed successfully. Expires at: $($this.TokenExpiry)"
        }
        catch {
            Write-Error "Token request failed: $($_.Exception.Message)"
            if ($_.Exception.Response) {
                $reader = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())
                $reader.BaseStream.Position = 0
                $responseBody = $reader.ReadToEnd()
                Write-Error "Response: $responseBody"
            }
            throw "Failed to get access token: $($_.Exception.Message)"
        }
    }

    # Acquire a Dataverse access token via OAuth 2.0 device code flow.
    # No Az module required. Works for guest accounts and multi-tenant scenarios
    # because it authenticates directly against the specified tenant's endpoint
    # without relying on any cached Az session.
    # The well-known Azure PowerShell first-party client (1950a258-...) is
    # registered in every Entra tenant and supports device code for any scope.
    # Acquire a token by reading pac CLI's own MSAL token cache directly.
    # pac stores its cache at %LOCALAPPDATA%\Microsoft\PowerAppsCli\tokencache_msalv3.dat
    # as a DPAPI-encrypted MSAL v3 JSON blob.
    # Strategy:
    #   1. Decrypt with DPAPI + parse the JSON directly (no MSAL.NET library needed)
    #   2. Use a cached access token if one exists and is not expired
    #   3. Otherwise exchange a cached refresh token for a fresh access token
    # This uses the SAME client_id pac used, so the resulting token has identical
    # permissions to what pac uses when it runs pac solution import, etc.
    # Returns $null if the cache is missing or the exchange fails.
    [string] TryGetTokenFromPacCache([string]$tenantId) {
        try {
            $cacheFile = Join-Path $env:LOCALAPPDATA "Microsoft\PowerAppsCli\tokencache_msalv3.dat"
            if (-not (Test-Path $cacheFile)) { return $null }

            $resourceUrl = "https://$($this.DataverseHost)"
            $nowUnix     = [long](([datetime]::UtcNow - [datetime]'1970-01-01').TotalSeconds)

            # Decrypt DPAPI-protected cache and parse JSON (no MSAL.NET required)
            $encBytes   = [System.IO.File]::ReadAllBytes($cacheFile)
            $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $encBytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            $cache = [System.Text.Encoding]::UTF8.GetString($plainBytes) | ConvertFrom-Json

            # 1. Try a non-expired cached access token for our Dataverse resource
            if ($cache.AccessToken) {
                $atEntry = $cache.AccessToken.PSObject.Properties.Value |
                    Where-Object {
                        $_.credential_type -eq "AccessToken" -and
                        $_.secret -and
                        ($_.target -match [regex]::Escape($this.DataverseHost) -or
                         $_.target -match [regex]::Escape("crm.dynamics.com")) -and
                        ([long]$_.expires_on - 300) -gt $nowUnix
                    } |
                    Sort-Object { [long]$_.expires_on } -Descending |
                    Select-Object -First 1

                if ($atEntry) {
                    Write-Host "  ✓ Token acquired from pac CLI auth cache" -ForegroundColor Green
                    return $atEntry.secret
                }
            }

            # 2. Exchange a refresh token for a fresh access token using pac's own client_id
            if ($cache.RefreshToken) {
                $rtEntry = $cache.RefreshToken.PSObject.Properties.Value |
                    Where-Object { $_.credential_type -eq "RefreshToken" -and $_.secret } |
                    Select-Object -First 1

                if ($rtEntry) {
                    $tokenUri = "https://$($this.AadHost)/$tenantId/oauth2/v2.0/token"
                    $body     = @{
                        client_id     = $rtEntry.client_id
                        grant_type    = "refresh_token"
                        refresh_token = $rtEntry.secret
                        scope         = "$resourceUrl/.default"
                    }
                    $resp = Invoke-RestMethod -Method Post -Uri $tokenUri `
                        -Body $body -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
                    Write-Host "  ✓ Token refreshed from pac CLI auth cache" -ForegroundColor Green
                    return $resp.access_token
                }
            }

            return $null
        }
        catch {
            Write-Verbose "Pac cache token acquisition failed: $($_.Exception.Message)"
            return $null
        }
    }

    # Discover the home tenant ID from pac's MSAL cache without needing it ahead of time.
    # Reads the Account and AccessToken sections of the MSAL v3 cache (same DPAPI-encrypted file)
    # and returns the 'realm' (= tenant GUID) of the first entry matching this Dataverse host.
    [string] GetTenantIdFromPacCache() {
        try {
            $cacheFile = Join-Path $env:LOCALAPPDATA "Microsoft\PowerAppsCli\tokencache_msalv3.dat"
            if (-not (Test-Path $cacheFile)) { return $null }

            $encBytes   = [System.IO.File]::ReadAllBytes($cacheFile)
            $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $encBytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
            $cache = [System.Text.Encoding]::UTF8.GetString($plainBytes) | ConvertFrom-Json

            # Prefer realm from an access token entry for our specific Dataverse host
            if ($cache.AccessToken) {
                $atEntry = $cache.AccessToken.PSObject.Properties.Value |
                    Where-Object {
                        $_.credential_type -eq "AccessToken" -and $_.realm -and
                        ($_.target -match [regex]::Escape($this.DataverseHost) -or
                         $_.target -match [regex]::Escape("crm.dynamics.com"))
                    } | Select-Object -First 1
                if ($atEntry) {
                    Write-Verbose "Discovered tenant ID from pac CLI cache (access token): $($atEntry.realm)"
                    return $atEntry.realm
                }
            }

            # Fallback: take realm from the first account entry in the cache
            if ($cache.Account) {
                $account = $cache.Account.PSObject.Properties.Value |
                    Where-Object { $_.realm } | Select-Object -First 1
                if ($account) {
                    Write-Verbose "Discovered tenant ID from pac CLI cache (account): $($account.realm)"
                    return $account.realm
                }
            }

            return $null
        }
        catch {
            Write-Verbose "GetTenantIdFromPacCache failed: $($_.Exception.Message)"
            return $null
        }
    }

    [string] GetTokenViaDeviceCode([string]$tenantId) {
        $resourceUrl   = "https://$($this.DataverseHost)"
        $scope         = "$resourceUrl/.default"
        $psClientId    = "1950a258-227b-4e31-a9cf-717495945fc2"  # Azure PowerShell (first-party)
        $deviceCodeUri = "https://$($this.AadHost)/$tenantId/oauth2/v2.0/devicecode"
        $tokenUri      = "https://$($this.AadHost)/$tenantId/oauth2/v2.0/token"

        # Request the device code
        $dcBody = @{ client_id = $psClientId; scope = $scope }
        $dcResponse = Invoke-RestMethod -Method Post -Uri $deviceCodeUri `
            -Body $dcBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop

        Write-Host ""
        Write-Host $dcResponse.message -ForegroundColor Yellow
        Write-Host ""

        # Try to open the verification URL in the browser automatically
        try { Start-Process $dcResponse.verification_uri } catch { }

        # Poll until the user completes sign-in or the code expires
        $interval  = if ($dcResponse.interval)    { [int]$dcResponse.interval }    else { 5 }
        $expiresAt = (Get-Date).AddSeconds([int]$dcResponse.expires_in)
        $tokenBody = @{
            client_id   = $psClientId
            grant_type  = "urn:ietf:params:oauth:grant-type:device_code"
            device_code = $dcResponse.device_code
        }

        while ((Get-Date) -lt $expiresAt) {
            Start-Sleep -Seconds $interval
            try {
                $tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenUri `
                    -Body $tokenBody -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
                return $tokenResponse.access_token
            }
            catch {
                $errCode = $null
                try { $errCode = ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch { }
                if ($errCode -eq "authorization_pending") { continue }
                if ($errCode -eq "slow_down")             { $interval += 5; continue }
                throw "Device code flow failed: $($_.ErrorDetails.Message ?? $_.Exception.Message)"
            }
        }

        throw "Device code authentication timed out."
    }

    # Get token for interactive authentication.
    # Resolution order:
    #   1. If TenantId is not set, auto-discover it from pac CLI's MSAL cache
    #   2. Silent: read pac CLI's MSAL cache directly (DPAPI decrypt + JSON parse)
    #   3. Device code: browser sign-in — fallback only if pac cache unavailable
    # No Az module or Connect-AzAccount required.
    [void] GetTokenFromPacAuth() {
        try {
            $effectiveTenantId = $this.TenantId

            # Auto-discover TenantId from pac's MSAL cache if not explicitly provided
            if (-not $effectiveTenantId) {
                Write-Verbose "TenantId not set — discovering from pac CLI auth cache..."
                $effectiveTenantId = $this.GetTenantIdFromPacCache()
                if (-not $effectiveTenantId) {
                    throw "Could not determine tenant ID from pac CLI auth cache.`nPlease run 'pac auth create --interactive --environment <url>' first."
                }
                Write-Verbose "Discovered TenantId: $effectiveTenantId"
            }

            # 1. Try silent acquisition from pac's MSAL cache first (no browser, no Az module)
            Write-Verbose "Attempting silent token acquisition from pac CLI cache..."
            $silent = $this.TryGetTokenFromPacCache($effectiveTenantId)
            if ($silent) {
                $this.AccessToken = $silent
                $this.TokenExpiry = (Get-Date).AddMinutes(55)
                $this.Headers     = $this.SetDefaultHeaders($this.AccessToken)
                return
            }

            # 2. Fall back to device code (browser prompt, one-time per session)
            Write-Host "  pac auth cache unavailable — falling back to device code flow..." -ForegroundColor Yellow
            Write-Host "  NOTE: if 403 errors occur after login, run 'pac auth create --interactive --environment <url>'" -ForegroundColor Yellow
            $token = $this.GetTokenViaDeviceCode($effectiveTenantId)
            $this.AccessToken = $token
            $this.TokenExpiry = (Get-Date).AddMinutes(55)
            $this.Headers     = $this.SetDefaultHeaders($this.AccessToken)
            Write-Host "  ✓ Token acquired via device code flow" -ForegroundColor Green
        }
        catch {
            throw "Failed to get interactive token: $($_.Exception.Message)`nPlease run 'pac auth create --interactive --environment <url>' to authenticate."
        }
    }

    # Check if token needs refresh and refresh if necessary
    [void] EnsureValidToken() {
        if ((Get-Date) -ge $this.TokenExpiry) {
            Write-Verbose "Token expired, refreshing..."
            $this.RefreshToken()
        }
    }

    # Set Default Headers
    [hashtable] SetDefaultHeaders([string]$token) {
        $this.Headers = @{
            "Authorization"    = "Bearer $token"
            "Content-Type"     = "application/json"
            "Accept"           = "application/json"
            "OData-MaxVersion" = "4.0"
            "OData-Version"    = "4.0"
        }
        return $this.Headers
    }

    # Set Request URL
    [string] SetRequestUrl([string]$requestUrlRemainder) {
        $requestUrl = "https://$($this.DataverseHost)/api/data/v9.2/$requestUrlRemainder"
        return $requestUrl
    }

    # Invoke Dataverse HTTP GET
    [object] InvokeGet([string]$requestUrlRemainder) {
        try {
            $this.EnsureValidToken()
            $requestUrl = $this.SetRequestUrl($requestUrlRemainder)
            $response = Invoke-RestMethod $requestUrl -Method 'GET' -Headers $this.Headers
            return $response
        }
        catch {
            Write-Error "GET request failed for '$requestUrlRemainder': $($_.Exception.Message)"
            throw
        }
    }

    # Invoke Dataverse HTTP POST
    [object] InvokePost([string]$requestUrlRemainder, [string]$body) {
        try {
            $this.EnsureValidToken()
            $requestUrl = $this.SetRequestUrl($requestUrlRemainder)
            $response = Invoke-RestMethod $requestUrl -Method 'POST' -Headers $this.Headers -Body $body
            return $response
        }
        catch {
            Write-Error "POST request failed for '$requestUrlRemainder': $($_.Exception.Message)"
            throw
        }
    }

    # Invoke Dataverse HTTP PATCH
    [object] InvokePatch([string]$requestUrlRemainder, [string]$body) {
        try {
            $this.EnsureValidToken()
            $requestUrl = $this.SetRequestUrl($requestUrlRemainder)
            $response = Invoke-RestMethod $requestUrl -Method 'PATCH' -Headers $this.Headers -Body $body
            return $response
        }
        catch {
            Write-Error "PATCH request failed for '$requestUrlRemainder': $($_.Exception.Message)"
            throw
        }
    }

    # Invoke Dataverse HTTP DELETE
    [void] InvokeDelete([string]$requestUrlRemainder) {
        try {
            $this.EnsureValidToken()
            $requestUrl = $this.SetRequestUrl($requestUrlRemainder)
            Invoke-RestMethod $requestUrl -Method 'DELETE' -Headers $this.Headers
        }
        catch {
            Write-Error "DELETE request failed for '$requestUrlRemainder': $($_.Exception.Message)"
            throw
        }
    }

    # WhoAmI - Get current user context
    [object] WhoAmI() {
        return $this.InvokeGet("WhoAmI")
    }

    # RetrieveMultiple: Fetch records from a Dataverse table
    [array] RetrieveMultiple([string]$entityLogicalName, [string]$odataQuery = "") {
        $query = $odataQuery.TrimStart('?')
        $requestUrlRemainder = $entityLogicalName
        if ($query -and $query.Trim() -ne "") {
            $requestUrlRemainder += "?$query"
        }
        try {
            $response = $this.InvokeGet($requestUrlRemainder)
            return $response.value
        }
        catch {
            Write-Error "RetrieveMultiple failed for '$entityLogicalName': $($_.Exception.Message)"
            throw
        }
    }

    # RetrieveMultipleByFetchXml: Fetch records using FetchXML query
    [array] RetrieveMultipleByFetchXml([string]$entityLogicalName, [string]$fetchXml) {
        # URL-encode the FetchXML
        $encodedFetchXml = [System.Uri]::EscapeDataString($fetchXml)
        $requestUrlRemainder = "${entityLogicalName}?fetchXml=$encodedFetchXml"
        
        try {
            $response = $this.InvokeGet($requestUrlRemainder)
            return $response.value
        }
        catch {
            Write-Error "RetrieveMultipleByFetchXml failed for '$entityLogicalName': $($_.Exception.Message)"
            throw
        }
    }

    # Retrieve: Fetch a single record by ID
    [object] Retrieve([string]$entityLogicalName, [string]$recordId, [string]$selectColumns = "") {
        $requestUrlRemainder = "$entityLogicalName($recordId)"
        if ($selectColumns) {
            $requestUrlRemainder += "?`$select=$selectColumns"
        }
        try {
            return $this.InvokeGet($requestUrlRemainder)
        }
        catch {
            Write-Error "Retrieve failed for '$entityLogicalName' with ID '$recordId': $($_.Exception.Message)"
            throw
        }
    }

    # Create: Create a new record
    [string] Create([string]$entityLogicalName, [hashtable]$record) {
        $body = $record | ConvertTo-Json -Depth 10
        try {
            $response = $this.InvokePost($entityLogicalName, $body)
            # Extract the ID from the OData-EntityId header
            $entityId = $response.Headers.'OData-EntityId' -replace ".*\((.*)\).*", '$1'
            return $entityId
        }
        catch {
            Write-Error "Create failed for '$entityLogicalName': $($_.Exception.Message)"
            throw
        }
    }

    # Update: Update an existing record
    [void] Update([string]$entityLogicalName, [string]$recordId, [hashtable]$updates) {
        $requestUrlRemainder = "$entityLogicalName($recordId)"
        $body = $updates | ConvertTo-Json -Depth 10
        try {
            $this.InvokePatch($requestUrlRemainder, $body)
        }
        catch {
            Write-Error "Update failed for '$entityLogicalName' with ID '$recordId': $($_.Exception.Message)"
            throw
        }
    }

    # Delete: Delete a record
    [void] Delete([string]$entityLogicalName, [string]$recordId) {
        $requestUrlRemainder = "$entityLogicalName($recordId)"
        try {
            $this.InvokeDelete($requestUrlRemainder)
        }
        catch {
            Write-Error "Delete failed for '$entityLogicalName' with ID '$recordId': $($_.Exception.Message)"
            throw
        }
    }

    # Get Solution ID by unique name
    [string] GetSolutionId([string]$solutionName) {
        $requestUrlRemainder = "solutions?`$filter=uniquename eq '$solutionName'&`$select=solutionid,friendlyname"
        $response = $this.InvokeGet($requestUrlRemainder)
        
        if ($response.value.Count -eq 0) {
            throw "Solution '$solutionName' not found"
        }
        
        return $response.value[0].solutionid
    }

    # Get Solution Components
    [array] GetSolutionComponents([string]$solutionId) {
        $requestUrlRemainder = "solutioncomponents?`$filter=_solutionid_value eq '$solutionId'&`$select=solutioncomponentid,componenttype,objectid,rootsolutioncomponentid,ismetadata&`$orderby=rootsolutioncomponentid desc"
        $response = $this.InvokeGet($requestUrlRemainder)
        return $response.value
    }

    # Add Component to Solution
    [bool] AddComponentToSolution([string]$componentId, [int]$componentType, [string]$solutionName, [bool]$doNotIncludeSubcomponents) {
        $body = @{
            ComponentId              = $componentId
            ComponentType            = $componentType
            SolutionUniqueName       = $solutionName
            AddRequiredComponents    = $false
            DoNotIncludeSubcomponents = $doNotIncludeSubcomponents
        } | ConvertTo-Json
        
        try {
            $this.InvokePost("AddSolutionComponent", $body)
            return $true
        }
        catch {
            Write-Warning "Failed to add component $componentId (type: $componentType): $($_.Exception.Message)"
            return $false
        }
    }

    # Create Solution
    [bool] CreateSolution([string]$uniqueName, [string]$displayName, [string]$publisherPrefix) {
        # First get the publisher
        $publisherResponse = $this.InvokeGet("publishers?`$filter=customizationprefix eq '$publisherPrefix'&`$select=publisherid")
        
        if ($publisherResponse.value.Count -eq 0) {
            throw "Publisher with prefix '$publisherPrefix' not found"
        }
        
        $publisherId = $publisherResponse.value[0].publisherid
        
        $body = @{
            uniquename                = $uniqueName
            friendlyname              = $displayName
            description               = "Created by PowerShell script"
            "publisherid@odata.bind"  = "/publishers($publisherId)"
        } | ConvertTo-Json
        
        try {
            $this.InvokePost("solutions", $body)
            return $true
        }
        catch {
            Write-Warning "Failed to create solution '$uniqueName': $($_.Exception.Message)"
            return $false
        }
    }

    # Check if Solution Exists
    [bool] SolutionExists([string]$solutionName) {
        try {
            $this.GetSolutionId($solutionName)
            return $true
        }
        catch {
            return $false
        }
    }

    # Execute Action or Function
    [object] ExecuteAction([string]$actionName, [hashtable]$parameters = @{}) {
        $body = if ($parameters.Count -gt 0) { $parameters | ConvertTo-Json -Depth 10 } else { "" }
        try {
            return $this.InvokePost($actionName, $body)
        }
        catch {
            Write-Error "ExecuteAction failed for '$actionName': $($_.Exception.Message)"
            throw
        }
    }

    # Execute Batch Request
    [array] ExecuteBatch([array]$requests) {
        $batchId = [Guid]::NewGuid().ToString()
        $changesetId = [Guid]::NewGuid().ToString()
        
        $batchContent = "--batch_$batchId`r`n"
        $batchContent += "Content-Type: multipart/mixed; boundary=changeset_$changesetId`r`n`r`n"
        
        $requestNumber = 1
        foreach ($request in $requests) {
            $batchContent += "--changeset_$changesetId`r`n"
            $batchContent += "Content-Type: application/http`r`n"
            $batchContent += "Content-Transfer-Encoding: binary`r`n"
            $batchContent += "Content-ID: $requestNumber`r`n`r`n"
            
            $method = $request.Method
            $url = $this.SetRequestUrl($request.Url)
            $batchContent += "$method $url HTTP/1.1`r`n"
            $batchContent += "Content-Type: application/json`r`n`r`n"
            
            if ($request.Body) {
                $batchContent += ($request.Body | ConvertTo-Json -Depth 10)
            }
            
            $batchContent += "`r`n"
            $requestNumber++
        }
        
        $batchContent += "--changeset_$changesetId--`r`n"
        $batchContent += "--batch_$batchId--`r`n"
        
        $batchHeaders = @{
            "Authorization"    = "Bearer $($this.AccessToken)"
            "Content-Type"     = "multipart/mixed; boundary=batch_$batchId"
            "OData-MaxVersion" = "4.0"
            "OData-Version"    = "4.0"
        }
        
        try {
            $this.EnsureValidToken()
            $batchUrl = "https://$($this.DataverseHost)/api/data/v9.2/`$batch"
            $response = Invoke-RestMethod -Uri $batchUrl -Method Post -Headers $batchHeaders -Body $batchContent
            return $response
        }
        catch {
            Write-Error "Batch request failed: $($_.Exception.Message)"
            throw
        }
    }
}

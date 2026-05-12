<#
.SYNOPSIS
    Signs a plugin .nupkg file using dotnet nuget sign.

.DESCRIPTION
    Plugin packages that use Dataverse managed identity must be signed before being
    pushed to an environment. This script wraps 'dotnet nuget sign' and supports
    both PFX-file-based signing (CI/CD) and Windows certificate-store signing (dev).

    Signing is required when:
      - The plugin package is linked to a managed identity in Dataverse.
      - The environment enforces package signing (recommended for production).

    Prerequisites:
      - .NET SDK installed and on PATH (dotnet --version to verify)
      - A code-signing certificate in PFX format or in the Windows certificate store

    For development, you can generate a self-signed certificate:
      New-SelfSignedCertificate -Type CodeSigning -Subject "CN=DevPluginSigning" `
        -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(1)

.PARAMETER PackagePath
    Path to the .nupkg file to sign.

.PARAMETER CertificatePath
    Path to a .pfx certificate file. Provide either this or -CertificateFingerprint.

.PARAMETER CertificatePassword
    Password for the .pfx certificate file.

.PARAMETER CertificateFingerprint
    SHA-256 fingerprint of a certificate in the Windows certificate store.
    Provide either this or -CertificatePath.

.PARAMETER CertificateStoreLocation
    Certificate store location when using -CertificateFingerprint.
    Defaults to 'CurrentUser'.

.PARAMETER CertificateStoreName
    Certificate store name when using -CertificateFingerprint.
    Defaults to 'My'.

.PARAMETER Timestamper
    URL of a RFC 3161 timestamp server. Recommended for production to prevent
    signature expiry. Example: 'http://timestamp.digicert.com'

.PARAMETER HashAlgorithm
    Hash algorithm for the signature. Defaults to 'SHA256'. Dataverse accepts SHA256+.

.PARAMETER Overwrite
    Overwrite the existing signature if the package is already signed.

.EXAMPLE
    # Sign using a PFX file (CI/CD)
    .\Sign-PluginPackage.ps1 `
        -PackagePath "src/plugins/pub_MySolution/Publisher.Plugins.MySolution.Feature/bin/Debug/pub_Publisher.Plugins.MySolution.Feature.1.0.0.nupkg" `
        -CertificatePath "certs/signing.pfx" `
        -CertificatePassword "P@ssword" `
        -Timestamper "http://timestamp.digicert.com"

.EXAMPLE
    # Sign using a certificate from the Windows store (dev)
    .\Sign-PluginPackage.ps1 `
        -PackagePath "path/to/plugin.nupkg" `
        -CertificateFingerprint "AABBCCDD..."

.EXAMPLE
    # Sign all .nupkg files in a directory
    Get-ChildItem "src/plugins" -Recurse -Filter "*.nupkg" | ForEach-Object {
        .\Sign-PluginPackage.ps1 -PackagePath $_.FullName -CertificateFingerprint "AABBCCDD..."
    }
#>
[CmdletBinding(DefaultParameterSetName = 'Pfx')]
param(
    [Parameter(Mandatory)]
    [string]$PackagePath,

    # PFX-based signing
    [Parameter(ParameterSetName = 'Pfx', Mandatory)]
    [string]$CertificatePath,

    [Parameter(ParameterSetName = 'Pfx')]
    [string]$CertificatePassword,

    # Store-based signing
    [Parameter(ParameterSetName = 'Store', Mandatory)]
    [string]$CertificateFingerprint,

    [Parameter(ParameterSetName = 'Store')]
    [ValidateSet('CurrentUser', 'LocalMachine')]
    [string]$CertificateStoreLocation = 'CurrentUser',

    [Parameter(ParameterSetName = 'Store')]
    [string]$CertificateStoreName = 'My',

    # Common options
    [string]$Timestamper,

    [ValidateSet('SHA256', 'SHA384', 'SHA512')]
    [string]$HashAlgorithm = 'SHA256',

    [switch]$Overwrite
)

$ErrorActionPreference = 'Stop'

# ─── Verify dotnet is available ──────────────────────────────────────────────
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw ".NET SDK not found. Install from https://dot.net and ensure 'dotnet' is on PATH."
}

# ─── Resolve package path ────────────────────────────────────────────────────
$PackagePath = Resolve-Path $PackagePath -ErrorAction Stop | Select-Object -ExpandProperty Path
Write-Host ""
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  Sign Plugin Package" -ForegroundColor Cyan
Write-Host "  Package  : $PackagePath" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# ─── Build dotnet nuget sign arguments ───────────────────────────────────────
$signArgs = @('nuget', 'sign', $PackagePath, '--hash-algorithm', $HashAlgorithm)

switch ($PSCmdlet.ParameterSetName) {
    'Pfx' {
        $certPath = Resolve-Path $CertificatePath -ErrorAction Stop | Select-Object -ExpandProperty Path
        Write-Host "Signing mode : PFX certificate"
        Write-Host "Certificate  : $certPath"
        $signArgs += '--certificate-path', $certPath
        if ($CertificatePassword) {
            $signArgs += '--certificate-password', $CertificatePassword
        }
    }
    'Store' {
        Write-Host "Signing mode  : Windows certificate store"
        Write-Host "Fingerprint   : $CertificateFingerprint"
        Write-Host "Store         : $CertificateStoreLocation\$CertificateStoreName"
        $signArgs += '--certificate-fingerprint', $CertificateFingerprint
        $signArgs += '--certificate-store-location', $CertificateStoreLocation
        $signArgs += '--certificate-store-name', $CertificateStoreName
    }
}

if ($Timestamper) {
    Write-Host "Timestamper  : $Timestamper"
    $signArgs += '--timestamper', $Timestamper
}

if ($Overwrite) {
    $signArgs += '--overwrite'
}

Write-Host ""
Write-Host "Running: dotnet $($signArgs -join ' ')" -ForegroundColor DarkGray
Write-Host ""

# ─── Execute signing ─────────────────────────────────────────────────────────
& dotnet @signArgs
if ($LASTEXITCODE -ne 0) {
    throw "dotnet nuget sign failed with exit code $LASTEXITCODE. See output above."
}

# ─── Verify the signature was applied ────────────────────────────────────────
Write-Host ""
Write-Host "Verifying signature..." -ForegroundColor DarkGray
& dotnet nuget verify $PackagePath
if ($LASTEXITCODE -ne 0) {
    Write-Warning "dotnet nuget verify reported issues. Review output above before pushing to Dataverse."
}
else {
    Write-Host "Signature verified successfully." -ForegroundColor Green
}

Write-Host ""
Write-Host "==========================================" -ForegroundColor Green
Write-Host "  Package signed: $PackagePath" -ForegroundColor Green
Write-Host "==========================================" -ForegroundColor Green
Write-Host ""

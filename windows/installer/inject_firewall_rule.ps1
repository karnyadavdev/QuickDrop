# Adds the firewall rules to the installer file.

param(
    [Parameter(Mandatory = $true)]
    [string]$IssPath
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$rulesPath = Join-Path $scriptDir 'firewall_rules.iss'
$iconPath = Join-Path $scriptDir '..\runner\resources\app_icon.ico'

if (-not (Test-Path $rulesPath)) { Write-Error "Missing $rulesPath" }
if (-not (Test-Path -LiteralPath $IssPath)) {
    Write-Error "Generated Inno script not found: $IssPath"
}

$marker       = '; QuickDrop firewall rules'
$rulesContent = Get-Content -Raw -LiteralPath $rulesPath
$issContent   = Get-Content -Raw -LiteralPath $IssPath

function Set-SetupValue($content, $name, $value) {
    $pattern = "(?m)^$([regex]::Escape($name))=.*$"
    if ([regex]::IsMatch($content, $pattern)) {
        return [regex]::Replace($content, $pattern, "$name=$value")
    }
    return $content -replace '(?m)^\[Setup\]\s*$', "[Setup]`r`n$name=$value"
}

$versionMatch = [regex]::Match($issContent, '(?m)^AppVersion=(.+)$')
if (-not $versionMatch.Success) { throw 'Generated installer has no AppVersion.' }
$versionWithBuildNumber = $versionMatch.Groups[1].Value.Trim()
$version = $versionWithBuildNumber.Split('+')[0]
$numericParts = @($versionWithBuildNumber.Replace('+', '.').Split('.'))
$invalidNumericParts = @($numericParts | Where-Object { $_ -notmatch '^\d+$' })
if ($numericParts.Count -gt 4 -or $invalidNumericParts.Count -gt 0) {
    throw "AppVersion cannot be converted to Windows version metadata: $versionWithBuildNumber"
}
while ($numericParts.Count -lt 4) { $numericParts += '0' }
$numericVersion = $numericParts -join '.'

$values = [ordered]@{
    AppName                   = 'QuickDrop'
    AppVersion                = $version
    AppVerName                = "QuickDrop $version"
    AppPublisher              = 'karnyadavdev'
    UninstallDisplayName      = 'QuickDrop'
    OutputDir                 = '.'
    OutputBaseFilename        = "QuickDrop-$version-Installer"
    SetupIconFile             = $iconPath
    VersionInfoVersion        = $numericVersion
    VersionInfoProductVersion = $numericVersion
    VersionInfoCompany        = 'karnyadavdev'
    VersionInfoDescription    = 'QuickDrop Installer'
    VersionInfoProductName    = 'QuickDrop'
    VersionInfoCopyright      = 'Copyright (C) 2026 karnyadavdev'
}
foreach ($item in $values.GetEnumerator()) {
    $issContent = Set-SetupValue $issContent $item.Key $item.Value
}
Set-Content -LiteralPath $IssPath -Value $issContent -NoNewline

if ($issContent.Contains($marker)) {
    Write-Host 'Firewall rules already present; skipping.'
    exit 0
}

$runSection = $issContent.IndexOf('[Run]')
if ($runSection -ge 0) {
    $issContent = $issContent.Insert($runSection, "$rulesContent`r`n`r`n")
} else {
    $issContent = "$issContent`r`n$rulesContent"
}
Set-Content -LiteralPath $IssPath -Value $issContent -NoNewline
Write-Host "Firewall rules added before the app launch in $IssPath"

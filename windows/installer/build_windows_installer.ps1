# Builds the Windows installer and adds the firewall rules.
# Run this from the project folder:
#   powershell -ExecutionPolicy Bypass -File windows/installer/build_windows_installer.ps1

$ErrorActionPreference = 'Stop'

$dart = $env:QUICKDROP_DART
if ($dart -and -not (Test-Path $dart)) {
    throw "QUICKDROP_DART does not point to Dart: $dart"
}
if (-not $dart) {
    $dart = (Get-Command dart.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
}
if (-not $dart -and $env:FLUTTER_ROOT) {
    $candidate = Join-Path $env:FLUTTER_ROOT 'bin\cache\dart-sdk\bin\dart.exe'
    if (Test-Path $candidate) { $dart = $candidate }
}
if (-not $dart) {
    $candidate = Join-Path $HOME 'flutter\bin\cache\dart-sdk\bin\dart.exe'
    if (Test-Path $candidate) { $dart = $candidate }
}
if (-not $dart) {
    throw 'Dart was not found. Add Flutter/Dart to PATH, set FLUTTER_ROOT, or set QUICKDROP_DART to the Dart executable.'
}

$flutter = $env:QUICKDROP_FLUTTER
if ($flutter -and -not (Test-Path $flutter)) {
    throw "QUICKDROP_FLUTTER does not point to Flutter: $flutter"
}
if (-not $flutter) {
    $flutter = (Get-Command flutter.bat -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
}
if (-not $flutter -and $env:FLUTTER_ROOT) {
    $candidate = Join-Path $env:FLUTTER_ROOT 'bin\flutter.bat'
    if (Test-Path $candidate) { $flutter = $candidate }
}
if (-not $flutter) {
    $candidate = Join-Path $HOME 'flutter\bin\flutter.bat'
    if (Test-Path $candidate) { $flutter = $candidate }
}
if (-not $flutter) {
    throw 'Flutter was not found. Add Flutter to PATH, set FLUTTER_ROOT, or set QUICKDROP_FLUTTER to flutter.bat.'
}

$iscc = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
if (-not (Test-Path $iscc)) {
    Write-Error "Inno Setup compiler not found at $iscc. Install Inno Setup 6."
}

Write-Host '==> Building the current Windows app'
Push-Location $PSScriptRoot\..\..
try {
    & $flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw "Flutter build failed (exit $LASTEXITCODE)" }

    $app = Join-Path (Get-Location) 'build\windows\x64\runner\Release\QuickDrop.exe'
    if (-not (Test-Path -LiteralPath $app)) {
        throw "Expected Windows app was not created: $app"
    }

    Write-Host '==> Generating Inno Setup script (inno_bundle)'
    $releaseDir = Join-Path (Get-Location) 'build\windows\x64\installer\Release'
    $iss = Join-Path $releaseDir 'inno-script.iss'
    if (Test-Path -LiteralPath $iss) {
        Remove-Item -LiteralPath $iss -Force
    }
    & $dart run inno_bundle --no-app --release --no-installer
    if ($LASTEXITCODE -ne 0) { throw "inno_bundle failed (exit $LASTEXITCODE)" }
    if (-not (Test-Path -LiteralPath $iss)) {
        throw "Expected generated Inno script was not created: $iss"
    }

    Write-Host '==> Injecting firewall [Run] rules'
    & powershell -ExecutionPolicy Bypass -File windows/installer/inject_firewall_rule.ps1 -IssPath $iss
    if ($LASTEXITCODE -ne 0) { throw "Firewall injection failed (exit $LASTEXITCODE)" }

    $issContent = Get-Content -Raw -LiteralPath $iss
    $versionMatch = [regex]::Match($issContent, '(?m)^AppVersion=(.+)$')
    if (-not $versionMatch.Success) { throw 'Generated installer has no AppVersion.' }
    $version = $versionMatch.Groups[1].Value.Trim()
    $expectedInstaller = Join-Path $releaseDir "QuickDrop-$version-Installer.exe"
    $oldInstallers = Get-ChildItem -LiteralPath $releaseDir -Filter 'QuickDrop-*-Installer.exe' -File
    foreach ($oldInstaller in $oldInstallers) {
        Remove-Item -LiteralPath $oldInstaller.FullName -Force
    }

    Write-Host "==> Compiling installer with ISCC: $iss"
    & $iscc $iss
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed (exit $LASTEXITCODE)" }

    if (-not (Test-Path -LiteralPath $expectedInstaller)) {
        throw "Expected installer was not created: $expectedInstaller"
    }

    Write-Host "==> Done: $expectedInstaller"
} finally {
    Pop-Location
}

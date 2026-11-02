# Downloads the prebuilt native backend for Windows from the
# NielloUI GitHub Releases page and unpacks it under third_party/native/.
# Mirrors tools/fetch-native.sh (which covers Linux/macOS).
#
# Run as: powershell -ExecutionPolicy Bypass -File tools/fetch-native.ps1
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$Plat = 'windows-x64'
$Dest = Join-Path $Root "third_party\native\$Plat"

$Ver = if ($env:NIELLO_NATIVE_VERSION) { $env:NIELLO_NATIVE_VERSION } else { 'latest' }
if ($Ver -eq 'latest') {
    $Url = "https://github.com/Odalith/NielloUI/releases/latest/download/niello-native-$Plat.zip"
} else {
    $Url = "https://github.com/Odalith/NielloUI/releases/download/$Ver/niello-native-$Plat.zip"
}

Write-Host "fetch-native: $Plat -> $Dest"
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

# GitHub requires TLS 1.2; old Windows PowerShell defaults lower.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# The progress bar makes large downloads crawl in Windows PowerShell 5.1.
$ProgressPreference = 'SilentlyContinue'

$Tmp = Join-Path $env:TEMP 'niello-native.zip'
$Downloaded = $false
for ($Attempt = 1; $Attempt -le 3 -and -not $Downloaded; $Attempt++) {
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Tmp -UseBasicParsing
        $Downloaded = $true
    } catch {
        if ($Attempt -eq 3) {
            Write-Error "fetch-native: download failed - no release published yet? (tried $Url)"
        }
        Start-Sleep -Seconds 2
    }
}

Expand-Archive -Path $Tmp -DestinationPath $Dest -Force
Remove-Item $Tmp
Write-Host 'fetch-native: done. Contents:'
Get-ChildItem -Recurse -File $Dest | Select-Object -First 10 -ExpandProperty FullName

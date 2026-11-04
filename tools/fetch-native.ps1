# Downloads the prebuilt native backend for Windows from the
# NielloUI GitHub Releases page and unpacks it under third_party/native/.
# Mirrors tools/fetch-native.sh (which covers Linux/macOS).
#
# Also fetches SDL3 (default on). SDL ships official Windows binaries,
# so the SDL3 runtime comes from the libsdl-org release pinned to the
# bindings vintage (SDL 3.4.12) and SDL3.dll is staged under
# third_party\sdl3\windows-x64\ - copy it beside your .exe to run.
# Pass -NoSdl to use a system SDL3 instead.
#
# Run as: powershell -ExecutionPolicy Bypass -File tools/fetch-native.ps1
# Options: [-Version <tag>] [-Sdl] [-NoSdl] [-SdlOnly] [-NativeOnly]
# Version: -Version wins, else $env:NIELLO_NATIVE_VERSION, else latest.
param(
    [string]$Version,
    [switch]$Sdl,
    [switch]$NoSdl,
    [switch]$SdlOnly,
    [switch]$NativeOnly
)
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$Plat = 'windows-x64'
$SdlVersion = '3.4.12'

$WantNative = -not $SdlOnly
$WantSdl = -not $NoSdl -and -not $NativeOnly

$Ver = if ($Version) { $Version } elseif ($env:NIELLO_NATIVE_VERSION) { $env:NIELLO_NATIVE_VERSION } else { 'latest' }
if ($Ver -eq 'latest') {
    $NativeUrl = "https://github.com/Odalith/NielloUI/releases/latest/download/niello-native-$Plat.zip"
} else {
    $NativeUrl = "https://github.com/Odalith/NielloUI/releases/download/$Ver/niello-native-$Plat.zip"
}
$SdlUrl = "https://github.com/libsdl-org/SDL/releases/download/release-$SdlVersion/SDL3-$SdlVersion-win32-x64.zip"

# GitHub requires TLS 1.2; old Windows PowerShell defaults lower.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
# The progress bar makes large downloads crawl in Windows PowerShell 5.1.
$ProgressPreference = 'SilentlyContinue'

function Fetch-Zip([string]$Url, [string]$TmpName, [string]$Hint) {
    $Tmp = Join-Path $env:TEMP $TmpName
    $Downloaded = $false
    for ($Attempt = 1; $Attempt -le 3 -and -not $Downloaded; $Attempt++) {
        try {
            Invoke-WebRequest -Uri $Url -OutFile $Tmp -UseBasicParsing
            $Downloaded = $true
        } catch {
            if ($Attempt -eq 3) {
                Write-Error "fetch-native: download failed - $Hint (tried $Url)"
            }
            Start-Sleep -Seconds 2
        }
    }
    return $Tmp
}

if ($WantNative) {
    $Dest = Join-Path $Root "third_party\native\$Plat"
    Write-Host "fetch-native: niello-native-$Plat.zip -> $Dest"
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $Tmp = Fetch-Zip $NativeUrl 'niello-native.zip' 'no release published yet?'
    Expand-Archive -Path $Tmp -DestinationPath $Dest -Force
    Remove-Item $Tmp
    Write-Host 'fetch-native: native contents:'
    Get-ChildItem -Recurse -File $Dest | Select-Object -First 10 -ExpandProperty FullName
}

if ($WantSdl) {
    $Dest = Join-Path $Root "third_party\sdl3\$Plat"
    Write-Host "fetch-native: SDL3-$SdlVersion-win32-x64.zip (libsdl-org) -> $Dest"
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    $Tmp = Fetch-Zip $SdlUrl 'niello-sdl3.zip' 'SDL3 official release unavailable?'
    $Stage = Join-Path $env:TEMP 'niello-sdl3-stage'
    if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
    Expand-Archive -Path $Tmp -DestinationPath $Stage -Force
    Remove-Item $Tmp
    # The runtime zip's folder layout varies; find the DLL wherever it is.
    $Dll = Get-ChildItem -Path $Stage -Recurse -Filter 'SDL3.dll' | Select-Object -First 1
    if (-not $Dll) {
        Write-Error 'fetch-native: SDL3.dll not found in the SDL3 release zip'
    }
    Copy-Item $Dll.FullName -Destination (Join-Path $Dest 'SDL3.dll') -Force
    $License = Get-ChildItem -Path $Stage -Recurse -Filter 'LICENSE.txt' | Select-Object -First 1
    if ($License) { Copy-Item $License.FullName -Destination (Join-Path $Dest 'LICENSE.txt') -Force }
    Remove-Item -Recurse -Force $Stage
    Write-Host 'fetch-native: SDL3 contents:'
    Get-ChildItem -Recurse -File $Dest | Select-Object -ExpandProperty FullName
    Write-Host 'fetch-native: copy SDL3.dll beside your .exe to run.'
}

Write-Host 'fetch-native: done.'

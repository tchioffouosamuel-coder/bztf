$ErrorActionPreference = 'Stop'

$appRoot = Split-Path $PSScriptRoot -Parent
$workspace = Split-Path $appRoot -Parent
$sdkDll = Join-Path $workspace 'RFID Desktop Reader SDK-EN\SDK-EN\c#\c#-api\GReaderApi.dll'
$bundledDll = Join-Path $PSScriptRoot 'bin\GReaderApi.dll'
$sources = @(
    (Join-Path $PSScriptRoot 'ReaderBridge.cs'),
    (Join-Path $PSScriptRoot 'BridgeSettings.cs')
)
$outputDir = Join-Path $PSScriptRoot 'bin'
$output = Join-Path $outputDir 'ReaderBridge.exe'
$compiler = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'

if (-not (Test-Path -LiteralPath $sdkDll)) { $sdkDll = $bundledDll }
if (-not (Test-Path -LiteralPath $sdkDll)) { throw "DLL constructeur introuvable: $sdkDll" }
if (-not (Test-Path -LiteralPath $compiler)) { throw "Compilateur .NET Framework introuvable: $compiler" }

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null
$outputDll = Join-Path $outputDir 'GReaderApi.dll'
if ([IO.Path]::GetFullPath($sdkDll) -ne [IO.Path]::GetFullPath($outputDll)) {
    Copy-Item -LiteralPath $sdkDll -Destination $outputDll -Force
}

& $compiler /nologo /target:exe /optimize+ /out:$output /reference:$sdkDll /reference:System.Core.dll /reference:System.Web.Extensions.dll $sources
if ($LASTEXITCODE -ne 0) { throw 'La compilation du pont RFID a échoué.' }

Write-Host "Pont RFID compilé: $output"

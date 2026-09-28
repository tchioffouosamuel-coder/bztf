$ErrorActionPreference = 'Stop'

$compiler = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$source = Join-Path $PSScriptRoot 'BiblioRFIDLauncher.cs'
$outputDirectory = Join-Path $PSScriptRoot 'bin'
$output = Join-Path $outputDirectory 'BiblioRFID.exe'

if (-not (Test-Path -LiteralPath $compiler)) {
    throw "Compilateur .NET Framework introuvable : $compiler"
}

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
& $compiler /nologo /target:winexe /optimize+ /out:$output /reference:System.dll /reference:System.Windows.Forms.dll $source
if ($LASTEXITCODE -ne 0) { throw 'La compilation du lanceur BiblioRFID a échoué.' }

Write-Host "Lanceur compilé : $output"

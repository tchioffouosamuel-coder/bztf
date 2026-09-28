$ErrorActionPreference = 'Stop'
$appRoot = $PSScriptRoot

if (-not (Test-Path (Join-Path $appRoot 'node_modules'))) {
  npm install --prefix $appRoot
  if ($LASTEXITCODE -ne 0) { throw 'Installation des dépendances impossible.' }
}

powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $appRoot 'bridge\build.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Compilation du pont RFID impossible.' }

node --no-warnings=ExperimentalWarning (Join-Path $appRoot 'server.js')

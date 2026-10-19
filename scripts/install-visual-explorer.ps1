# Instala exclusivamente el Explorador visual de Muondia en VS Code.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$source = Join-Path $repo 'tools\visual-explorer'
if (-not (Test-Path (Join-Path $source 'package.json'))) {
    throw 'No existe la extension visual de Muondia.'
}
$target = Join-Path $env:USERPROFILE '.vscode\extensions\magullodev.muondia-visual-0.1.0'
New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
if (-not (Test-Path $target)) {
    New-Item -ItemType Junction -Path $target -Target $source | Out-Null
}
Write-Host 'Explorador visual de Muondia preparado. Reinicia VS Code.'

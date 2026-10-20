# Instala únicamente el explorador propio de Muondia en VS Code.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$source = Join-Path $repo 'tools\visual-explorer'
$package = Join-Path $source 'package.json'
if (-not (Test-Path -LiteralPath $package)) {
    throw 'No existe el explorador de Muondia.'
}
$target = Join-Path $env:USERPROFILE '.vscode\extensions\magullodev.muondia-visual-0.1.0'
New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
if (Test-Path -LiteralPath $target) {
    $link = Get-Item -LiteralPath $target -Force
    if ($link.LinkType -ne 'Junction' -or
        [IO.Path]::GetFullPath($link.Target) -ne [IO.Path]::GetFullPath($source)) {
        throw "La ruta de extensión ya existe y no apunta a Muondia: $target"
    }
} else {
    New-Item -ItemType Junction -Path $target -Target $source | Out-Null
}
Write-Host 'Explorador de Muondia instalado. En VS Code ejecuta Developer: Reload Window.'

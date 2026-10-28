param([switch]$Watch)

$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'sync_main.ps1'
if (-not (Test-Path -LiteralPath $script)) {
    throw "No se encuentra el sincronizador principal: $script"
}
if ($Watch) {
    & $script -Watch
} else {
    & $script
}
exit $LASTEXITCODE

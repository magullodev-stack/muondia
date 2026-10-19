# Instala o retira la integración Git de Muondia con VS Code.
# No crea tareas programadas ni mantiene procesos residentes.
param([switch]$Install, [switch]$Remove)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$extension = Join-Path $repo 'tools\visual-explorer'
$target = Join-Path $env:USERPROFILE '.vscode\extensions\magullodev.muondia-visual-0.1.0'

if ($Install -eq $Remove) {
    throw 'Indica -Install o -Remove.'
}

$remote = (& git -C $repo remote get-url origin)
$branch = (& git -C $repo branch --show-current)
if ($remote -notmatch '^(https://github\.com/|git@github\.com:)magullodev-stack/muondia(\.git)?$' -or
    $branch -ne 'dev') {
    throw 'Se esperaba el repositorio magullodev-stack/muondia en la rama dev.'
}

# Una instalación anterior de la tarea de un minuto queda retirada.
$oldTask = Get-ScheduledTask -TaskName 'Muondia Git Sync' -ErrorAction SilentlyContinue
if ($oldTask) {
    Unregister-ScheduledTask -TaskName 'Muondia Git Sync' -Confirm:$false
}

if ($Remove) {
    if (Test-Path -LiteralPath $target) {
        $item = Get-Item -LiteralPath $target -Force
        if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'La ruta de instalación no es un enlace. No se elimina.'
        }
        [IO.Directory]::Delete($target)
    }
    Write-Host 'Sincronización Muondia desinstalada.'
    return
}

if (-not (Test-Path -LiteralPath (Join-Path $extension 'package.json'))) {
    throw 'Falta la extensión Muondia. Ejecuta git pull --ff-only origin dev.'
}

# Excluir del control de versiones credenciales locales de la aplicación.
$ignoreFile = Join-Path $repo '.gitignore'
$ignore = if (Test-Path -LiteralPath $ignoreFile) {
    [IO.File]::ReadAllText($ignoreFile)
} else { '' }
foreach ($rule in @('/android/app/google-services.json','/.env','/.env.*',
    '/.muondia/','*.p12','*.pfx','*.pem','*.key','*.keystore','*.jks')) {
    if ($rule -notin @($ignore -split '\r?\n')) {
        if ($ignore.Length -gt 0 -and -not $ignore.EndsWith([char]10)) {
            $ignore += [Environment]::NewLine
        }
        $ignore += $rule + [Environment]::NewLine
    }
}
[IO.File]::WriteAllText($ignoreFile,$ignore,[Text.UTF8Encoding]::new($false))

$extensionsDir = Split-Path $target -Parent
New-Item -ItemType Directory -Path $extensionsDir -Force | Out-Null
if (Test-Path -LiteralPath $target) {
    $item = Get-Item -LiteralPath $target -Force
    if (-not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'La ruta de instalación ya existe y no es un enlace.'
    }
    $linked = @($item.Target)[0]
    if (-not $linked) { throw 'No se puede resolver el enlace existente.' }
    $resolved = if ([IO.Path]::IsPathRooted($linked)) {
        [IO.Path]::GetFullPath($linked)
    } else {
        [IO.Path]::GetFullPath((Join-Path $extensionsDir $linked))
    }
    if ($resolved -ine [IO.Path]::GetFullPath($extension)) {
        throw 'La ruta de instalación apunta a otra extensión.'
    }
} else {
    New-Item -ItemType Junction -Path $target -Target $extension | Out-Null
}

# Retirar la extensión de la antigua plataforma, sin tocar EmbeDroid.
$code = Get-Command 'code' -ErrorAction SilentlyContinue
if ($code) {
    $installed = @(& $code.Source --list-extensions)
    if ($installed -contains 'magullodev.ai-apps-android') {
        & $code.Source --uninstall-extension 'magullodev.ai-apps-android' | Out-Null
    }
}
Write-Host 'Muondia lista. Recarga VS Code para activar el Explorador y la sincronización cada 10 s.'

# Muondia: sincronizacion Git bidireccional de la rama dev.
# Uso: .\scripts\sync-dev.ps1 -Install | -Once | -Remove
# Una tarea de Windows ejecuta una pasada cada minuto; no hay proceso residente.
param(
    [switch]$Install,
    [switch]$Once,
    [switch]$Remove
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$taskName = 'Muondia Git Sync'
$logFile = Join-Path $repo '.git\muondia-sync.log'

function Write-SyncLog([string]$Message) {
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -LiteralPath $logFile -Value "[$stamp] $Message" -Encoding UTF8
}

function Invoke-Git([string[]]$GitArgs) {
    $previous = $ErrorActionPreference
    try {
        # En Windows PowerShell 5.1, stderr de Git puede generar NativeCommandError.
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $repo @GitArgs 2>&1)
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($code -ne 0) {
        throw "git $($GitArgs -join ' '): $(($output | Out-String).Trim())"
    }
    return ($output | Out-String).Trim()
}

function Protect-LocalFiles {
    $file = Join-Path $repo '.gitignore'
    $rules = @(
        '/android/app/google-services.json',
        '/android/local.properties',
        '/.env',
        '/.env.*',
        '/.ai-apps/',
        '/.muondia/',
        '*.keystore',
        '*.jks',
        '*.p12',
        '*.pfx',
        '*.pem',
        '*.key'
    )
    $content = if (Test-Path -LiteralPath $file) {
        [IO.File]::ReadAllText($file)
    } else { '' }
    $existing = @($content -split '\r?\n')
    $missing = @($rules | Where-Object { $_ -notin $existing })
    if ($missing.Count -eq 0) { return }

    if ($content.Length -gt 0 -and -not $content.EndsWith([char]10)) {
        $content += [Environment]::NewLine
    }
    $content += '# Muondia: archivos privados locales' + [Environment]::NewLine
    $content += ($missing -join [Environment]::NewLine) + [Environment]::NewLine
    [IO.File]::WriteAllText($file, $content, [Text.UTF8Encoding]::new($false))
}

function Invoke-Sync {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        throw 'Git no esta instalado o no esta en PATH.'
    }
    $origin = Invoke-Git -GitArgs @('remote', 'get-url', 'origin')
    if ($origin -notmatch '^(https://github\.com/|git@github\.com:)magullodev-stack/muondia(\.git)?$') {
        throw "Remoto inesperado: $origin"
    }
    $branch = Invoke-Git -GitArgs @('branch', '--show-current')
    if ($branch -ne 'dev') { throw "Se esperaba la rama dev; actual: $branch" }

    foreach ($state in @('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'rebase-apply', 'rebase-merge')) {
        if (Test-Path (Join-Path $repo ".git\$state")) {
            throw "Hay una operacion Git pendiente ($state). No se sincroniza."
        }
    }

    $mutex = New-Object System.Threading.Mutex($false, 'Local\MuondiaGitSync')
    $acquired = $false
    try {
        $acquired = $mutex.WaitOne(0)
        if (-not $acquired) { return }

        $env:GIT_TERMINAL_PROMPT = '0'
        Protect-LocalFiles
        Invoke-Git -GitArgs @('fetch', '--quiet', 'origin', 'dev') | Out-Null
        Invoke-Git -GitArgs @('add', '-A') | Out-Null

        # Bloquear la publicacion accidental de credenciales, aunque esten versionadas.
        $staged = @((Invoke-Git -GitArgs @('diff', '--cached', '--name-only')) -split '\r?\n')
        $sensitive = @($staged | Where-Object {
            $_ -match '(^|/)(google-services\.json|local\.properties|\.env(\..*)?|[^/]+\.(pem|key|p12|pfx|jks|keystore))$'
        })
        if ($sensitive.Count -gt 0) {
            throw "Archivos privados preparados para commit: $($sensitive -join ', '). Revisa Git."
        }

        if ($staged.Count -gt 0 -and @($staged | Where-Object { $_ }).Count -gt 0) {
            Invoke-Git -GitArgs @('commit', '-m', 'Sync Muondia') | Out-Null
            Write-SyncLog 'Commit local preparado.'
        }

        try {
            Invoke-Git -GitArgs @('rebase', 'origin/dev') | Out-Null
        } catch {
            # Ante un conflicto no se descartan commits ni se deja un rebase a medias.
            $problem = $_.Exception.Message
            if ((Test-Path (Join-Path $repo '.git\rebase-merge')) -or
                (Test-Path (Join-Path $repo '.git\rebase-apply'))) {
                Invoke-Git -GitArgs @('rebase', '--abort') | Out-Null
            }
            throw "Conflicto con origin/dev; commits locales conservados. $problem"
        }

        $localHead = Invoke-Git -GitArgs @('rev-parse', 'HEAD')
        $remoteHead = Invoke-Git -GitArgs @('rev-parse', 'origin/dev')
        if ($localHead -ne $remoteHead) {
            Invoke-Git -GitArgs @('push', 'origin', 'dev') | Out-Null
            Write-SyncLog "Cambios enviados a origin/dev: $localHead"
        }
    } finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if ($Install -and $Remove) { throw 'Usa -Install o -Remove, no ambos.' }
if ($Remove) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host 'Sincronizacion automatica de Muondia desinstalada.'
    return
}

if ($Install) {
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (
        '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Once' -f $PSCommandPath
    )
    $trigger = New-ScheduledTaskTrigger -Daily -At (Get-Date).AddMinutes(1)
    $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 1)
    $trigger.Repetition = $repeat.Repetition
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    Write-Host 'Muondia Git Sync instalada: sincronizacion cada minuto.'
}

try {
    Invoke-Sync
    Write-Host 'Muondia dev sincronizada con origin/dev.'
} catch {
    Write-SyncLog $_.Exception.Message
    Write-Error $_.Exception.Message
    exit 1
}

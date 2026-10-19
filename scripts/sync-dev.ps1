# Muondia: Git bidireccional desde VS Code. Sin tareas de Windows.
param([switch]$Watch)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$env:GIT_TERMINAL_PROMPT = '0'
$log = Join-Path $repo '.git\muondia-sync.log'

function G([string[]]$command) {
    $old = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $repo @command 2>&1)
        $exit = $LASTEXITCODE
    } finally { $ErrorActionPreference = $old }
    if ($exit -ne 0) {
        throw "git $($command -join ' '): $(($output | Out-String).Trim())"
    }
    return ($output | Out-String).Trim()
}

function Report([string]$message) {
    $line = "[$(Get-Date -Format 'HH:mm:ss')] $message"
    Add-Content -LiteralPath $log -Value $line -Encoding UTF8
    Write-Host $line
}

function Ensure-Ignores {
    $file = Join-Path $repo '.gitignore'
    $content = if (Test-Path $file) { [IO.File]::ReadAllText($file) } else { '' }
    $rules = @('/android/local.properties', '/android/app/google-services.json',
        '/.env', '/.env.*', '/.muondia/', '*.jks', '*.keystore',
        '*.pem', '*.p12', '*.pfx', '*.key')
    $known = @($content -split '\r?\n')
    $new = @($rules | Where-Object { $_ -notin $known })
    if ($new.Count -eq 0) { return }
    if ($content.Length -gt 0 -and -not $content.EndsWith([char]10)) {
        $content += [Environment]::NewLine
    }
    $content += ($new -join [Environment]::NewLine) + [Environment]::NewLine
    [IO.File]::WriteAllText($file, $content, [Text.UTF8Encoding]::new($false))
}

function Sync([bool]$allowCommit) {
    if ((G @('branch', '--show-current')) -ne 'dev' -or
        (G @('remote', 'get-url', 'origin')) -notmatch
        '^(https://github\.com/|git@github\.com:)magullodev-stack/muondia(\.git)?$') {
        throw 'Repositorio o rama inesperados. Solo se sincroniza muondia/dev.'
    }
    foreach ($state in @('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'rebase-merge', 'rebase-apply')) {
        if (Test-Path (Join-Path $repo ".git\$state")) {
            throw "Operacion Git pendiente: $state"
        }
    }

    Ensure-Ignores
    G @('fetch', '--quiet', '--no-tags', 'origin', 'dev') | Out-Null
    $dirty = G @('status', '--porcelain', '--untracked-files=all')
    if ($dirty -and -not $allowCommit) { return }

    if ($dirty) {
        G @('add', '-A') | Out-Null
        $staged = G @('diff', '--cached', '--name-only')
        $private = @($staged -split '\r?\n' | Where-Object {
            $_ -match '(^|/)(google-services\.json|local\.properties|\.env(\..*)?|[^/]+\.(jks|keystore|pem|p12|pfx|key))$'
        })
        if ($private.Count -gt 0) {
            G @('reset', '--quiet') | Out-Null
            throw 'Archivos privados detectados. No se publica nada.'
        }
        if ($staged) {
            G @('commit', '-m', 'Sync Muondia') | Out-Null
            Report 'Cambios locales confirmados.'
        }
    }

    $behind = [int](G @('rev-list', '--count', 'HEAD..origin/dev'))
    $ahead = [int](G @('rev-list', '--count', 'origin/dev..HEAD'))
    if ($behind -gt 0 -and $ahead -gt 0) {
        try {
            G @('rebase', 'origin/dev') | Out-Null
        } catch {
            $reason = $_.Exception.Message
            if ((Test-Path (Join-Path $repo '.git\rebase-merge')) -or
                (Test-Path (Join-Path $repo '.git\rebase-apply'))) {
                G @('rebase', '--abort') | Out-Null
            }
            throw "Conflicto: commits conservados. $reason"
        }
        Report 'Cambios de ambas partes integrados.'
    } elseif ($behind -gt 0) {
        G @('merge', '--ff-only', 'origin/dev') | Out-Null
        Report 'GitHub actualizado en VS Code.'
    }
    if ([int](G @('rev-list', '--count', 'origin/dev..HEAD')) -gt 0) {
        G @('push', 'origin', 'dev') | Out-Null
        Report 'Cambios publicados en GitHub.'
    }
}

if (-not $Watch) {
    Sync $true
    Write-Host 'Muondia sincronizada.'
    return
}

Report 'Sincronizacion iniciada con VS Code.'
$previous = ''
$stableSince = Get-Date
$previousError = ''
while ($true) {
    try {
        $status = G @('status', '--porcelain', '--untracked-files=all')
        if ($status -ne $previous) {
            $stableSince = Get-Date
            $previous = $status
        }
        $safe = -not $status -or ((Get-Date) - $stableSince).TotalSeconds -ge 12
        Sync $safe
        $previousError = ''
    } catch {
        $reason = $_.Exception.Message
        if ($reason -ne $previousError) {
            Report "Pendiente: $reason"
            $previousError = $reason
        }
    }
    Start-Sleep -Seconds 3
}

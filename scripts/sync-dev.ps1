param([switch]$Watch)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$env:GIT_TERMINAL_PROMPT = '0'

function Git([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& git -C $repo @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($exitCode -ne 0) {
        throw "git $($Arguments -join ' '): $(($output | Out-String).Trim())"
    }
    return ($output | Out-String).Trim()
}

function Protect-Files {
    $file = Join-Path $repo '.gitignore'
    $text = if (Test-Path -LiteralPath $file) { [IO.File]::ReadAllText($file) } else { '' }
    $existing = @($text -split '\r?\n')
    $rules = @('**/google-services.json', '**/local.properties',
        '**/.env', '**/.env.*', '**/*.keystore', '**/*.jks',
        '**/*.pem', '**/*.p12', '**/*.pfx', '**/*.key',
        '/.muondia/', '/.ai-apps/')
    $missing = @($rules | Where-Object { $_ -notin $existing })
    if ($missing.Count -eq 0) { return }
    if ($text.Length -gt 0 -and -not $text.EndsWith([char]10)) {
        $text += [Environment]::NewLine
    }
    $text += ($missing -join [Environment]::NewLine) + [Environment]::NewLine
    [IO.File]::WriteAllText($file, $text, [Text.UTF8Encoding]::new($false))
}

function Sync([bool]$AllowCommit) {
    if ((Git @('branch', '--show-current')) -ne 'dev' -or
        (Git @('remote', 'get-url', 'origin')) -notmatch
        '^(https://github\.com/|git@github\.com:)magullodev-stack/muondia(\.git)?$') {
        throw 'El repositorio debe ser magullodev-stack/muondia en la rama dev.'
    }

    foreach ($pending in @('MERGE_HEAD', 'CHERRY_PICK_HEAD', 'rebase-apply', 'rebase-merge')) {
        if (Test-Path -LiteralPath (Join-Path $repo ".git\$pending")) {
            throw "Git tiene una operacion pendiente: $pending"
        }
    }

    $mutex = New-Object System.Threading.Mutex($false, 'Local\MuondiaGitSync')
    $locked = $false
    try {
        $locked = $mutex.WaitOne(0)
        if (-not $locked) { return }

        Protect-Files
        Git @('fetch', '--quiet', '--no-tags', 'origin', 'dev') | Out-Null
        $dirty = Git @('status', '--porcelain', '--untracked-files=all')
        if ($dirty -and -not $AllowCommit) { return }

        if ($dirty) {
            Git @('add', '-A') | Out-Null
            $names = Git @('diff', '--cached', '--name-only')
            $sensitive = @($names -split '\r?\n' | Where-Object {
                $_ -match '(^|/)(google-services\.json|local\.properties|\.env(\..*)?|[^/]+\.(key|pem|jks|keystore|p12|pfx))$'
            })
            if ($sensitive.Count -gt 0) {
                Git @('reset', '--quiet') | Out-Null
                throw 'Hay archivos privados en el commit; sincronizacion detenida.'
            }
            if ($names) {
                Git @('commit', '-m', 'Sync Muondia') | Out-Null
                Write-Host 'Muondia: cambios locales confirmados.'
            }
        }

        $behind = [int](Git @('rev-list', '--count', 'HEAD..origin/dev'))
        $ahead = [int](Git @('rev-list', '--count', 'origin/dev..HEAD'))
        if ($behind -gt 0 -and $ahead -gt 0) {
            try {
                Git @('rebase', 'origin/dev') | Out-Null
            } catch {
                $reason = $_.Exception.Message
                if ((Test-Path (Join-Path $repo '.git\rebase-merge')) -or
                    (Test-Path (Join-Path $repo '.git\rebase-apply'))) {
                    Git @('rebase', '--abort') | Out-Null
                }
                throw "Conflicto Git: commits conservados. $reason"
            }
        } elseif ($behind -gt 0) {
            Git @('merge', '--ff-only', 'origin/dev') | Out-Null
            Write-Host 'Muondia: cambios de GitHub recibidos.'
        }

        if ([int](Git @('rev-list', '--count', 'origin/dev..HEAD')) -gt 0) {
            Git @('push', 'origin', 'dev') | Out-Null
            Write-Host 'Muondia: cambios publicados en GitHub.'
        }
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

if (-not $Watch) {
    Sync $true
    Write-Host 'Muondia: sincronizacion completada.'
    return
}

$lastSnapshot = ''
$stableAt = Get-Date
$lastError = ''
while ($true) {
    try {
        $working = Git @('status', '--porcelain', '--untracked-files=all')
        $tracked = Git @('diff', '--binary', '--no-ext-diff')
        $untracked = Git @('ls-files', '--others', '--exclude-standard')
        $details = @($untracked -split '\r?\n' | Where-Object { $_ } | ForEach-Object {
            $item = Get-Item -LiteralPath (Join-Path $repo $_) -ErrorAction Stop
            $_ + ':' + $item.Length + ':' + $item.LastWriteTimeUtc.Ticks
        })
        $snapshot = $working + $tracked + ($details -join '|')
        if ($snapshot -ne $lastSnapshot) {
            $lastSnapshot = $snapshot
            $stableAt = Get-Date
        }
        $ready = -not $working -or ((Get-Date) - $stableAt).TotalSeconds -ge 6
        Sync $ready
        $lastError = ''
    } catch {
        $message = $_.Exception.Message
        if ($message -ne $lastError) {
            Write-Warning "Muondia Git: $message"
            $lastError = $message
        }
    }
    Start-Sleep -Seconds 2
}

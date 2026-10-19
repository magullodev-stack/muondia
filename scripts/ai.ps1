param(
    [switch]$GuardarClave,
    [switch]$Iniciar,
    [switch]$ProbarLuna,
    [Security.SecureString]$Clave
)

$ErrorActionPreference = 'Stop'
if (@($GuardarClave, $Iniciar, $ProbarLuna | Where-Object { $_ }).Count -ne 1) {
    throw 'Indica una acción: -GuardarClave, -Iniciar o -ProbarLuna.'
}
if (-not $env:LOCALAPPDATA) { throw 'Este comando requiere Windows.' }

$local = Join-Path $env:LOCALAPPDATA 'Muondia'
$secretPath = Join-Path $local 'openai-key.dpapi'
$sessionPath = Join-Path $local 'ai-session.json'
$serverPath = Join-Path $PSScriptRoot '..\ai\service\bin\server.dart'

if ($GuardarClave) {
    if (-not $Clave) {
        $Clave = Read-Host 'Introduce la clave de Muondia (una sola vez)' -AsSecureString
    }
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Clave)
    try {
        $candidate = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        if ($candidate -cnotmatch '^sk-[!-~]+$') {
            throw 'La clave no tiene un formato válido.'
        }
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        $candidate = $null
    }
    New-Item -ItemType Directory -Path $local -Force | Out-Null
    $encrypted = ConvertFrom-SecureString -SecureString $Clave
    [IO.File]::WriteAllText($secretPath, $encrypted, [Text.Encoding]::ASCII)
    Write-Host 'Clave cifrada en el perfil de Windows. Muondia la recuperará automáticamente.'
    return
}

function Get-Session {
    if (-not (Test-Path -LiteralPath $sessionPath)) { return $null }
    try {
        $session = Get-Content -LiteralPath $sessionPath -Raw | ConvertFrom-Json
        $uri = [Uri]$session.endpoint
        if ($uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1' -or
            -not $session.token -or -not $session.pid) { return $null }
        $health = Invoke-RestMethod -Uri "$($session.endpoint)/health" -Headers @{
            Authorization = "Bearer $($session.token)"
        } -TimeoutSec 2
        if ($health.service -eq 'muondia-ai' -and $health.pid -eq $session.pid) {
            return $session
        }
    } catch {}
    return $null
}

function Find-Dart {
    $found = Get-Command 'dart.exe' -ErrorAction SilentlyContinue
    if ($found) { return $found.Source }
    $flutter = Get-Command 'flutter.bat' -ErrorAction SilentlyContinue
    if ($flutter) {
        $fromFlutter = Join-Path (Split-Path $flutter.Source -Parent) 'cache\dart-sdk\bin\dart.exe'
        if (Test-Path -LiteralPath $fromFlutter) { return $fromFlutter }
    }
    $localFlutter = Join-Path $env:USERPROFILE 'development\flutter\bin\cache\dart-sdk\bin\dart.exe'
    if (Test-Path -LiteralPath $localFlutter) { return $localFlutter }
    throw 'No se encuentra Dart en la instalación de Flutter.'
}

function Start-MuondiaAi {
    $session = Get-Session
    if ($session) { return $session }
    if (-not (Test-Path -LiteralPath $secretPath)) {
        throw 'Falta la clave cifrada. Ejecuta scripts\ai.ps1 -GuardarClave una sola vez.'
    }
    $secure = ConvertTo-SecureString (Get-Content -LiteralPath $secretPath -Raw)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
    $bytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $token = [Convert]::ToBase64String($bytes)
    $dart = Find-Dart
    $saved = @{}
    foreach ($name in @('MUONDIA_OPENAI_API_KEY', 'MUONDIA_AI_TOKEN',
                          'MUONDIA_AI_READY_FILE', 'MUONDIA_AI_PORT')) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
    }
    try {
        $env:MUONDIA_OPENAI_API_KEY = $key
        $env:MUONDIA_AI_TOKEN = $token
        $env:MUONDIA_AI_READY_FILE = $sessionPath
        $env:MUONDIA_AI_PORT = '0'
        if (Test-Path -LiteralPath $sessionPath) {
            Remove-Item -LiteralPath $sessionPath
        }
        $process = Start-Process -FilePath $dart -ArgumentList ('"' + $serverPath + '"') -PassThru -WindowStyle Hidden -WorkingDirectory (Split-Path $PSScriptRoot -Parent) -RedirectStandardOutput (Join-Path $local 'ai.stdout.log') -RedirectStandardError (Join-Path $local 'ai.stderr.log')
    } finally {
        foreach ($name in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
        }
        $key = $null
    }
    for ($i = 0; $i -lt 100; $i++) {
        $session = Get-Session
        if ($session) { return $session }
        if ($process.HasExited) { break }
        Start-Sleep -Milliseconds 100
    }
    throw 'El servicio Muondia IA no ha arrancado. Revisa el registro local ai.stderr.log.'
}

$session = Start-MuondiaAi
if ($Iniciar) {
    Write-Host "Servicio de IA disponible: $($session.endpoint)"
    return
}

$body = @{
    application = 'muondia'
    model = 'gpt-5.6-luna'
    input = 'Responde con un objeto JSON cuyo campo respuesta sea exactamente MUONDIA_OK.'
    schemaName = 'muondia_connection_test'
    schema = @{
        type = 'object'
        additionalProperties = $false
        properties = @{ respuesta = @{ type = 'string' } }
        required = @('respuesta')
    }
} | ConvertTo-Json -Depth 10

$result = Invoke-RestMethod -Uri "$($session.endpoint)/v1/generate" -Method Post -Headers @{
    Authorization = "Bearer $($session.token)"
} -ContentType 'application/json' -Body $body -TimeoutSec 100
$data = $result.text | ConvertFrom-Json
Write-Host "Luna: $($data.respuesta)"

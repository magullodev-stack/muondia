$ErrorActionPreference = 'Stop'
$avd = 'Muondia'
$serial = 'emulator-5554'

$sdk = if ($env:ANDROID_HOME) {
    $env:ANDROID_HOME
} elseif ($env:ANDROID_SDK_ROOT) {
    $env:ANDROID_SDK_ROOT
} else {
    Join-Path $env:LOCALAPPDATA 'Android\Sdk'
}

$adb = Join-Path $sdk 'platform-tools\adb.exe'
$emulator = Join-Path $sdk 'emulator\emulator.exe'
if (-not (Test-Path -LiteralPath $adb) -or
    -not (Test-Path -LiteralPath $emulator)) {
    throw 'No se encuentran las herramientas del SDK de Android.'
}
if (@(& $emulator -list-avds) -notcontains $avd) {
    throw "El emulador virtual '$avd' no existe."
}

function Read-Adb([string[]]$Arguments) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $adb @Arguments 2>&1)
        if ($LASTEXITCODE -ne 0) { return '' }
        return ($output | Out-String).Trim()
    } finally {
        $ErrorActionPreference = $previous
    }
}

$connected = (Read-Adb -Arguments @('devices')) -match '(?m)^emulator-5554\s+(device|offline)\s*$'
$starting = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -match '^(emulator|qemu-system-.*)\.exe$' -and
        $_.CommandLine -match '(?i)-avd\s+"?Muondia(?:\s|")'
    })

if (-not $connected -and $starting.Count -eq 0) {
    Start-Process -FilePath $emulator -ArgumentList @(
        '-avd', $avd, '-port', '5554', '-no-window', '-no-boot-anim'
    ) | Out-Null
}

$ready = $false
for ($i = 0; $i -lt 180; $i++) {
    $devices = Read-Adb -Arguments @('devices')
    if ($devices -match '(?m)^emulator-5554\s+device\s*$') {
        $boot = Read-Adb -Arguments @('-s', $serial, 'shell', 'getprop', 'sys.boot_completed')
        if ($boot -eq '1') {
            $ready = $true
            break
        }
    }
    Start-Sleep -Seconds 1
}
if (-not $ready) {
    throw 'Muondia no terminó de arrancar Android.'
}

$identity = @( (Read-Adb -Arguments @('-s', $serial, 'emu', 'avd', 'name')) -split '\r?\n' |
    ForEach-Object { $_.Trim() } )
if ($identity -notcontains $avd) {
    throw "$serial está ocupado por otro emulador. No se iniciará Muondia allí."
}

Write-Host 'Android preparado: Muondia.'

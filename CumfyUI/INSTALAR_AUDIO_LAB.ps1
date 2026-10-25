# AUDIO_LAB: safe Windows Portable setup.
# Download audio_lab_nodes.py and audio_lab_tts_worker.py first from
# the authenticated GitHub repo dev/CumfyUI into your Downloads folder.
# This script does NOT change ComfyUI's embedded Python packages.

$ErrorActionPreference = "Stop"
$root = "G:\IA\ComfyUI"
$comfy = Join-Path $root "ComfyUI"
$lab = Join-Path $root "AudioLab"
$downloads = Join-Path $env:USERPROFILE "Downloads"
$bridge = Join-Path $downloads "audio_lab_nodes.py"
$worker = Join-Path $downloads "audio_lab_tts_worker.py"
$fpsSync = Join-Path $comfy "custom_nodes\mmaudio_fps_sync.py"

foreach ($file in @($bridge, $worker)) {
    if (!(Test-Path -LiteralPath $file)) {
        throw "Falta $file. Descarga el archivo en GitHub (sesión iniciada), rama dev."
    }
}
if (!(Test-Path -LiteralPath $fpsSync)) {
    throw "Falta mmaudio_fps_sync.py en ComfyUI\custom_nodes. AUDIO_LAB usa el mismo nodo de FPS que MMAUDIO."
}
if (!(Test-Path -LiteralPath (Join-Path $comfy "custom_nodes"))) {
    throw "No existe la carpeta ComfyUI\custom_nodes en $comfy"
}
# Buscar Python 3.12 real sin exigir el lanzador 'py.exe'.
# Ignorar los alias de Microsoft Store: no son una instalacion de Python.
$candidates = @()
$pyLauncher = Get-Command py -ErrorAction SilentlyContinue
if ($pyLauncher) {
    $candidates += [pscustomobject]@{ Executable = $pyLauncher.Source; Arguments = @("-3.12") }
}
foreach ($name in @("python", "python3.12")) {
    $found = Get-Command $name -ErrorAction SilentlyContinue
    if ($found -and $found.Source -notmatch "WindowsApps") {
        $candidates += [pscustomobject]@{ Executable = $found.Source; Arguments = @() }
    }
}
$commonPaths = @(
    (Join-Path $env:LOCALAPPDATA "Programs\Python\Python312\python.exe"),
    (Join-Path $env:ProgramFiles "Python312\python.exe")
)
foreach ($path in $commonPaths) {
    if (Test-Path -LiteralPath $path) {
        $candidates += [pscustomobject]@{ Executable = $path; Arguments = @() }
    }
}

$selected = $null
foreach ($candidate in $candidates) {
    $launchArgs = @($candidate.Arguments)
    try {
        $detected = & $candidate.Executable @launchArgs -c "import sys; print('YES' if sys.version_info[:2] == (3, 12) else 'NO')" 2>$null
        if ($LASTEXITCODE -eq 0 -and $detected -eq "YES") {
            $selected = $candidate
            break
        }
    } catch {
        # Probar el siguiente candidato.
    }
}
if (-not $selected) {
    throw "No encuentro Python 3.12 independiente de ComfyUI. Instala con: winget install -e --id Python.Python.3.12; abre otra ventana de PowerShell y reintenta."
}
Write-Host "Python 3.12 detectado: $($selected.Executable)"

New-Item -ItemType Directory -Path $lab -Force | Out-Null
Copy-Item -LiteralPath $bridge -Destination (Join-Path $comfy "custom_nodes\audio_lab_nodes.py") -Force
Copy-Item -LiteralPath $worker -Destination (Join-Path $lab "tts_worker.py") -Force

$python = Join-Path $lab ".venv\Scripts\python.exe"
if (!(Test-Path -LiteralPath $python)) {
    $launchArgs = @($selected.Arguments)
    & $selected.Executable @launchArgs -m venv (Join-Path $lab ".venv")
    if ($LASTEXITCODE -ne 0) { throw "No se ha podido crear AudioLab\.venv" }
}

& $python -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw "No se ha podido actualizar pip" }

& $python -m pip install --upgrade qwen-tts soundfile
if ($LASTEXITCODE -ne 0) { throw "Error instalando Qwen3-TTS en AudioLab\.venv" }

& $python -c "import torch; print('CUDA disponible en AudioLab:',torch.cuda.is_available()); print('PyTorch:',torch.__version__); print('CUDA runtime:',torch.version.cuda)"
if ($LASTEXITCODE -ne 0) { throw "No se pudo importar PyTorch en el entorno de AudioLab" }

& $python -c "import torch,sys; sys.exit(0 if torch.cuda.is_available() else 2)"
if ($LASTEXITCODE -ne 0) {
    Write-Warning "El entorno aislado de voz no tiene CUDA; aún no generará con GPU."
    Write-Warning "No reinstales PyTorch de ComfyUI: habría que corregir solo AudioLab\.venv."
} else {
    Write-Host "AUDIO_LAB preparado. Reinicia ComfyUI e importa AUDIO_LAB.json." -ForegroundColor Green
}

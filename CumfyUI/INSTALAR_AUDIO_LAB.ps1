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
if (!(Get-Command py -ErrorAction SilentlyContinue)) {
    throw "No encuentro py.exe. Instala Python 3.12 para Windows y vuelve a ejecutar."
}

& py -3.12 --version
if ($LASTEXITCODE -ne 0) {
    throw "Necesitas Python 3.12 instalado en Windows para el entorno aislado de Qwen3-TTS."
}

New-Item -ItemType Directory -Path $lab -Force | Out-Null
Copy-Item -LiteralPath $bridge -Destination (Join-Path $comfy "custom_nodes\audio_lab_nodes.py") -Force
Copy-Item -LiteralPath $worker -Destination (Join-Path $lab "tts_worker.py") -Force

$python = Join-Path $lab ".venv\Scripts\python.exe"
if (!(Test-Path -LiteralPath $python)) {
    & py -3.12 -m venv (Join-Path $lab ".venv")
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

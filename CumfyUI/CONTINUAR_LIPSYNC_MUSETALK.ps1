# AUDIO_LAB / MuseTalk 1.5
# Continuation AFTER the first installer stopped at mmpose/chumpy.
# Does not re-create the environment or download torch again.
# Operates ONLY in G:\IA\ComfyUI\AudioLab\lipsync\.venv.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$root = "G:\IA\ComfyUI\AudioLab\lipsync"
$repo = Join-Path $root "MuseTalk"
$python = Join-Path $root ".venv\Scripts\python.exe"
$mim = Join-Path $root ".venv\Scripts\mim.exe"
$hf = Join-Path $root ".venv\Scripts\huggingface-cli.exe"
$worker = Join-Path $env:USERPROFILE "Downloads\audio_lab_lipsync_worker.py"
$dest = Join-Path $root "lipsync_worker.py"

foreach ($f in @($python, $mim, $worker, (Join-Path $repo "scripts\inference.py"))) {
    if (!(Test-Path -LiteralPath $f)) { throw "Falta archivo necesario: $f" }
}
if (!(Get-Command ffmpeg.exe -ErrorAction SilentlyContinue)) {
    throw "FFmpeg no esta en PATH. Abre nueva PowerShell y comprueba ffmpeg -version."
}
function RunPip([string[]]$Packages) {
    & $python -m pip @Packages
    if ($LASTEXITCODE -ne 0) { throw "Fallo la instalacion de pip: $($Packages -join ' ')" }
}
Write-Host "[1/5] Preparando instalacion antigua de chumpy (sin recompilar torch)."
# pip 26 in the initial attempt built chumpy in an isolated env without pip.
# chumpy setup.py itself imports pip._internal.req; therefore keep pip
# available by explicitly opting out of PEP 517 build isolation.
RunPip @("install", "--no-deps", "pip==24.0", "wheel==0.43.0")
RunPip @("install", "--no-deps", "--no-build-isolation", "chumpy==0.70")
& $python -c "import chumpy; print('chumpy instalado')"
if ($LASTEXITCODE -ne 0) { throw "chumpy no se puede importar." }

Write-Host "[2/5] Instalando solo el MMPose pendiente."
& $mim install "mmpose==1.1.0"
if ($LASTEXITCODE -ne 0) {
    throw "MMPose sigue fallando. No vuelvas a ejecutar el instalador completo."
}

Write-Host "[3/5] Corrigiendo NumPy y OpenCV del entorno aislado."
# openmim pulled numpy 2.2.6 / opencv-contrib 5.0.0 even though
# MuseTalk 1.5 / TensorFlow 2.12 require numpy 1.23.5.
RunPip @("install", "--force-reinstall", "--no-deps",
         "numpy==1.23.5", "opencv-contrib-python==4.9.0.80")
# openmim downgraded rich below the range used by gradio/typer.
RunPip @("install", "--no-deps", "rich==13.9.4")
& $python -c "import torch, numpy, cv2, mediapipe, soundfile, mmcv, mmengine, mmdet, mmpose; print('NumPy:', numpy.__version__, 'OpenCV:', cv2.__version__, 'CUDA:', torch.cuda.is_available()); assert numpy.__version__ == '1.23.5'; assert cv2.__version__.startswith('4.9.0'); assert torch.cuda.is_available()"
if ($LASTEXITCODE -ne 0) {
    throw "Las dependencias del lip-sync no se pueden importar correctamente."
}

Write-Host "[4/5] Descargando solo los pesos que falten desde Hugging Face."
if (!(Test-Path -LiteralPath $hf)) {
    throw "Falta huggingface-cli.exe en el entorno lipsync/.venv."
}
$env:HF_HOME = Join-Path $root "hf_cache"
$models = Join-Path $repo "models"
New-Item -ItemType Directory -Path $models -Force | Out-Null
$downloads = @(
    @{ id="TMElyralab/MuseTalk"; folder=$models; includes=@() },
    @{ id="stabilityai/sd-vae-ft-mse"; folder=(Join-Path $models "sd-vae"); includes=@("config.json", "diffusion_pytorch_model.bin") },
    @{ id="openai/whisper-tiny"; folder=(Join-Path $models "whisper"); includes=@("config.json", "pytorch_model.bin", "preprocessor_config.json") },
    @{ id="yzd-v/DWPose"; folder=(Join-Path $models "dwpose"); includes=@("dw-ll_ucoco_384.pth") },
    @{ id="ByteDance/LatentSync"; folder=(Join-Path $models "syncnet"); includes=@("latentsync_syncnet.pt") },
    @{ id="ManyOtherFunctions/face-parse-bisent"; folder=(Join-Path $models "face-parse-bisent"); includes=@("79999_iter.pth", "resnet18-5c106cde.pth") }
)
foreach ($item in $downloads) {
    Write-Host "Modelos: $($item.id)"
    $arguments = @("download", $item.id, "--local-dir", $item.folder)
    foreach ($include in $item.includes) { $arguments += @("--include", $include) }
    & $hf @arguments
    if ($LASTEXITCODE -ne 0) { throw "Fallo la descarga del modelo: $($item.id)" }
}
foreach ($required in @(
    (Join-Path $repo "models\musetalkV15\unet.pth"),
    (Join-Path $repo "models\musetalkV15\musetalk.json"),
    (Join-Path $repo "models\whisper\pytorch_model.bin")
)) {
    if (!(Test-Path -LiteralPath $required)) { throw "Falta el checkpoint: $required" }
}

Write-Host "[5/5] Copiando el trabajador de lip-sync."
& $python -m py_compile $worker
if ($LASTEXITCODE -ne 0) { throw "Error de sintaxis en audio_lab_lipsync_worker.py" }
if (Test-Path -LiteralPath $dest) {
    $backup = $dest + "." + (Get-Date -Format "yyyyMMdd-HHmmss") + ".bak"
    Copy-Item -LiteralPath $dest -Destination $backup -Force
}
Copy-Item -LiteralPath $worker -Destination $dest -Force
if ((Get-FileHash -LiteralPath $dest -Algorithm SHA256).Hash -ne
    (Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash) {
    throw "La copia del worker no coincide con el origen."
}
Write-Host ""
Write-Host "DEPENDENCIAS Y PESOS DE MUSETALK PREPARADOS."
Write-Host "Esto NO demuestra aun que el lip-sync funcione sobre un video."
Write-Host "La siguiente prueba sera ejecutar MuseTalk sobre un clip de prueba corto."

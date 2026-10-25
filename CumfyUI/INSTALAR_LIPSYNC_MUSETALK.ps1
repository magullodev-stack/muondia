# Instala MuseTalk 1.5 en un Python 3.10 AISLADO.
# NO modifica python_embeded, MMAUDIO, ni el AudioLab Qwen3-TTS.
# Requiere Windows 11, NVIDIA CUDA, Python 3.10, FFmpeg y conexión a Internet.
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$root = "G:\IA\ComfyUI\AudioLab\lipsync"
$repo = Join-Path $root "MuseTalk"
$venv = Join-Path $root ".venv"
$python = Join-Path $venv "Scripts\python.exe"
$downloads = Join-Path $env:USERPROFILE "Downloads"
$worker = Join-Path $downloads "audio_lab_lipsync_worker.py"
$workerDest = Join-Path $root "lipsync_worker.py"

if (!(Test-Path -LiteralPath $worker)) {
    throw "Descarga audio_lab_lipsync_worker.py desde GitHub dev a Descargas."
}
if (!(Select-String -LiteralPath $worker -Pattern 'def track_faces' -Quiet)) {
    throw "El lipsync worker no es la version actual. Descargalo otra vez de dev."
}

$py310 = $null
$pyLauncher = Get-Command py.exe -ErrorAction SilentlyContinue
if ($pyLauncher) {
    try {
        $candidate = (& py.exe -3.10 -c "import sys;print(sys.executable)" 2>$null | Select-Object -Last 1)
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { $py310 = $candidate }
    } catch {}
}
if (!$py310) {
    foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA "Programs\Python\Python310\python.exe"),
        "C:\Program Files\Python310\python.exe",
        "C:\Python310\python.exe"
    )) {
        if (Test-Path -LiteralPath $candidate) {
            $version = (& $candidate -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>$null)
            if ($version -eq "3.10") { $py310 = $candidate; break }
        }
    }
}
if (!$py310) {
    throw "Falta Python 3.10 (independiente del 3.12 ya instalado). Instala: winget install -e --id Python.Python.3.10 ; vuelve a ejecutar este script."
}

$ffmpeg = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
if (!$ffmpeg) {
    throw "Falta FFmpeg en PATH. Instala con: winget install -e --id Gyan.FFmpeg ; abre una PowerShell nueva y vuelve a ejecutar este script."
}

New-Item -ItemType Directory -Path $root -Force | Out-Null
if (!(Test-Path -LiteralPath $python)) {
    & $py310 -m venv $venv
    if ($LASTEXITCODE -ne 0) { throw "No se pudo crear el Python 3.10 aislado." }
}
& $python -c "import sys; assert sys.version_info[:2] == (3,10)"
if ($LASTEXITCODE -ne 0) { throw "MuseTalk necesita Python 3.10; se detectó otra version." }

if (!(Test-Path -LiteralPath (Join-Path $repo "scripts\inference.py"))) {
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($git) {
        & git clone --depth 1 "https://github.com/TMElyralab/MuseTalk.git" $repo
        if ($LASTEXITCODE -ne 0) { throw "No se pudo descargar el repositorio MuseTalk." }
    } else {
        $zip = Join-Path $root "MuseTalk-main.zip"
        Invoke-WebRequest "https://github.com/TMElyralab/MuseTalk/archive/refs/heads/main.zip" -OutFile $zip
        Expand-Archive -LiteralPath $zip -DestinationPath $root -Force
        Move-Item -LiteralPath (Join-Path $root "MuseTalk-main") -Destination $repo
        Remove-Item -LiteralPath $zip
    }
}

& $python -m pip install --upgrade pip
if ($LASTEXITCODE -ne 0) { throw "Error actualizando pip en lipsync/.venv." }

# Paquetes versionados por el proyecto oficial MuseTalk; solo en este .venv.
& $python -m pip install "torch==2.0.1" "torchvision==0.15.2" "torchaudio==2.0.2" --index-url "https://download.pytorch.org/whl/cu118"
if ($LASTEXITCODE -ne 0) { throw "Error instalando CUDA/PyTorch aislado (MuseTalk)." }
& $python -m pip install -r (Join-Path $repo "requirements.txt")
if ($LASTEXITCODE -ne 0) { throw "Error instalando dependencias oficiales de MuseTalk." }
& $python -m pip install "mediapipe==0.10.11" "openmim"
if ($LASTEXITCODE -ne 0) { throw "Error instalando detector de rostros y openmim." }

$mim = Join-Path $venv "Scripts\mim.exe"
if (!(Test-Path -LiteralPath $mim)) { throw "No se instaló mim.exe." }
foreach ($package in @("mmengine","mmcv==2.0.1","mmdet==3.1.0","mmpose==1.1.0")) {
    Write-Host "MuseTalk / MMLab: instalando $package"
    & $mim install $package
    if ($LASTEXITCODE -ne 0) {
        throw "Falló MMLab ($package). No alteres ComfyUI: el fallo está limitado al entorno aislado."
    }
}

# Descargar los pesos desde Hugging Face oficial, sin mirrors no verificados.
$hfcli = Join-Path $venv "Scripts\huggingface-cli.exe"
if (!(Test-Path -LiteralPath $hfcli)) { throw "Falta huggingface-cli en MuseTalk .venv." }
$models = Join-Path $repo "models"
New-Item -ItemType Directory -Path $models -Force | Out-Null
$tasks = @(
  @{model="TMElyralab/MuseTalk"; dir=$models; files=@()},
  @{model="stabilityai/sd-vae-ft-mse"; dir=(Join-Path $models "sd-vae"); files=@("config.json","diffusion_pytorch_model.bin")},
  @{model="openai/whisper-tiny"; dir=(Join-Path $models "whisper"); files=@("config.json","pytorch_model.bin","preprocessor_config.json")},
  @{model="yzd-v/DWPose"; dir=(Join-Path $models "dwpose"); files=@("dw-ll_ucoco_384.pth")},
  @{model="ByteDance/LatentSync"; dir=(Join-Path $models "syncnet"); files=@("latentsync_syncnet.pt")},
  @{model="ManyOtherFunctions/face-parse-bisent"; dir=(Join-Path $models "face-parse-bisent"); files=@("79999_iter.pth","resnet18-5c106cde.pth")}
)
foreach ($t in $tasks) {
    Write-Host "Descargando: $($t.model)"
    $cmdArgs = @("download", $t.model, "--local-dir", $t.dir)
    foreach ($f in $t.files) { $cmdArgs += @("--include",$f) }
    & $hfcli @cmdArgs
    if ($LASTEXITCODE -ne 0) { throw "Descarga incompleta: $($t.model)" }
}

# Verificación antes de activar: nunca ocultar un modelo ausente.
foreach ($required in @(
    (Join-Path $repo "models\musetalkV15\unet.pth"),
    (Join-Path $repo "models\musetalkV15\musetalk.json"),
    (Join-Path $repo "models\whisper\pytorch_model.bin")
)) {
    if (!(Test-Path -LiteralPath $required)) { throw "Falta checkpoint: $required" }
}
& $python -m py_compile $worker
if ($LASTEXITCODE -ne 0) { throw "El lip-sync worker tiene error de sintaxis." }
& $python -c "import torch, cv2, mediapipe, soundfile, mmcv, mmdet, mmpose; assert torch.cuda.is_available(), 'CUDA no disponible en MuseTalk'; print('LIP-SYNC CUDA:', torch.cuda.is_available()); print('GPU:',torch.cuda.get_device_name(0))"
if ($LASTEXITCODE -ne 0) { throw "CUDA o dependencias del lip-sync no estan listas en el entorno aislado." }

if (Test-Path -LiteralPath $workerDest) {
    Copy-Item -LiteralPath $workerDest -Destination ($workerDest+".bak") -Force
}
Copy-Item -LiteralPath $worker -Destination $workerDest -Force
Write-Host ""
Write-Host "MuseTalk 1.5 preparado en: $root"
Write-Host "Abre AUDIO_LAB.json de dev y prueba primero una frase corta con UNA cara."
Write-Host "El motor instalado aun necesita una primera inferencia real de validacion."

# AUDIO_LAB: reparar unicamente los pesos ausentes de MuseTalk 1.5.
# NO instala Python/FFmpeg/PyTorch/dependencias; NO baja MuseTalk 1.0 ni SyncNet.
# Para usar despues del error "Falta el checkpoint ...whisper\pytorch_model.bin".
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

$root = "G:\IA\ComfyUI\AudioLab\lipsync"
$repo = Join-Path $root "MuseTalk"
$models = Join-Path $repo "models"
$hf = Join-Path $root ".venv\Scripts\huggingface-cli.exe"
$py = Join-Path $root ".venv\Scripts\python.exe"
$sourceWorker = Join-Path $env:USERPROFILE "Downloads\audio_lab_lipsync_worker.py"
$workerDest = Join-Path $root "lipsync_worker.py"

foreach ($required in @($hf, $py, $sourceWorker, (Join-Path $repo "scripts\inference.py"))) {
    if (!(Test-Path -LiteralPath $required)) { throw "Falta un archivo de la instalacion existente: $required" }
}

# Cada comando descarga UN archivo exacto. El --include repetido del instalador
# anterior sobreescribia el filtro: solo se bajaba el ultimo de cada lista.
$files = @(
    @{ model="TMElyralab/MuseTalk"; file="musetalkV15/unet.pth"; dest=$models },
    @{ model="TMElyralab/MuseTalk"; file="musetalkV15/musetalk.json"; dest=$models },
    @{ model="stabilityai/sd-vae-ft-mse"; file="config.json"; dest=(Join-Path $models "sd-vae") },
    @{ model="stabilityai/sd-vae-ft-mse"; file="diffusion_pytorch_model.bin"; dest=(Join-Path $models "sd-vae") },
    @{ model="openai/whisper-tiny"; file="config.json"; dest=(Join-Path $models "whisper") },
    @{ model="openai/whisper-tiny"; file="pytorch_model.bin"; dest=(Join-Path $models "whisper") },
    @{ model="openai/whisper-tiny"; file="preprocessor_config.json"; dest=(Join-Path $models "whisper") },
    @{ model="yzd-v/DWPose"; file="dw-ll_ucoco_384.pth"; dest=(Join-Path $models "dwpose") },
    @{ model="ManyOtherFunctions/face-parse-bisent"; file="79999_iter.pth"; dest=(Join-Path $models "face-parse-bisent") },
    @{ model="ManyOtherFunctions/face-parse-bisent"; file="resnet18-5c106cde.pth"; dest=(Join-Path $models "face-parse-bisent") }
)

foreach ($entry in $files) {
    $relativeFile = $entry.file.Replace('/', '\')
    $target = Join-Path $entry.dest $relativeFile
    if ((Test-Path -LiteralPath $target) -and (Get-Item -LiteralPath $target).Length -gt 0) {
        Write-Host "OK (ya existe): $($entry.file)"
        continue
    }
    New-Item -ItemType Directory -Path $entry.dest -Force | Out-Null
    Write-Host "Descargando SOLO el archivo ausente: $($entry.model) / $($entry.file)"
    & $hf download $entry.model $entry.file --local-dir $entry.dest
    if ($LASTEXITCODE -ne 0) { throw "Descarga fallida: $($entry.model) / $($entry.file)" }
    if (!(Test-Path -LiteralPath $target) -or (Get-Item -LiteralPath $target).Length -eq 0) {
        throw "El archivo sigue ausente despues de descargar: $target"
    }
}

# Preparar el worker que la primera ejecucion dejo pendiente. No hay inferencia aqui.
& $py -m py_compile $sourceWorker
if ($LASTEXITCODE -ne 0) { throw "Error de sintaxis: audio_lab_lipsync_worker.py" }
if (Test-Path -LiteralPath $workerDest) {
    $backup = $workerDest + "." + (Get-Date -Format "yyyyMMdd-HHmmss") + ".bak"
    Copy-Item -LiteralPath $workerDest -Destination $backup -Force
}
Copy-Item -LiteralPath $sourceWorker -Destination $workerDest -Force
if ((Get-FileHash -LiteralPath $sourceWorker -Algorithm SHA256).Hash -ne
    (Get-FileHash -LiteralPath $workerDest -Algorithm SHA256).Hash) {
    throw "El worker instalado no coincide con el original."
}
Write-Host ""
Write-Host "LISTO: estan los checkpoints de inferencia de MuseTalk 1.5."
Write-Host "El lip-sync sobre un video aun NO ha sido probado."

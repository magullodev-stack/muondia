# AUDIO_LAB: actualizar nodos y workers aislados sin reinstalar Qwen ni PyTorch.
# Descarga de dev: AUDIO_LAB.json, audio_lab_nodes.py,
# audio_lab_tts_worker.py y audio_lab_lipsync_worker.py a Descargas.
# Ejecutar con ComfyUI CERRADO.
$ErrorActionPreference = "Stop"

$downloads = Join-Path $env:USERPROFILE "Downloads"
$bridge = Join-Path $downloads "audio_lab_nodes.py"
$worker = Join-Path $downloads "audio_lab_tts_worker.py"
$lipWorker = Join-Path $downloads "audio_lab_lipsync_worker.py"
$workflow = Join-Path $downloads "AUDIO_LAB.json"
$comfyPython = "G:\IA\ComfyUI\python_embeded\python.exe"
$voicePython = "G:\IA\ComfyUI\AudioLab\.venv\Scripts\python.exe"
$bridgeDest = "G:\IA\ComfyUI\ComfyUI\custom_nodes\audio_lab_nodes.py"
$workerDest = "G:\IA\ComfyUI\AudioLab\tts_worker.py"
$lipDest = "G:\IA\ComfyUI\AudioLab\lipsync\lipsync_worker.py"

foreach ($required in @($bridge, $worker, $lipWorker, $workflow, $comfyPython, $voicePython)) {
    if (!(Test-Path -LiteralPath $required)) {
        throw "Falta: $required"
    }
}

if (!(Select-String -LiteralPath $bridge -Pattern 'class AudioLabLipSyncMuseTalk' -Quiet)) {
    throw "audio_lab_nodes.py es antiguo: debe incluir AudioLabLipSyncMuseTalk."
}
if (!(Select-String -LiteralPath $lipWorker -Pattern 'def track_faces' -Quiet)) {
    throw "audio_lab_lipsync_worker.py es antiguo o incorrecto."
}
if (!(Select-String -LiteralPath $bridge -Pattern 'class AudioLabDialoguePlanner' -Quiet)) {
    throw "audio_lab_nodes.py es antiguo: descarga la version actualizada de dev."
}
if (!(Select-String -LiteralPath $worker -Pattern 'jobs-json' -Quiet)) {
    throw "audio_lab_tts_worker.py es antiguo: descarga la version actualizada de dev."
}
$workflowJson = Get-Content -LiteralPath $workflow -Raw | ConvertFrom-Json
$plannerFound = @($workflowJson.definitions.subgraphs[0].nodes |
    Where-Object { $_.type -eq 'AudioLabLipSyncMuseTalk' }).Count -eq 1
if (!$plannerFound) {
    throw "AUDIO_LAB.json es antiguo: debe integrar el lip-sync MuseTalk."
}

# Syntax preflight BEFORE replacing the working installation.
& $comfyPython -m py_compile $bridge
if ($LASTEXITCODE -ne 0) { throw "Error de sintaxis en audio_lab_nodes.py" }
& $voicePython -m py_compile $worker
if ($LASTEXITCODE -ne 0) { throw "Error de sintaxis en audio_lab_tts_worker.py" }
& $comfyPython -m py_compile $lipWorker
if ($LASTEXITCODE -ne 0) { throw "Error de sintaxis en audio_lab_lipsync_worker.py" }
New-Item -ItemType Directory -Path (Split-Path -Parent $lipDest) -Force | Out-Null

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
foreach ($pair in @(
    @{from=$bridge; to=$bridgeDest},
    @{from=$worker; to=$workerDest},
    @{from=$lipWorker; to=$lipDest}
)) {
    if (Test-Path -LiteralPath $pair.to) {
        Copy-Item -LiteralPath $pair.to -Destination ($pair.to + "." + $stamp + ".bak") -Force
    }
    Copy-Item -LiteralPath $pair.from -Destination $pair.to -Force
}
Write-Host ""
Write-Host "AUDIO_LAB actualizado: planificador A/B, lip-sync MuseTalk y mezcla segura."
Write-Host "Cierra cualquier pestana antigua, reinicia ComfyUI y carga:"
Write-Host "  $workflow"
Write-Host "Importante: MuseTalk requiere ejecutar INSTALAR_LIPSYNC_MUSETALK.ps1 por separado."

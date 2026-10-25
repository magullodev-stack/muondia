# AUDIO_LAB: actualizar nodos y workers aislados sin reinstalar Qwen ni PyTorch.
# Descarga de dev: AUDIO_LAB.json, audio_lab_nodes.py,
# audio_lab_tts_worker.py, audio_lab_lipsync_worker.py,
# AUDIO_LAB_TIMELINE.html a Descargas.
# Ejecutar con ComfyUI CERRADO.
$ErrorActionPreference = "Stop"

$downloads = Join-Path $env:USERPROFILE "Downloads"
$bridge = Join-Path $downloads "audio_lab_nodes.py"
$worker = Join-Path $downloads "audio_lab_tts_worker.py"
$lipWorker = Join-Path $downloads "audio_lab_lipsync_worker.py"
$workflow = Join-Path $downloads "AUDIO_LAB.json"
$editor = Join-Path $downloads "AUDIO_LAB_TIMELINE.html"
$comfyPython = "G:\IA\ComfyUI\python_embeded\python.exe"
$voicePython = "G:\IA\ComfyUI\AudioLab\.venv\Scripts\python.exe"
$bridgeDest = "G:\IA\ComfyUI\ComfyUI\custom_nodes\audio_lab_nodes.py"
$workerDest = "G:\IA\ComfyUI\AudioLab\tts_worker.py"
$lipDest = "G:\IA\ComfyUI\AudioLab\lipsync\lipsync_worker.py"
$editorDest = "G:\IA\ComfyUI\AudioLab\AUDIO_LAB_TIMELINE.html"

foreach ($required in @($bridge, $worker, $lipWorker, $workflow, $editor, $comfyPython, $voicePython)) {
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
if (!(Select-String -LiteralPath $bridge -Pattern 'AUDIO_LAB no elegirá el momento' -Quiet)) {
    throw "audio_lab_nodes.py es antiguo: no admite tiempos explicitos."
}
if (!(Select-String -LiteralPath $editor -Pattern 'id="video"' -Quiet)) {
    throw "AUDIO_LAB_TIMELINE.html es antiguo o incorrecto."
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
$scriptNode = @($workflowJson.definitions.subgraphs[0].nodes |
    Where-Object { $_.type -eq 'AudioLabDialoguePlanner' })
if ($scriptNode.Count -ne 1 -or $scriptNode[0].widgets_values[1] -ne "") {
    throw "AUDIO_LAB.json es antiguo: debe exigir marcar los tiempos manualmente."
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
    @{from=$lipWorker; to=$lipDest},
    @{from=$editor; to=$editorDest}
)) {
    if (Test-Path -LiteralPath $pair.to) {
        Copy-Item -LiteralPath $pair.to -Destination ($pair.to + "." + $stamp + ".bak") -Force
    }
    Copy-Item -LiteralPath $pair.from -Destination $pair.to -Force
}
Write-Host ""
Write-Host "AUDIO_LAB actualizado: control temporal exacto A/B, lip-sync MuseTalk y mezcla segura."
Write-Host "Abre el editor temporal con este comando:"
Write-Host "  Start-Process \"$editorDest\""
Write-Host "Cierra cualquier pestana antigua, reinicia ComfyUI y carga:"
Write-Host "  $workflow"
Write-Host "Importante: MuseTalk requiere ejecutar INSTALAR_LIPSYNC_MUSETALK.ps1 por separado."

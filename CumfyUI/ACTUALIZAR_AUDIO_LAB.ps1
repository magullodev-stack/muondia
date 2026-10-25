# AUDIO_LAB - actualiza los dos nodos Python y el worker sin reinstalar paquetes.
# Descarga desde la rama dev: AUDIO_LAB.json, audio_lab_nodes.py y
# audio_lab_tts_worker.py a tu carpeta Descargas.
# Ejecutar con ComfyUI CERRADO.
$ErrorActionPreference = "Stop"

$downloads = Join-Path $env:USERPROFILE "Downloads"
$bridge = Join-Path $downloads "audio_lab_nodes.py"
$worker = Join-Path $downloads "audio_lab_tts_worker.py"
$workflow = Join-Path $downloads "AUDIO_LAB.json"
$comfyPython = "G:\IA\ComfyUI\python_embeded\python.exe"
$voicePython = "G:\IA\ComfyUI\AudioLab\.venv\Scripts\python.exe"
$bridgeDest = "G:\IA\ComfyUI\ComfyUI\custom_nodes\audio_lab_nodes.py"
$workerDest = "G:\IA\ComfyUI\AudioLab\tts_worker.py"

foreach ($required in @($bridge, $worker, $workflow, $comfyPython, $voicePython)) {
    if (!(Test-Path -LiteralPath $required)) {
        throw "Falta: $required"
    }
}

if (!(Select-String -LiteralPath $bridge -Pattern 'class AudioLabDialoguePlanner' -Quiet)) {
    throw "audio_lab_nodes.py es antiguo: descarga la version actualizada de dev."
}
if (!(Select-String -LiteralPath $worker -Pattern 'jobs-json' -Quiet)) {
    throw "audio_lab_tts_worker.py es antiguo: descarga la version actualizada de dev."
}
$workflowJson = Get-Content -LiteralPath $workflow -Raw | ConvertFrom-Json
$plannerFound = @($workflowJson.definitions.subgraphs[0].nodes |
    Where-Object { $_.type -eq 'AudioLabDialoguePlanner' }).Count -eq 1
if (!$plannerFound) {
    throw "AUDIO_LAB.json es antiguo: descarga la version actualizada de dev."
}

# Syntax preflight BEFORE replacing the working installation.
& $comfyPython -m py_compile $bridge
if ($LASTEXITCODE -ne 0) { throw "Error de sintaxis en audio_lab_nodes.py" }
& $voicePython -m py_compile $worker
if ($LASTEXITCODE -ne 0) { throw "Error de sintaxis en audio_lab_tts_worker.py" }

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
foreach ($pair in @(
    @{from=$bridge; to=$bridgeDest},
    @{from=$worker; to=$workerDest}
)) {
    if (Test-Path -LiteralPath $pair.to) {
        Copy-Item -LiteralPath $pair.to -Destination ($pair.to + "." + $stamp + ".bak") -Force
    }
    Copy-Item -LiteralPath $pair.from -Destination $pair.to -Force
}
Write-Host ""
Write-Host "AUDIO_LAB actualizado: planificador A/B y mezcla con control de duracion."
Write-Host "Cierra cualquier pestana antigua, reinicia ComfyUI y carga:"
Write-Host "  $workflow"
Write-Host "El lip-sync NO esta instalado: este paso actualiza la planificacion de voz."

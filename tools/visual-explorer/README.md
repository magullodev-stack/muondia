# Muondia · Explorador visual

Esta extensión representa las pantallas declaradas en lib/development/experiences.json.
Enumera sus estados y las imágenes de cada pantalla; se ampliará con
previsualizaciones controladas y edición contextual de imágenes.

Git es independiente: VS Code inicia scripts/sync-dev.ps1 automáticamente
mediante .vscode/tasks.json. Comprueba GitHub cada tres segundos. Las
modificaciones locales se confirman tras un intervalo de estabilidad.
No requiere tareas de Windows ni mantiene servicios fuera de VS Code.

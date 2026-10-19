# Muondia · Explorador visual

Extensión local de VS Code específica de Muondia. Se instala con
PowerShell: scripts/sync-dev.ps1 -Install.

La sincronización Git comprueba origin/dev cada 10 segundos y al recuperar
el foco de VS Code. Integra cambios remotos con git merge --ff-only y envía
commits locales con git push. **Nunca** hace git add, commits automáticos,
rebase, reset ni push forzado: el código a medio escribir permanece intacto.
Si Git detecta cambios locales incompatibles o ramas divergentes, se detiene
y muestra el motivo en el canal de salida Muondia. No depende de Flutter ni
del emulador.

El Explorador muestra las pantallas declaradas en
lib/development/experiences.json y los recursos de cada una cuando existan.
El puente para abrir estados Flutter y el inspector contextual de imágenes
se incorporarán con las primeras pantallas; **no están implementados aún**.

No usa scripts de AI-APPS, registros multiaplicación ni tareas de Windows.

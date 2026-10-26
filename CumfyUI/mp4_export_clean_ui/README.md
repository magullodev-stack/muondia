# Exportación MP4: panel simplificado

Oculta los controles `loop_count` y `pingpong` **solo** en los nodos `VHS_VideoCombine` cuyo título contiene `GUARDAR VÍDEO MP4`, incluidos los nodos de `GENERATOR_WAN 2.2.json` y `GENERATOR_LTX2_V62.json`.

Sus valores se mantienen internamente en `loop_count = 0` y `pingpong = false`, sin alterar el resto de ajustes, la vista previa, el formato o los enlaces. Los widgets se conservan en la serialización del workflow para evitar incompatibilidades con VideoHelperSuite.

## Instalación en ComfyUI

1. Copia **la carpeta completa** `mp4_export_clean_ui` a `ComfyUI/custom_nodes/mp4_export_clean_ui` (con `__init__.py` y `web/js/hide_mp4_controls.js` dentro).
2. Reinicia ComfyUI y recarga la página del navegador (si es necesario, recarga forzada).
3. Abre el workflow: el panel «GUARDAR VÍDEO MP4» ya no mostrará «loop_count» ni «pingpong».

No basta con editar los valores del JSON: los widgets visibles los define `VHS_VideoCombine` en VideoHelperSuite. Este complemento es solo de interfaz, no añade nodos nuevos ni necesita librerías adicionales.

# muondia
Muondia — aplicación interactiva de conocimiento e inteligencia artificial

## Inteligencia artificial

`ai/service/` contiene el servicio de generación estructurada y `ai/client/` el cliente Dart. Las reglas y los prompts pertenecen a cada experiencia. Contrato técnico: [`ai/README.md`](ai/README.md).

## Emulador integrado: compatibilidad con Android 17

Entorno comprobado en Windows 11: **Android 17 (AVD `Muondia`)**, **Flutter/Dart-Code oficiales** y **EmbeDroid original `utpalbarman.embedroid@1.0.2`**. La aplicación Flutter se compiló y mostró `Hello World!` en una pestaña del emulador dentro de VS Code.

**Advertencia:** EmbeDroid 1.0.2 incorpora `scrcpy-server-v3.2.jar`. Con este AVD, la transmisión se iniciaba y se cerraba inmediatamente con `AbstractMethodError` en `IDisplayWindowListener.onDisplayAnimationsDisabledChanged` y `The stream closed unexpectedly`. Es un problema del servidor de vídeo, no de Flutter.

**Corrección local que funcionó:** usar el servidor oficial **scrcpy 3.3.4**, manteniendo la versión declarada por el cliente de EmbeDroid coherente con el archivo:

- Extensión instalada fuera del repositorio: `%USERPROFILE%\.vscode\extensions\utpalbarman.embedroid-1.0.2`.
- Servidor en `media\vendor\scrcpy-server-v3.3.4.jar`, obtenido de [scrcpy v3.3.4](https://github.com/Genymobile/scrcpy/releases/tag/v3.3.4) (recurso `scrcpy-server-v3.3.4`, renombrado con extensión `.jar`). SHA-256 del recurso oficial: `8588238c9a5a00aa542906b6ec7e6d5541d9ffb9b5d0f6e1bc0e365e2303079e`.
- Cliente de la extensión en `dist\extension.js`: la constante de versión del servidor pasó de `Lt="3.2"` a `Lt="3.3.4"`. **Cambiar solo el JAR no basta**; tampoco basta con cambiar solo la versión del cliente.
- Se conservaron copias de los archivos originales en `backup-scrcpy-original` dentro de la instalación local de la extensión.

**Importante:** este ajuste está **solo en la instalación local de EmbeDroid**, no en Git ni en el código de Muondia. **Actualizar o reinstalar EmbeDroid puede sobrescribirlo**. Si vuelve a fallar la transmisión tras una actualización, comprobar la versión y el servidor incluidos en esa instalación antes de repetir la adaptación; no reutilizar ciegamente esta modificación en otra versión. El arranque completamente automático después de reiniciar Windows queda pendiente de comprobación independiente.

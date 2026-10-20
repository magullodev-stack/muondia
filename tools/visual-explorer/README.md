# Muondia · Explorador visual

La extensión `magullodev.muondia-visual` añade una única vista dentro del Explorador de VS Code. Solo actúa en el proyecto Muondia y usa el emulador `emulator-5554` y la sesión Flutter existentes.

**Previsualización segura** es el modo predeterminado en desarrollo: las pantallas usan un servicio de autenticación inactivo. No se generan preguntas ni se consulta la IA por seleccionar una pantalla. El **recorrido real** es una entrada diferenciada; únicamente estará habilitado cuando Muondia disponga de autenticación y navegación reales y así lo declare su catálogo. Antes de ejecutarlo solicita confirmación, porque puede hacer llamadas de IA.

El catálogo `lib/development/experiences.json` define las pantallas, sus estados, carpetas de imágenes y las capas controlables. Las nuevas imágenes se descubren automáticamente dentro de dichas carpetas. Las que no tienen una capa declarada aparecen como **⏳ Pendiente**. Las imágenes están directamente bajo su pantalla, junto a los estados, sin carpetas intermedias.

La extensión lee la ubicación observada en Android (archivo privado `files/muondia_active_visual.txt`) cada cinco segundos cuando hay sesión Dart-Code y muestra en amarillo la categoría, pantalla y estado realmente abiertos. También vigila cambios de archivos, incluida la sincronización externa de Git. No deduce la pantalla activa simplemente del clic.

El **ojo** oculta o muestra una capa del modo de desarrollo mediante `lib/development/visual_layers.dart` sin borrar archivos ni alterar su espacio en pantalla; en release todas las imágenes permanecen visibles. El nombre de la imagen abre el original. Con botón derecho:

- **Sustituir** preserva el nombre, las referencias y el historial Git; actualizar el archivo PNG en Android requiere reconstruir Flutter.
- **Cambiar nombre** actualiza la ruta y sus referencias literales, siempre que se puedan auditar; ante referencias ambiguas cancela la operación.
- **Eliminar** solo permite enviar a la papelera imágenes pendientes, sin referencias. No borra capas Flutter activas a ciegas.

El catálogo puede crecer con Loading, Test y Home cuando sus pantallas se hayan implementado realmente en Muondia. El monitor no muestra pantallas que no existen.

Para instalar la extensión una sola vez:

```powershell
& "C:\Users\Miquelet\repos\muondia\scripts\install-visual-explorer.ps1"
```

Para cargar o actualizar el manifiesto de la extensión, ejecutar **Developer: Reload Window** en VS Code. No se instalan dependencias ni se arrancan tareas, emuladores o sesiones Flutter adicionales. Ejecutar las pruebas locales con `node --test tools/visual-explorer/extension.test.cjs`.

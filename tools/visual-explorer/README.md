# Muondia · Explorador visual

El panel vive en el Explorador de VS Code y lee únicamente el catálogo de Muondia:
`lib/development/experiences.json`.

Cada pantalla declara sus estados y las imágenes que le pertenecen. Los ojos
permiten ocultar o mostrar cada imagen durante el desarrollo; el cambio se
aplica mediante `lib/development/visual_layers.dart` y Hot Restart, sin
eliminar el PNG. En compilaciones release las cuatro imágenes permanecen
visibles. Al sustituir una imagen se conserva su nombre y sus referencias.

Para instalar la extensión en VS Code desde el repositorio Muondia,
ejecutar una vez `scripts/install-visual-explorer.ps1` y recargar la
ventana de VS Code. La extensión no incluye Firebase ni integra herramientas
del repositorio anterior. Git sigue ejecutándose de forma independiente.

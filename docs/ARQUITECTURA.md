# Organización de Muondia

Muondia es **un solo proyecto Flutter**. El código común, los recursos y el entorno de desarrollo están dentro del mismo repositorio.

## Organización actual

- `android/`: integración Android generada por Flutter.
- `lib/main.dart`: aplicación de prueba; permanece intacta durante la migración del núcleo de IA.
- `test image/`: recurso gráfico provisional de la prueba de sincronización.
- `ai/service/`: puente HTTP local de IA, con pruebas.
- `ai/client/`: cliente Dart para consumir el servicio.
- `scripts/`: sincronización Git y herramientas locales existentes.
- `tools/`: arranque y explorador visual propios de VS Code.
- `.vscode/`: configuración de depuración, tareas y recarga automática.
- `docs/`: documentación de arquitectura y de IA.

## Estructura a medida que se desarrollen las experiencias

Las pantallas se organizarán en `lib/app/` (Auth, onboarding, Home, perfil y ajustes) y `lib/modes/` (modalidades como Estudio). `lib/ai/` se creará cuando alguna experiencia utilice el cliente de IA. Los recursos definitivos se organizarán en `assets/`; las pruebas permanecerán en `test/`.

Estas carpetas se crearán **cuando tengan contenido real**, evitando infraestructura sin uso. Los componentes de desarrollo y la sincronización que ya funcionan no dependen del nuevo servicio de IA.

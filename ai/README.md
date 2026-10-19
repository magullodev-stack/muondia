# IA de Muondia

El núcleo de IA es independiente del emulador y del código de las pantallas.

- `service/`: servicio HTTP local de desarrollo. Ejecuta las llamadas a OpenAI mediante la API Responses; usa `dart:io` y `dart:convert` y no necesita otro SDK.
- `client/`: cliente Dart para que Flutter solicite generaciones estructuradas al servicio sin exponer la clave de OpenAI.

## Contrato técnico

El servicio expone `GET /health` y `POST /v1/generate`; ambas rutas requieren `Authorization: Bearer <token de sesión>`. La generación recibe `application`, `model`, `input`, `schemaName` y `schema` y devuelve `text` y, si está disponible, `usage`. Las reglas, modelos y prompts de cada experiencia pertenecen a Muondia, no al servicio.

Para pruebas offline del servicio (se emplea un proveedor HTTP simulado):

```powershell
cd ai\service
flutter pub get
flutter test
```

## Conexión con OpenAI: pendiente

Todavía **no se ha creado ni incorporado la nueva credencial de OpenAI**, no se ha iniciado el servidor y el cliente **no se ha conectado a `lib/main.dart`**. El arranque de Android, EmbeDroid, Dart-Code y Git permanece intacto.

Cuando configuremos el acceso a OpenAI, el servidor admitirá `MUONDIA_OPENAI_API_KEY`, `MUONDIA_AI_TOKEN`, `MUONDIA_AI_READY_FILE` y opcionalmente `MUONDIA_AI_PORT` mediante variables de entorno de un proceso privado. Ninguna clave debe estar en Git, `pubspec.yaml`, Dart defines ni dentro de una APK. El móvil solo recibe el token temporal del servicio, nunca la credencial del proveedor.

Para producción se necesitará un backend con autenticación de usuarios, no el servicio local de desarrollo. No copiar configuraciones privadas de otros proyectos.

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

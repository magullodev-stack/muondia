# IA de Muondia

El núcleo de IA es independiente del emulador y del código de las pantallas.

- `service/`: servicio HTTP local de desarrollo. Ejecuta las llamadas a DeepSeek mediante Chat Completions (`https://api.deepseek.com/chat/completions`); usa `dart:io` y `dart:convert` y no necesita otro SDK.
- `client/`: cliente Dart para que Flutter solicite generaciones estructuradas al servicio sin exponer la clave de DeepSeek.

## Salida estructurada

DeepSeek solo ofrece `response_format: json_object`, que garantiza JSON sintácticamente válido pero no que cumpla el esquema. El servicio incluye el esquema y un ejemplo de estructura en el mensaje de sistema, valida la respuesta contra el esquema (subconjunto de JSON Schema: `type`, `enum`, `const`, `anyOf`, `properties`, `required`, `additionalProperties: false`, `items`, `minItems`, `maxItems`, `minLength`, `maxLength`, `minimum`, `maximum`) y reintenta una vez si la salida llega vacía, es inválida o no cumple el esquema. Los diagnósticos incluyen rutas del esquema, nunca el contenido generado.

- `thinking` (opcional, `false` por defecto): activa la fase de razonamiento del modelo.
- `maxTokens` (opcional, 1–32768, 8192 por defecto): si la respuesta se corta por límite se devuelve error en lugar de JSON incompleto.
- Saldo agotado (HTTP 402 del proveedor): el servicio responde `provider_insufficient_balance`.

## Contrato técnico

El servicio expone `GET /health` y `POST /v1/generate`; ambas rutas requieren `Authorization: Bearer <token de sesión>`. La generación recibe `application`, `model`, `input`, `schemaName` y `schema` (más `thinking`, `maxTokens` e `image` opcionales) y devuelve `text` (JSON ya validado contra el esquema), `attempts` y, si está disponible, `usage`. Las reglas, modelos y prompts de cada experiencia pertenecen a Muondia, no al servicio.

Para pruebas offline del servicio (se emplea un proveedor HTTP simulado):

```powershell
cd ai\service
flutter pub get
flutter test
```

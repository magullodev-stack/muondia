# Producción del test de bienvenida (IA)

Genera las diez preguntas del test inicial con DeepSeek a través del servicio
local de `ai/service`. La app nunca recibe la clave del proveedor.

## Fases

1. **G (generación)**: una llamada por casilla (tema × dimensión), diez en
   paralelo. Devuelve dato factual, pregunta, cuatro opciones y la correcta.
2. **R (revisión)**: una llamada por casilla, encadenada a su G sin esperar a
   las demás. Devuelve solo correcciones de campos.
3. **S (ordenación)**: una llamada ordena las diez de más a menos fáciles.

Después Dart baraja las opciones y registra los cruces usados para variar los
siguientes tests.

## Resiliencia

- Cada casilla se reintenta sola (hasta 3 intentos) si la llamada falla de
  forma transitoria, la salida no cumple la estructura o incumple las reglas
  locales. Una casilla fallida no invalida las otras nueve.
- `onboarding_quiz_validation.dart` aplica reglas gratuitas antes de gastar la
  revisión: longitudes (pregunta ≤ 160, opción ≤ 70), cuatro opciones distintas
  (sin distinguir mayúsculas ni acentos) y respuesta ausente de la pregunta.
  También se comprueba tras la revisión: si una corrección rompe esas reglas se
  conserva la fila original.
- Saldo agotado, credenciales y rechazos del proveedor no se reintentan.
- Si S falla tras sus reintentos se conserva el orden de generación.

## Coste y latencia

- Los prompts empiezan por la parte fija y terminan con las variables, para que
  DeepSeek reutilice el prefijo (caché de contexto, entrada mucho más barata).
- `AiOnboardingQuizPipeline.prefetch()` empieza a generar en segundo plano (por
  ejemplo al completar el registro o durante la introducción). La siguiente
  llamada a `generate()` recoge ese resultado; se consume una sola vez.
- `thinking` está desactivado en G, R y S (parámetros `lunaThinking`,
  `reviewThinking`, `sortThinking`).

## Conexión

`lib/app/generation_dependencies.dart` crea el cliente con estos
`--dart-define`: `MUONDIA_AI_URL` (por defecto `http://127.0.0.1:8787`),
`MUONDIA_AI_TOKEN` y `MUONDIA_AI_MODEL` (por defecto `deepseek-flash`).

Las pantallas pasan `generate` y `onboardingQuizHint.generate` a la página del
test, igual que en ai-apps. La pista vive aquí, en `production/`, para que
copiar la carpeta `interaction/` de ai-apps no la sobrescriba.

# Inteligencia artificial de Muondia

## Responsabilidades

Muondia define la experiencia, su estado, sus reglas y la validación del resultado. Los modelos ejecutan tareas concretas, sin mantener la realidad ni el estado persistente de la aplicación.

Los prompts y los procedimientos propios de cada experiencia pertenecen a esa experiencia, dentro de `lib/app/` o `lib/modes/`. Los modelos pueden sustituirse sin modificar las reglas de juego.

## Componentes

- `ai/service/`: transporte seguro hacia el proveedor, contrato HTTP y tratamiento de errores.
- `ai/client/`: comunicación del cliente Flutter con el servicio.
Consulta `ai/README.md` para el contrato técnico.

# Inteligencia artificial de Muondia

## Responsabilidades

Muondia define la experiencia, su estado, sus reglas y la validación del resultado. Los modelos ejecutan tareas concretas, sin mantener la realidad ni el estado persistente de la aplicación.

Los prompts y los procedimientos propios de cada experiencia se incorporarán junto a esa experiencia dentro de `lib/app/` o `lib/modes/`. Los modelos pueden sustituirse sin modificar las reglas de juego.

## Componentes

- `ai/service/`: transporte seguro hacia el proveedor, contrato HTTP y tratamiento de errores.
- `ai/client/`: comunicación del cliente Flutter con el servicio.
- `lib/ai/`: punto de integración con Flutter, **pendiente** de crear cuando incorporemos una funcionalidad que necesite IA.

No se han migrado los prompts de Luna, los pivotes ni el pipeline del Test de bienvenida: pertenecen a cada experiencia y se tratarán de forma independiente. Tampoco se han incorporado credenciales. La conexión con OpenAI se realizará en una etapa posterior.

Consulta `ai/README.md` para el contrato técnico.

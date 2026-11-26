# Operación Cafecito

Juego 3D de sigilo en una oficina: consigue tu café y vuelve a tu escritorio sin que los jefes te pillen.

**Jugar:** https://operacion-cafecito.pages.dev

- Etapa 1: busca una cápsula, prepara el café y vuelve.
- Etapa 2 · La U: solo una de las cafeteras tiene café hoy. Encuéntrala.
- Ranking en línea por mapa (Supabase).
- Editor de mapas incluido.

Controles: WASD para moverte, mouse para mirar, Shift para correr, C para agacharte y E para interactuar.

## Ambientes

| Ambiente | Rama | Dirección | Ranking |
|---|---|---|---|
| Producción (público) | `main` | https://operacion-cafecito.pages.dev | tabla `puntajes` |
| Pruebas | `dev` | https://dev.operacion-cafecito.pages.dev | tabla `puntajes_dev` |

Los cambios se suben primero a `dev`. Cuando están probados, se juntan con `main` y quedan públicos.

## Páginas

| Página | Para qué |
|---|---|
| `/` | Juego normal con las etapas |
| `/daily` | Solo el daily de hoy y el ranking de los días anteriores |
| `/gestor` | Programar cada día del daily: plano completo, inicio, cafetera con café y rutas de jefes (solo en dev; pide clave) |

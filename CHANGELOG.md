# CHANGELOG — GamingScrcpy

Registro en lenguaje de usuario, por versión. El detalle técnico y las mediciones
están en `BUILD_REPORT.md`; el cómo-usar, en `README_GAMING.md`.
User-facing record, by version. Technical detail and measurements live in
`BUILD_REPORT.md`; usage in `README_GAMING.md`.

## v5 · Sesión 0 — 2026-10-21

**Nuevo / New**

- **Modo presentación en un clic.** En la pestaña *Rápido*, el botón
  `Modo presentación` activa de una vez ventana sin bordes, siempre encima, OSD
  compacto y color neutro, y avisa de que todavía falta pulsar *Espejo* para
  lanzar. Cada ajuste sigue estando donde siempre, así que se puede anular uno a
  uno. Durante una sesión en curso el botón no actúa y dice por qué.
  *In the Quick tab, `Presentation mode` sets borderless, always-on-top, compact
  OSD and a neutral grade in one click, then tells you to press Mirror. Nothing is
  hidden, so each of the four can be undone individually. While a session is
  running the button refuses and explains why.*

**Corregido / Fixed**

- **Un bitrate bajo ya no se lee como "se murió el espejo.** El OSD y
  `--game-telemetry-log` mostraban `0 KB/s` cuando llegaban menos de 1024 B/s —
  un caso real con AV1 en una escena estática. El OSD ahora imprime `<1 KB/S`, y
  la telemetría añade `v_bytes=` / `a_bytes=` con los bytes de cada segundo para
  que un `0` se pueda distinguir de "no ha llegado nada".
  *A low bitrate no longer reads as a dead stream: the OSD prints `<1 KB/S`
  instead of `0 KB/s`, and the telemetry line ends with the window's byte totals.*

## v4 — 2026-10-19

- Ventana sin bordes real (`--game-borderless-fullscreen`): la bandera existed
  pero no se aplicaba; ahora el arranque sin bordes ocupa toda el área de trabajo
  y se reafirma tras cada cambio de geometría.
- Selector de perfiles con descripción dinámica, 10 perfiles nuevos con nombres en
  español, y validación `--validate-profiles` en el lanzador.
- Telemetría y OSD con fps, latencia, bitrate y resolución real de origen; el
  error de unidades que hacía ver `5 KB/s` en un flujo de 5300 KB/s quedó corregido.
- Jerga i18n: toda la interfaz en ES/EN con cambio de idioma en caliente, atajos en
  tabla de teclas, panel de filtros con overlay, badge de audio no soportado en
  Android < 11 y botón de diagnóstico.
- Empaquetado: `dist/GamingScrcpy-win64-fork.zip` auto-probado tras la extracción
  (`tools/package_selftest.sh`), con el lanzador, el icono y las herramientas
  dentro del archivo.
- El codec AV1 se midió en vez de suponerse: se puede ver por software, pero con
  ~1,4 s de latencia frente a 17–30 ms de h264, así que sigue siendo la opción de
  grabación y no la de directo.

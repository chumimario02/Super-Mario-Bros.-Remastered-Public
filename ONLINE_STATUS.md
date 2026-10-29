# SMB1R Online - estado del trabajo

> Nota para continuar la próxima sesión. Este archivo se puede borrar antes de
> publicar el fork.

## Hecho

- Fork: `github.com/chumimario02/Super-Mario-Bros.-Remastered-Public`
- Remotos del clon local (`smb1r-online/`):
  - `origin`   -> tu fork
  - `upstream` -> JHDev2006 (original)
- `Scripts/Multiplayer/NetPlay.gd` (autoload `NetPlay` registrado en `project.godot`)
  - WebRTC en malla (`WebRTCMultiplayerPeer.create_mesh`) + servidor de salas por websocket.
  - Salas públicas, listado, unirse por código, hello/handshake, RPCs de estado.
  - El host manda el `.lvl` completo a los que entran (también a mitad de partida).
- `Scripts/Multiplayer/RemotePlayer.gd`: muñeco de los otros jugadores
  (posición interpolada, animación, frame, flip, power-up, personaje, nombre).
- `Scripts/Multiplayer/MultiplayerMenu.gd`: menú SINGLEPLAYER / MULTIPLAYER,
  crear sala, lista de salas, lobby, ajustes (nombre + URL del servidor).
- `Scripts/UI/CustomLevelMenu.gd`: `play_level()` y `online_play()` ahora abren
  ese menú en vez de ir directo al selector de personaje.
- `addons/webrtc_native/`: GDExtension oficial de WebRTC (en Windows/Linux el
  WebRTC no viene incluido en Godot; en web sí).
- `server/`: servidor de salas Node.js (`ws`) + `Dockerfile` + `render.yaml` +
  página de estado en `/`. Probado en local: `GET /rooms` y `/health` OK.
- `tests/net_smoke.tscn` + `tests/net_smoke.gd`: test headless de 2 instancias.

## Verificado

- Dos instancias de Godot conectan por WebRTC (malla) y se hablan por RPC.
- El host manda el nivel, ambos lo construyen y llegan a la pantalla de
  transición; el nivel entra en escena en los dos.

## Pendiente / bug actual

1. **Los muñecos no aparecen todavía.** El `_enter_tree` de `LevelClass.gd` se
   corta después de `update_theme()` (probablemente por el sistema de resource
   packs), así que `spawn_in_extra_players()` nunca se llama.
   - Solución en marcha: `NetPlay._watch_level()` detecta `Global.current_level`
     por polling desde `_process` (ya escrito, sin probar) y crea los muñecos
     cuando llega el primer paquete de estado.
   - Revertidos todos los prints de debug en `LevelClass.gd` y `Global.gd`.
2. Probar en partida real con la ROM (hace falta el ROM de SMB1 en el PC del
   usuario; aquí no está).
3. Desplegar `server/` en Render y poner la URL `wss://.../ws` por defecto en
   `NetPlay.DEFAULT_SERVER` (ahora `ws://127.0.0.1:8080/ws`).
4. Limpiar prints `[NetPlay] ...`, decidir si `tests/` se queda en el repo,
   commit + push al fork.
5. Cosas opcionales: chat, sincronizar enemigos/bloques, reconexión, kick,
   límite de jugadores configurable, pantalla de "se ha ido el host".

## Cómo probar en local

```powershell
# 1) servidor de salas
cd smb1r-online\server
npm install
node index.js

# 2) test headless (dos procesos)
#    host
.\tools\godot\Godot_v4.6-stable_win64_console.exe --headless --path .\smb1r-online res://tests/net_smoke.tscn -- --role=host --auto-advance
#    cliente (con el código que imprime el host)
.\tools\godot\Godot_v4.6-stable_win64_console.exe --headless --path .\smb1r-online res://tests/net_smoke.tscn -- --role=client --room=ABCD --auto-advance
```

En el juego: `CUSTOM LEVELS -> nivel -> PLAY -> MULTIPLAYER -> SETTINGS` y poner
`ws://127.0.0.1:8080/ws` (o la IP LAN del host / la URL de Render).

# SMB1R Online - room server

Tiny Node.js websocket server used by the **NetPlay** autoload of SMB1R Online.

It does two things and nothing else:

1. Keeps a list of public rooms (`GET /rooms`).
2. Relays the WebRTC handshake (SDP offers/answers and ICE candidates).

Gameplay itself is peer to peer: after the handshake the players connect
directly to each other and the server is no longer in the loop.

## Run locally

```bash
cd server
npm install
npm start
```

Then in game: `CUSTOM LEVELS -> any level -> PLAY -> MULTIPLAYER -> SETTINGS`
and set the room server to `ws://127.0.0.1:8080/ws`.

Open <http://127.0.0.1:8080> to see the live room list.

> For LAN testing both players can use the host machine's LAN IP instead of
> `127.0.0.1`, e.g. `ws://192.168.1.50:8080/ws`.

## Deploy (free)

### Render

1. Push this repository to GitHub (your fork).
2. Go to <https://render.com> -> **New** -> **Web Service**.
3. Connect the repository and set **Root Directory** to `server`.
4. Build command: `npm install`, start command: `node index.js`.
5. Instance type: **Free**.
6. Copy the public URL (`https://your-service.onrender.com`) and use
   `wss://your-service.onrender.com/ws` as the room server in game.

`render.yaml` is included, so **New -> Blueprint** also works.

### Fly.io / Railway / any VPS

The included `Dockerfile` listens on `$PORT` (default `8080`) and needs no
persistent storage.

## Protocol (for reference)

Client -> server

| type        | fields                                  |
| ----------- | --------------------------------------- |
| `hello`     | `name`                                  |
| `list`      | -                                       |
| `create`    | `public`, `name` (level name), `max`     |
| `join`      | `room`, `name`                          |
| `leave`     | -                                       |
| `signal`    | `to`, `data` (SDP / ICE)                |
| `room_info` | `level`, `public` (host only)           |
| `started`   | - (host only)                           |

Server -> client

| type          | fields                                      |
| ------------- | ------------------------------------------- |
| `rooms`       | `rooms[]`                                   |
| `created`     | `room`, `id`, `level`, `max`, `peers[]`     |
| `joined`      | `room`, `id`, `level`, `max`, `peers[]`     |
| `peer_joined` | `peer` `{id, name}`                         |
| `peer_left`   | `id`                                        |
| `signal`      | `from`, `data`                              |
| `room_closed` | `msg`                                       |
| `error`       | `msg`                                       |

Peer id `1` is always the host of a room.

/*
 * SMB1R Online - room server
 * --------------------------
 * Tiny websocket server that keeps track of public rooms and relays the WebRTC
 * handshake (SDP offers/answers + ICE candidates) between players.
 *
 * Gameplay is pure peer to peer: once the handshake is done the players talk
 * directly to each other and this server is not involved anymore.
 *
 *   npm install
 *   npm start
 *
 * Environment:
 *   PORT  - port to listen on (default 8080)
 */

const http = require("http");
const fs = require("fs");
const path = require("path");
const { WebSocketServer } = require("ws");

const PORT = process.env.PORT || 8080;
const PUBLIC_URL = process.env.PUBLIC_URL || "";
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const ROOM_TTL_MS = 1000 * 60 * 60 * 6;

/** @type {Map<string, Room>} */
const rooms = new Map();
let connectionCounter = 0;

// ---------------------------------------------------------------------------
// HTTP (health + room list + status page)
// ---------------------------------------------------------------------------

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");

  if (req.method === "OPTIONS") {
    res.writeHead(204);
    res.end();
    return;
  }

  if (url.pathname === "/rooms") {
    sendJson(res, 200, publicRoomList());
    return;
  }

  if (url.pathname === "/health") {
    sendJson(res, 200, { ok: true, rooms: rooms.size, uptime: process.uptime() });
    return;
  }

  if (url.pathname === "/" || url.pathname === "/index.html") {
    const file = path.join(__dirname, "public", "index.html");
    if (fs.existsSync(file)) {
      res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
      fs.createReadStream(file).pipe(res);
    } else {
      res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8" });
      res.end("SMB1R Online room server is running.\n");
    }
    return;
  }

  sendJson(res, 404, { error: "not found" });
});

function sendJson(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Content-Length": Buffer.byteLength(body),
  });
  res.end(body);
}

function publicRoomList() {
  return [...rooms.values()]
    .filter((room) => room.isPublic)
    .map((room) => ({
      code: room.code,
      level: room.level,
      host: room.hostName,
      players: room.peers.size,
      max: room.max,
      started: room.started,
    }));
}

// ---------------------------------------------------------------------------
// Websocket room protocol
// ---------------------------------------------------------------------------

const wss = new WebSocketServer({ server });

wss.on("connection", (ws) => {
  ws.connectionId = ++connectionCounter;
  ws.room = null;
  ws.peerId = 0;
  ws.name = "PLAYER";
  ws.isAlive = true;

  ws.on("pong", () => {
    ws.isAlive = true;
  });

  ws.on("message", (raw) => {
    let msg;
    try {
      msg = JSON.parse(raw.toString());
    } catch (error) {
      return sendError(ws, "Malformed message.");
    }
    if (!msg || typeof msg.t !== "string") {
      return sendError(ws, "Malformed message.");
    }
    try {
      handleMessage(ws, msg);
    } catch (error) {
      console.error("message error:", error);
      sendError(ws, "Server error.");
    }
  });

  ws.on("close", () => leaveRoom(ws, "Player disconnected."));
  ws.on("error", () => leaveRoom(ws, "Player disconnected."));
});

function handleMessage(ws, msg) {
  switch (msg.t) {
    case "hello":
      ws.name = cleanName(msg.name);
      return;

    case "list":
      return send(ws, { t: "rooms", rooms: publicRoomList() });

    case "create":
      return createRoom(ws, msg);

    case "join":
      return joinRoom(ws, msg);

    case "leave":
      return leaveRoom(ws, "You left the room.");

    case "signal":
      return relaySignal(ws, msg);

    case "relay":
      return relayGame(ws, msg);

    case "room_info":
      return updateRoomInfo(ws, msg);

    case "started":
      return markStarted(ws);

    default:
      return sendError(ws, "Unknown message type: " + msg.t);
  }
}

function createRoom(ws, msg) {
  leaveRoom(ws, "");
  const code = generateRoomCode();
  const room = {
    code,
    level: cleanText(msg.name) || "CUSTOM LEVEL",
    hostName: ws.name,
    isPublic: msg.public !== false,
    max: clampInt(msg.max, 2, 8, 4),
    peers: new Map(),
    nextId: 2,
    started: false,
    createdAt: Date.now(),
  };
  room.peers.set(1, ws);
  rooms.set(code, room);
  ws.room = room;
  ws.peerId = 1;
  ws.isHost = true;

  send(ws, {
    t: "created",
    room: code,
    id: 1,
    level: room.level,
    max: room.max,
    peers: [],
  });
  console.log(`[room ${code}] created by ${ws.name} (${room.level})`);
}

function joinRoom(ws, msg) {
  const code = String(msg.room || "").toUpperCase().trim();
  const room = rooms.get(code);
  if (!room) {
    return sendError(ws, "That room does not exist anymore.");
  }
  if (room.peers.size >= room.max) {
    return sendError(ws, "That room is full.");
  }
  leaveRoom(ws, "");

  const id = room.nextId++;
  room.peers.set(id, ws);
  ws.room = room;
  ws.peerId = id;
  ws.isHost = false;
  if (msg.name) ws.name = cleanName(msg.name);

  const peers = [...room.peers.entries()]
    .filter(([peerId]) => peerId !== id)
    .map(([peerId, peer]) => ({ id: peerId, name: peer.name }));

  send(ws, {
    t: "joined",
    room: code,
    id,
    level: room.level,
    max: room.max,
    peers,
  });

  broadcast(room, { t: "peer_joined", peer: { id, name: ws.name } }, id);
  console.log(`[room ${code}] ${ws.name} joined as #${id}`);
}

function leaveRoom(ws, reason) {
  const room = ws.room;
  if (!room) {
    ws.room = null;
    ws.peerId = 0;
    ws.isHost = false;
    return;
  }
  const leavingId = ws.peerId;
  const wasHost = room.peers.get(leavingId) === ws && leavingId === 1;
  room.peers.delete(leavingId);
  ws.room = null;
  ws.peerId = 0;

  if (wasHost) {
    for (const [, peer] of room.peers) {
      send(peer, { t: "room_closed", msg: "The host left the room." });
      peer.room = null;
      peer.peerId = 0;
      peer.isHost = false;
    }
    rooms.delete(room.code);
    console.log(`[room ${room.code}] closed (host left)`);
    return;
  }

  if (room.peers.size === 0) {
    rooms.delete(room.code);
    return;
  }

  broadcast(room, { t: "peer_left", id: leavingId, msg: reason || "" });
}

function relaySignal(ws, msg) {
  const room = ws.room;
  if (!room) return;
  const target = room.peers.get(Number(msg.to));
  if (!target || target === ws) return;
  send(target, { t: "signal", from: ws.peerId, data: msg.data || {} });
}

/**
 * Gameplay relay: forwards a method call to the room (or a single peer).
 * The server never inspects the payload, it only routes it.
 */
function relayGame(ws, msg) {
  const room = ws.room;
  if (!room) return;
  const method = String(msg.m || "");
  if (!method.startsWith("net_")) return;
  const payload = {
    t: "relay",
    from: ws.peerId,
    m: method,
    a: Array.isArray(msg.a) ? msg.a : [],
  };
  const to = Number(msg.to || 0);
  if (to > 0) {
    const target = room.peers.get(to);
    if (target && target !== ws) send(target, payload);
    return;
  }
  broadcast(room, payload, ws.peerId);
}

function updateRoomInfo(ws, msg) {
  const room = ws.room;
  if (!room || ws.peerId !== 1) return;
  if (typeof msg.level === "string" && msg.level.trim() !== "") {
    room.level = cleanText(msg.level);
  }
  if (typeof msg.public === "boolean") {
    room.isPublic = msg.public;
  }
}

function markStarted(ws) {
  const room = ws.room;
  if (!room || ws.peerId !== 1) return;
  room.started = true;
}

function broadcast(room, payload, exceptId = -1) {
  for (const [id, peer] of room.peers) {
    if (id === exceptId) continue;
    send(peer, payload);
  }
}

function send(ws, payload) {
  if (ws.readyState === ws.OPEN) {
    ws.send(JSON.stringify(payload));
  }
}

function sendError(ws, message) {
  send(ws, { t: "error", msg: message });
}

function generateRoomCode() {
  let code;
  do {
    code = "";
    for (let i = 0; i < 4; i++) {
      code += CODE_ALPHABET[Math.floor(Math.random() * CODE_ALPHABET.length)];
    }
  } while (rooms.has(code));
  return code;
}

function cleanName(value) {
  const name = String(value || "").trim().toUpperCase().slice(0, 12);
  return name || "PLAYER";
}

function cleanText(value) {
  return String(value || "").replace(/\s+/g, " ").trim().slice(0, 48);
}

function clampInt(value, min, max, fallback) {
  const number = Number(value);
  if (!Number.isFinite(number)) return fallback;
  return Math.min(max, Math.max(min, Math.round(number)));
}

// Drop rooms that have been empty/orphaned for a long time.
setInterval(() => {
  const now = Date.now();
  for (const [code, room] of rooms) {
    if (room.peers.size === 0 || now - room.createdAt > ROOM_TTL_MS) {
      rooms.delete(code);
    }
  }
  for (const ws of wss.clients) {
    if (ws.isAlive === false) {
      ws.terminate();
      continue;
    }
    ws.isAlive = false;
    ws.ping();
  }
}, 30000).unref();

server.listen(PORT, () => {
  console.log(`SMB1R Online room server listening on port ${PORT}`);
  if (PUBLIC_URL) console.log(`Public URL: ${PUBLIC_URL}`);
});

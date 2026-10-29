extends Node
## SMB1R Online - Peer to peer co-op for custom levels.
##
## Uses WebRTC (data channels) for a full mesh between the players and a small
## websocket server (see the /server folder) that only handles room discovery
## and the WebRTC handshake. No gameplay data ever touches the server.
##
## Registered as the "NetPlay" autoload in project.godot.

signal rooms_listed(rooms: Array)
signal lobby_joined()
signal lobby_left()
signal peers_changed()
signal status_changed(text: String)
signal error_raised(text: String)
signal level_started()
signal room_closed(reason: String)

const MAX_PLAYERS := 4
const STATE_HZ := 20.0
const DEFAULT_SERVER := "wss://smb1r-online-rooms.onrender.com/ws"
const CONFIG_PATH := "user://multiplayer.cfg"
const REMOTE_PLAYER_SCRIPT := preload("res://Scripts/Multiplayer/RemotePlayer.gd")
const STUN_SERVERS := ["stun:stun.l.google.com:19302", "stun:stun1.l.google.com:19302"]

enum Mode { OFFLINE, LOBBY, IN_ROOM }

var mode: Mode = Mode.OFFLINE

## Address of the room server. Overridable from the in-game menu.
var signal_url := DEFAULT_SERVER
var player_name := "PLAYER"

var my_id := 0
var is_host := false
var room_code := ""
var room_level_name := ""

## id -> {"id": int, "name": String}
var peers_info := {}

## Level state for the current online session.
var level_active := false
var level_file := {}
var level_hash := ""
var level_name := ""
var level_author := "PLAYER"
## "custom" (.lvl dictionary) or "campaign" (SMB1 / SMBS / SMBLL / SMBANN).
var level_mode := "custom"
var campaign_id := "SMB1"
var campaign_world := 1
var campaign_level := 1

var _ws: WebSocketPeer = null
var _ws_opened := false
var _pending_action := {}
var _status := ""

var _rtc: WebRTCMultiplayerPeer = null
var _conns := {}
var _remote_desc := {}
var _candidates := {}

var _puppets := {}
var _puppet_parent: Node = null
var _local_player: Player = null
var _current_level: Level = null
var _send_accum := 0.0
var _hello_sent := false
var _entity_cache := {}
var _entity_cache_root: Node = null
## True while applying an event that came from another peer (prevents echo loops).
var _applying_remote := false
## Test helper: skips the "press a button" wait on the level transition screen.
var _auto_advance := false
var _simple_level := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_load_config()
	_auto_advance = "--auto-advance" in OS.get_cmdline_user_args()
	_simple_level = "--simple-level" in OS.get_cmdline_user_args()
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


func _process(delta: float) -> void:
	_poll_socket()
	_watch_level(delta)
	_send_local_state(delta)


# --------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------

func is_in_room() -> bool:
	return mode == Mode.IN_ROOM


func is_playing_online() -> bool:
	return level_active and _rtc != null


func get_status() -> String:
	return _status


func get_peers_with_me() -> Array:
	var out := []
	for id in peers_info.keys():
		out.append(peers_info[id])
	out.sort_custom(func(a, b): return int(a["id"]) < int(b["id"]))
	return out


func get_room_code() -> String:
	return room_code


func set_server_url(url: String) -> void:
	signal_url = url.strip_edges()
	if signal_url == "":
		signal_url = DEFAULT_SERVER
	_save_config()


func set_player_name(new_name: String) -> void:
	player_name = _sanitize_name(new_name)
	_save_config()


## Connect (if needed) and ask the server for the public room list.
func request_rooms() -> void:
	_queue_action({"t": "list"})


## Create a public room. Only the host may call this.
func create_room(for_level_name := "") -> void:
	room_level_name = for_level_name if for_level_name != "" else "CUSTOM LEVEL"
	_queue_action({
		"t": "create",
		"public": true,
		"name": room_level_name,
		"max": MAX_PLAYERS,
		"player": player_name,
	})


func join_room(code: String) -> void:
	var clean := code.strip_edges().to_upper()
	if clean == "":
		error_raised.emit("Room code is empty.")
		return
	_queue_action({"t": "join", "room": clean, "name": player_name})


func leave_room() -> void:
	if mode == Mode.IN_ROOM:
		_send_ws({"t": "leave"})
	_clear_session()
	lobby_left.emit()


## Fully disconnect from the room server.
func shutdown() -> void:
	leave_room()
	if _ws != null:
		_ws.close()
	_ws = null
	_ws_opened = false
	mode = Mode.OFFLINE
	_set_status("")


# Host: broadcast the current custom level and load it locally.
func start_level() -> void:
	if not is_host:
		return
	if level_mode == "campaign":
		start_campaign(campaign_id, campaign_world, campaign_level)
		return
	if not level_active:
		capture_level()
	rpc("net_start_level", level_file, _level_meta())
	_enter_level_scene()


## Host: start a campaign (SMB1 / SMBS / SMBLL / SMBANN) level for the room.
func start_campaign(campaign: String, world: int, level: int) -> void:
	level_mode = "campaign"
	campaign_id = campaign
	campaign_world = max(1, world)
	campaign_level = max(1, level)
	level_hash = "campaign:%s:%d:%d" % [campaign_id, campaign_world, campaign_level]
	level_name = "%s %d-%d" % [campaign_id, campaign_world, campaign_level]
	level_active = true
	rpc("net_start_campaign", campaign_id, campaign_world, campaign_level)
	_enter_campaign_level()


func _enter_campaign_level() -> void:
	level_started.emit()
	Global.current_campaign = campaign_id
	Global.level_num = campaign_level
	Global.world_num = campaign_world
	Global.current_game_mode = Global.GameMode.CAMPAIGN
	Global.current_custom_campaign = ""
	Level.first_load = true
	Level.can_set_time = true
	var path := Level.get_scene_string(campaign_world, campaign_level)
	Global.transition_to_scene(path)


## Grab the level the menu is currently pointing at.
func capture_level() -> void:
	level_mode = "custom"
	level_file = LevelEditor.level_file.duplicate(true)
	level_name = LevelEditor.level_name
	level_author = LevelEditor.level_author
	level_hash = JSON.stringify(level_file).sha256_text()
	level_active = true


# --------------------------------------------------------------------------
# Level lifecycle
# --------------------------------------------------------------------------

## Called by Level.spawn_in_extra_players() as soon as a level scene starts.
func on_level_entered(level: Level) -> void:
	_current_level = level
	_clear_puppets()
	_local_player = null


## Detects level scene changes without touching the level code. The level
## script can bail out of its own _enter_tree (resource packs do weird things),
## so polling Global.current_level is the reliable option.
func _watch_level(delta: float) -> void:
	if not is_playing_online():
		return
	var current = Global.current_level
	if current == null or not is_instance_valid(current):
		return
	var level := current as Level
	if level == null:
		return
	if level == _current_level:
		if _local_player != null and not is_instance_valid(_local_player):
			_clear_puppets()
			_local_player = null
		return
	_current_level = level
	_clear_puppets()
	_puppet_parent = null
	_local_player = null
	# Speedrun ghosts look like extra players online, so keep them off.
	SpeedrunHandler.ghost_active = false
	SpeedrunHandler.ghost_enabled = false
	get_tree().call_group("PlayerGhosts", "delete")
	print("[NetPlay] level detected (players=%d)" % get_tree().get_nodes_in_group("Players").size())


func _enter_level_scene() -> void:
	print("[NetPlay] _enter_level_scene host=%s hash=%s" % [is_host, level_hash])
	level_started.emit()
	Global.current_game_mode = Global.GameMode.CUSTOM_LEVEL
	LevelEditor.level_file = level_file
	LevelEditor.level_name = level_name
	LevelEditor.level_author = level_author
	LevelEditor.load_play = true
	LevelEditor.sub_areas = [null, null, null, null, null]
	Checkpoint.sublevel_id = 0
	Level.first_load = true
	Level.can_set_time = true
	Global.level_num = 1
	Global.world_num = 1
	Global.custom_level_idx = 0
	LevelTransition.level_to_transition_to = "res://Scenes/Levels/LevelEditor.tscn"
	if _simple_level:
		Global.transition_to_scene("res://Scenes/Levels/CustomLevelBase.tscn")
		return
	Global.transition_to_scene("res://Scenes/Levels/LevelTransition.tscn")
	if _auto_advance:
		_auto_advance_transition()


func _auto_advance_transition() -> void:
	print("[NetPlay] auto-advance armed")
	for i in 40:
		await get_tree().create_timer(0.25).timeout
		var scene := get_tree().current_scene
		if scene != null and scene.has_method("transition") and not Global.transitioning_scene:
			print("[NetPlay] auto-advance firing on %s" % str(scene))
			scene.call("transition")
			return
	print("[NetPlay] auto-advance gave up")


func _level_meta() -> Dictionary:
	return {
		"hash": level_hash,
		"name": level_name,
		"author": level_author,
	}


# --------------------------------------------------------------------------
# Room server (websocket) plumbing
# --------------------------------------------------------------------------

func _queue_action(action: Dictionary) -> void:
	_pending_action = action
	if _ws != null and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_flush_action()
	elif _ws == null or _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_open_socket()


func _open_socket() -> void:
	_ws = WebSocketPeer.new()
	_ws_opened = false
	_set_status("Connecting to room server...")
	var err := _ws.connect_to_url(signal_url)
	if err != OK:
		_set_status("")
		error_raised.emit("Could not reach the room server (%s)." % signal_url)
		_ws = null


func _flush_action() -> void:
	if _pending_action.is_empty():
		return
	_send_ws(_pending_action)
	_pending_action = {}


func _poll_socket() -> void:
	if _ws == null:
		return
	_ws.poll()
	var state := _ws.get_ready_state()
	if state == WebSocketPeer.STATE_OPEN:
		if not _ws_opened:
			_ws_opened = true
			_send_ws({"t": "hello", "name": player_name})
			_flush_action()
		while _ws.get_available_packet_count() > 0:
			var txt := _ws.get_packet().get_string_from_utf8()
			var msg = JSON.parse_string(txt)
			if msg is Dictionary:
				_handle_server_message(msg)
	elif state == WebSocketPeer.STATE_CLOSED:
		if _ws_opened:
			_ws_opened = false
			_clear_puppets()
			if mode == Mode.IN_ROOM:
				_clear_session()
				_set_status("")
				room_closed.emit("Lost connection to the room server.")
		_ws = null


func _send_ws(payload: Dictionary) -> void:
	if _ws == null or _ws.get_ready_state() != WebSocketPeer.STATE_OPEN:
		return
	_ws.send_text(JSON.stringify(payload))


func _handle_server_message(msg: Dictionary) -> void:
	match str(msg.get("t", "")):
		"rooms":
			rooms_listed.emit(msg.get("rooms", []))
		"created", "joined":
			_on_room_joined(msg)
		"peer_joined":
			var peer: Dictionary = msg.get("peer", {})
			peers_info[int(peer.get("id", 0))] = peer
			peers_changed.emit()
			_maybe_connect_peer(int(peer.get("id", 0)), my_id > int(peer.get("id", 0)))
		"peer_left":
			var left_id := int(msg.get("id", 0))
			peers_info.erase(left_id)
			peers_changed.emit()
			_remove_puppet(left_id)
			if _rtc != null and _rtc.has_peer(left_id):
				_rtc.remove_peer(left_id)
			_conns.erase(left_id)
		"signal":
			_on_remote_signal(int(msg.get("from", 0)), msg.get("data", {}))
		"room_closed":
			var reason := str(msg.get("msg", "The host left the room."))
			_clear_session()
			_set_status("")
			room_closed.emit(reason)
		"error":
			error_raised.emit(str(msg.get("msg", "Unknown server error.")))
		"ok":
			pass


func _on_room_joined(msg: Dictionary) -> void:
	var keep_mode := level_mode
	var keep_campaign := campaign_id
	var keep_world := campaign_world
	var keep_level := campaign_level
	_clear_session()
	level_mode = keep_mode
	campaign_id = keep_campaign
	campaign_world = keep_world
	campaign_level = keep_level
	mode = Mode.IN_ROOM
	my_id = int(msg.get("id", 1))
	is_host = my_id == 1
	room_code = str(msg.get("room", ""))
	if msg.has("level"):
		room_level_name = str(msg.get("level", room_level_name))
	peers_info.clear()
	peers_info[my_id] = {"id": my_id, "name": player_name}
	for p in msg.get("peers", []):
		peers_info[int(p.get("id", 0))] = p
	_create_mesh()
	for id in peers_info.keys():
		var other := int(id)
		if other == my_id:
			continue
		# Deterministic offerer: host (1) always answers, and between clients the
		# highest id sends the offer. This avoids WebRTC glare on simultaneous joins.
		_maybe_connect_peer(other, other == 1 or my_id > other, true)
	_set_status("Room %s" % room_code if room_code != "" else "In room")
	lobby_joined.emit()
	peers_changed.emit()


func _clear_session() -> void:
	level_active = false
	level_mode = "custom"
	level_file = {}
	level_hash = ""
	level_name = ""
	_local_player = null
	_current_level = null
	_hello_sent = false
	for id in _puppets.keys():
		_remove_puppet(int(id))
	_puppets.clear()
	_conns.clear()
	_remote_desc.clear()
	_candidates.clear()
	if _rtc != null or multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	_rtc = null
	peers_info.clear()
	is_host = false
	my_id = 0
	room_code = ""
	mode = Mode.LOBBY


# --------------------------------------------------------------------------
# WebRTC mesh
# --------------------------------------------------------------------------

func _create_mesh() -> void:
	var peer := WebRTCMultiplayerPeer.new()
	var err := OK
	if is_host:
		err = peer.create_server()
	else:
		err = peer.create_mesh(my_id)
	if err != OK:
		error_raised.emit("Could not start WebRTC (%s)." % error_string(err))
		return
	_rtc = peer
	multiplayer.multiplayer_peer = peer


func _maybe_connect_peer(peer_id: int, as_offerer: bool, force := false) -> void:
	if _rtc == null or peer_id <= 0 or peer_id == my_id:
		return
	if _conns.has(peer_id) and not force:
		return
	var conn: WebRTCPeerConnection = _conns.get(peer_id)
	if conn == null:
		conn = WebRTCPeerConnection.new()
		var err := conn.initialize({"iceServers": [{"urls": STUN_SERVERS}]})
		if err != OK:
			error_raised.emit("WebRTC is not available on this build.")
			return
		_conns[peer_id] = conn
		_remote_desc[peer_id] = false
		_candidates[peer_id] = []
		conn.session_description_created.connect(_on_sdp_created.bind(peer_id))
		conn.ice_candidate_created.connect(_on_ice_candidate.bind(peer_id))
		if not _rtc.has_peer(peer_id):
			_rtc.add_peer(conn, peer_id)
	elif not _rtc.has_peer(peer_id):
		_rtc.add_peer(conn, peer_id)
	if as_offerer:
		conn.create_offer()


func _on_sdp_created(type: String, sdp: String, peer_id: int) -> void:
	if not _conns.has(peer_id):
		return
	_conns[peer_id].set_local_description(type, sdp)
	_send_ws({"t": "signal", "to": peer_id, "data": {"type": type, "sdp": sdp}})


func _on_ice_candidate(mid: String, index: int, sdp: String, peer_id: int) -> void:
	_send_ws({
		"t": "signal",
		"to": peer_id,
		"data": {"type": "candidate", "mid": mid, "index": index, "name": sdp},
	})


func _on_remote_signal(from_id: int, data: Dictionary) -> void:
	if from_id <= 0:
		return
	var kind := str(data.get("type", ""))
	if kind == "offer" or kind == "answer":
		if _rtc == null:
			return
		if not _conns.has(from_id):
			_maybe_connect_peer(from_id, false)
		var conn: WebRTCPeerConnection = _conns.get(from_id)
		if conn == null:
			return
		conn.set_remote_description(kind, str(data.get("sdp", "")))
		_remote_desc[from_id] = true
		for c in _candidates.get(from_id, []):
			conn.add_ice_candidate(str(c.get("mid", "")), int(c.get("index", 0)), str(c.get("name", "")))
		_candidates[from_id] = []
		if kind == "offer" and conn.has_method("create_answer"):
			conn.create_answer()
	elif kind == "candidate":
		var cand := {
			"mid": str(data.get("mid", "")),
			"index": int(data.get("index", 0)),
			"name": str(data.get("name", "")),
		}
		if _remote_desc.get(from_id, false) and _conns.has(from_id):
			_conns[from_id].add_ice_candidate(cand["mid"], cand["index"], cand["name"])
		else:
			if not _candidates.has(from_id):
				_candidates[from_id] = []
			_candidates[from_id].append(cand)


func _on_peer_connected(id: int) -> void:
	if not is_host and id == 1 and not _hello_sent:
		_hello_sent = true
		rpc_id(1, "net_hello", {"name": player_name})
	peers_changed.emit()


func _on_peer_disconnected(id: int) -> void:
	_remove_puppet(id)
	peers_changed.emit()


func _on_connected_to_server() -> void:
	pass


func _on_connection_failed() -> void:
	error_raised.emit("WebRTC connection failed.")


func _on_server_disconnected() -> void:
	pass


# --------------------------------------------------------------------------
# RPCs
# --------------------------------------------------------------------------

@rpc("any_peer", "call_remote", "reliable")
func net_hello(info: Dictionary) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 0:
		return
	var remote_name := str(info.get("name", "PLAYER"))
	if peers_info.has(sender):
		peers_info[sender]["name"] = remote_name
	else:
		peers_info[sender] = {"id": sender, "name": remote_name}
	peers_changed.emit()
	if is_host and level_active:
		rpc_id(sender, "net_start_level", level_file, _level_meta())


@rpc("any_peer", "call_remote", "reliable")
func net_request_level() -> void:
	if not is_host or not level_active:
		return
	rpc_id(multiplayer.get_remote_sender_id(), "net_start_level", level_file, _level_meta())


# --------------------------------------------------------------------------
# World events (blocks, enemies)
# --------------------------------------------------------------------------

## Stable id for a level entity. Every peer builds the same level file, so the
## tile position + layer identify the same node on every machine.
func entity_id(node: Node) -> String:
	if node == null or not is_instance_valid(node):
		return ""
	if not node.has_meta("tile_position") or not node.has_meta("layer"):
		return ""
	var tile: Vector2i = node.get_meta("tile_position")
	return "%d:%d:%d" % [int(node.get_meta("layer")), tile.x, tile.y]


func broadcast_block_hit(block: Node) -> void:
	if not is_playing_online() or _applying_remote:
		return
	var id := entity_id(block)
	if id == "":
		return
	rpc("net_block_hit", id, _room_key())


func broadcast_enemy_died(enemy: Node) -> void:
	if not is_playing_online() or _applying_remote:
		return
	var id := entity_id(enemy)
	if id == "":
		return
	rpc("net_enemy_died", id, _room_key())


@rpc("any_peer", "call_remote", "reliable")
func net_block_hit(id: String, room: String) -> void:
	if not level_active or room != _room_key():
		return
	var node := _find_entity(id)
	if node == null or not node.has_method("dispense_item"):
		return
	_applying_remote = true
	node.call("dispense_item")
	_applying_remote = false


@rpc("any_peer", "call_remote", "reliable")
func net_enemy_died(id: String, room: String) -> void:
	if not level_active or room != _room_key():
		return
	var node := _find_entity(id)
	if node == null or not is_instance_valid(node):
		return
	if node.has_method("die"):
		_applying_remote = true
		node.call("die")
		_applying_remote = false


func _find_entity(id: String) -> Node:
	var root := _scene_root()
	if root == null:
		return null
	if _entity_cache_root != root:
		_entity_cache_root = root
		_entity_cache.clear()
		var stack: Array[Node] = [root]
		while stack.size() > 0:
			var current: Node = stack.pop_back()
			var key := entity_id(current)
			if key != "":
				_entity_cache[key] = current
			for child in current.get_children():
				stack.append(child)
	var found = _entity_cache.get(id)
	if found != null and is_instance_valid(found):
		return found
	_entity_cache.erase(id)
	return null


func _scene_root() -> Node:
	if _current_level == null or not is_instance_valid(_current_level):
		return null
	var parent := _current_level.get_parent()
	return parent if parent != null else _current_level


@rpc("authority", "call_remote", "reliable")
func net_start_level(remote_level: Dictionary, meta: Dictionary) -> void:
	if remote_level.is_empty():
		return
	var new_hash := str(meta.get("hash", ""))
	if level_active and level_hash == new_hash:
		return
	level_file = remote_level
	level_name = str(meta.get("name", "CUSTOM LEVEL"))
	level_author = str(meta.get("author", "PLAYER"))
	level_hash = new_hash
	level_active = true
	_enter_level_scene()


@rpc("authority", "call_remote", "reliable")
func net_start_campaign(campaign: String, world: int, level: int) -> void:
	var new_hash := "campaign:%s:%d:%d" % [campaign, world, level]
	if level_active and level_hash == new_hash:
		return
	level_mode = "campaign"
	campaign_id = campaign
	campaign_world = world
	campaign_level = level
	level_hash = new_hash
	level_name = "%s %d-%d" % [campaign, world, level]
	level_active = true
	_enter_campaign_level()


@rpc("any_peer", "call_remote", "unreliable_ordered")
func net_player_state(data: Dictionary) -> void:
	var sender := multiplayer.get_remote_sender_id()
	if sender <= 0 or not level_active:
		return
	if str(data.get("h", "")) != level_hash or str(data.get("r", "")) != _room_key():
		_remove_puppet(sender)
		return
	var puppet = _puppets.get(sender)
	if puppet == null or not is_instance_valid(puppet):
		puppet = _spawn_puppet(sender)
	if puppet == null:
		return
	puppet.apply_state(data)


# --------------------------------------------------------------------------
# Local player replication
# --------------------------------------------------------------------------

func _send_local_state(delta: float) -> void:
	if not is_playing_online() or _rtc == null:
		return
	_send_accum += delta
	if _send_accum < 1.0 / STATE_HZ:
		return
	_send_accum = 0.0
	if not is_instance_valid(_local_player):
		_local_player = get_tree().get_first_node_in_group("Players") as Player
	if not is_instance_valid(_local_player):
		return
	if Global.current_level == null or not is_instance_valid(Global.current_level):
		return
	var player := _local_player
	var power_state: PowerUpState = player.power_state
	if power_state == null:
		return
	var sprite := player.sprite
	var data := {
		"h": level_hash,
		"r": _room_key(),
		"n": player_name,
		"x": player.global_position.x,
		"y": player.global_position.y,
		"a": str(sprite.animation),
		"f": sprite.frame,
		"fx": -1 if sprite.scale.x < 0 else 1,
		"s": str(power_state.state_name),
		"c": player.character,
		"v": 1 if player.visible else 0,
	}
	rpc("net_player_state", data)


## Identifies the concrete sub-room we are in (main room, bonus room, ...),
## so players inside a pipe do not see each other in the wrong room.
func _room_key() -> String:
	if Global.current_level == null or not is_instance_valid(Global.current_level):
		return ""
	var level := Global.current_level as Level
	if level == null:
		return ""
	var parent: Node = level.get_parent()
	if parent != null and parent.get("sublevel_id") != null:
		return "%s:%s" % [str(level.room_type), str(parent.sublevel_id)]
	return str(level.room_type)


# --------------------------------------------------------------------------
# Remote player puppets
# --------------------------------------------------------------------------

func _spawn_puppet(peer_id: int):
	for id in _puppets.keys():
		if not peers_info.has(int(id)):
			_remove_puppet(int(id))
	var existing = _puppets.get(peer_id)
	if existing != null and is_instance_valid(existing):
		return existing
	if not is_instance_valid(_local_player):
		_local_player = get_tree().get_first_node_in_group("Players") as Player
	if not is_instance_valid(_local_player):
		return null
	var parent := _local_player.get_parent()
	if parent == null:
		return null
	if parent != _puppet_parent:
		_clear_puppets()
		_puppet_parent = parent
	_remove_stray_puppets(parent)
	var node = REMOTE_PLAYER_SCRIPT.new()
	node.name = "Remote_" + str(peer_id)
	parent.add_child(node)
	node.reference = _local_player
	node.setup(peer_id, str(peers_info.get(peer_id, {}).get("name", "PLAYER")))
	node.z_index = _local_player.z_index
	_puppets[peer_id] = node
	return node


## Removes leftover puppet nodes (e.g. after a respawn) that are no longer
## tracked in _puppets. Without this, dead players respawn duplicated.
func _remove_stray_puppets(parent: Node) -> void:
	for child in parent.get_children():
		if child.name.begins_with("Remote_") and not _puppets.values().has(child):
			child.queue_free()


func _remove_puppet(peer_id: int) -> void:
	var puppet = _puppets.get(peer_id)
	if puppet != null and is_instance_valid(puppet):
		puppet.queue_free()
	_puppets.erase(peer_id)


func _clear_puppets() -> void:
	for id in _puppets.keys():
		_remove_puppet(int(id))
	_puppets.clear()


# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

func _default_name() -> String:
	var name := OS.get_environment("USERNAME")
	if name == "":
		name = OS.get_environment("USER")
	return _sanitize_name(name)


func _sanitize_name(raw: String) -> String:
	var clean := raw.strip_edges().to_upper()
	if clean == "":
		return "PLAYER"
	if clean.length() > 12:
		clean = clean.substr(0, 12)
	return clean


func _load_config() -> void:
	player_name = _default_name()
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) == OK:
		signal_url = str(cfg.get_value("net", "server", DEFAULT_SERVER))
		player_name = _sanitize_name(str(cfg.get_value("net", "name", player_name)))


func _save_config() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("net", "server", signal_url)
	cfg.set_value("net", "name", player_name)
	cfg.save(CONFIG_PATH)


func _set_status(text: String) -> void:
	_status = text
	status_changed.emit(text)

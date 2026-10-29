extends Node
## Headless smoke test for the online layer.
##
##   godot --headless --path . res://tests/net_smoke.tscn -- --role=host
##   godot --headless --path . res://tests/net_smoke.tscn -- --role=client --room=ABCD
##
## The host prints "ROOM=XXXX" as soon as the room exists, and both sides print
## "[NetPlay] Level entered" once the shared level scene is running.

var role := "host"
var room := ""
var got_ping := false
var started := false


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="):
			role = arg.replace("--role=", "")
		elif arg.begins_with("--room="):
			room = arg.replace("--room=", "").to_upper()

	NetPlay.error_raised.connect(func(msg): print("NET_ERROR: ", msg))
	NetPlay.room_closed.connect(func(msg): print("ROOM_CLOSED: ", msg))
	NetPlay.peers_changed.connect(_on_peers_changed)
	NetPlay.lobby_joined.connect(_on_lobby_joined)
	NetPlay.level_started.connect(func(): print("LEVEL_STARTED_SIGNAL"))

	print("ROLE=", role)
	_test_menu()
	NetPlay.set_server_url(_server_url())

	if role == "host":
		NetPlay.create_room("SMOKE TEST")
	else:
		if room == "":
			print("MISSING --room")
			get_tree().quit(1)
			return
		NetPlay.join_room(room)


func _server_url() -> String:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--server="):
			return arg.replace("--server=", "")
	return "ws://127.0.0.1:8080/ws"


func _test_menu() -> void:
	var menu := MultiplayerMenu.new()
	add_child(menu)
	menu.open("SMOKE TEST")
	await get_tree().process_frame
	await get_tree().process_frame
	menu.close()
	menu.queue_free()
	print("MENU_OK")


func _on_lobby_joined() -> void:
	print("ROOM=", NetPlay.get_room_code())


func _on_peers_changed() -> void:
	var players := NetPlay.get_peers_with_me()
	print("PEERS=", players.size())
	if role == "host" and players.size() >= 2 and not started:
		started = true
		_run_host_sequence()


func _run_host_sequence() -> void:
	await get_tree().create_timer(1.0).timeout
	print("SENDING_PING")
	rpc("net_test_ping", "hello from host")
	await get_tree().create_timer(2.0).timeout
	print("HOST_START_LEVEL")
	LevelEditor.level_file = _test_level()
	LevelEditor.level_name = "NET TEST"
	LevelEditor.level_author = "TESTER"
	NetPlay.start_level()


@rpc("any_peer", "call_remote", "reliable")
func net_test_ping(text: String) -> void:
	if got_ping:
		return
	got_ping = true
	print("PING_RECEIVED: ", text, " from ", multiplayer.get_remote_sender_id())


func _test_level() -> Dictionary:
	return {
		"Info": {"Name": "NET TEST", "Author": "TESTER", "Description": "smoke test", "Difficulty": 0},
		"Levels": [
			{"Data": "A=A=A=A=A=A=GQ", "BG": "A=A=A=A=A=A=A=A", "Layers": []},
			{}, {}, {}, {},
		],
	}

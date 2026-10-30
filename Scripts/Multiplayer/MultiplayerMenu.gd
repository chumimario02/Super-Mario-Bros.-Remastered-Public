class_name MultiplayerMenu
extends Control
## The "Singleplayer / Multiplayer" chooser shown when pressing PLAY on a
## custom level, plus the online lobby (create room, public room list, join).

signal singleplayer_chosen
signal host_start_requested
signal lss_requested
signal closed

const MIN_PANEL_SIZE := Vector2(210, 130)
const CHARACTER_SELECT_SCENE := preload("res://Scenes/Prefabs/UI/CharacterSelect.tscn")

var _panel: PanelContainer
var _pages := {}
var _page := ""
var _status: Label
var _room_code_label: Label
var _room_level_label: Label
var _players_box: VBoxContainer
var _start_button: Button
var _rooms_box: VBoxContainer
var _games_box: VBoxContainer
var _servers_name: LineEdit
var _host_box: VBoxContainer
var _world_select: OptionButton
var _level_select: OptionButton
var _inf_lives: CheckBox
var _inf_time: CheckBox
var _campaign_row: HBoxContainer
var _character_btn: Button
var _public_check: CheckBox
var _character_select_open := false
var _host_campaign := ""
var _name_edit: LineEdit
var _server_edit: LineEdit
var _code_edit: LineEdit
var _busy := false
var standalone := false


func _ready() -> void:
	visible = false
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	NetPlay.rooms_listed.connect(_on_rooms_listed)
	NetPlay.lobby_joined.connect(_on_lobby_joined)
	NetPlay.lobby_left.connect(_on_lobby_left)
	NetPlay.peers_changed.connect(_refresh_lobby)
	NetPlay.error_raised.connect(_on_error)
	NetPlay.room_closed.connect(_on_room_closed)
	NetPlay.level_started.connect(_on_level_started)
	NetPlay.status_changed.connect(_on_status_changed)


# --------------------------------------------------------------------------
# UI construction
# --------------------------------------------------------------------------

func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.72)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_panel = PanelContainer.new()
	_panel.custom_minimum_size = MIN_PANEL_SIZE
	center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 6)
	margin.add_theme_constant_override("margin_right", 6)
	margin.add_theme_constant_override("margin_top", 6)
	margin.add_theme_constant_override("margin_bottom", 6)
	_panel.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 2)
	margin.add_child(root)

	_pages["modes"] = _build_modes_page()
	_pages["servers"] = _build_servers_page()
	_pages["games"] = _build_games_page()
	_pages["rooms"] = _build_rooms_page()
	_pages["lobby"] = _build_lobby_page()
	_pages["settings"] = _build_settings_page()
	for page in _pages.values():
		root.add_child(page)
		page.visible = false

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(0, 24)
	_status.add_theme_font_size_override("font_size", 8)
	_status.add_theme_color_override("font_color", Color(1, 1, 0.4))
	root.add_child(_status)


func _build_page(title: String) -> VBoxContainer:
	var page := VBoxContainer.new()
	var header := Label.new()
	header.text = title
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page.add_child(header)
	page.add_child(HSeparator.new())
	return page


func _button(text: String, callback: Callable, page: Container, size := Vector2.ZERO) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.custom_minimum_size = size
	btn.pressed.connect(callback)
	page.add_child(btn)
	return btn


func _build_modes_page() -> VBoxContainer:
	var page := _build_page("CUSTOM LEVEL")
	var level := Label.new()
	level.name = "LevelName"
	level.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	level.add_theme_font_size_override("font_size", 8)
	level.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(level)
	_button("SINGLEPLAYER", _on_singleplayer, page)
	_button("MULTIPLAYER", _show_online, page)
	_button("BACK", _on_close, page)
	return page


func _build_servers_page() -> VBoxContainer:
	var page := _build_page("SERVERS")

	var name_row := HBoxContainer.new()
	page.add_child(name_row)
	var name_label := Label.new()
	name_label.text = "NAME"
	name_label.add_theme_font_size_override("font_size", 8)
	name_row.add_child(name_label)
	_servers_name = LineEdit.new()
	_servers_name.max_length = 12
	_servers_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_servers_name.add_theme_font_size_override("font_size", 10)
	name_row.add_child(_servers_name)
	_button("SAVE", _on_save_name, name_row)

	_public_check = CheckBox.new()
	_public_check.text = "PUBLIC SERVER"
	_public_check.button_pressed = true
	_public_check.add_theme_font_size_override("font_size", 8)
	page.add_child(_public_check)

	_button("CREATE SERVER", _on_create_room, page)
	_button("PUBLIC SERVERS", _on_browse_rooms, page)

	var code_row := HBoxContainer.new()
	page.add_child(code_row)
	_code_edit = LineEdit.new()
	_code_edit.placeholder_text = "CODE"
	_code_edit.max_length = 6
	_code_edit.custom_minimum_size = Vector2(70, 0)
	_code_edit.add_theme_font_size_override("font_size", 10)
	code_row.add_child(_code_edit)
	_button("JOIN", _on_join_code, code_row)

	_button("SETTINGS", func(): _show_page("settings"), page)
	_button("BACK", _show_modes, page)
	return page


func _build_games_page() -> VBoxContainer:
	var page := _build_page("SELECT GAME")
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(190, 96)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page.add_child(scroll)
	_games_box = VBoxContainer.new()
	_games_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_games_box)
	var row := HBoxContainer.new()
	page.add_child(row)
	_button("REFRESH", _refresh_games, row)
	_button("BACK", _show_online, row)
	return page


func _build_rooms_page() -> VBoxContainer:
	var page := _build_page("PUBLIC ROOMS")
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(190, 96)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	page.add_child(scroll)
	_rooms_box = VBoxContainer.new()
	_rooms_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_rooms_box)
	var row := HBoxContainer.new()
	page.add_child(row)
	_button("REFRESH", _on_browse_rooms, row)
	_button("BACK", _show_online, row)
	return page


func _build_lobby_page() -> VBoxContainer:
	var page := _build_page("ROOM")
	_room_code_label = Label.new()
	_room_code_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_room_code_label.add_theme_font_size_override("font_size", 12)
	page.add_child(_room_code_label)
	_room_level_label = Label.new()
	_room_level_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_room_level_label.add_theme_font_size_override("font_size", 8)
	_room_level_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_room_level_label)
	page.add_child(HSeparator.new())
	_players_box = VBoxContainer.new()
	_players_box.custom_minimum_size = Vector2(190, 40)
	page.add_child(_players_box)

	_host_box = VBoxContainer.new()
	page.add_child(_host_box)
	_campaign_row = HBoxContainer.new()
	_host_box.add_child(_campaign_row)
	var world_label := Label.new()
	world_label.text = "WORLD"
	world_label.add_theme_font_size_override("font_size", 8)
	_campaign_row.add_child(world_label)
	_world_select = OptionButton.new()
	_world_select.add_theme_font_size_override("font_size", 8)
	_campaign_row.add_child(_world_select)
	var level_label := Label.new()
	level_label.text = "LEVEL"
	level_label.add_theme_font_size_override("font_size", 8)
	_campaign_row.add_child(level_label)
	_level_select = OptionButton.new()
	_level_select.add_theme_font_size_override("font_size", 8)
	_campaign_row.add_child(_level_select)
	_inf_lives = CheckBox.new()
	_inf_lives.text = "INFINITE LIVES"
	_inf_lives.add_theme_font_size_override("font_size", 8)
	_host_box.add_child(_inf_lives)
	_inf_time = CheckBox.new()
	_inf_time.text = "NO TIME LIMIT"
	_inf_time.add_theme_font_size_override("font_size", 8)
	_host_box.add_child(_inf_time)

	_character_btn = _button("CHARACTER: MARIO", _cycle_character, page)
	_start_button = _button("START LEVEL", _on_start_level, page)
	_button("LEAVE ROOM", _on_leave_room, page)
	return page


func _cycle_character() -> void:
	if _character_select_open:
		return
	_character_select_open = true
	var select = CHARACTER_SELECT_SCENE.instantiate()
	var host: Node = get_tree().current_scene
	var canvas = host.get_node_or_null("CanvasLayer") if host != null else null
	if canvas != null:
		canvas.add_child(select)
	elif host != null:
		host.add_child(select)
	else:
		add_child(select)
	hide()
	select.set("player_id", 0)
	select.open()
	await select.selected
	select.queue_free()
	_character_select_open = false
	show()
	_focus_page()
	if is_instance_valid(_character_btn):
		_character_btn.text = ("CHARACTER: " + Player.CHARACTERS[int(Global.player_characters[0])]).to_upper()


func _focus_page() -> void:
	await get_tree().process_frame
	var target := _first_focusable(_pages.get(_page, self))
	if target != null:
		target.grab_focus()


func _build_settings_page() -> VBoxContainer:
	var page := _build_page("ONLINE SETTINGS")
	var name_label := Label.new()
	name_label.text = "PLAYER NAME"
	name_label.add_theme_font_size_override("font_size", 8)
	page.add_child(name_label)
	_name_edit = LineEdit.new()
	_name_edit.max_length = 12
	_name_edit.add_theme_font_size_override("font_size", 10)
	page.add_child(_name_edit)

	var server_label := Label.new()
	server_label.text = "ROOM SERVER"
	server_label.add_theme_font_size_override("font_size", 8)
	page.add_child(server_label)
	_server_edit = LineEdit.new()
	_server_edit.add_theme_font_size_override("font_size", 10)
	page.add_child(_server_edit)

	_button("SAVE", _on_save_settings, page)
	_button("BACK", _show_online, page)
	return page


# --------------------------------------------------------------------------
# Page handling
# --------------------------------------------------------------------------

func open(level_name := "CUSTOM LEVEL", is_standalone := false) -> void:
	standalone = is_standalone
	get_tree().paused = false
	_busy = false
	_status.text = ""
	var mode_page: VBoxContainer = _pages["modes"]
	for child in mode_page.get_children():
		if child.name == "LevelName":
			child.text = level_name if level_name != "" else "CUSTOM LEVEL"
	_name_edit.text = NetPlay.player_name
	_server_edit.text = NetPlay.signal_url
	_servers_name.text = NetPlay.player_name
	_code_edit.text = ""
	show()
	if standalone:
		_show_page("servers")
	elif NetPlay.is_in_room():
		_show_page("lobby")
	else:
		_show_page("modes")


func open_standalone() -> void:
	open("NETPLAY", true)


func close() -> void:
	hide()


func _show_page(page_name: String) -> void:
	_page = page_name
	for key in _pages.keys():
		_pages[key].visible = key == page_name
	_status.text = NetPlay.get_status().to_upper() if page_name != "modes" else ""
	await get_tree().process_frame
	var target := _first_focusable(_pages[page_name])
	if target != null:
		target.grab_focus()


func _show_modes() -> void:
	if NetPlay.is_in_room():
		return
	_show_page("modes")


func _show_online() -> void:
	_code_edit.text = ""
	_show_page("servers")


func _first_focusable(node: Node) -> Control:
	for child in node.get_children():
		if child is Button and child.visible and not child.disabled:
			return child
		if child is LineEdit and child.visible:
			return child
		var found := _first_focusable(child)
		if found != null:
			return found
	return null


func _process(_delta: float) -> void:
	if not visible:
		return
	if Global.multibind_action_just_pressed("ui_back"):
		var focus := get_viewport().gui_get_focus_owner()
		if focus is LineEdit:
			return
		_on_back()


func _on_back() -> void:
	match _page:
		"modes":
			_on_close()
		"servers":
			_on_close()
		"rooms":
			_show_online()
		"games":
			_show_online()
		"settings":
			_show_online()
		"lobby":
			_on_leave_room()


# --------------------------------------------------------------------------
# Buttons
# --------------------------------------------------------------------------

func _on_singleplayer() -> void:
	hide()
	singleplayer_chosen.emit()


func _on_close() -> void:
	hide()
	closed.emit()


func _on_create_room() -> void:
	if _busy:
		return
	_set_status("Choose the level for your server.")
	_show_page("games")
	_refresh_games()


func _refresh_games() -> void:
	if not is_instance_valid(_games_box):
		return
	for child in _games_box.get_children():
		child.queue_free()

	# Main games (campaigns)
	var campaigns := [
		{"id": "SMB1", "title": "SUPER MARIO BROS."},
		{"id": "SMBLL", "title": "SMB: LOST LEVELS"},
	]
	for entry in campaigns:
		var btn := Button.new()
		btn.text = str(entry["title"])
		btn.add_theme_font_size_override("font_size", 8)
		btn.pressed.connect(_on_pick_campaign.bind(str(entry["id"])))
		_games_box.add_child(btn)

	var lss := Button.new()
	lss.text = "LSS - LEVEL SHARE SQUARE"
	lss.add_theme_font_size_override("font_size", 8)
	lss.pressed.connect(_on_pick_lss)
	_games_box.add_child(lss)

	# Custom levels
	if LevelEditor.level_file is Dictionary and not LevelEditor.level_file.is_empty():
		var current := Button.new()
		var current_name := LevelEditor.level_name if LevelEditor.level_name != "" else "CUSTOM LEVEL"
		current.text = ("CURRENT LEVEL: " + current_name).to_upper()
		current.add_theme_font_size_override("font_size", 8)
		current.pressed.connect(_on_use_current_level)
		_games_box.add_child(current)

	var levels := _scan_levels()
	for entry in levels:
		var btn := Button.new()
		btn.text = str(entry["name"]).to_upper()
		btn.tooltip_text = "By " + str(entry["author"])
		btn.add_theme_font_size_override("font_size", 8)
		btn.pressed.connect(_on_pick_game.bind(entry))
		_games_box.add_child(btn)


func _scan_levels() -> Array:
	var found := []
	var roots := [
		Global.config_path.path_join("custom_levels"),
		Global.config_path.path_join("custom_levels/downloaded"),
	]
	for root in roots:
		var root_path := str(root)
		if not DirAccess.dir_exists_absolute(root_path):
			continue
		for file_name in DirAccess.get_files_at(root_path):
			var file_str := str(file_name)
			if not file_str.ends_with(".lvl"):
				continue
			var path := root_path.path_join(file_str)
			var data = JSONParser.parse_to_dict(path)
			if not (data is Dictionary) or data.is_empty():
				continue
			var info: Dictionary = data.get("Info", {})
			found.append({
				"path": path,
				"name": str(info.get("Name", file_str.get_basename())),
				"author": str(info.get("Author", "PLAYER")),
			})
	return found


func _on_use_current_level() -> void:
	_busy = true
	_set_status("Creating server...")
	NetPlay.level_mode = "custom"
	NetPlay.create_room(LevelEditor.level_name, _public_check.button_pressed)


## Host picked a main game (SMB1 / SMBS / SMBLL). The room starts at 1-1.
func _on_pick_campaign(campaign: String) -> void:
	NetPlay.level_mode = "campaign"
	NetPlay.campaign_id = campaign
	NetPlay.campaign_world = 1
	NetPlay.campaign_level = 1
	_busy = true
	_set_status("Creating server...")
	NetPlay.create_room(_campaign_title(campaign) + " 1-1", _public_check.button_pressed)


func _campaign_title(campaign: String) -> String:
	match campaign:
		"SMBS":
			return "SMB: SPECIAL"
		"SMBLL":
			return "SMB: LOST LEVELS"
		"SMBANN":
			return "ALL NIGHT NIPPON"
		_:
			return "SUPER MARIO BROS."


func _on_pick_lss() -> void:
	hide()
	lss_requested.emit()


func _on_pick_game(entry: Dictionary) -> void:
	var data = JSONParser.parse_to_dict(str(entry.get("path", "")))
	if not (data is Dictionary) or data.is_empty():
		_set_status("Could not read that level file.")
		return
	LevelEditor.level_file = data
	LevelEditor.level_name = str(entry.get("name", "CUSTOM LEVEL"))
	LevelEditor.level_author = str(entry.get("author", "PLAYER"))
	Global.current_game_mode = Global.GameMode.CUSTOM_LEVEL
	LevelEditor.load_play = true
	_busy = true
	_set_status("Creating server...")
	NetPlay.create_room(LevelEditor.level_name, _public_check.button_pressed)


func _on_browse_rooms() -> void:
	if _busy:
		return
	_busy = true
	_set_status("Looking for rooms...")
	NetPlay.request_rooms()


func _on_join_code() -> void:
	if _busy:
		return
	var code := _code_edit.text.strip_edges().to_upper()
	if code == "":
		_set_status("Type a room code first.")
		return
	_busy = true
	_set_status("Joining %s..." % code)
	NetPlay.join_room(code)


func _on_start_level() -> void:
	NetPlay.infinite_lives = _inf_lives.button_pressed
	NetPlay.infinite_time = _inf_time.button_pressed
	if NetPlay.level_mode == "campaign" and is_instance_valid(_world_select):
		NetPlay.campaign_world = _world_select.selected + 1
		NetPlay.campaign_level = _level_select.selected + 1
	if standalone:
		hide()
		NetPlay.start_level()
		return
	if NetPlay.level_mode != "campaign":
		NetPlay.capture_level()
	hide()
	host_start_requested.emit()


func _on_leave_room() -> void:
	NetPlay.leave_room()
	_show_online()


func _on_save_settings() -> void:
	NetPlay.set_player_name(_name_edit.text)
	NetPlay.set_server_url(_server_edit.text)
	_set_status("Saved.")
	_show_online()


# --------------------------------------------------------------------------
# NetPlay callbacks
# --------------------------------------------------------------------------

func _on_rooms_listed(rooms: Array) -> void:
	_busy = false
	for child in _rooms_box.get_children():
		child.queue_free()
	if rooms.is_empty():
		var empty := Label.new()
		empty.text = "NO PUBLIC ROOMS RIGHT NOW."
		empty.add_theme_font_size_override("font_size", 8)
		_rooms_box.add_child(empty)
	else:
		for room in rooms:
			var btn := Button.new()
			var level := str(room.get("level", "CUSTOM LEVEL"))
			var host := str(room.get("host", "PLAYER"))
			var count := int(room.get("players", 1))
			var max_players := int(room.get("max", NetPlay.MAX_PLAYERS))
			btn.text = ("%s  %s (%d/%d)" % [str(room.get("code", "?")), level, count, max_players]).to_upper()
			btn.tooltip_text = "Host: %s" % host
			btn.add_theme_font_size_override("font_size", 8)
			btn.pressed.connect(_on_room_button.bind(str(room.get("code", ""))))
			_rooms_box.add_child(btn)
	_show_page("rooms")
	_set_status("Rooms: %d" % rooms.size())


func _on_room_button(code: String) -> void:
	_busy = true
	_set_status("Joining %s..." % code)
	NetPlay.join_room(code)


func _on_lobby_joined() -> void:
	_busy = false
	_show_page("lobby")
	_refresh_lobby()


func _on_lobby_left() -> void:
	_busy = false
	if visible:
		_show_page("servers")


func _refresh_lobby() -> void:
	if not is_instance_valid(_players_box):
		return
	var players := NetPlay.get_peers_with_me()
	for child in _players_box.get_children():
		child.queue_free()
	for p in players:
		var line := Label.new()
		var marker := " (HOST)" if int(p.get("id", 0)) == 1 else ""
		line.text = ("- %s%s" % [str(p.get("name", "PLAYER")), marker]).to_upper()
		line.add_theme_font_size_override("font_size", 8)
		_players_box.add_child(line)
	_room_code_label.text = ("CODE: %s" % NetPlay.get_room_code()).to_upper()
	var shown_level := NetPlay.room_level_name
	if shown_level == "":
		shown_level = LevelEditor.level_name
	_room_level_label.text = shown_level.to_upper()
	if is_instance_valid(_character_btn):
		_character_btn.text = ("CHARACTER: " + Player.CHARACTERS[int(Global.player_characters[0])]).to_upper()
	_start_button.visible = NetPlay.is_host
	_start_button.disabled = !NetPlay.is_host
	_refresh_host_options()


func _refresh_host_options() -> void:
	if not is_instance_valid(_host_box):
		return
	var is_campaign := NetPlay.level_mode == "campaign"
	_host_box.visible = NetPlay.is_host
	if is_instance_valid(_campaign_row):
		_campaign_row.visible = is_campaign
	_inf_lives.button_pressed = NetPlay.infinite_lives
	_inf_time.button_pressed = NetPlay.infinite_time
	if not is_campaign:
		return
	if _host_campaign != NetPlay.campaign_id:
		_host_campaign = NetPlay.campaign_id
		_world_select.clear()
		var worlds := 13 if _host_campaign == "SMBLL" else 8
		for w in worlds:
			_world_select.add_item(str(w + 1))
		_world_select.selected = clampi(NetPlay.campaign_world - 1, 0, worlds - 1)
		_level_select.clear()
		for l in 4:
			_level_select.add_item(str(l + 1))
		_level_select.selected = clampi(NetPlay.campaign_level - 1, 0, 3)
		_inf_lives.button_pressed = NetPlay.infinite_lives


func _on_save_name() -> void:
	NetPlay.set_player_name(_servers_name.text)
	_set_status("Jugador: " + NetPlay.player_name)


func _on_error(message: String) -> void:
	_busy = false
	_set_status(message)
	if _page == "modes":
		_show_page("servers")


func _on_room_closed(reason: String) -> void:
	_busy = false
	_set_status(reason)
	_show_page("servers")


func _on_level_started() -> void:
	hide()


func _on_status_changed(text: String) -> void:
	if visible and text != "":
		_set_status(text)


func _set_status(text: String) -> void:
	if is_instance_valid(_status):
		_status.text = text.to_upper()

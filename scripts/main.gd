extends Node3D
## Game manager: menu/HUD, player input, bots, camera, round flow and the
## Supabase Realtime message handling.
##
## Round authority: the "host" (earliest joiner in the room's presence list)
## drives phase changes; every client mirrors them from broadcast events, so
## a new host can take over seamlessly if the old one leaves.

const SEND_INTERVAL := 0.1
const COUNTDOWN := 3.0
const ROUND_END_WAIT := 4.0
const CAM_OFFSET := Vector3(0, 7.5, 10.5)

enum Mode { MENU, ONLINE, PRACTICE }

var mode := Mode.MENU
var level: Level
var actors: Node3D
var cam: Camera3D
var cam_t := 0.0
var cam_scale := 1.0

var my_id := ""
var my_name := "Beast"
var my_color := 0
var room := "PUBLIC"
var beasts := {}  # id -> Beast
var local_ids: Array[String] = []
var players := {}  # presence: id -> meta
var bot_brains := {}

var phase := "lobby"  # lobby | countdown | playing | ending
var phase_timer := 0.0
var round_no := 0
var alive: Array = []
var wins := {}
var respawn_timers := {}
var send_timer := 0.0
var net_status := ""

var _shot_path := ""
var _shot_timer := 0.0

# UI
var menu: Control
var name_edit: LineEdit
var room_edit: LineEdit
var status_label: Label
var color_buttons: Array[Button] = []
var hud: Control
var info_label: Label
var board_label: Label
var center_label: Label
var center_timer := 0.0
var invite_button: Button


func _ready() -> void:
	randomize()
	_setup_input()
	level = Level.new()
	add_child(level)
	level.build()
	actors = Node3D.new()
	add_child(actors)
	cam = Camera3D.new()
	cam.fov = 55
	add_child(cam)
	cam.position = CAM_OFFSET
	_build_ui()
	Net.message.connect(_on_net)

	var url_room := Net.url_param("room")
	if url_room != "":
		room_edit.text = _clean_room(url_room)
	for arg in OS.get_cmdline_user_args():
		if arg == "--autopractice":
			_start_practice.call_deferred()
		elif arg.begins_with("--shot="):
			_shot_path = arg.trim_prefix("--shot=")
			_shot_timer = 6.0
		elif arg.begins_with("--cam-scale="):
			cam_scale = float(arg.trim_prefix("--cam-scale="))
		elif arg.begins_with("--shot-at="):
			_shot_timer = float(arg.trim_prefix("--shot-at="))


# ---------------------------------------------------------------- input

func _setup_input() -> void:
	_bind("move_left", [KEY_A, KEY_LEFT])
	_bind("move_right", [KEY_D, KEY_RIGHT])
	_bind("move_up", [KEY_W, KEY_UP])
	_bind("move_down", [KEY_S, KEY_DOWN])
	_bind("jump", [KEY_SPACE])
	_bind("punch", [KEY_J], MOUSE_BUTTON_LEFT)
	_bind("grab", [KEY_K], MOUSE_BUTTON_RIGHT)
	_bind("lift", [KEY_L, KEY_SHIFT])
	_bind("leave", [KEY_ESCAPE])


func _bind(action: String, keys: Array, mouse := -1) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for k in keys:
		var e := InputEventKey.new()
		e.physical_keycode = k
		InputMap.action_add_event(action, e)
	if mouse >= 0:
		var m := InputEventMouseButton.new()
		m.button_index = mouse
		InputMap.action_add_event(action, m)


func _unhandled_input(event: InputEvent) -> void:
	if mode == Mode.MENU:
		return
	if event.is_action_pressed("punch") and beasts.has(my_id):
		beasts[my_id].in_punch = true
	elif event.is_action_pressed("leave"):
		_leave_to_menu()


# ---------------------------------------------------------------- start / stop

func _start_practice() -> void:
	_read_menu()
	_clear_world()
	mode = Mode.PRACTICE
	my_id = "me"
	_spawn_local(my_id, my_name, my_color)
	for i in 3:
		var id := "bot%d" % i
		_spawn_local(id, "Bot %d" % (i + 1), (my_color + 2 + i * 2) % BeastLook.PALETTE.size())
		bot_brains[id] = {"think": 0.0, "target": null, "jitter": Vector2.ZERO, "grab_t": 0.0, "punch_cd": 1.0}
	_enter_game()


func _start_online() -> void:
	if not Net.available:
		status_label.text = "Online play needs the web build (Supabase Realtime)."
		return
	_read_menu()
	_clear_world()
	mode = Mode.ONLINE
	my_id = _rand_id()
	_spawn_local(my_id, my_name, my_color)
	net_status = "connecting"
	Net.join(room, {"id": my_id, "name": my_name, "color": my_color, "joined": int(Time.get_unix_time_from_system() * 1000.0)})
	_enter_game()
	_flash("Room %s - waiting for players..." % room, 3.0)


func _enter_game() -> void:
	phase = "lobby"
	menu.visible = false
	hud.visible = true
	invite_button.visible = mode == Mode.ONLINE
	get_viewport().gui_release_focus()


func _leave_to_menu() -> void:
	if mode == Mode.ONLINE:
		Net.leave()
	_clear_world()
	mode = Mode.MENU
	menu.visible = true
	hud.visible = false


func _clear_world() -> void:
	for b in beasts.values():
		b.queue_free()
	beasts.clear()
	local_ids.clear()
	bot_brains.clear()
	respawn_timers.clear()
	players.clear()
	alive.clear()
	wins.clear()
	phase = "lobby"
	phase_timer = 0.0
	round_no = 0


func _spawn_local(id: String, nm: String, color_idx: int) -> Beast:
	var b := Beast.new()
	actors.add_child(b)
	b.setup(id, nm, color_idx, false, level.spawns[randi() % 7])
	b.hit_remote.connect(_on_hit_remote)
	b.hand_lookup = _hand_lookup
	beasts[id] = b
	local_ids.append(id)
	return b


func _spawn_puppet(id: String, meta: Dictionary) -> void:
	var b := Beast.new()
	actors.add_child(b)
	b.setup(id, _clean_name(str(meta.get("name", "Beast"))), int(meta.get("color", 0)), true, Vector3(0, -200, 0))
	b.set_active(false)  # appears with its first snapshot
	beasts[id] = b


# ---------------------------------------------------------------- frame loop

func _physics_process(_dt: float) -> void:
	if mode == Mode.MENU:
		return
	var me: Beast = beasts.get(my_id)
	if me:
		me.in_move = Input.get_vector("move_left", "move_right", "move_up", "move_down")
		me.in_jump = Input.is_action_pressed("jump")
		me.in_grab = Input.is_action_pressed("grab")
		me.in_lift = Input.is_action_pressed("lift")
	for id in bot_brains:
		_bot_tick(beasts[id], bot_brains[id], _dt)


func _process(dt: float) -> void:
	_update_camera(dt)
	_tick_flash(dt)
	if _shot_path != "":
		_shot_timer -= dt
		if _shot_timer <= 0.0:
			get_viewport().get_texture().get_image().save_png(_shot_path)
			get_tree().quit()
	if mode == Mode.MENU:
		return
	phase_timer = maxf(phase_timer - dt, 0.0)
	_check_falls(dt)
	if _is_host():
		_host_tick()
	if mode == Mode.ONLINE:
		send_timer -= dt
		if send_timer <= 0.0 and beasts.has(my_id):
			send_timer = SEND_INTERVAL
			Net.send("st", beasts[my_id].pack_state())
	_update_hud()


func _check_falls(dt: float) -> void:
	for id in local_ids:
		var b: Beast = beasts[id]
		if b.active and b.body.global_position.y < Level.KILL_Y:
			b.set_active(false)
			if phase == "playing" and alive.has(id):
				_emit({"k": "out", "id": id})
			else:
				respawn_timers[id] = 1.5
	for id in respawn_timers.keys():
		respawn_timers[id] -= dt
		if respawn_timers[id] <= 0.0:
			respawn_timers.erase(id)
			if beasts.has(id) and (phase != "playing" or alive.has(id)):
				beasts[id].respawn(level.spawns[randi() % 7])


# ---------------------------------------------------------------- rounds

func _participants() -> Array:
	var ids: Array = players.keys() if mode == Mode.ONLINE else beasts.keys()
	if mode == Mode.ONLINE and not ids.has(my_id):
		ids.append(my_id)
	ids.sort()
	return ids


func _host_id() -> String:
	if mode != Mode.ONLINE or players.is_empty():
		return my_id
	var best := ""
	var best_t := INF
	for id in players:
		var t := float(players[id].get("joined", 0))
		if t < best_t or (t == best_t and id < best):
			best_t = t
			best = id
	return best


func _is_host() -> bool:
	return _host_id() == my_id


func _host_tick() -> void:
	var ids := _participants()
	match phase:
		"lobby":
			if ids.size() >= 2:
				_emit({"k": "countdown"})
		"countdown":
			if phase_timer <= 0.0:
				if ids.size() >= 2:
					_emit({"k": "round_start", "n": round_no + 1, "ids": ids})
				else:
					_emit({"k": "lobby"})
		"playing":
			alive = alive.filter(func(id): return ids.has(id))
			if alive.size() <= 1:
				var winner: String = alive[0] if alive.size() == 1 else ""
				var w := wins.duplicate()
				if winner != "":
					w[winner] = int(w.get(winner, 0)) + 1
				_emit({"k": "round_end", "winner": winner, "wins": w})
		"ending":
			if phase_timer <= 0.0:
				_emit({"k": "countdown"} if ids.size() >= 2 else {"k": "lobby"})


func _emit(d: Dictionary) -> void:
	if mode == Mode.ONLINE:
		Net.send("ev", d)
	_handle_event(d)


func _handle_event(d: Dictionary) -> void:
	match str(d.get("k", "")):
		"hit":
			var to := str(d.get("to", ""))
			if local_ids.has(to):
				var imp: Array = d.get("imp", [0, 0, 0])
				beasts[to].receive_hit(int(d.get("part", 0)), Vector3(imp[0], imp[1], imp[2]), float(d.get("dmg", 1)))
		"countdown":
			phase = "countdown"
			phase_timer = COUNTDOWN
		"round_start":
			phase = "playing"
			round_no = int(d.get("n", 1))
			alive = d.get("ids", []).map(func(x): return str(x))
			respawn_timers.clear()
			for id in local_ids:
				var i := alive.find(id)
				if i >= 0:
					beasts[id].respawn(level.spawns[i % level.spawns.size()])
				else:
					beasts[id].set_active(false)
			_flash("ROUND %d - FIGHT!" % round_no, 2.0)
		"out":
			var id := str(d.get("id", ""))
			alive.erase(id)
			_flash("%s fell off!" % _name_of(id), 1.8)
		"round_end":
			phase = "ending"
			phase_timer = ROUND_END_WAIT
			wins = d.get("wins", {})
			var winner := str(d.get("winner", ""))
			_flash(("%s WINS!" % _name_of(winner)) if winner != "" else "DRAW!", 3.5)
		"lobby":
			phase = "lobby"
			for id in local_ids:
				if not beasts[id].active:
					beasts[id].respawn(level.spawns[randi() % 7])
		"sync":
			if _is_host():
				return
			phase = str(d.get("phase", "lobby"))
			round_no = int(d.get("n", 0))
			alive = d.get("alive", []).map(func(x): return str(x))
			wins = d.get("wins", {})
			phase_timer = float(d.get("timer", 0))
			if phase == "playing" and not alive.has(my_id) and beasts.has(my_id):
				beasts[my_id].set_active(false)
				_flash("Round in progress - you join next round", 3.0)


# ---------------------------------------------------------------- network

func _on_net(event: String, p: Variant) -> void:
	if mode != Mode.ONLINE or typeof(p) != TYPE_DICTIONARY:
		return
	match event:
		"status":
			net_status = str(p.get("s", ""))
			if net_status != "SUBSCRIBED":
				_flash("Connection: %s" % net_status, 2.5)
		"presence":
			_on_presence(p.get("players", []))
		"st":
			_on_state(p)
		"ev":
			_handle_event(p)


func _on_presence(list: Array) -> void:
	var now := {}
	for m in list:
		if typeof(m) == TYPE_DICTIONARY and m.has("id"):
			now[str(m.id)] = m
	var someone_joined := false
	for id in now:
		if id != my_id and not beasts.has(id):
			_spawn_puppet(id, now[id])
			someone_joined = true
			_flash("%s joined" % _name_of(id), 1.5)
	for id in beasts.keys():
		if id != my_id and not now.has(id):
			_flash("%s left" % _name_of(id), 1.5)
			beasts[id].queue_free()
			beasts.erase(id)
			alive.erase(id)
	players = now
	if someone_joined and _is_host():
		Net.send("ev", {"k": "sync", "phase": phase, "n": round_no, "alive": alive, "wins": wins, "timer": phase_timer})


func _on_state(d: Dictionary) -> void:
	var id := str(d.get("id", ""))
	var b: Beast = beasts.get(id)
	if b == null or not b.is_puppet:
		return
	b.push_state(d)
	for g in d.get("g", []):
		if str(g[0]) == my_id and beasts.has(my_id):
			beasts[my_id].refresh_remote_grab(id, int(g[2]), int(g[1]))


func _on_hit_remote(owner_id: String, part: int, impulse: Vector3, dmg: float) -> void:
	if mode == Mode.ONLINE:
		Net.send("ev", {"k": "hit", "to": owner_id, "part": part,
			"imp": [snappedf(impulse.x, 0.01), snappedf(impulse.y, 0.01), snappedf(impulse.z, 0.01)], "dmg": dmg})


func _hand_lookup(owner_id: String, hand: int) -> Variant:
	var b: Beast = beasts.get(owner_id)
	if b == null or not b.active:
		return null
	return b.hand_pos(hand)


# ---------------------------------------------------------------- bots

func _bot_tick(b: Beast, brain: Dictionary, dt: float) -> void:
	b.in_jump = false
	if not b.active or b.is_stunned():
		b.in_move = Vector2.ZERO
		b.in_grab = false
		b.in_lift = false
		return
	var pos := b.body.global_position
	brain.think -= dt
	brain.punch_cd -= dt
	brain.grab_t -= dt
	if brain.think <= 0.0:
		brain.think = randf_range(0.25, 0.6)
		brain.jitter = Vector2(randf_range(-0.5, 0.5), randf_range(-0.5, 0.5))
		var best: Beast = null
		var best_d := INF
		for o in beasts.values():
			if o != b and o.active:
				var dd := pos.distance_to(o.body.global_position)
				if dd < best_d:
					best_d = dd
					best = o
		brain.target = best
	var tgt: Beast = brain.target
	if tgt == null or not is_instance_valid(tgt) or not tgt.active:
		b.in_move = Vector2(-pos.x, -pos.z).limit_length(1.0) * 0.5
		b.in_grab = false
		return
	var to := tgt.body.global_position - pos
	var dist := Vector2(to.x, to.z).length()
	var dir := Vector2(to.x, to.z).normalized()
	if brain.grab_t > 0.0:
		# Drag the victim toward the nearest deck edge.
		var edge := Vector2(signf(pos.x), 0) if absf(pos.x) / 8.0 > absf(pos.z) / 5.5 else Vector2(0, signf(pos.z))
		b.in_grab = true
		b.in_lift = brain.grab_t < 0.7
		b.in_move = edge * 0.8
		return
	b.in_grab = false
	b.in_lift = false
	if not level.is_safe(pos):
		dir = (dir + Vector2(-pos.x, -pos.z).normalized() * 1.3).normalized()
	b.in_move = (dir + brain.jitter * 0.4).limit_length(1.0) * (0.3 if dist < 1.2 else 1.0)
	if dist < 1.8 and brain.punch_cd <= 0.0:
		b.in_punch = true
		brain.punch_cd = randf_range(0.4, 0.9)
	if dist < 1.3 and randf() < 0.012:
		brain.grab_t = 2.2
	if randf() < 0.004 or (to.y > 1.0 and dist < 3.0 and randf() < 0.05):
		b.in_jump = true


# ---------------------------------------------------------------- camera

func _update_camera(dt: float) -> void:
	if mode == Mode.MENU:
		cam_t += dt * 0.12
		cam.position = Vector3(sin(cam_t) * 17.0, 8.0, cos(cam_t) * 17.0)
		cam.look_at(Vector3(0, 0.5, 0))
		return
	var focus := Vector3(0, 0.5, 0)
	var me: Beast = beasts.get(my_id)
	if me and me.active:
		focus = me.body.global_position
	else:
		var n := 0
		var sum := Vector3.ZERO
		for b in beasts.values():
			if b.active:
				sum += b.body.global_position
				n += 1
		if n > 0:
			focus = sum / n
	focus.y = clampf(focus.y, -2.0, 6.0)
	cam.position = cam.position.lerp(focus + CAM_OFFSET * cam_scale, 1.0 - exp(-dt * 4.0))
	cam.look_at(cam.position - CAM_OFFSET * cam_scale)


# ---------------------------------------------------------------- UI

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var theme := Theme.new()
	theme.default_font_size = 20
	var panel_box := StyleBoxFlat.new()
	panel_box.bg_color = Color(0.08, 0.09, 0.14, 0.88)
	panel_box.set_corner_radius_all(18)
	panel_box.set_content_margin_all(28)
	theme.set_stylebox("panel", "PanelContainer", panel_box)
	for state in ["normal", "hover", "pressed", "focus"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = {"normal": Color(0.95, 0.55, 0.15), "hover": Color(1, 0.65, 0.25),
			"pressed": Color(0.8, 0.42, 0.1), "focus": Color(0.95, 0.55, 0.15)}[state]
		sb.set_corner_radius_all(12)
		sb.set_content_margin_all(12)
		theme.set_stylebox(state, "Button", sb)

	# Menu
	menu = CenterContainer.new()
	menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu.theme = theme
	layer.add_child(menu)
	var panel := PanelContainer.new()
	menu.add_child(panel)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 12)
	vb.custom_minimum_size = Vector2(420, 0)
	panel.add_child(vb)
	var title := Label.new()
	title.text = "BEAST BRAWL"
	title.add_theme_font_size_override("font_size", 56)
	title.add_theme_color_override("font_color", Color(1, 0.8, 0.25))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var sub := Label.new()
	sub.text = "Wobbly online brawler - throw them off the roof!"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 16)
	vb.add_child(sub)
	name_edit = _field(vb, "Name", "Beast")
	name_edit.max_length = 12
	room_edit = _field(vb, "Room", "PUBLIC")
	room_edit.max_length = 12
	var cl := Label.new()
	cl.text = "Color"
	vb.add_child(cl)
	var crow := HBoxContainer.new()
	crow.add_theme_constant_override("separation", 8)
	vb.add_child(crow)
	for i in BeastLook.PALETTE.size():
		var cb := Button.new()
		cb.custom_minimum_size = Vector2(40, 40)
		for state in ["normal", "hover", "pressed", "focus"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = BeastLook.PALETTE[i]
			sb.set_corner_radius_all(20)
			cb.add_theme_stylebox_override(state, sb)
		cb.pressed.connect(_pick_color.bind(i))
		crow.add_child(cb)
		color_buttons.append(cb)
	_pick_color(randi() % BeastLook.PALETTE.size())
	var online := Button.new()
	online.text = "PLAY ONLINE"
	online.pressed.connect(_start_online)
	vb.add_child(online)
	var practice := Button.new()
	practice.text = "PRACTICE vs BOTS"
	practice.pressed.connect(_start_practice)
	vb.add_child(practice)
	status_label = Label.new()
	status_label.add_theme_color_override("font_color", Color(1, 0.6, 0.6))
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vb.add_child(status_label)
	var help := Label.new()
	help.text = "WASD move | Space jump | J / LMB punch\nK / RMB hold grab | + Shift/L lift & throw | Esc leave"
	help.add_theme_font_size_override("font_size", 15)
	help.add_theme_color_override("font_color", Color(0.75, 0.78, 0.85))
	help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(help)

	# HUD
	hud = Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.theme = theme
	hud.visible = false
	layer.add_child(hud)
	info_label = _hud_label(Vector2(20, 16), 18)
	board_label = _hud_label(Vector2(0, 16), 18)
	board_label.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	board_label.offset_left = -300
	board_label.offset_right = -20
	board_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	center_label = _hud_label(Vector2.ZERO, 46)
	center_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	center_label.offset_left = -500
	center_label.offset_right = 500
	center_label.offset_top = 110
	center_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	center_label.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
	var hint := _hud_label(Vector2.ZERO, 15)
	hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	hint.offset_left = -500
	hint.offset_right = 500
	hint.offset_top = -40
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.text = "WASD move  |  Space jump  |  J/LMB punch  |  K/RMB grab  |  Shift lift & throw  |  Esc leave"
	invite_button = Button.new()
	invite_button.text = "Copy invite link"
	invite_button.position = Vector2(20, 120)
	invite_button.add_theme_font_size_override("font_size", 15)
	invite_button.focus_mode = Control.FOCUS_NONE
	invite_button.pressed.connect(func():
		Net.copy_invite(room)
		_flash("Invite link copied!", 1.5))
	hud.add_child(invite_button)


func _field(parent: Control, label: String, value: String) -> LineEdit:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(70, 0)
	row.add_child(l)
	var e := LineEdit.new()
	e.text = value
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(e)
	return e


func _hud_label(pos: Vector2, size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_constant_override("outline_size", 8)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(l)
	return l


func _pick_color(i: int) -> void:
	my_color = i
	for j in color_buttons.size():
		for state in ["normal", "hover", "pressed", "focus"]:
			var sb: StyleBoxFlat = color_buttons[j].get_theme_stylebox(state)
			sb.set_border_width_all(4 if j == i else 0)
			sb.border_color = Color.WHITE


func _read_menu() -> void:
	my_name = _clean_name(name_edit.text)
	room = _clean_room(room_edit.text)
	room_edit.text = room


func _update_hud() -> void:
	var lines: Array[String] = []
	if mode == Mode.ONLINE:
		lines.append("Room: %s   (%s)" % [room, net_status])
		lines.append("Players: %d%s" % [_participants().size(), "   [host]" if _is_host() else ""])
	else:
		lines.append("Practice vs bots")
	var ph := {"lobby": "Waiting for players", "countdown": "Get ready... %d" % ceili(phase_timer),
		"playing": "Round %d - %d alive" % [round_no, alive.size()], "ending": "Round over"}
	lines.append(ph.get(phase, phase))
	info_label.text = "\n".join(lines)
	var board: Array[String] = ["SCORE"]
	for id in _participants():
		var mark := "" if phase != "playing" or alive.has(id) else "  x"
		board.append("%s  %d%s" % [_name_of(id), int(wins.get(id, 0)), mark])
	board_label.text = "\n".join(board)


func _flash(text: String, secs: float) -> void:
	center_label.text = text
	center_timer = secs


func _tick_flash(dt: float) -> void:
	if center_timer > 0.0:
		center_timer -= dt
		if center_timer <= 0.0:
			center_label.text = ""
	if center_timer <= 0.0:
		var counting := mode != Mode.MENU and phase == "countdown"
		center_label.text = ("Next round in %d" % ceili(phase_timer)) if counting else ""


# ---------------------------------------------------------------- helpers

func _name_of(id: String) -> String:
	if beasts.has(id):
		return beasts[id].display_name
	if players.has(id):
		return str(players[id].get("name", "?"))
	return "?"


func _clean_name(s: String) -> String:
	s = s.strip_edges().left(12)
	return s if s != "" else "Beast"


func _clean_room(s: String) -> String:
	var out := ""
	for ch in s.strip_edges().to_upper():
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch == "-":
			out += ch
	out = out.left(12)
	return out if out != "" else "PUBLIC"


func _rand_id() -> String:
	return "%08x" % (randi() & 0x7fffffff)

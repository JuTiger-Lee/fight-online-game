class_name Beast
extends Node3D
## Wobbly ragdoll brawler. A local beast simulates its own physics (balance,
## hover legs, arm springs, grabs). A puppet beast mirrors a remote player:
## its parts are kinematic and follow interpolated network snapshots.

signal hit_remote(owner_id: String, part: int, impulse: Vector3, dmg: float)

enum Part { BODY, ARM_L, ARM_R, LEG_L, LEG_R }
enum ArmMode { LIMP, IDLE, REACH, LIFT, PUNCH }

const LAYER_WORLD := 1
const LAYER_BEAST := 2
const LAYER_PUPPET := 4

const BODY_R := 0.44
const BODY_H := 1.0
const HEAD_R := 0.44
const HEAD_Y := 0.66
const SHOULDER := Vector3(0.52, 0.16, 0.0)
const HIP := Vector3(0.2, -0.4, 0.0)
const ARM_RAD := 0.13
const ARM_LEN := 0.72
const HAND_OFF := 0.31
const LEG_RAD := 0.15
const LEG_LEN := 0.6
const FOOT_OFF := 0.25
const STAND_H := 0.95
const SPEED := 4.3
const JUMP_SPEED := 5.2
const PUNCH_TIME := 0.3
const PUNCH_IMPULSE := 26.0
const DIZZY_LIMIT := 3.0
const STUN_TIME := 3.0
const INTERP_MS := 140.0

var net_id := ""
var display_name := ""
var color := Color.RED
var is_puppet := false
var active := true
var hand_lookup: Callable  # (owner_id: String, hand: int) -> Vector3, for remote grabs

var parts: Array[RigidBody3D] = []
var body: RigidBody3D
var total_mass := 0.0

# Input, written by the player controller / bot AI every physics frame.
var in_move := Vector2.ZERO
var in_jump := false
var in_punch := false
var in_grab := false
var in_lift := false

var facing := Vector3.FORWARD
var grounded := false
var stun_t := 0.0
var stagger_t := 0.0
var getup_t := 0.0
var dizzy := 0.0
var jump_cd := 0.0
var hover_lock := 0.0
var punch_t := 0.0
var punch_side := 1
var walk_phase := 0.0
var gait := 0.0  # 0 = standing still, 1 = full-speed walk
var _move_dir := Vector3.FORWARD

var _rids: Array[RID] = []
var _rest: Array[Vector3] = []
var _layers: Array[int] = []
var _grabs: Array = [null, null]  # per hand: {joint, target, owner_id, part}
var _remote_grabs := {}  # "grabber:hand" -> {by, hand, part, until}
var _punched := {}
var _probe := SphereShape3D.new()

var _snaps: Array = []
var _offsets: Array[float] = []
var _offset := 0.0
var _remote_stunned := false

var _label: Label3D
var _stars: Label3D


func setup(id: String, nm: String, color_idx: int, puppet: bool, at: Vector3) -> void:
	net_id = id
	display_name = nm
	color = BeastLook.PALETTE[color_idx % BeastLook.PALETTE.size()]
	is_puppet = puppet
	_build(at)
	BeastLook.new().dress(self, color_idx)


# ---------------------------------------------------------------- building

func _build(at: Vector3) -> void:
	# Body: jelly-bean capsule + head sphere, one rigid body (visuals in BeastLook).
	body = _make_part(Part.BODY, 7.0, at)
	var cap := CapsuleShape3D.new()
	cap.radius = BODY_R
	cap.height = BODY_H
	_add_shape(body, cap, Vector3.ZERO)
	var head := SphereShape3D.new()
	head.radius = HEAD_R
	_add_shape(body, head, Vector3(0, HEAD_Y, 0))
	body.angular_damp = 1.5
	body.linear_damp = 0.2

	for side in [-1, 1]:
		var shoulder := at + Vector3(SHOULDER.x * side, SHOULDER.y, 0)
		var arm := _make_part(Part.ARM_L if side < 0 else Part.ARM_R, 0.5, shoulder - Vector3(0, HAND_OFF, 0))
		var acap := CapsuleShape3D.new()
		acap.radius = ARM_RAD
		acap.height = ARM_LEN
		_add_shape(arm, acap, Vector3.ZERO)
		var am := CapsuleMesh.new()
		am.radius = ARM_RAD - 0.01
		am.height = ARM_LEN - 0.08
		_add_mesh(arm, am, _limb_mat(), Vector3(0, 0.04, 0))
		arm.linear_damp = 0.6
		arm.angular_damp = 1.0
	for side in [-1, 1]:
		var hip := at + Vector3(HIP.x * side, HIP.y, 0)
		var leg := _make_part(Part.LEG_L if side < 0 else Part.LEG_R, 0.6, hip - Vector3(0, FOOT_OFF, 0))
		var lcap := CapsuleShape3D.new()
		lcap.radius = LEG_RAD
		lcap.height = LEG_LEN
		_add_shape(leg, lcap, Vector3.ZERO)
		var lm := CapsuleMesh.new()
		lm.radius = LEG_RAD
		lm.height = LEG_LEN - 0.1
		_add_mesh(leg, lm, _limb_mat(), Vector3(0, 0.05, 0))
		leg.linear_damp = 0.8
		leg.angular_damp = 2.0
		# Legs only touch other beasts; the hover spring does the standing.
		if not is_puppet:
			leg.collision_mask = LAYER_BEAST | LAYER_PUPPET

	parts.sort_custom(func(a, b): return a.get_meta("part") < b.get_meta("part"))
	for p in parts:
		total_mass += p.mass
		_rids.append(p.get_rid())
		_rest.append(p.position - at)
		_layers.append(p.collision_layer)
	for i in parts.size():
		for j in range(i + 1, parts.size()):
			parts[i].add_collision_exception_with(parts[j])

	if not is_puppet:
		_pin(body, parts[Part.ARM_L], at + Vector3(-SHOULDER.x, SHOULDER.y, 0))
		_pin(body, parts[Part.ARM_R], at + Vector3(SHOULDER.x, SHOULDER.y, 0))
		_pin(body, parts[Part.LEG_L], at + Vector3(-HIP.x, HIP.y, 0))
		_pin(body, parts[Part.LEG_R], at + Vector3(HIP.x, HIP.y, 0))

	_label = Label3D.new()
	_label.text = display_name
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.font_size = 56
	_label.outline_size = 14
	_label.pixel_size = 0.004
	_label.modulate = color.lightened(0.35)
	_label.no_depth_test = true
	_label.top_level = true
	add_child(_label)
	_stars = Label3D.new()
	_stars.text = "* @ *"
	_stars.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_stars.font_size = 64
	_stars.outline_size = 12
	_stars.pixel_size = 0.004
	_stars.modulate = Color(1, 0.9, 0.2)
	_stars.top_level = true
	_stars.visible = false
	add_child(_stars)


func _make_part(idx: int, mass: float, pos: Vector3) -> RigidBody3D:
	var rb := RigidBody3D.new()
	rb.mass = mass
	rb.position = pos
	rb.can_sleep = false
	rb.set_meta("beast", self)
	rb.set_meta("part", idx)
	var pm := PhysicsMaterial.new()
	pm.friction = 0.8
	rb.physics_material_override = pm
	if is_puppet:
		rb.freeze = true
		rb.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		rb.collision_layer = LAYER_PUPPET
		rb.collision_mask = 0
	else:
		rb.collision_layer = LAYER_BEAST
		rb.collision_mask = LAYER_WORLD | LAYER_BEAST | LAYER_PUPPET
	add_child(rb)
	parts.append(rb)
	return rb


func _add_shape(rb: RigidBody3D, shape: Shape3D, offset: Vector3) -> void:
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = offset
	rb.add_child(cs)


func _add_mesh(parent: Node3D, mesh: Mesh, mat: Material, offset: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = offset
	parent.add_child(mi)
	return mi


func _limb_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.5
	m.rim_enabled = true
	m.rim = 0.25
	m.rim_tint = 0.6
	return m


func _pin(a: RigidBody3D, b: RigidBody3D, at: Vector3) -> PinJoint3D:
	var j := PinJoint3D.new()
	add_child(j)
	j.global_position = at
	j.node_a = j.get_path_to(a)
	j.node_b = j.get_path_to(b)
	return j


# ---------------------------------------------------------------- public api

func hand_pos(hand: int) -> Vector3:
	var arm := parts[Part.ARM_L + hand]
	return arm.to_global(Vector3(0, -HAND_OFF, 0))


func is_stunned() -> bool:
	return _remote_stunned if is_puppet else stun_t > 0.0


func receive_hit(part: int, impulse: Vector3, dmg: float) -> void:
	if not active or is_puppet:
		return
	parts[clampi(part, 0, parts.size() - 1)].apply_central_impulse(impulse * 0.35)
	body.apply_central_impulse(impulse * 0.65)
	stagger_t = 0.4
	if stun_t > 0.0:
		stun_t = minf(stun_t + 0.5, 5.0)
		return
	dizzy += dmg
	if dizzy >= DIZZY_LIMIT:
		stun(STUN_TIME)


func stun(t: float) -> void:
	stun_t = t
	dizzy = 0.0
	release_all()


func release_all() -> void:
	for h in 2:
		_release(h)


func respawn(at: Vector3) -> void:
	release_all()
	_remote_grabs.clear()
	stun_t = 0.0
	stagger_t = 0.0
	getup_t = 0.0
	dizzy = 0.0
	facing = Vector3.FORWARD
	set_active(true)
	for i in parts.size():
		var p := parts[i]
		p.global_transform = Transform3D(Basis(), at + _rest[i])
		p.linear_velocity = Vector3.ZERO
		p.angular_velocity = Vector3.ZERO


func set_active(on: bool) -> void:
	if on == active:
		return
	active = on
	visible = on
	_label.visible = on
	if not on:
		_stars.visible = false
		release_all()
		_remote_grabs.clear()
	for i in parts.size():
		var p := parts[i]
		p.collision_layer = _layers[i] if on else 0
		if not is_puppet:
			p.freeze = not on
	if not on:
		for i in parts.size():
			parts[i].global_transform = Transform3D(Basis(), Vector3(0, -200, 0) + _rest[i])


## Called when a remote player's snapshot says they are holding one of our parts.
func refresh_remote_grab(by_id: String, hand: int, part: int) -> void:
	if not active or is_puppet:
		return
	_remote_grabs["%s:%d" % [by_id, hand]] = {
		"by": by_id, "hand": hand, "part": clampi(part, 0, parts.size() - 1),
		"until": Time.get_ticks_msec() + 400,
	}


func pack_state() -> Dictionary:
	var p: Array = []
	for part in parts:
		var o := part.global_position
		var q := part.global_basis.get_rotation_quaternion()
		for v in [o.x, o.y, o.z, q.x, q.y, q.z, q.w]:
			p.append(snappedf(v, 0.001))
	var g: Array = []
	for h in 2:
		var gr = _grabs[h]
		if gr != null and gr.owner_id != "":
			g.append([gr.owner_id, gr.part, h])
	return {
		"id": net_id, "t": Time.get_ticks_msec(), "p": p,
		"h": 0 if active else 1, "s": 1 if stun_t > 0.0 else 0, "g": g,
	}


func push_state(d: Dictionary) -> void:
	var t := float(d.get("t", 0))
	var now := float(Time.get_ticks_msec())
	_offsets.append(now - t)
	if _offsets.size() > 30:
		_offsets.pop_front()
	_offset = _offsets.min()
	if not _snaps.is_empty() and t <= _snaps[-1].t:
		return
	var p: Array = d.get("p", [])
	if p.size() < parts.size() * 7:
		return
	_snaps.append({"t": t, "p": p})
	if _snaps.size() > 24:
		_snaps.pop_front()
	_remote_stunned = int(d.get("s", 0)) == 1
	var hidden := int(d.get("h", 0)) == 1
	if hidden == active:
		set_active(not hidden)
		_snaps = [_snaps[-1]]


# ---------------------------------------------------------------- simulation

func _physics_process(dt: float) -> void:
	if is_puppet:
		_puppet_update()
	elif active:
		_simulate(dt)
	_update_labels()


func _simulate(dt: float) -> void:
	jump_cd = maxf(jump_cd - dt, 0.0)
	hover_lock = maxf(hover_lock - dt, 0.0)
	dizzy = maxf(dizzy - dt * 0.5, 0.0)
	if stun_t > 0.0:
		stun_t -= dt
		if stun_t <= 0.0:
			getup_t = 0.8
	var stunned := stun_t > 0.0
	var bal := 0.0 if stunned else 1.0
	if getup_t > 0.0:
		getup_t -= dt
		bal *= lerpf(1.0, 0.25, getup_t / 0.8)
	if stagger_t > 0.0:
		stagger_t -= dt
		bal *= 0.3

	var space := get_world_3d().direct_space_state
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
	var t := Time.get_ticks_msec() * 0.001

	# Gait: cadence and stride follow actual ground speed.
	var vh := Vector3(body.linear_velocity.x, 0, body.linear_velocity.z)
	var target_gait := clampf(vh.length() / SPEED, 0.0, 1.2) if grounded and not stunned else 0.0
	gait = lerpf(gait, target_gait, minf(dt * 8.0, 1.0))
	if vh.length() > 0.3:
		_move_dir = vh.normalized()
	walk_phase = fmod(walk_phase + dt * lerpf(5.0, 12.5, minf(gait, 1.0)) * (1.0 if gait > 0.05 else 0.0), TAU)
	# Body bobs up at mid-stance, dips at foot-strike; gentle breathing at rest.
	var stand := STAND_H - 0.05 * gait + absf(cos(walk_phase)) * 0.08 * gait + sin(t * 2.4) * 0.015 * (1.0 - minf(gait, 1.0))

	# Hover "legs": a spring that keeps the body at standing height.
	var origin := body.global_position
	var ray := PhysicsRayQueryParameters3D.create(origin, origin + Vector3.DOWN * (STAND_H + 0.6),
		LAYER_WORLD | LAYER_BEAST | LAYER_PUPPET, _rids)
	var hit := space.intersect_ray(ray)
	var dist := INF
	if not hit.is_empty():
		dist = origin.distance_to(hit.position)
	grounded = dist < STAND_H + 0.2
	if bal > 0.0 and hover_lock <= 0.0 and dist < STAND_H + 0.45:
		var err := stand - dist
		var f := (err * 70.0 - body.linear_velocity.y * 9.0 + g) * total_mass * bal
		if f > 0.0:
			body.apply_central_force(Vector3.UP * f)
			var under = hit.collider
			if under is RigidBody3D and not under.freeze:
				under.apply_force(Vector3.DOWN * f * 0.5, hit.position - under.global_position)

	# Upright + facing torque (PD controller), scaled by body inertia.
	var mv := Vector3(in_move.x, 0, in_move.y)
	if mv.length() > 1.0:
		mv = mv.normalized()
	if not stunned and mv.length() > 0.15:
		facing = mv.normalized()
	# Lean into the walk and waddle side to side over the stance foot.
	var lean := 0.17 * minf(gait, 1.0)
	var roll := sin(walk_phase) * 0.13 * minf(gait, 1.0)
	var desired := Basis.looking_at(facing, Vector3.UP) * Basis(Vector3.RIGHT, -lean) * Basis(Vector3.FORWARD, roll)
	var qe := (Quaternion(desired) * body.global_basis.orthonormalized().get_rotation_quaternion().inverse()).normalized()
	if qe.w < 0.0:
		qe = -qe
	var ang := qe.get_angle()
	var axis := qe.get_axis() if ang > 0.001 else Vector3.UP
	var inv := PhysicsServer3D.body_get_direct_state(body.get_rid()).inverse_inertia
	var inertia := 1.0 / maxf(inv.x, 0.001)
	var torque := (axis * ang * 55.0 - body.angular_velocity * 9.0) * inertia * bal
	body.apply_torque(torque)

	# Walking.
	if not stunned:
		var speed := SPEED * (0.55 if _holding() else 1.0)
		var accel := (9.0 if mv.length() > 0.1 else 5.0) if grounded else 2.0
		body.apply_central_force((mv * speed - vh) * accel * total_mass * maxf(bal, 0.15))
		if in_jump and grounded and jump_cd <= 0.0 and bal > 0.5:
			body.apply_central_impulse(Vector3.UP * JUMP_SPEED * total_mass * 0.85)
			jump_cd = 0.55
			hover_lock = 0.3

	_drive_legs(bal)
	_drive_arms(dt, stunned, space, t)
	_apply_remote_grabs()
	in_punch = false


func _drive_legs(bal: float) -> void:
	if bal <= 0.0:
		return
	var amp := minf(gait, 1.0)
	var flat_fw := Vector3(facing.x, 0, facing.z).normalized()
	var flat_rt := flat_fw.cross(Vector3.UP)
	for side: int in [-1, 1]:
		var leg := parts[Part.LEG_L if side < 0 else Part.LEG_R]
		var hip := body.to_global(Vector3(HIP.x * side, HIP.y, 0))
		var ph := walk_phase + (0.0 if side < 0 else PI)
		# Foot swings along the travel direction and lifts on the forward swing.
		var swing := sin(ph) * 0.42 * amp
		var lift := maxf(cos(ph), 0.0) * 0.26 * amp
		var target := hip + Vector3.DOWN * (LEG_LEN - lift) + _move_dir * swing + flat_rt * side * 0.05
		_spring(leg, Vector3(0, -FOOT_OFF, 0), target, 110.0 * bal, 200.0, false)
		# Keep the foot pointing where the beast faces (twist around the leg).
		var leg_fw := -leg.global_basis.z
		leg_fw = Vector3(leg_fw.x, 0, leg_fw.z).normalized()
		var twist := leg_fw.cross(flat_fw).y
		leg.apply_torque(Vector3.UP * (twist * 6.0 - leg.angular_velocity.y * 0.6) * bal)


func _drive_arms(dt: float, stunned: bool, space: PhysicsDirectSpaceState3D, t: float) -> void:
	if in_punch and not stunned and punch_t <= 0.0:
		punch_side = -punch_side
		punch_t = PUNCH_TIME
		_punched.clear()
	punch_t = maxf(punch_t - dt, 0.0)

	var bb := body.global_basis
	var up := bb.y
	var fw := -bb.z
	var rt := bb.x
	for hand in 2:
		var side := -1 if hand == 0 else 1
		var arm := parts[Part.ARM_L + hand]
		var shoulder := body.to_global(Vector3(SHOULDER.x * side, SHOULDER.y, 0))
		var mode := ArmMode.IDLE
		if stunned:
			mode = ArmMode.LIMP
		elif punch_t > 0.1 and side == punch_side and _grabs[hand] == null:
			mode = ArmMode.PUNCH
		elif in_grab:
			mode = ArmMode.LIFT if in_lift else ArmMode.REACH

		if mode == ArmMode.LIMP or not in_grab:
			_release(hand)
		var attached: bool = _grabs[hand] != null
		var target := shoulder
		var k := 25.0
		var limit := 120.0
		match mode:
			ArmMode.LIMP:
				continue
			ArmMode.IDLE:
				# Swing opposite to the same-side leg; sway a little at rest.
				var amp := minf(gait, 1.0)
				var arm_swing := sin(walk_phase + (PI if side < 0 else 0.0)) * 0.38 * amp
				var sway := sin(t * 2.4 + side) * 0.04 * (1.0 - amp)
				target = shoulder - up * (0.58 - absf(arm_swing) * 0.25) + fw * (0.14 + arm_swing + sway) + rt * side * 0.1
				k = 35.0
			ArmMode.REACH:
				target = shoulder + fw * 0.72 + up * 0.12 - rt * side * 0.14
				k = 160.0 if attached else 110.0
				limit = 420.0
			ArmMode.LIFT:
				target = shoulder + up * 0.8 + fw * 0.3 - rt * side * 0.1
				k = 220.0
				limit = 520.0
			ArmMode.PUNCH:
				target = shoulder + fw * 1.05 + up * 0.1 - rt * side * 0.22
				k = 700.0
				limit = 900.0
		_spring(arm, Vector3(0, -HAND_OFF, 0), target, k, limit, true)

		if (mode == ArmMode.REACH or mode == ArmMode.LIFT) and not attached:
			_try_grab(hand, space)
		elif mode == ArmMode.PUNCH:
			_try_punch(hand, fw, space)
		if _grabs[hand] != null:
			var gr = _grabs[hand]
			if not is_instance_valid(gr.target) or (gr.target.has_meta("beast") and not gr.target.get_meta("beast").active):
				_release(hand)


## PD spring pulling a point on `rb` toward `target`; optional equal and
## opposite reaction on the body so grabbing a ledge lets you climb.
func _spring(rb: RigidBody3D, local_pt: Vector3, target: Vector3, k: float, limit: float, react: bool) -> void:
	var pt := rb.to_global(local_pt)
	var r := pt - rb.global_position
	var v := rb.linear_velocity + rb.angular_velocity.cross(r)
	var f := ((target - pt) * k - v * 2.0 * sqrt(k)) * rb.mass
	f = f.limit_length(limit)
	rb.apply_force(f, r)
	if react:
		body.apply_force(-f, pt - body.global_position)


func _probe_hand(hand: int, radius: float, space: PhysicsDirectSpaceState3D) -> Array[Dictionary]:
	_probe.radius = radius
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = _probe
	q.transform = Transform3D(Basis(), hand_pos(hand))
	q.collision_mask = LAYER_WORLD | LAYER_BEAST | LAYER_PUPPET
	q.exclude = _rids
	return space.intersect_shape(q, 6)


func _try_grab(hand: int, space: PhysicsDirectSpaceState3D) -> void:
	var hits := _probe_hand(hand, 0.24, space)
	if hits.is_empty():
		return
	var target: PhysicsBody3D = hits[0].collider
	var owner_id := ""
	var part := 0
	if target.has_meta("beast"):
		var b: Beast = target.get_meta("beast")
		if not b.active:
			return
		part = target.get_meta("part")
		if b.is_puppet:
			owner_id = b.net_id
	var j := PinJoint3D.new()
	add_child(j)
	j.global_position = hand_pos(hand)
	j.node_a = j.get_path_to(parts[Part.ARM_L + hand])
	j.node_b = j.get_path_to(target)
	_grabs[hand] = {"joint": j, "target": target, "owner_id": owner_id, "part": part}


func _release(hand: int) -> void:
	var gr = _grabs[hand]
	if gr == null:
		return
	if is_instance_valid(gr.joint):
		gr.joint.queue_free()
	_grabs[hand] = null


func _holding() -> bool:
	return _grabs[0] != null or _grabs[1] != null


func _try_punch(hand: int, fw: Vector3, space: PhysicsDirectSpaceState3D) -> void:
	var arm := parts[Part.ARM_L + hand]
	if arm.linear_velocity.length() < 2.0:
		return
	for h in _probe_hand(hand, 0.3, space):
		var c = h.collider
		var dir := (fw + Vector3.UP * 0.3).normalized()
		if c.has_meta("beast"):
			var b: Beast = c.get_meta("beast")
			if b == self or _punched.has(b) or not b.active:
				continue
			_punched[b] = true
			var part: int = c.get_meta("part")
			var dmg := 1.0
			if part == Part.BODY and hand_pos(hand).y > c.global_position.y + 0.35:
				dmg = 1.5  # headshot
			var imp := dir * PUNCH_IMPULSE
			if b.is_puppet:
				hit_remote.emit(b.net_id, part, imp, dmg)
			else:
				b.receive_hit(part, imp, dmg)
		elif c is RigidBody3D and not c.freeze:
			c.apply_central_impulse(dir * 4.0)


func _apply_remote_grabs() -> void:
	if _remote_grabs.is_empty() or not hand_lookup.is_valid():
		return
	var now := Time.get_ticks_msec()
	for key in _remote_grabs.keys():
		var gr: Dictionary = _remote_grabs[key]
		if now > gr.until:
			_remote_grabs.erase(key)
			continue
		var hp: Variant = hand_lookup.call(gr.by, gr.hand)
		if hp == null:
			_remote_grabs.erase(key)
			continue
		var p := parts[gr.part]
		var to: Vector3 = hp - p.global_position
		if to.length() > 2.5:
			_remote_grabs.erase(key)
			continue
		var f := (to * 90.0 - p.linear_velocity * 10.0) * total_mass * 0.6
		p.apply_central_force(f.limit_length(650.0))


func _puppet_update() -> void:
	if _snaps.is_empty() or not active:
		return
	var rt := float(Time.get_ticks_msec()) - _offset - INTERP_MS
	var a: Dictionary = _snaps[0]
	var b: Dictionary = _snaps[0]
	var alpha := 0.0
	if rt >= _snaps[-1].t:
		a = _snaps[-1]
		b = a
	elif rt > _snaps[0].t:
		for i in range(_snaps.size() - 1):
			if _snaps[i].t <= rt and rt < _snaps[i + 1].t:
				a = _snaps[i]
				b = _snaps[i + 1]
				alpha = (rt - a.t) / maxf(b.t - a.t, 1.0)
				break
	for k in parts.size():
		var o := k * 7
		var pa := Vector3(a.p[o], a.p[o + 1], a.p[o + 2])
		var pb := Vector3(b.p[o], b.p[o + 1], b.p[o + 2])
		var qa := Quaternion(a.p[o + 3], a.p[o + 4], a.p[o + 5], a.p[o + 6]).normalized()
		var qb := Quaternion(b.p[o + 3], b.p[o + 4], b.p[o + 5], b.p[o + 6]).normalized()
		parts[k].global_transform = Transform3D(Basis(qa.slerp(qb, alpha)), pa.lerp(pb, alpha))


func _update_labels() -> void:
	if not active:
		return
	var top := body.global_position + Vector3.UP * 1.65
	_label.global_position = top
	_stars.visible = is_stunned()
	if _stars.visible:
		_stars.global_position = body.global_position + Vector3.UP * 1.35

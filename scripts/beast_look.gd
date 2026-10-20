class_name BeastLook
extends Node3D
## Procedural costume for a Beast (jelly-bean body, animal ears/beaks/tails,
## big cartoon face, mitt hands, stubby feet) plus secondary motion:
## squash & stretch / jiggle from body acceleration, blinking, dizzy eyes.
## Purely visual - works the same for local beasts and network puppets.

enum Species { CAT, BEAR, DINO, CHICK, BUNNY, FOX, MONSTER, FROG }

const PALETTE: Array[Color] = [
	Color(0.92, 0.3, 0.26), Color(0.36, 0.56, 0.95), Color(0.42, 0.8, 0.3), Color(1.0, 0.82, 0.22),
	Color(0.95, 0.47, 0.68), Color(1.0, 0.56, 0.2), Color(0.6, 0.42, 0.9), Color(0.25, 0.78, 0.72),
]
const SPECIES_BY_COLOR: Array[int] = [
	Species.CAT, Species.BEAR, Species.DINO, Species.CHICK,
	Species.BUNNY, Species.FOX, Species.MONSTER, Species.FROG,
]
## The visual root pivots at the bottom of the bean so squash looks grounded.
const PIVOT := 0.57
const BEAN_R := 0.46
const BEAN_H := 1.74
const BEAN_Y := 0.3

var beast: Beast
var species := Species.CAT
var base := Color.WHITE
var accent := Color.WHITE
var light := Color.WHITE

var _eye_pivots: Array[Node3D] = []
var _pupils: Array[MeshInstance3D] = []
var _pupil_rest: Array[Vector3] = []
var _jig := Vector3.ZERO
var _jig_v := Vector3.ZERO
var _last_pos := Vector3.ZERO
var _last_vel := Vector3.ZERO
var _warm := 0
var _blink_t := 0.0
var _next_blink := 2.0


func dress(b: Beast, color_idx: int) -> void:
	beast = b
	species = SPECIES_BY_COLOR[color_idx % SPECIES_BY_COLOR.size()]
	base = PALETTE[color_idx % PALETTE.size()]
	accent = base.darkened(0.35)
	light = base.lightened(0.55)
	position = Vector3(0, -PIVOT, 0)
	b.body.add_child(self)
	_build_body()
	_build_face()
	_build_species()
	for hand in 2:
		_build_hand(b.parts[Beast.Part.ARM_L + hand])
	for leg in 2:
		_build_leg(b.parts[Beast.Part.LEG_L + leg])
	_next_blink = randf_range(1.5, 4.0)


# ---------------------------------------------------------------- building

func _build_body() -> void:
	var bean := CapsuleMesh.new()
	bean.radius = BEAN_R
	bean.height = BEAN_H
	bean.radial_segments = 48
	bean.rings = 16
	var mi := _mesh(self, bean, _mat(base), _p(0, BEAN_Y, 0))
	mi.scale = Vector3(1.0, 1.0, 0.94)
	var belly := SphereMesh.new()
	belly.radius = 0.34
	belly.height = 0.68
	_mesh(self, belly, _mat(light), _p(0, 0.0, -0.31)).scale = Vector3(0.95, 1.2, 0.5)


func _build_face() -> void:
	var eye_y := 0.8
	var eye_x := 0.17
	var eye_z := -0.37
	if species == Species.FROG:
		eye_y = 1.1
		eye_x = 0.21
		eye_z = -0.2
		for side in [-1, 1]:
			var bump := SphereMesh.new()
			bump.radius = 0.17
			bump.height = 0.34
			_mesh(self, bump, _mat(base), _p(eye_x * side, eye_y - 0.03, eye_z + 0.06))
	var white := _mat(Color(0.98, 0.98, 0.96), 0.3)
	var black := _mat(Color(0.04, 0.04, 0.07), 0.2)
	var shine := _mat(Color.WHITE, 0.1)
	shine.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	for side in [-1, 1]:
		var pivot := Node3D.new()
		pivot.position = _p(eye_x * side, eye_y, eye_z)
		add_child(pivot)
		_eye_pivots.append(pivot)
		var eye := SphereMesh.new()
		eye.radius = 0.13
		eye.height = 0.26
		_mesh(pivot, eye, white, Vector3.ZERO).scale = Vector3(1.0, 1.12, 0.75)
		var pupil := SphereMesh.new()
		pupil.radius = 0.07
		pupil.height = 0.14
		var pm := _mesh(pivot, pupil, black, Vector3(0.012 * -side, 0.01, -0.088))
		pm.scale = Vector3(1, 1.1, 0.55)
		_pupils.append(pm)
		_pupil_rest.append(pm.position)
		var glint := SphereMesh.new()
		glint.radius = 0.024
		glint.height = 0.048
		_mesh(pm, glint, shine, Vector3(0.028, 0.035, -0.05))

	match species:
		Species.CHICK:
			var beak := CylinderMesh.new()
			beak.top_radius = 0.0
			beak.bottom_radius = 0.11
			beak.height = 0.22
			var bm := _mesh(self, beak, _mat(Color(1.0, 0.55, 0.12)), _p(0, 0.58, -0.5))
			bm.rotation.x = -PI / 2
			bm.scale = Vector3(1.25, 1.0, 0.7)
		Species.BEAR, Species.FOX:
			var muzzle := SphereMesh.new()
			muzzle.radius = 0.15
			muzzle.height = 0.3
			var mz_col := light if species == Species.BEAR else Color(0.98, 0.95, 0.9)
			_mesh(self, muzzle, _mat(mz_col), _p(0, 0.56, -0.4)).scale = Vector3(1.35, 0.9, 0.75)
			var nose := SphereMesh.new()
			nose.radius = 0.055
			nose.height = 0.11
			_mesh(self, nose, black, _p(0, 0.63, -0.52)).scale = Vector3(1.3, 0.8, 0.8)
			_mouth(Vector3(0, 0.49, -0.49), 0.75, false)
		Species.FROG:
			_mouth(Vector3(0, 0.62, -0.42), 2.2, false)
		Species.BUNNY:
			_mouth(Vector3(0, 0.55, -0.43), 0.9, true)
		_:
			_mouth(Vector3(0, 0.53, -0.42), 1.0, false)


func _mouth(at: Vector3, width: float, buck_teeth: bool) -> void:
	var hole := SphereMesh.new()
	hole.radius = 0.1
	hole.height = 0.2
	_mesh(self, hole, _mat(Color(0.35, 0.05, 0.08)), _p(at.x, at.y, at.z)).scale = Vector3(1.5 * width, 0.8, 0.45)
	var tongue := SphereMesh.new()
	tongue.radius = 0.05
	tongue.height = 0.1
	_mesh(self, tongue, _mat(Color(0.95, 0.4, 0.45)), _p(at.x, at.y - 0.035, at.z - 0.035)).scale = Vector3(1.4 * width, 0.6, 0.6)
	var teeth := BoxMesh.new()
	teeth.size = Vector3(0.1, 0.06, 0.025) if buck_teeth else Vector3(0.17 * width, 0.035, 0.03)
	var ty := at.y + (0.035 if buck_teeth else 0.045)
	_mesh(self, teeth, _mat(Color(1, 1, 0.97), 0.3), _p(at.x, ty, at.z - 0.04))


func _build_species() -> void:
	var inner := _mat(Color(1.0, 0.7, 0.75))
	match species:
		Species.CAT:
			for side in [-1, 1]:
				_cone(_mat(base), Vector3(0.25 * side, 1.12, 0.02), 0.13, 0.27, Vector3(0, 0, -0.4 * side))
				_cone(inner, Vector3(0.245 * side, 1.11, -0.03), 0.07, 0.17, Vector3(0, 0, -0.4 * side))
			for y in [-0.25, 0.0, 0.25]:
				var ring := TorusMesh.new()
				ring.inner_radius = BEAN_R - 0.015
				ring.outer_radius = BEAN_R + 0.02
				var rm := _mesh(self, ring, _mat(accent), _p(0, y, 0))
				rm.scale = Vector3(1, 0.6, 0.94)
		Species.BEAR:
			for side in [-1, 1]:
				_sphere(_mat(base), Vector3(0.29 * side, 1.06, 0.03), 0.14, Vector3(1, 1, 0.6))
				_sphere(_mat(light), Vector3(0.29 * side, 1.06, -0.03), 0.08, Vector3(1, 1, 0.5))
		Species.DINO:
			var spike := _mat(Color(1.0, 0.85, 0.3))
			var rows := [[1.08, 0.2], [0.82, 0.4], [0.52, 0.45], [0.22, 0.45], [-0.08, 0.44]]
			for r in rows:
				_cone(spike, Vector3(0, r[0], r[1]), 0.09, 0.2, Vector3(PI / 2 - 0.5, 0, 0))
			var tail := CapsuleMesh.new()
			tail.radius = 0.15
			tail.height = 0.75
			var tm := _mesh(self, tail, _mat(base), _p(0, -0.42, 0.55))
			tm.rotation.x = 1.05
		Species.CHICK:
			var red := _mat(Color(0.95, 0.2, 0.2))
			_sphere(red, Vector3(0, 1.18, -0.12), 0.08, Vector3.ONE)
			_sphere(red, Vector3(0, 1.22, 0.02), 0.1, Vector3.ONE)
			_sphere(red, Vector3(0, 1.17, 0.16), 0.08, Vector3.ONE)
		Species.BUNNY:
			for side in [-1, 1]:
				var ear := CapsuleMesh.new()
				ear.radius = 0.08
				ear.height = 0.62
				var em := _mesh(self, ear, _mat(base), _p(0.15 * side, 1.38, 0.04))
				em.rotation.z = -0.18 * side
				em.scale = Vector3(1, 1, 0.6)
				var ein := CapsuleMesh.new()
				ein.radius = 0.045
				ein.height = 0.45
				var im := _mesh(self, ein, inner, _p(0.155 * side, 1.37, 0.0))
				im.rotation.z = -0.18 * side
				im.scale = Vector3(1, 1, 0.5)
		Species.FOX:
			for side in [-1, 1]:
				_cone(_mat(base), Vector3(0.24 * side, 1.15, 0.02), 0.14, 0.34, Vector3(0, 0, -0.32 * side))
				_cone(_mat(Color(0.2, 0.12, 0.1)), Vector3(0.262 * side, 1.27, 0.02), 0.06, 0.12, Vector3(0, 0, -0.32 * side))
			var tail := CapsuleMesh.new()
			tail.radius = 0.19
			tail.height = 0.85
			var tm := _mesh(self, tail, _mat(base), _p(0, -0.3, 0.6))
			tm.rotation.x = 0.9
			_sphere(_mat(Color(0.98, 0.95, 0.9)), Vector3(0, -0.03, 0.92), 0.15, Vector3.ONE)
		Species.MONSTER:
			var bone := _mat(Color(0.96, 0.92, 0.8))
			for side in [-1, 1]:
				_cone(bone, Vector3(0.22 * side, 1.15, 0.0), 0.08, 0.3, Vector3(0, 0, -0.55 * side))
			for s in [[0.3, 0.2, -0.3], [-0.33, -0.05, -0.26], [0.36, -0.2, 0.2], [-0.2, 0.5, 0.36]]:
				_spot(_mat(accent), Vector3(s[0], s[1], s[2]), 0.08)
		Species.FROG:
			for s in [[0.28, 0.1, 0.32], [-0.3, -0.2, 0.28], [0.1, 0.55, 0.42]]:
				_spot(_mat(accent), Vector3(s[0], s[1], s[2]), 0.07)


func _build_hand(arm: RigidBody3D) -> void:
	var mitt := SphereMesh.new()
	mitt.radius = 0.16
	mitt.height = 0.32
	var mi := _mesh(arm, mitt, _mat(base.lightened(0.1)), Vector3(0, -Beast.HAND_OFF - 0.02, 0))
	mi.scale = Vector3(1.0, 0.9, 0.85)


func _build_leg(leg: RigidBody3D) -> void:
	var foot := SphereMesh.new()
	foot.radius = 0.17
	foot.height = 0.34
	var col := Color(1.0, 0.55, 0.12) if species == Species.CHICK else accent
	var mi := _mesh(leg, foot, _mat(col), Vector3(0, -0.27, -0.07))
	mi.scale = Vector3(1.0, 0.55, 1.4)


func _cone(mat: Material, at: Vector3, r: float, h: float, rot: Vector3) -> MeshInstance3D:
	var c := CylinderMesh.new()
	c.top_radius = 0.0
	c.bottom_radius = r
	c.height = h
	c.radial_segments = 24
	var mi := _mesh(self, c, mat, _p(at.x, at.y, at.z))
	mi.rotation = rot
	return mi


func _sphere(mat: Material, at: Vector3, r: float, scl: Vector3) -> MeshInstance3D:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	var mi := _mesh(self, s, mat, _p(at.x, at.y, at.z))
	mi.scale = scl
	return mi


## Flattened dot lying on the bean surface, facing outward.
func _spot(mat: Material, at: Vector3, r: float) -> void:
	var n := Vector3(at.x, 0, at.z).normalized()
	var mi := _sphere(mat, at, r, Vector3.ONE)
	mi.basis = Basis.looking_at(n) * Basis.from_scale(Vector3(1, 1, 0.4))


func _mesh(parent: Node3D, mesh: Mesh, mat: Material, at: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = at
	parent.add_child(mi)
	return mi


## Body-space point -> visual-root space (the root sits PIVOT below the body).
func _p(x: float, y: float, z: float) -> Vector3:
	return Vector3(x, y + PIVOT, z)


func _mat(c: Color, rough := 0.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = rough
	m.rim_enabled = true
	m.rim = 0.25
	m.rim_tint = 0.6
	return m


# ---------------------------------------------------------------- motion

func _process(dt: float) -> void:
	if dt <= 0.0 or not beast.active:
		_warm = 0
		return
	var body := beast.body
	var pos := body.global_position
	var vel := (pos - _last_pos) / dt
	var acc := (vel - _last_vel) / dt
	_last_pos = pos
	_last_vel = vel
	if _warm < 3:
		_warm += 1
		return
	# Jelly spring driven by acceleration in body space: lag, squash, stretch.
	var local_acc := (body.global_basis.orthonormalized().inverse() * acc).limit_length(80.0)
	_jig_v += (-_jig * 140.0 - _jig_v * 10.0 - local_acc * 0.012) * dt
	_jig += _jig_v * dt
	_jig = _jig.limit_length(0.22)
	var sq := clampf(_jig.y, -0.16, 0.16)
	scale = Vector3(1.0 - sq * 0.6, 1.0 + sq, 1.0 - sq * 0.6)
	rotation = Vector3(clampf(_jig.z * 1.4, -0.3, 0.3), 0, clampf(-_jig.x * 1.4, -0.3, 0.3))

	# Blink, or spin the pupils while dizzy.
	_next_blink -= dt
	if _next_blink <= 0.0:
		_blink_t = 0.14
		_next_blink = randf_range(2.0, 5.0)
	_blink_t = maxf(_blink_t - dt, 0.0)
	var lid := 0.12 if _blink_t > 0.0 else 1.0
	var dizzy := beast.is_stunned()
	var t := Time.get_ticks_msec() * 0.001
	for i in _eye_pivots.size():
		_eye_pivots[i].scale.y = lerpf(_eye_pivots[i].scale.y, lid, minf(dt * 30.0, 1.0))
		var off := Vector3.ZERO
		if dizzy:
			var a := t * 9.0 * (1.0 if i == 0 else -1.0)
			off = Vector3(cos(a), sin(a), 0) * 0.04
		_pupils[i].position = _pupil_rest[i] + off

class_name Level
extends Node3D
## "Truck Rooftop" arena: a deck floating high above the city with a parked
## truck to climb, a few crates and a side platform. Fall off and you're out.

const KILL_Y := -12.0
const DECK := Vector3(16, 1, 11)

var spawns: Array[Vector3] = [
	Vector3(-5, 1.3, 2.5), Vector3(5, 1.3, 2.5), Vector3(-2, 1.3, 3.8), Vector3(2, 1.3, 3.8),
	Vector3(-6, 1.3, -0.5), Vector3(6.5, 1.3, 0.5), Vector3(0, 1.3, 1.0), Vector3(-11.5, 1.3, 2.0),
]


func build() -> void:
	_environment()
	var deck := _mat(Color(0.55, 0.6, 0.68))
	var trim := _mat(Color(0.95, 0.75, 0.2))
	var white := _mat(Color(0.92, 0.9, 0.86))
	var red := _mat(Color(0.82, 0.2, 0.18))
	var glass := _mat(Color(0.15, 0.2, 0.3))
	var crate := _mat(Color(0.65, 0.45, 0.25))
	var side := _mat(Color(0.5, 0.47, 0.44))

	_box(Vector3(0, -0.5, 0), DECK, deck)
	_box(Vector3(0, 0.02, DECK.z * 0.5 - 0.15), Vector3(DECK.x, 0.04, 0.3), trim, false)
	_box(Vector3(0, 0.02, -DECK.z * 0.5 + 0.15), Vector3(DECK.x, 0.04, 0.3), trim, false)

	# Truck: trailer + cab. Grab the top edge to climb up.
	_box(Vector3(-1.2, 1.15, -3.4), Vector3(7.0, 2.3, 3.2), white)
	_box(Vector3(-1.2, 1.1, -1.79), Vector3(7.0, 0.35, 0.02), red, false)
	_box(Vector3(3.5, 0.85, -3.4), Vector3(2.2, 1.7, 3.2), red)
	_box(Vector3(4.61, 1.15, -3.4), Vector3(0.02, 0.6, 2.6), glass, false)

	# Crates.
	_box(Vector3(-6.3, 0.5, -3.6), Vector3(1, 1, 1), crate)
	_box(Vector3(-6.3, 1.5, -3.6), Vector3(1, 1, 1), crate)
	_box(Vector3(-7.3, 0.5, -3.6), Vector3(1, 1, 1), crate)
	_box(Vector3(7.0, 0.5, 4.0), Vector3(1, 1, 1), crate)

	# Side platform across a small gap.
	_box(Vector3(-11.5, -0.5, 1.5), Vector3(4, 1, 6), side)
	_box(Vector3(-11.5, 0.02, 4.35), Vector3(4, 0.04, 0.3), trim, false)

	_city()


func is_safe(p: Vector3) -> bool:
	return absf(p.x) < DECK.x * 0.5 - 1.5 and absf(p.z) < DECK.z * 0.5 - 1.5


func _environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.32, 0.55, 0.9)
	sm.sky_horizon_color = Color(0.85, 0.88, 0.95)
	sm.ground_horizon_color = Color(0.85, 0.88, 0.95)
	sm.ground_bottom_color = Color(0.6, 0.72, 0.88)
	sm.ground_curve = 0.15
	sky.sky_material = sm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.45
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 6.0
	env.fog_enabled = true
	env.fog_light_color = Color(0.72, 0.8, 0.92)
	env.fog_density = 0.0035
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -35, 0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 45.0
	add_child(sun)


func _city() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var mats := [_mat(Color(0.45, 0.48, 0.55)), _mat(Color(0.6, 0.58, 0.55)), _mat(Color(0.38, 0.42, 0.5))]
	for i in 36:
		var w := rng.randf_range(5, 11)
		var d := rng.randf_range(5, 11)
		var top := rng.randf_range(-34, -20)
		var pos := Vector3(rng.randf_range(-70, 70), top - 15, rng.randf_range(-80, 25))
		if absf(pos.x) < 14 and pos.z > -10:
			pos.z -= 25
		var mi := _box(pos, Vector3(w, 30, d), mats[i % mats.size()], false)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.8
	return m


func _box(pos: Vector3, size: Vector3, mat: Material, collide := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.material_override = mat
	if collide:
		var sb := StaticBody3D.new()
		sb.position = pos
		sb.collision_layer = Beast.LAYER_WORLD
		sb.collision_mask = 0
		var cs := CollisionShape3D.new()
		var sh := BoxShape3D.new()
		sh.size = size
		cs.shape = sh
		sb.add_child(cs)
		sb.add_child(mi)
		add_child(sb)
	else:
		mi.position = pos
		add_child(mi)
	return mi

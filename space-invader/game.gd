extends Node2D

# Space Invaders-inspired arena shooter
# Controls:
# WASD / Arrow keys = move
# Double-tap a direction = dash
# Space / Left mouse button = shoot
# 1 / 2 / 3 = choose an upgrade when leveling up
# R = restart after game over

const PLAYER_SPEED := 300.0
const DASH_SPEED := 900.0
const DASH_DURATION := 0.16
const DASH_COOLDOWN := 0.65
const DOUBLE_TAP_WINDOW := 0.26

const ENEMY_SPAWN_INTERVAL := 1.8
const ENEMY_BASE_SPEED := 75.0
const ENEMY_RADIUS := 15.0

const BULLET_SPEED := 620.0
const BULLET_LIFETIME := 1.5
const BULLET_SPREAD_DEGREES := 7.0

var player_pos := Vector2.ZERO
var player_hp := 100.0
var player_max_hp := 100.0
var player_radius := 16.0

var bullets: Array[Dictionary] = []
var enemies: Array[Dictionary] = []
var enemy_bullets: Array[Dictionary] = []

var score := 0
var level := 1
var next_level_score := 100
var game_over := false
var choosing_upgrade := false

var damage := 20.0
var fire_interval := 0.32
var projectile_count := 1
var fire_timer := 0.0

var spawn_timer := 0.0
var enemy_spawned_total := 0
var dash_timer := 0.0
var dash_cooldown_timer := 0.0
var dash_direction := Vector2.ZERO
var invulnerable_timer := 0.0

var last_tap_time: Dictionary = {}
var last_tap_direction: Dictionary = {}
var move_input := Vector2.ZERO

var rng := RandomNumberGenerator.new()


func _ready() -> void:
	rng.randomize()
	get_viewport().size_changed.connect(_on_resize)
	_on_resize()
	spawn_timer = 0.8
	queue_redraw()


func _on_resize() -> void:
	var size := get_viewport_rect().size
	if player_pos == Vector2.ZERO:
		player_pos = Vector2(size.x * 0.5, size.y * 0.75)
	player_pos.x = clampf(player_pos.x, player_radius, size.x - player_radius)
	player_pos.y = clampf(player_pos.y, player_radius, size.y - player_radius)
	queue_redraw()


func _process(delta: float) -> void:
	if game_over:
		queue_redraw()
		return

	if choosing_upgrade:
		queue_redraw()
		return

	var screen := get_viewport_rect().size
	_read_movement_input()

	# Dash timers
	dash_cooldown_timer = maxf(0.0, dash_cooldown_timer - delta)
	invulnerable_timer = maxf(0.0, invulnerable_timer - delta)

	# Move freely in eight directions
	if dash_timer > 0.0:
		player_pos += dash_direction * DASH_SPEED * delta
		dash_timer = maxf(0.0, dash_timer - delta)
	else:
		player_pos += move_input * PLAYER_SPEED * delta

	player_pos.x = clampf(player_pos.x, player_radius, screen.x - player_radius)
	player_pos.y = clampf(player_pos.y, player_radius + 42.0, screen.y - player_radius)

	# Shoot toward the mouse cursor, or upward if the mouse is very close
	fire_timer -= delta
	var wants_to_shoot := Input.is_key_pressed(KEY_SPACE) or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if wants_to_shoot and fire_timer <= 0.0:
		_shoot()
		fire_timer = fire_interval

	_update_bullets(delta)
	_update_enemies(delta)
	_update_enemy_bullets(delta)

	# Spawn enemies slowly, one at a time. Spawn interval decreases slightly with level.
	spawn_timer -= delta
	if spawn_timer <= 0.0:
		_spawn_enemy()
		spawn_timer = maxf(0.55, ENEMY_SPAWN_INTERVAL - float(level - 1) * 0.06)

	queue_redraw()


func _read_movement_input() -> void:
	move_input = Vector2.ZERO
	var left := Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT)
	var right := Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT)
	var up := Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP)
	var down := Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN)

	if left:
		move_input.x -= 1.0
	if right:
		move_input.x += 1.0
	if up:
		move_input.y -= 1.0
	if down:
		move_input.y += 1.0

	if move_input.length() > 1.0:
		move_input = move_input.normalized()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key: Key = event.keycode
		if game_over and key == KEY_R:
			_restart_game()
			return

		if choosing_upgrade:
			if key == KEY_1:
				_apply_upgrade(1)
			elif key == KEY_2:
				_apply_upgrade(2)
			elif key == KEY_3:
				_apply_upgrade(3)
			return

		# Double-tap the same movement direction to dash
		var direction := Vector2.ZERO
		var direction_name := ""

		if key == KEY_A or key == KEY_LEFT:
			direction = Vector2.LEFT
			direction_name = "left"
		elif key == KEY_D or key == KEY_RIGHT:
			direction = Vector2.RIGHT
			direction_name = "right"
		elif key == KEY_W or key == KEY_UP:
			direction = Vector2.UP
			direction_name = "up"
		elif key == KEY_S or key == KEY_DOWN:
			direction = Vector2.DOWN
			direction_name = "down"

		if direction_name != "":
			var now := Time.get_ticks_msec() / 1000.0
			var previous := float(last_tap_time.get(direction_name, -100.0))
			if now - previous <= DOUBLE_TAP_WINDOW and dash_cooldown_timer <= 0.0:
				dash_direction = direction
				dash_timer = DASH_DURATION
				dash_cooldown_timer = DASH_COOLDOWN
				invulnerable_timer = maxf(invulnerable_timer, DASH_DURATION)
				last_tap_time[direction_name] = -100.0
			else:
				last_tap_time[direction_name] = now

	elif event is InputEventMouseButton and event.pressed:
		if choosing_upgrade:
			var screen := get_viewport_rect().size
			var third := screen.x / 3.0
			if event.position.x < third:
				_apply_upgrade(1)
			elif event.position.x < third * 2.0:
				_apply_upgrade(2)
			else:
				_apply_upgrade(3)


func _shoot() -> void:
	var target := get_global_mouse_position()
	var direction := target - player_pos
	if direction.length() < 8.0:
		direction = Vector2.UP
	direction = direction.normalized()

	# Spread multi-shot evenly around the aim direction, with a little random angle per bullet.
	var spread_step := 9.0
	var start_angle := -spread_step * float(projectile_count - 1) * 0.5
	for i in range(projectile_count):
		var angle_deg := start_angle + spread_step * float(i)
		angle_deg += rng.randf_range(-BULLET_SPREAD_DEGREES, BULLET_SPREAD_DEGREES)
		var velocity := direction.rotated(deg_to_rad(angle_deg)) * BULLET_SPEED
		bullets.append({
			"pos": player_pos + direction * 22.0,
			"vel": velocity,
			"life": BULLET_LIFETIME,
			"damage": damage
		})


func _update_bullets(delta: float) -> void:
	var screen := get_viewport_rect().size
	for i in range(bullets.size() - 1, -1, -1):
		var bullet: Dictionary = bullets[i]
		bullet["pos"] = bullet["pos"] + bullet["vel"] * delta
		bullet["life"] = float(bullet["life"]) - delta
		bullets[i] = bullet

		var pos: Vector2 = bullet["pos"]
		if float(bullet["life"]) <= 0.0 or pos.x < -20.0 or pos.x > screen.x + 20.0 or pos.y < -20.0 or pos.y > screen.y + 20.0:
			bullets.remove_at(i)
			continue

		var hit_enemy := -1
		for e in range(enemies.size()):
			var enemy: Dictionary = enemies[e]
			if pos.distance_to(enemy["pos"]) <= ENEMY_RADIUS + 5.0:
				hit_enemy = e
				break

		if hit_enemy >= 0:
			var enemy: Dictionary = enemies[hit_enemy]
			enemy["hp"] = float(enemy["hp"]) - float(bullet["damage"])
			enemies[hit_enemy] = enemy
			bullets.remove_at(i)

			if float(enemy["hp"]) <= 0.0:
				var enemy_pos: Vector2 = enemy["pos"]
				enemies.remove_at(hit_enemy)
				score += int(enemy["score"])
				_check_level_up()
				# Tiny score pop is intentionally represented by a short-lived particle-like dot.
				enemy_bullets.append({
					"pos": enemy_pos,
					"vel": Vector2.ZERO,
					"life": 0.08,
					"friendly": true
				})


func _spawn_enemy() -> void:
	var screen := get_viewport_rect().size
	var side := rng.randi_range(0, 3)
	var spawn_pos := Vector2.ZERO

	match side:
		0:
			spawn_pos = Vector2(rng.randf_range(20.0, screen.x - 20.0), 48.0)
		1:
			spawn_pos = Vector2(rng.randf_range(20.0, screen.x - 20.0), screen.y - 20.0)
		2:
			spawn_pos = Vector2(18.0, rng.randf_range(65.0, screen.y - 20.0))
		_:
			spawn_pos = Vector2(screen.x - 18.0, rng.randf_range(65.0, screen.y - 20.0))

	enemy_spawned_total += 1
	var enemy_hp := 40.0 + float(level - 1) * 5.0
	var enemy_speed := ENEMY_BASE_SPEED + float(level - 1) * 4.0
	enemies.append({
		"pos": spawn_pos,
		"hp": enemy_hp,
		"max_hp": enemy_hp,
		"speed": enemy_speed,
		"score": 20 + level * 2
	})


func _update_enemies(delta: float) -> void:
	for i in range(enemies.size() - 1, -1, -1):
		var enemy: Dictionary = enemies[i]
		var pos: Vector2 = enemy["pos"]
		var direction := (player_pos - pos).normalized()
		pos += direction * float(enemy["speed"]) * delta
		enemy["pos"] = pos
		enemies[i] = enemy

		if pos.distance_to(player_pos) <= ENEMY_RADIUS + player_radius:
			if invulnerable_timer <= 0.0:
				player_hp -= 25.0
				invulnerable_timer = 0.8
				# Push the enemy away after contact so it doesn't drain all HP in one frame.
				var push := (pos - player_pos).normalized()
				enemy["pos"] = pos + push * 40.0
				enemies[i] = enemy
				if player_hp <= 0.0:
					player_hp = 0.0
					game_over = true


func _update_enemy_bullets(delta: float) -> void:
	for i in range(enemy_bullets.size() - 1, -1, -1):
		var bullet: Dictionary = enemy_bullets[i]
		bullet["life"] = float(bullet["life"]) - delta
		if bool(bullet.get("friendly", false)):
			enemy_bullets[i] = bullet
			if float(bullet["life"]) <= 0.0:
				enemy_bullets.remove_at(i)
			continue

		bullet["pos"] = bullet["pos"] + bullet["vel"] * delta
		enemy_bullets[i] = bullet
		if float(bullet["life"]) <= 0.0:
			enemy_bullets.remove_at(i)
			continue

		var bullet_pos: Vector2 = bullet["pos"]
		if invulnerable_timer <= 0.0 and bullet_pos.distance_to(player_pos) < player_radius + 5.0:
			enemy_bullets.remove_at(i)
			player_hp -= 12.0
			invulnerable_timer = 0.6
			if player_hp <= 0.0:
				player_hp = 0.0
				game_over = true


func _check_level_up() -> void:
	if score >= next_level_score:
		level += 1
		next_level_score = 100 * level
		choosing_upgrade = true


func _apply_upgrade(choice: int) -> void:
	match choice:
		1:
			damage += 8.0
		2:
			fire_interval = maxf(0.09, fire_interval * 0.78)
		3:
			projectile_count = mini(7, projectile_count + 1)

	choosing_upgrade = false
	queue_redraw()


func _restart_game() -> void:
	player_hp = player_max_hp
	score = 0
	level = 1
	next_level_score = 100
	game_over = false
	choosing_upgrade = false
	damage = 20.0
	fire_interval = 0.32
	projectile_count = 1
	fire_timer = 0.0
	spawn_timer = 0.8
	enemy_spawned_total = 0
	dash_timer = 0.0
	dash_cooldown_timer = 0.0
	invulnerable_timer = 0.0
	last_tap_time.clear()
	bullets.clear()
	enemies.clear()
	enemy_bullets.clear()
	player_pos = get_viewport_rect().size * Vector2(0.5, 0.75)
	queue_redraw()


func _draw() -> void:
	var screen := get_viewport_rect().size
	draw_rect(Rect2(Vector2.ZERO, screen), Color("#080d20"))

	# Background stars
	for i in range(70):
		var x := fposmod(float(i) * 137.0 + 23.0, screen.x)
		var y := fposmod(float(i) * 83.0 + 11.0, screen.y)
		draw_circle(Vector2(x, y), 1.1, Color("#273557"))

	# Player ship and dash glow
	if invulnerable_timer > 0.0:
		draw_circle(player_pos, player_radius + 8.0, Color(0.30, 0.85, 1.0, 0.25))
	var ship := PackedVector2Array([
		player_pos + Vector2(0, -19),
		player_pos + Vector2(16, -4),
		player_pos + Vector2(12, 14),
		player_pos + Vector2(-12, 14),
		player_pos + Vector2(-16, -4)
	])
	draw_colored_polygon(ship, Color("#4de6ff"))
	draw_circle(player_pos, 4.0, Color.WHITE)

	# Player bullets
	for bullet in bullets:
		var pos: Vector2 = bullet["pos"]
		var vel: Vector2 = bullet["vel"]
		draw_line(pos - vel.normalized() * 7.0, pos + vel.normalized() * 7.0, Color("#ffe66d"), 4.0)

	# Chasing enemies and health bars
	for enemy in enemies:
		var pos: Vector2 = enemy["pos"]
		draw_circle(pos, ENEMY_RADIUS, Color("#ff6384"))
		draw_circle(pos + Vector2(-5, -3), 3.0, Color("#080d20"))
		draw_circle(pos + Vector2(5, -3), 3.0, Color("#080d20"))
		var hp_ratio := clampf(float(enemy["hp"]) / float(enemy["max_hp"]), 0.0, 1.0)
		draw_rect(Rect2(pos + Vector2(-ENEMY_RADIUS, -ENEMY_RADIUS - 8), Vector2(ENEMY_RADIUS * 2.0, 3)), Color("#492337"))
		draw_rect(Rect2(pos + Vector2(-ENEMY_RADIUS, -ENEMY_RADIUS - 8), Vector2(ENEMY_RADIUS * 2.0 * hp_ratio, 3)), Color("#8cff85"))

	# Enemy shots / tiny defeat spark
	for bullet in enemy_bullets:
		var pos: Vector2 = bullet["pos"]
		if bool(bullet.get("friendly", false)):
			draw_circle(pos, 5.0, Color("#ffe66d"))
		else:
			draw_circle(pos, 5.0, Color("#ff9c66"))

	# HUD
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(18, 28), "SCORE  %06d" % score, HORIZONTAL_ALIGNMENT_LEFT, -1, 19, Color.WHITE)
	draw_string(font, Vector2(18, 54), "LEVEL  %d" % level, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, Color("#4de6ff"))
	draw_string(font, Vector2(screen.x - 18, 28), "HP", HORIZONTAL_ALIGNMENT_RIGHT, -1, 16, Color.WHITE)
	draw_rect(Rect2(screen.x - 178, 38, 160, 12), Color("#492337"))
	draw_rect(Rect2(screen.x - 178, 38, 160.0 * player_hp / player_max_hp, 12), Color("#8cff85"))
	draw_string(font, Vector2(18, screen.y - 18), "MOVE: WASD/ARROWS   DOUBLE-TAP: DASH   SHOOT: SPACE / LEFT CLICK", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("#aab8d6"))

	if choosing_upgrade:
		draw_rect(Rect2(Vector2.ZERO, screen), Color(0.02, 0.04, 0.10, 0.82))
		_draw_centered_text("LEVEL UP!", screen.y * 0.30, 40, Color("#ffe66d"))
		_draw_centered_text("Choose an upgrade", screen.y * 0.30 + 38, 22, Color.WHITE)
		_draw_upgrade_card(screen.x * 0.18, screen.y * 0.43, screen.x * 0.64, 78, "1  DAMAGE +8", "Each shot hits harder", Color("#ff6384"))
		_draw_upgrade_card(screen.x * 0.18, screen.y * 0.43 + 94, screen.x * 0.64, 78, "2  FIRE RATE", "Shoot faster", Color("#4de6ff"))
		_draw_upgrade_card(screen.x * 0.18, screen.y * 0.43 + 188, screen.x * 0.64, 78, "3  MULTI-SHOT", "Add one more projectile", Color("#8cff85"))

	if game_over:
		draw_rect(Rect2(Vector2.ZERO, screen), Color(0.02, 0.04, 0.10, 0.82))
		_draw_centered_text("GAME OVER", screen.y * 0.43, 42, Color("#ff6384"))
		_draw_centered_text("Final score: %d" % score, screen.y * 0.43 + 42, 22, Color.WHITE)
		_draw_centered_text("Press R to restart", screen.y * 0.43 + 82, 20, Color("#4de6ff"))


func _draw_centered_text(message: String, y: float, size: int, color: Color) -> void:
	var font := ThemeDB.fallback_font
	var screen := get_viewport_rect().size
	draw_string(font, Vector2(screen.x / 2.0, y), message, HORIZONTAL_ALIGNMENT_CENTER, -1, size, color)


func _draw_upgrade_card(x: float, y: float, w: float, h: float, title: String, subtitle: String, color: Color) -> void:
	draw_rect(Rect2(x, y, w, h), Color("#151f3b"))
	draw_rect(Rect2(x, y, w, h), color, false, 2.0)
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(x + 18, y + 31), title, HORIZONTAL_ALIGNMENT_LEFT, w - 36, 20, color)
	draw_string(font, Vector2(x + 18, y + 58), subtitle, HORIZONTAL_ALIGNMENT_LEFT, w - 36, 15, Color.WHITE)

// Temple Run clone — Odin + raylib
// Run: odin run . -o:speed
//
// Controls: A/D or arrows = switch lane, SPACE/W/UP = jump,
//           S/DOWN = slide (in air: slam down), P = pause, ESC = quit.
package temple_run

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:time"
import rl "vendor:raylib"

WIN_W :: 1280
WIN_H :: 720

// --- Tuning ------------------------------------------------------------

LANE_WIDTH    :: f32(3.0)
TRACK_HALF    :: LANE_WIDTH * 1.5
GRAVITY       :: f32(-32.0)
JUMP_VELOCITY :: f32(11.5)
SLAM_VELOCITY :: f32(-26.0)
SLIDE_TIME    :: f32(0.65)
RUN_HEIGHT    :: f32(1.8)
SLIDE_HEIGHT  :: f32(0.9)
PLAYER_WIDTH  :: f32(0.8)
PLAYER_DEPTH  :: f32(0.7)
LANE_LERP     :: f32(14.0)

BASE_SPEED  :: f32(11.0)
MAX_SPEED   :: f32(30.0)
SPEED_RAMP  :: f32(0.25) // units/s gained per second
SPAWN_AHEAD :: f32(-130.0)
DESPAWN_Z   :: f32(10.0)

// --- Palette -----------------------------------------------------------

SKY_TOP    :: rl.Color{16, 14, 34, 255}
SKY_BOTTOM :: rl.Color{78, 42, 66, 255}
FOG        :: rl.Color{30, 22, 46, 255}
FLOOR_A    :: rl.Color{96, 85, 70, 255}
FLOOR_B    :: rl.Color{82, 72, 59, 255}
WALL_C     :: rl.Color{72, 62, 86, 255}
PILLAR_C   :: rl.Color{116, 100, 84, 255}
PILLAR_CAP :: rl.Color{140, 122, 96, 255}
WOOD       :: rl.Color{152, 97, 50, 255}
WOOD_DARK  :: rl.Color{112, 70, 38, 255}
STONE      :: rl.Color{134, 128, 146, 255}
STONE_DARK :: rl.Color{104, 99, 118, 255}
GOLD       :: rl.Color{255, 200, 40, 255}
BODY_C     :: rl.Color{226, 88, 58, 255}
SKIN_C     :: rl.Color{243, 204, 168, 255}
LIMB_C     :: rl.Color{62, 44, 40, 255}

// --- Types -------------------------------------------------------------

Game_State :: enum {
	Menu,
	Playing,
	Dead,
}

Obstacle_Kind :: enum {
	Low,   // hurdle: jump over
	High,  // overhang: slide under
	Block, // wall: change lane
}

Obstacle :: struct {
	kind: Obstacle_Kind,
	lane: int,
	z:    f32,
}

Coin :: struct {
	lane: int,
	z:    f32,
}

Player :: struct {
	lane:        int, // -1 | 0 | +1
	x:           f32, // smoothed world x
	y:           f32,
	vy:          f32,
	sliding:     bool,
	slide_timer: f32,
	slam_slide:  bool, // slide queued after an air-slam
}

Game :: struct {
	state:       Game_State,
	paused:      bool,
	player:      Player,
	obstacles:   [dynamic]Obstacle,
	coins:       [dynamic]Coin,
	speed:       f32,
	distance:    f32,
	coin_count:  int,
	last_row_z:  f32,
	next_gap:    f32,
	high_score:  int,
	new_best:    bool,
	death_timer: f32,
	time:        f32,
}

// --- Helpers -----------------------------------------------------------

score :: proc(g: ^Game) -> int {
	return int(g.distance) + g.coin_count * 10
}

// Blend toward fog color with distance so the corridor recedes into dark.
fade_z :: proc(c: rl.Color, z: f32) -> rl.Color {
	t := clamp((-z - 50.0) / 80.0, 0, 1)
	return rl.Color {
		u8(f32(c.r) + (f32(FOG.r) - f32(c.r)) * t),
		u8(f32(c.g) + (f32(FOG.g) - f32(c.g)) * t),
		u8(f32(c.b) + (f32(FOG.b) - f32(c.b)) * t),
		c.a,
	}
}

player_box :: proc(p: Player) -> rl.BoundingBox {
	h := p.sliding ? SLIDE_HEIGHT : RUN_HEIGHT
	return {
		min = {p.x - PLAYER_WIDTH / 2, p.y + 0.05, -PLAYER_DEPTH / 2},
		max = {p.x + PLAYER_WIDTH / 2, p.y + h, PLAYER_DEPTH / 2},
	}
}

obstacle_box :: proc(ob: Obstacle) -> rl.BoundingBox {
	x := f32(ob.lane) * LANE_WIDTH
	switch ob.kind {
	case .Low:
		return {min = {x - 1.25, 0.00, ob.z - 0.30}, max = {x + 1.25, 0.95, ob.z + 0.30}}
	case .High:
		return {min = {x - 1.25, 1.15, ob.z - 0.30}, max = {x + 1.25, 3.40, ob.z + 0.30}}
	case .Block:
		return {min = {x - 1.30, 0.00, ob.z - 0.50}, max = {x + 1.30, 3.40, ob.z + 0.50}}
	}
	return {}
}

// --- Spawning ----------------------------------------------------------

rand_gap :: proc(speed: f32) -> f32 {
	// gaps widen a little as speed climbs so reaction time stays fair
	return (9.5 + rand.float32() * 6.0) * (0.85 + 0.45 * speed / MAX_SPEED)
}

// One "row" of obstacles. A randomly chosen safe lane never gets a Block,
// so every row is survivable by construction.
spawn_row :: proc(g: ^Game, z: f32) {
	safe := rand.int_max(3) - 1
	for lane in -1 ..= 1 {
		if lane == safe {
			if rand.float32() < 0.45 {
				kind := rand.float32() < 0.5 ? Obstacle_Kind.Low : Obstacle_Kind.High
				append(&g.obstacles, Obstacle{kind, lane, z})
			}
		} else {
			r := rand.float32()
			if r < 0.62 {
				kind: Obstacle_Kind
				switch {
				case r < 0.22:
					kind = .Low
				case r < 0.40:
					kind = .High
				case:
					kind = .Block
				}
				append(&g.obstacles, Obstacle{kind, lane, z})
			}
		}
	}
	// coin trail in the gap behind this row
	if rand.float32() < 0.65 {
		lane := rand.int_max(3) - 1
		n := 4 + rand.int_max(3)
		for i in 0 ..< n {
			append(&g.coins, Coin{lane, z - 2.2 - f32(i) * 1.4})
		}
	}
}

update_spawns :: proc(g: ^Game, dt: f32) {
	g.last_row_z += g.speed * dt
	for {
		nz := g.last_row_z - g.next_gap
		if nz < SPAWN_AHEAD do break
		spawn_row(g, nz)
		g.last_row_z = nz
		g.next_gap = rand_gap(g.speed)
	}
}

reset_run :: proc(g: ^Game) {
	clear(&g.obstacles)
	clear(&g.coins)
	g.player = {}
	g.paused = false
	g.new_best = false
	g.speed = BASE_SPEED
	g.distance = 0
	g.coin_count = 0
	g.death_timer = 0
	g.last_row_z = -26
	g.next_gap = rand_gap(BASE_SPEED)
	update_spawns(g, 0) // pre-fill the corridor to the horizon
}

// --- Update ------------------------------------------------------------

update_player :: proc(g: ^Game, dt: f32) {
	p := &g.player

	if rl.IsKeyPressed(.LEFT) || rl.IsKeyPressed(.A) do p.lane = max(p.lane - 1, -1)
	if rl.IsKeyPressed(.RIGHT) || rl.IsKeyPressed(.D) do p.lane = min(p.lane + 1, 1)
	p.x += (f32(p.lane) * LANE_WIDTH - p.x) * min(LANE_LERP * dt, 1)

	grounded := p.y <= 0.001 && p.vy <= 0

	if (rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.UP) || rl.IsKeyPressed(.W)) && grounded {
		p.vy = JUMP_VELOCITY
		p.sliding = false
		p.slide_timer = 0
		grounded = false
	}

	if rl.IsKeyPressed(.DOWN) || rl.IsKeyPressed(.S) || rl.IsKeyPressed(.LEFT_CONTROL) {
		if grounded {
			p.sliding = true
			p.slide_timer = SLIDE_TIME
		} else {
			p.vy = SLAM_VELOCITY // air-slam, slide on touchdown
			p.slam_slide = true
		}
	}

	if !grounded {
		p.vy += GRAVITY * dt
		p.y += p.vy * dt
		if p.y <= 0 {
			p.y = 0
			p.vy = 0
			if p.slam_slide {
				p.sliding = true
				p.slide_timer = SLIDE_TIME
				p.slam_slide = false
			}
		}
	}

	if p.sliding {
		p.slide_timer -= dt
		if p.slide_timer <= 0 do p.sliding = false
	}
}

kill_player :: proc(g: ^Game) {
	g.state = .Dead
	g.death_timer = 0
	s := score(g)
	g.new_best = s > g.high_score && g.high_score > 0
	if s > g.high_score do g.high_score = s
}

update_playing :: proc(g: ^Game, dt: f32) {
	g.speed = min(g.speed + SPEED_RAMP * dt, MAX_SPEED)
	g.distance += g.speed * dt

	update_player(g, dt)

	ds := g.speed * dt
	pbox := player_box(g.player)

	i := 0
	for i < len(g.obstacles) {
		ob := &g.obstacles[i]
		ob.z += ds
		if ob.z > DESPAWN_Z {
			unordered_remove(&g.obstacles, i)
			continue
		}
		if abs(ob.z) < 3 && rl.CheckCollisionBoxes(pbox, obstacle_box(ob^)) {
			kill_player(g)
			return
		}
		i += 1
	}

	i = 0
	for i < len(g.coins) {
		c := &g.coins[i]
		c.z += ds
		if c.z > DESPAWN_Z {
			unordered_remove(&g.coins, i)
			continue
		}
		if abs(c.z) < 0.8 && abs(f32(c.lane) * LANE_WIDTH - g.player.x) < 0.9 {
			g.coin_count += 1
			unordered_remove(&g.coins, i)
			continue
		}
		i += 1
	}

	update_spawns(g, dt)
}

// --- Drawing -----------------------------------------------------------

make_camera :: proc(g: ^Game) -> rl.Camera3D {
	p := g.player
	shake: rl.Vector3
	if g.state == .Dead && g.death_timer < 0.45 {
		k := (0.45 - g.death_timer) * 0.6
		shake = {(rand.float32() - 0.5) * k, (rand.float32() - 0.5) * k, 0}
	}
	cam: rl.Camera3D
	cam.position = rl.Vector3{p.x * 0.50, 4.4 + p.y * 0.30, 7.2} + shake
	cam.target = rl.Vector3{p.x * 0.72, 1.5 + p.y * 0.45, -4.0}
	cam.up = {0, 1, 0}
	cam.fovy = 58 + (g.speed - BASE_SPEED) / (MAX_SPEED - BASE_SPEED) * 10 // speed-FOV kick
	cam.projection = .PERSPECTIVE
	return cam
}

draw_track :: proc(g: ^Game) {
	// scrolling floor tiles + wall segments (segmented so fog fade works)
	offset := math.mod(g.distance, 8)
	for i in 0 ..< 40 {
		zc := 8.0 + offset - f32(i) * 4.0 - 2.0
		fc := fade_z(i % 2 == 0 ? FLOOR_A : FLOOR_B, zc)
		rl.DrawCube({0, -0.1, zc}, TRACK_HALF * 2 + 0.4, 0.2, 4.0, fc)
		wc := fade_z(WALL_C, zc)
		rl.DrawCube({-(TRACK_HALF + 1.35), 1.1, zc}, 1.1, 2.2, 4.0, wc)
		rl.DrawCube({+(TRACK_HALF + 1.35), 1.1, zc}, 1.1, 2.2, 4.0, wc)
	}

	// lane divider lines
	rl.DrawCube({-LANE_WIDTH / 2, 0.02, -65}, 0.07, 0.03, 150, rl.Color{210, 198, 160, 70})
	rl.DrawCube({+LANE_WIDTH / 2, 0.02, -65}, 0.07, 0.03, 150, rl.Color{210, 198, 160, 70})

	// scrolling pillars along the walls
	poff := math.mod(g.distance, 12)
	for i in 0 ..< 14 {
		z := 8.0 + poff - f32(i) * 12.0
		pc := fade_z(PILLAR_C, z)
		cc := fade_z(PILLAR_CAP, z)
		for sx in ([?]f32{-1, 1}) {
			x := sx * (TRACK_HALF + 1.35)
			rl.DrawCube({x, 2.1, z}, 1.3, 4.2, 1.3, pc)
			rl.DrawCube({x, 4.45, z}, 1.7, 0.5, 1.7, cc)
		}
	}
}

draw_obstacle :: proc(ob: Obstacle) {
	x := f32(ob.lane) * LANE_WIDTH
	switch ob.kind {
	case .Low:
		rl.DrawCube({x, 0.475, ob.z}, 2.5, 0.95, 0.5, fade_z(WOOD, ob.z))
		rl.DrawCube({x - 1.1, 0.45, ob.z}, 0.28, 0.9, 0.7, fade_z(WOOD_DARK, ob.z))
		rl.DrawCube({x + 1.1, 0.45, ob.z}, 0.28, 0.9, 0.7, fade_z(WOOD_DARK, ob.z))
	case .High:
		rl.DrawCube({x, 2.27, ob.z}, 2.5, 2.25, 0.55, fade_z(STONE, ob.z))
		rl.DrawCube({x - 1.2, 1.7, ob.z}, 0.35, 3.4, 0.7, fade_z(STONE_DARK, ob.z))
		rl.DrawCube({x + 1.2, 1.7, ob.z}, 0.35, 3.4, 0.7, fade_z(STONE_DARK, ob.z))
	case .Block:
		rl.DrawCube({x, 1.7, ob.z}, 2.6, 3.4, 1.0, fade_z(STONE_DARK, ob.z))
		rl.DrawCube({x, 3.5, ob.z}, 2.8, 0.35, 1.2, fade_z(STONE, ob.z))
	}
}

draw_coin :: proc(g: ^Game, c: Coin) {
	x := f32(c.lane) * LANE_WIDTH
	y := 1.0 + math.sin(g.time * 4 + c.z * 0.5) * 0.12
	s := math.sin(g.time * 5)
	co := math.cos(g.time * 5)
	a := rl.Vector3{x - 0.05 * s, y, c.z - 0.05 * co}
	b := rl.Vector3{x + 0.05 * s, y, c.z + 0.05 * co}
	rl.DrawCylinderEx(a, b, 0.32, 0.32, 12, fade_z(GOLD, c.z))
}

draw_player :: proc(g: ^Game) {
	p := g.player
	grounded := p.y <= 0.01
	phase := g.distance * 2.2

	bob: f32
	if grounded && !p.sliding && g.state == .Playing do bob = abs(math.sin(phase)) * 0.1
	y := p.y + bob

	body := g.state == .Dead ? rl.Color{200, 40, 40, 255} : BODY_C

	// blob shadow
	sr := 0.42 / (1 + p.y * 0.2)
	rl.DrawCylinder({p.x, 0.005, 0}, sr, sr, 0.01, 16, rl.Fade(rl.BLACK, 0.35))

	if p.sliding {
		rl.DrawCube({p.x, y + 0.30, 0.1}, 0.8, 0.5, 1.0, body)
		rl.DrawSphere({p.x, y + 0.62, -0.45}, 0.22, SKIN_C)
	} else {
		lo := grounded ? math.sin(phase) * 0.28 : 0.22
		rl.DrawCube({p.x - 0.18, y + 0.35, lo}, 0.22, 0.7, 0.22, LIMB_C)
		rl.DrawCube({p.x + 0.18, y + 0.35, -lo}, 0.22, 0.7, 0.22, LIMB_C)
		rl.DrawCube({p.x, y + 1.10, 0}, 0.72, 0.8, 0.45, body)
		rl.DrawCube({p.x - 0.46, y + 1.15, -lo * 0.8}, 0.16, 0.55, 0.16, SKIN_C)
		rl.DrawCube({p.x + 0.46, y + 1.15, lo * 0.8}, 0.16, 0.55, 0.16, SKIN_C)
		rl.DrawSphere({p.x, y + 1.68, 0}, 0.23, SKIN_C)
	}
}

draw_world :: proc(g: ^Game) {
	rl.ClearBackground(SKY_TOP) // also clears the depth buffer — required for 3D
	rl.DrawRectangleGradientV(0, 0, WIN_W, WIN_H, SKY_TOP, SKY_BOTTOM)
	rl.DrawCircle(WIN_W - 260, 130, 55, rl.Color{235, 225, 200, 40})
	rl.DrawCircle(WIN_W - 260, 130, 42, rl.Color{235, 225, 205, 230})

	cam := make_camera(g)
	rl.BeginMode3D(cam)
	draw_track(g)
	for ob in g.obstacles do draw_obstacle(ob)
	for c in g.coins do draw_coin(g, c)
	draw_player(g)
	rl.EndMode3D()
}

center_text :: proc(text: cstring, y, size: i32, color: rl.Color) {
	x := WIN_W / 2 - rl.MeasureText(text, size) / 2
	rl.DrawText(text, x + 2, y + 2, size, rl.Fade(rl.BLACK, 0.6))
	rl.DrawText(text, x, y, size, color)
}

draw_hud :: proc(g: ^Game) {
	switch g.state {
	case .Menu:
		rl.DrawRectangle(0, 0, WIN_W, WIN_H, rl.Fade(rl.BLACK, 0.35))
		center_text("TEMPLE RUN", 160, 84, GOLD)
		center_text("odin + raylib", 250, 22, rl.RAYWHITE)
		center_text("A / D  or  arrows — switch lane", 380, 24, rl.RAYWHITE)
		center_text("SPACE / W — jump        S / DOWN — slide", 415, 24, rl.RAYWHITE)
		center_text("P / ESC — pause        ESC (menu) — quit", 450, 24, rl.RAYWHITE)
		if g.high_score > 0 {
			center_text(fmt.ctprintf("BEST  %v", g.high_score), 510, 26, GOLD)
		}
		blink := math.mod(g.time, 1.0) < 0.6
		if blink do center_text("press SPACE to run", 580, 32, rl.Color{120, 235, 140, 255})

	case .Playing:
		rl.DrawRectangle(16, 14, 260, 104, rl.Fade(rl.BLACK, 0.45))
		rl.DrawText(fmt.ctprintf("SCORE  %v", score(g)), 30, 24, 30, rl.RAYWHITE)
		rl.DrawText(fmt.ctprintf("COINS  %v", g.coin_count), 30, 58, 22, GOLD)
		rl.DrawText(fmt.ctprintf("SPEED  %.0f", g.speed), 30, 86, 22, rl.Color{140, 200, 255, 255})
		if g.high_score > 0 {
			t := fmt.ctprintf("BEST  %v", g.high_score)
			rl.DrawText(t, WIN_W - 30 - rl.MeasureText(t, 24), 24, 24, rl.Fade(GOLD, 0.8))
		}
		if g.paused {
			rl.DrawRectangle(0, 0, WIN_W, WIN_H, rl.Fade(rl.BLACK, 0.5))
			center_text("PAUSED", 300, 60, rl.RAYWHITE)
			center_text("P to resume", 380, 24, rl.RAYWHITE)
		}

	case .Dead:
		rl.DrawRectangle(0, 0, WIN_W, WIN_H, rl.Fade(rl.BLACK, 0.55))
		center_text("YOU CRASHED", 200, 68, rl.Color{235, 80, 60, 255})
		center_text(fmt.ctprintf("SCORE  %v", score(g)), 310, 40, rl.RAYWHITE)
		center_text(
			fmt.ctprintf("distance %vm   +   %v coins x 10", int(g.distance), g.coin_count),
			365, 22, rl.LIGHTGRAY,
		)
		if g.new_best {
			center_text("NEW BEST!", 415, 30, GOLD)
		} else {
			center_text(fmt.ctprintf("BEST  %v", g.high_score), 415, 26, GOLD)
		}
		if g.death_timer > 0.4 && math.mod(g.time, 1.0) < 0.6 {
			center_text("press SPACE to run again", 520, 30, rl.Color{120, 235, 140, 255})
		}
	}
}

// --- Main --------------------------------------------------------------

main :: proc() {
	rand.reset(u64(time.time_to_unix_nano(time.now())))

	rl.SetConfigFlags({.VSYNC_HINT, .MSAA_4X_HINT})
	rl.InitWindow(WIN_W, WIN_H, "Temple Run — Odin + raylib")
	defer rl.CloseWindow()
	rl.SetTargetFPS(120)
	rl.SetExitKey(.KEY_NULL) // ESC handled per-state below

	g: Game
	defer delete(g.obstacles)
	defer delete(g.coins)
	g.state = .Menu
	reset_run(&g)

	quit := false
	for !rl.WindowShouldClose() && !quit {
		dt := min(rl.GetFrameTime(), f32(1.0 / 20.0))
		g.time += dt

		switch g.state {
		case .Menu:
			if rl.IsKeyPressed(.ESCAPE) do quit = true
			if rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.ENTER) {
				reset_run(&g)
				g.state = .Playing
			}
		case .Playing:
			if rl.IsKeyPressed(.P) || rl.IsKeyPressed(.ESCAPE) do g.paused = !g.paused
			if !g.paused do update_playing(&g, dt)
		case .Dead:
			g.death_timer += dt
			if rl.IsKeyPressed(.ESCAPE) do g.state = .Menu
			if g.death_timer > 0.4 && (rl.IsKeyPressed(.SPACE) || rl.IsKeyPressed(.ENTER)) {
				reset_run(&g)
				g.state = .Playing
			}
		}

		rl.BeginDrawing()
		draw_world(&g)
		draw_hud(&g)
		rl.EndDrawing()

		free_all(context.temp_allocator)
	}
}

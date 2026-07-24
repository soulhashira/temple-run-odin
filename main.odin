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
			spawn_dust({p.x, 0.05, 0.2}, 6, 2.5, 0.4)
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
	spawn_death_burst({g.player.x, 1.2, 0.2})
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
			spawn_coin_burst({f32(c.lane) * LANE_WIDTH, 1.0, c.z})
			unordered_remove(&g.coins, i)
			continue
		}
		i += 1
	}

	update_spawns(g, dt)
	update_effects(g, dt)
}

// --- HUD ---------------------------------------------------------------

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

	init_renderer()
	defer shutdown_renderer()

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
			update_particles(0, dt)
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

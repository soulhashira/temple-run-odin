// render.odin — all drawing for the temple run clone:
// per-pixel lighting shader, procedural textures, mesh pipeline,
// torches, particles, sky, and the post-processing pass.
package temple_run

import "core:math"
import "core:math/rand"
import rl "vendor:raylib"

// --- Palette -----------------------------------------------------------

SKY_TOP    :: rl.Color{16, 14, 34, 255}
SKY_BOTTOM :: rl.Color{78, 42, 66, 255}
FOG        :: rl.Color{30, 22, 46, 255}
GOLD       :: rl.Color{255, 200, 40, 255}
BODY_C     :: rl.Color{226, 88, 58, 255}
SKIN_C     :: rl.Color{243, 204, 168, 255}
LIMB_C     :: rl.Color{62, 44, 40, 255}

MAX_LIGHTS    :: 16
MAX_PARTICLES :: 512
STAR_COUNT    :: 140

// --- Shaders -----------------------------------------------------------

LIGHT_VS: cstring : `#version 330
in vec3 vertexPosition;
in vec2 vertexTexCoord;
in vec3 vertexNormal;
in vec4 vertexColor;
uniform mat4 mvp;
uniform mat4 matModel;
uniform mat4 matNormal;
out vec3 fragPosition;
out vec2 fragTexCoord;
out vec4 fragColor;
out vec3 fragNormal;
void main()
{
    fragPosition = vec3(matModel*vec4(vertexPosition, 1.0));
    fragTexCoord = vertexTexCoord;
    fragColor = vertexColor;
    fragNormal = normalize(vec3(matNormal*vec4(vertexNormal, 0.0)));
    gl_Position = mvp*vec4(vertexPosition, 1.0);
}`

LIGHT_FS: cstring : `#version 330
in vec3 fragPosition;
in vec2 fragTexCoord;
in vec4 fragColor;
in vec3 fragNormal;
uniform sampler2D texture0;
uniform vec4 colDiffuse;
out vec4 finalColor;

#define MAX_LIGHTS 16
uniform vec3 lightPos[MAX_LIGHTS];
uniform vec3 lightColor[MAX_LIGHTS];
uniform int lightCount;
uniform vec3 viewPos;
uniform vec3 sunDir;
uniform vec3 sunColor;
uniform vec3 ambientColor;
uniform vec3 fogColor;
uniform float fogDensity;

void main()
{
    vec4 texel = texture(texture0, fragTexCoord)*colDiffuse*fragColor;
    vec3 albedo = texel.rgb;
    vec3 N = normalize(fragNormal);
    vec3 V = normalize(viewPos - fragPosition);

    vec3 light = ambientColor;
    vec3 spec = vec3(0.0);

    float ndl = max(dot(N, -sunDir), 0.0);
    light += sunColor*ndl;
    if (ndl > 0.0)
    {
        vec3 H = normalize(V - sunDir);
        spec += sunColor*pow(max(dot(N, H), 0.0), 32.0)*0.4;
    }

    for (int i = 0; i < lightCount; i++)
    {
        vec3 Ld = lightPos[i] - fragPosition;
        float dist = length(Ld);
        vec3 L = Ld/max(dist, 0.0001);
        float atten = 1.0/(1.0 + 0.10*dist + 0.035*dist*dist);
        float diff = max(dot(N, L), 0.0);
        light += lightColor[i]*(diff*atten);
        if (diff > 0.0)
        {
            vec3 H = normalize(V + L);
            spec += lightColor[i]*(pow(max(dot(N, H), 0.0), 24.0)*atten*0.5);
        }
    }

    vec3 color = albedo*light + spec;

    float d = length(viewPos - fragPosition);
    float f = 1.0 - exp(-fogDensity*fogDensity*d*d);
    color = mix(color, fogColor, clamp(f, 0.0, 1.0));

    finalColor = vec4(color, texel.a);
}`

POST_FS: cstring : `#version 330
in vec2 fragTexCoord;
uniform sampler2D texture0;
uniform float time;
uniform float aberration;
uniform vec2 resolution;
out vec4 finalColor;
void main()
{
    vec2 uv = fragTexCoord;
    vec2 c = uv - vec2(0.5);
    float r2 = dot(c, c);
    vec2 off = c*r2*aberration*3.0;
    vec3 col;
    col.r = texture(texture0, uv + off).r;
    col.g = texture(texture0, uv).g;
    col.b = texture(texture0, uv - off).b;
    col = pow(col, vec3(0.90));
    float luma = dot(col, vec3(0.299, 0.587, 0.114));
    col = mix(vec3(luma), col, 1.14);
    col *= 1.0 - 0.5*smoothstep(0.18, 0.85, r2);
    float g = fract(sin(dot(uv*resolution + vec2(time*37.0, time*17.0), vec2(12.9898, 78.233)))*43758.5453);
    col += (g - 0.5)*0.04;
    finalColor = vec4(col, 1.0);
}`

// --- Renderer state ------------------------------------------------------

Star :: struct {
	x, y, size, phase, speed: f32,
}

Torch :: struct {
	pos:   rl.Vector3, // flame position
	side:  f32,
	flick: f32,
}

Particle :: struct {
	pos, vel: rl.Vector3,
	life:     f32,
	ttl:      f32,
	size:     f32,
	col:      rl.Color,
	grav:     f32,
	additive: bool,
}

Renderer :: struct {
	shader: rl.Shader,
	post:   rl.Shader,
	rt:     rl.RenderTexture2D,
	cam:    rl.Camera3D,

	mesh_cube:   rl.Mesh,
	mesh_sphere: rl.Mesh,
	mesh_cyl:    rl.Mesh,
	mesh_plane:  rl.Mesh,

	tex_floor: rl.Texture2D,
	tex_brick: rl.Texture2D,
	tex_stone: rl.Texture2D,
	tex_wood:  rl.Texture2D,
	tex_white: rl.Texture2D,
	tex_glow:  rl.Texture2D,

	mat_floor:  rl.Material,
	mat_brick:  rl.Material,
	mat_stone:  rl.Material,
	mat_wood:   rl.Material,
	mat_gold:   rl.Material,
	mat_flat:   rl.Material, // lit, white texture, tinted per draw
	mat_shadow: rl.Material, // unlit soft blob
	mat_flame:  rl.Material, // unlit emissive bits

	loc_view:        i32,
	loc_light_count: i32,
	loc_light_pos:   i32,
	loc_light_col:   i32,
	loc_ptime:       i32,
	loc_aberr:       i32,

	lights_pos:  [MAX_LIGHTS]rl.Vector3,
	lights_col:  [MAX_LIGHTS]rl.Vector3,
	light_count: i32,

	torches:     [24]Torch,
	torch_count: int,

	stars: [STAR_COUNT]Star,

	particles:      [MAX_PARTICLES]Particle,
	particle_count: int,

	last_step: int, // footstep phase tracker
	dust_acc:  f32, // slide dust spawn accumulator
}

rd: Renderer

// --- Small math helpers --------------------------------------------------

norm3 :: proc(v: rl.Vector3) -> rl.Vector3 {
	l := math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
	return v / l
}

mat_translate :: proc(x, y, z: f32) -> rl.Matrix {
	return {
		1, 0, 0, x,
		0, 1, 0, y,
		0, 0, 1, z,
		0, 0, 0, 1,
	}
}

mat_scale :: proc(x, y, z: f32) -> rl.Matrix {
	return {
		x, 0, 0, 0,
		0, y, 0, 0,
		0, 0, z, 0,
		0, 0, 0, 1,
	}
}

mat_ts :: proc(t, s: rl.Vector3) -> rl.Matrix {
	return {
		s.x, 0, 0, t.x,
		0, s.y, 0, t.y,
		0, 0, s.z, t.z,
		0, 0, 0, 1,
	}
}

mat_rot_x :: proc(a: f32) -> rl.Matrix {
	c := math.cos(a)
	s := math.sin(a)
	return {
		1, 0, 0, 0,
		0, c, -s, 0,
		0, s, c, 0,
		0, 0, 0, 1,
	}
}

mat_rot_y :: proc(a: f32) -> rl.Matrix {
	c := math.cos(a)
	s := math.sin(a)
	return {
		c, 0, s, 0,
		0, 1, 0, 0,
		-s, 0, c, 0,
		0, 0, 0, 1,
	}
}

mat_rot_z :: proc(a: f32) -> rl.Matrix {
	c := math.cos(a)
	s := math.sin(a)
	return {
		c, -s, 0, 0,
		s, c, 0, 0,
		0, 0, 1, 0,
		0, 0, 0, 1,
	}
}

// --- Procedural texture generation ----------------------------------------

hash01 :: proc(x, y: i32) -> f32 {
	h := u32(x)*0x27d4eb2d + u32(y)*0x9e3779b9
	h ~= h >> 15
	h *= 0x85ebca6b
	h ~= h >> 13
	return f32(h & 0xffffff) / f32(0xffffff)
}

vnoise :: proc(x, y: f32) -> f32 {
	fx := math.floor(x)
	fy := math.floor(y)
	xi := i32(fx)
	yi := i32(fy)
	xf := x - fx
	yf := y - fy
	sx := xf*xf*(3 - 2*xf)
	sy := yf*yf*(3 - 2*yf)
	a := hash01(xi, yi)
	b := hash01(xi + 1, yi)
	c := hash01(xi, yi + 1)
	d := hash01(xi + 1, yi + 1)
	return a + (b - a)*sx + (c - a)*sy + (a - b - c + d)*sx*sy
}

fbm :: proc(x, y: f32) -> f32 {
	return vnoise(x, y)*0.55 + vnoise(x*2.1 + 13, y*2.1 + 7)*0.28 + vnoise(x*4.3 + 31, y*4.3 + 17)*0.17
}

tex_from_pixels :: proc(pix: []rl.Color, w, h: i32) -> rl.Texture2D {
	img := rl.Image {
		data    = raw_data(pix),
		width   = w,
		height  = h,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	t := rl.LoadTextureFromImage(img)
	rl.GenTextureMipmaps(&t)
	rl.SetTextureFilter(t, .TRILINEAR)
	return t
}

make_floor_texture :: proc() -> rl.Texture2D {
	W :: 256
	H :: 256
	COLS :: 7
	ROWS :: 3
	pix := make([]rl.Color, W*H)
	defer delete(pix)
	for y in 0 ..< H {
		for x in 0 ..< W {
			cx := x*COLS/W
			cy := y*ROWS/H
			x0 := cx*W/COLS
			x1 := (cx + 1)*W/COLS
			y0 := cy*H/ROWS
			y1 := (cy + 1)*H/ROWS
			edge := min(x - x0, x1 - 1 - x, y - y0, y1 - 1 - y)
			n := fbm(f32(x)*0.055, f32(y)*0.055)
			r, gc, b: f32
			if edge < 2 {
				m := 0.75 + 0.5*n
				r = 50*m
				gc = 44*m
				b = 40*m
			} else {
				tb := 0.80 + 0.34*hash01(i32(cx)*7 + 3, i32(cy)*13 + 5)
				br := (0.72 + 0.5*n)*tb
				if edge < 5 do br *= 0.88
				r = 122*br
				gc = 108*br
				b = 88*br
			}
			pix[y*W + x] = {u8(clamp(r, 0, 255)), u8(clamp(gc, 0, 255)), u8(clamp(b, 0, 255)), 255}
		}
	}
	return tex_from_pixels(pix, W, H)
}

make_brick_texture :: proc() -> rl.Texture2D {
	W :: 256
	H :: 256
	BH :: 51
	BW :: 86
	pix := make([]rl.Color, W*H)
	defer delete(pix)
	for y in 0 ..< H {
		row := y/BH
		yy := y % BH
		off := row % 2 == 0 ? 0 : BW/2
		for x in 0 ..< W {
			xx := (x + off) % BW
			bi := (x + off)/BW
			n := fbm(f32(x)*0.05, f32(y)*0.05)
			r, gc, b: f32
			if yy < 4 || xx < 4 {
				m := 0.7 + 0.5*n
				r = 44*m
				gc = 38*m
				b = 54*m
			} else {
				tb := 0.78 + 0.4*hash01(i32(bi)*11 + 1, i32(row)*17 + 9)
				br := (0.74 + 0.45*n)*tb
				r = 98*br
				gc = 84*br
				b = 112*br
				mo := vnoise(f32(x)*0.018 + 40, f32(y)*0.018 + 90)
				if mo > 0.60 {
					k := clamp((mo - 0.60)*2.8, 0, 0.55)
					r = r*(1 - k) + 58*k
					gc = gc*(1 - k) + 92*k
					b = b*(1 - k) + 52*k
				}
			}
			pix[y*W + x] = {u8(clamp(r, 0, 255)), u8(clamp(gc, 0, 255)), u8(clamp(b, 0, 255)), 255}
		}
	}
	return tex_from_pixels(pix, W, H)
}

make_stone_texture :: proc() -> rl.Texture2D {
	W :: 256
	H :: 256
	pix := make([]rl.Color, W*H)
	defer delete(pix)
	for y in 0 ..< H {
		band := y % 64
		for x in 0 ..< W {
			n := fbm(f32(x)*0.045 + 200, f32(y)*0.045)
			br := 0.72 + 0.42*n
			if band >= 58 {
				br *= 0.55
			} else if band < 3 {
				br *= 1.10
			}
			pix[y*W + x] = {u8(clamp(136*br, 0, 255)), u8(clamp(122*br, 0, 255)), u8(clamp(102*br, 0, 255)), 255}
		}
	}
	return tex_from_pixels(pix, W, H)
}

make_wood_texture :: proc() -> rl.Texture2D {
	W :: 256
	H :: 256
	PL :: 64
	pix := make([]rl.Color, W*H)
	defer delete(pix)
	for y in 0 ..< H {
		row := y/PL
		yy := y % PL
		for x in 0 ..< W {
			gn := vnoise(f32(x)*0.05 + f32(row)*37, f32(y)*0.6)
			tb := 0.76 + 0.4*hash01(i32(row)*29 + 7, 3)
			br := (0.72 + 0.42*gn)*tb
			r, gc, b: f32
			if yy < 3 {
				r = 52*br
				gc = 34*br
				b = 20*br
			} else {
				r = 156*br
				gc = 100*br
				b = 52*br
			}
			pix[y*W + x] = {u8(clamp(r, 0, 255)), u8(clamp(gc, 0, 255)), u8(clamp(b, 0, 255)), 255}
		}
	}
	return tex_from_pixels(pix, W, H)
}

make_white_texture :: proc() -> rl.Texture2D {
	pix := make([]rl.Color, 16)
	defer delete(pix)
	for i in 0 ..< 16 do pix[i] = rl.WHITE
	return tex_from_pixels(pix, 4, 4)
}

make_glow_texture :: proc() -> rl.Texture2D {
	W :: 64
	pix := make([]rl.Color, W*W)
	defer delete(pix)
	for y in 0 ..< W {
		for x in 0 ..< W {
			dx := (f32(x) + 0.5)/W*2 - 1
			dy := (f32(y) + 0.5)/W*2 - 1
			r := math.sqrt(dx*dx + dy*dy)
			a := clamp(1 - r, 0, 1)
			a = a*a*(a*0.6 + 0.4) // soft shoulder, long tail
			pix[y*W + x] = {255, 255, 255, u8(255*a)}
		}
	}
	return tex_from_pixels(pix, W, W)
}

// --- Init / shutdown -------------------------------------------------------

shader_set3 :: proc(sh: rl.Shader, name: cstring, v: rl.Vector3) {
	v := v
	rl.SetShaderValue(sh, rl.GetShaderLocation(sh, name), &v, .VEC3)
}

shader_set1 :: proc(sh: rl.Shader, name: cstring, f: f32) {
	f := f
	rl.SetShaderValue(sh, rl.GetShaderLocation(sh, name), &f, .FLOAT)
}

lit_material :: proc(tex: rl.Texture2D) -> rl.Material {
	m := rl.LoadMaterialDefault()
	m.shader = rd.shader
	m.maps[0].texture = tex
	return m
}

flat_material :: proc(tex: rl.Texture2D) -> rl.Material {
	m := rl.LoadMaterialDefault()
	m.maps[0].texture = tex
	return m
}

init_renderer :: proc() {
	rd.shader = rl.LoadShaderFromMemory(LIGHT_VS, LIGHT_FS)
	rd.loc_view = rl.GetShaderLocation(rd.shader, "viewPos")
	rd.loc_light_count = rl.GetShaderLocation(rd.shader, "lightCount")
	rd.loc_light_pos = rl.GetShaderLocation(rd.shader, "lightPos[0]")
	rd.loc_light_col = rl.GetShaderLocation(rd.shader, "lightColor[0]")
	rd.shader.locs[rl.ShaderLocationIndex.VECTOR_VIEW] = rd.loc_view

	shader_set3(rd.shader, "ambientColor", {0.20, 0.19, 0.28})
	shader_set3(rd.shader, "sunDir", norm3({-0.36, -0.88, -0.31}))
	shader_set3(rd.shader, "sunColor", {0.33, 0.37, 0.52})
	shader_set3(rd.shader, "fogColor", {f32(FOG.r)/255.0, f32(FOG.g)/255.0, f32(FOG.b)/255.0})
	shader_set1(rd.shader, "fogDensity", 0.015)

	rd.post = rl.LoadShaderFromMemory(nil, POST_FS)
	rd.loc_ptime = rl.GetShaderLocation(rd.post, "time")
	rd.loc_aberr = rl.GetShaderLocation(rd.post, "aberration")
	res := rl.Vector2{WIN_W, WIN_H}
	rl.SetShaderValue(rd.post, rl.GetShaderLocation(rd.post, "resolution"), &res, .VEC2)

	rd.rt = rl.LoadRenderTexture(WIN_W, WIN_H)
	rl.SetTextureFilter(rd.rt.texture, .BILINEAR)
	rl.SetTextureWrap(rd.rt.texture, .CLAMP)

	rd.mesh_cube = rl.GenMeshCube(1, 1, 1)
	rd.mesh_sphere = rl.GenMeshSphere(1, 12, 18)
	rd.mesh_cyl = rl.GenMeshCylinder(1, 1, 20)
	rd.mesh_plane = rl.GenMeshPlane(1, 1, 1, 1)

	rd.tex_floor = make_floor_texture()
	rd.tex_brick = make_brick_texture()
	rd.tex_stone = make_stone_texture()
	rd.tex_wood = make_wood_texture()
	rd.tex_white = make_white_texture()
	rd.tex_glow = make_glow_texture()

	rd.mat_floor = lit_material(rd.tex_floor)
	rd.mat_brick = lit_material(rd.tex_brick)
	rd.mat_stone = lit_material(rd.tex_stone)
	rd.mat_wood = lit_material(rd.tex_wood)
	rd.mat_gold = lit_material(rd.tex_white)
	rd.mat_flat = lit_material(rd.tex_white)
	rd.mat_shadow = flat_material(rd.tex_glow)
	rd.mat_flame = flat_material(rd.tex_white)

	for i in 0 ..< STAR_COUNT {
		rd.stars[i] = {
			x     = hash01(i32(i), 11)*WIN_W,
			y     = hash01(i32(i), 313)*(WIN_H*0.52),
			size  = 1 + hash01(i32(i), 71)*1.8,
			phase = hash01(i32(i), 97)*6.28,
			speed = 0.6 + hash01(i32(i), 131)*2.2,
		}
	}
}

shutdown_renderer :: proc() {
	rl.UnloadMesh(rd.mesh_cube)
	rl.UnloadMesh(rd.mesh_sphere)
	rl.UnloadMesh(rd.mesh_cyl)
	rl.UnloadMesh(rd.mesh_plane)
	rl.UnloadTexture(rd.tex_floor)
	rl.UnloadTexture(rd.tex_brick)
	rl.UnloadTexture(rd.tex_stone)
	rl.UnloadTexture(rd.tex_wood)
	rl.UnloadTexture(rd.tex_white)
	rl.UnloadTexture(rd.tex_glow)
	rl.UnloadRenderTexture(rd.rt)
	rl.UnloadShader(rd.shader)
	rl.UnloadShader(rd.post)
}

// --- Torches / lights --------------------------------------------------------

torch_flicker :: proc(t, seed: f32) -> f32 {
	n := 0.5 + 0.31*math.sin(t*13.7 + seed*2.63) + 0.19*math.sin(t*31.3 + seed*5.97)
	return 0.62 + 0.48*clamp(n, 0, 1)
}

collect_torches :: proc(g: ^Game) {
	rd.torch_count = 0
	rd.light_count = 0
	poff := math.mod(g.distance, 12)
	base_id := int(g.distance/12)
	for i in 0 ..< 10 {
		z := 8.0 + poff - f32(i)*12.0
		for side in ([?]f32{-1, 1}) {
			if rd.torch_count >= len(rd.torches) do continue
			seed := f32((base_id + i)*2 + (side > 0 ? 1 : 0))
			fl := torch_flicker(g.time, seed)
			pos := rl.Vector3{side*(TRACK_HALF + 0.45), 3.1, z}
			rd.torches[rd.torch_count] = {pos, side, fl}
			rd.torch_count += 1
			if z < 9 && rd.light_count < MAX_LIGHTS {
				c := 2.3*fl
				rd.lights_pos[rd.light_count] = pos + {side*(-0.15), 0.25, 0}
				rd.lights_col[rd.light_count] = {1.00*c, 0.52*c, 0.20*c}
				rd.light_count += 1
			}
		}
	}
}

apply_frame_uniforms :: proc() {
	v := rd.cam.position
	rl.SetShaderValue(rd.shader, rd.loc_view, &v, .VEC3)
	rl.SetShaderValue(rd.shader, rd.loc_light_count, &rd.light_count, .INT)
	if rd.light_count > 0 {
		rl.SetShaderValueV(rd.shader, rd.loc_light_pos, raw_data(rd.lights_pos[:]), .VEC3, rd.light_count)
		rl.SetShaderValueV(rd.shader, rd.loc_light_col, raw_data(rd.lights_col[:]), .VEC3, rd.light_count)
	}
}

// --- Particles ----------------------------------------------------------------

spawn_particle :: proc(p: Particle) {
	if rd.particle_count >= MAX_PARTICLES do return
	q := p
	q.life = q.ttl
	rd.particles[rd.particle_count] = q
	rd.particle_count += 1
}

spawn_dust :: proc(pos: rl.Vector3, n: int, spread, size: f32) {
	for _ in 0 ..< n {
		spawn_particle(Particle{
			pos = pos + {(rand.float32() - 0.5)*0.3, rand.float32()*0.1, (rand.float32() - 0.5)*0.3},
			vel = {(rand.float32() - 0.5)*spread, 0.5 + rand.float32()*1.1, 0.8 + rand.float32()*1.2},
			ttl = 0.45 + rand.float32()*0.35,
			size = size*(0.7 + rand.float32()*0.7),
			col = {166, 148, 122, 255},
			grav = -1.6,
		})
	}
}

spawn_coin_burst :: proc(pos: rl.Vector3) {
	for _ in 0 ..< 10 {
		spawn_particle(Particle{
			pos = pos,
			vel = {(rand.float32() - 0.5)*4.0, (rand.float32() - 0.2)*3.5, (rand.float32() - 0.5)*3.0},
			ttl = 0.35 + rand.float32()*0.30,
			size = 0.18 + rand.float32()*0.12,
			col = {255, 205, 80, 255},
			grav = -5.0,
			additive = true,
		})
	}
}

spawn_death_burst :: proc(pos: rl.Vector3) {
	for _ in 0 ..< 14 {
		spawn_particle(Particle{
			pos = pos,
			vel = {(rand.float32() - 0.5)*7.0, rand.float32()*5.5, (rand.float32() - 0.3)*6.0},
			ttl = 0.6 + rand.float32()*0.5,
			size = 0.28 + rand.float32()*0.25,
			col = {120, 104, 90, 255},
			grav = -9.0,
		})
	}
	for _ in 0 ..< 12 {
		spawn_particle(Particle{
			pos = pos,
			vel = {(rand.float32() - 0.5)*8.0, rand.float32()*6.0, (rand.float32() - 0.3)*6.0},
			ttl = 0.4 + rand.float32()*0.4,
			size = 0.22 + rand.float32()*0.20,
			col = {255, 130, 50, 255},
			grav = -6.0,
			additive = true,
		})
	}
}

update_particles :: proc(scroll, dt: f32) {
	i := 0
	for i < rd.particle_count {
		p := &rd.particles[i]
		p.life -= dt
		if p.life <= 0 {
			rd.particles[i] = rd.particles[rd.particle_count - 1]
			rd.particle_count -= 1
			continue
		}
		p.vel.y += p.grav*dt
		p.pos += p.vel*dt
		p.pos.z += scroll
		i += 1
	}
}

draw_particles :: proc() {
	for i in 0 ..< rd.particle_count {
		p := rd.particles[i]
		if p.additive do continue
		a := p.life/p.ttl
		rl.DrawBillboard(rd.cam, rd.tex_glow, p.pos, p.size, rl.Fade(p.col, a*0.7))
	}
	rl.BeginBlendMode(.ADDITIVE)
	for i in 0 ..< rd.particle_count {
		p := rd.particles[i]
		if !p.additive do continue
		a := p.life/p.ttl
		rl.DrawBillboard(rd.cam, rd.tex_glow, p.pos, p.size, rl.Fade(p.col, a))
	}
	rl.EndBlendMode()
}

// --- Sky ------------------------------------------------------------------------

draw_sky :: proc(g: ^Game) {
	rl.DrawRectangleGradientV(0, 0, WIN_W, WIN_H, SKY_TOP, SKY_BOTTOM)
	for s in rd.stars {
		a := 0.35 + 0.65*(0.5 + 0.5*math.sin(g.time*s.speed + s.phase))
		rl.DrawRectangleRec({s.x, s.y, s.size, s.size}, rl.Fade({225, 228, 255, 255}, a*0.8))
	}
	mx: i32 = WIN_W - 260
	my: i32 = 130
	mc := rl.Vector2{f32(mx), f32(my)}
	rl.DrawCircleGradient(mc, 160, {226, 214, 182, 46}, {226, 214, 182, 0})
	rl.DrawCircleGradient(mc, 84, {232, 222, 194, 60}, {232, 222, 194, 0})
	rl.DrawCircle(mx, my, 42, {238, 231, 212, 255})
	rl.DrawCircle(mx - 12, my - 8, 7, {219, 210, 188, 255})
	rl.DrawCircle(mx + 10, my + 11, 5, {223, 214, 192, 255})
	rl.DrawCircle(mx + 16, my - 14, 4, {221, 212, 190, 255})
}

// --- 3D scene ---------------------------------------------------------------------

make_camera :: proc(g: ^Game) -> rl.Camera3D {
	p := g.player
	shake: rl.Vector3
	if g.state == .Dead && g.death_timer < 0.45 {
		k := (0.45 - g.death_timer)*0.6
		shake = {(rand.float32() - 0.5)*k, (rand.float32() - 0.5)*k, 0}
	}
	cam: rl.Camera3D
	cam.position = rl.Vector3{p.x*0.50, 4.4 + p.y*0.30, 7.2} + shake
	cam.target = rl.Vector3{p.x*0.72, 1.5 + p.y*0.45, -4.0}
	cam.up = {0, 1, 0}
	cam.fovy = 58 + (g.speed - BASE_SPEED)/(MAX_SPEED - BASE_SPEED)*10 // speed-FOV kick
	cam.projection = .PERSPECTIVE
	return cam
}

draw_box :: proc(m: ^rl.Material, center, size: rl.Vector3, tint: rl.Color = rl.WHITE) {
	m.maps[0].color = tint
	rl.DrawMesh(rd.mesh_cube, m^, mat_ts(center, size))
}

draw_track :: proc(g: ^Game) {
	offset := math.mod(g.distance, 8)
	for i in 0 ..< 30 {
		zc := 8.0 + offset - f32(i)*4.0 - 2.0
		tint := i % 2 == 0 ? rl.Color{255, 255, 255, 255} : rl.Color{228, 222, 214, 255}
		draw_box(&rd.mat_floor, {0, -0.1, zc}, {TRACK_HALF*2 + 0.4, 0.2, 4.0}, tint)
		draw_box(&rd.mat_brick, {-(TRACK_HALF + 1.35), 1.1, zc}, {1.1, 2.2, 4.0})
		draw_box(&rd.mat_brick, {+(TRACK_HALF + 1.35), 1.1, zc}, {1.1, 2.2, 4.0})
	}

	// lane divider lines
	draw_box(&rd.mat_flat, {-LANE_WIDTH/2, 0.02, -55}, {0.07, 0.03, 130}, {148, 138, 114, 255})
	draw_box(&rd.mat_flat, {+LANE_WIDTH/2, 0.02, -55}, {0.07, 0.03, 130}, {148, 138, 114, 255})

	// pillars along the walls
	poff := math.mod(g.distance, 12)
	for i in 0 ..< 10 {
		z := 8.0 + poff - f32(i)*12.0
		for sx in ([?]f32{-1, 1}) {
			x := sx*(TRACK_HALF + 1.35)
			draw_box(&rd.mat_stone, {x, 2.1, z}, {1.3, 4.2, 1.3})
			draw_box(&rd.mat_stone, {x, 4.45, z}, {1.7, 0.5, 1.7}, {214, 206, 190, 255})
		}
	}
}

draw_torches :: proc(g: ^Game) {
	for i in 0 ..< rd.torch_count {
		t := rd.torches[i]
		// sconce plate sunk into the wall
		draw_box(&rd.mat_stone, {t.side*(TRACK_HALF + 0.72), t.pos.y - 0.45, t.pos.z}, {0.16, 0.7, 0.3}, {170, 160, 150, 255})
		// angled wooden handle
		rd.mat_wood.maps[0].color = rl.WHITE
		hm := mat_translate(t.pos.x + t.side*0.17, t.pos.y - 0.33, t.pos.z)*mat_rot_z(t.side*0.5)*mat_scale(0.09, 0.62, 0.09)
		rl.DrawMesh(rd.mesh_cube, rd.mat_wood, hm)
		// flame: layered emissive blobs
		sway := math.sin(g.time*7.3 + t.pos.z)*0.03
		fp := t.pos + {sway, 0, 0}
		s := 0.10 + 0.05*t.flick
		rd.mat_flame.maps[0].color = {255, 140, 40, 255}
		rl.DrawMesh(rd.mesh_sphere, rd.mat_flame, mat_translate(fp.x, fp.y, fp.z)*mat_scale(s, s*1.8, s))
		rd.mat_flame.maps[0].color = {255, 226, 120, 255}
		rl.DrawMesh(rd.mesh_sphere, rd.mat_flame, mat_translate(fp.x, fp.y + 0.02, fp.z)*mat_scale(s*0.55, s*1.1, s*0.55))
	}
}

draw_torch_glows :: proc() {
	rl.BeginBlendMode(.ADDITIVE)
	for i in 0 ..< rd.torch_count {
		t := rd.torches[i]
		rl.DrawBillboard(rd.cam, rd.tex_glow, t.pos + {t.side*(-0.38), 0.1, 0}, 1.2*t.flick, rl.Fade({255, 150, 60, 255}, 0.45*t.flick))
	}
	rl.EndBlendMode()
}

draw_obstacle :: proc(ob: Obstacle) {
	x := f32(ob.lane)*LANE_WIDTH
	switch ob.kind {
	case .Low:
		draw_box(&rd.mat_wood, {x, 0.475, ob.z}, {2.5, 0.95, 0.5})
		draw_box(&rd.mat_wood, {x - 1.1, 0.45, ob.z}, {0.28, 0.9, 0.7}, {150, 132, 120, 255})
		draw_box(&rd.mat_wood, {x + 1.1, 0.45, ob.z}, {0.28, 0.9, 0.7}, {150, 132, 120, 255})
	case .High:
		draw_box(&rd.mat_stone, {x, 2.27, ob.z}, {2.5, 2.25, 0.55})
		draw_box(&rd.mat_stone, {x - 1.2, 1.7, ob.z}, {0.35, 3.4, 0.7}, {182, 176, 196, 255})
		draw_box(&rd.mat_stone, {x + 1.2, 1.7, ob.z}, {0.35, 3.4, 0.7}, {182, 176, 196, 255})
	case .Block:
		draw_box(&rd.mat_stone, {x, 1.7, ob.z}, {2.6, 3.4, 1.0}, {172, 168, 188, 255})
		draw_box(&rd.mat_stone, {x, 3.5, ob.z}, {2.8, 0.35, 1.2})
	}
}

draw_coin_mesh :: proc(g: ^Game, c: Coin) {
	x := f32(c.lane)*LANE_WIDTH
	y := 1.0 + math.sin(g.time*4 + c.z*0.5)*0.12
	spin := g.time*3.5 + c.z*0.7
	rd.mat_gold.maps[0].color = GOLD
	m := mat_translate(x, y, c.z)*mat_rot_y(spin)*mat_rot_x(math.PI/2)*mat_scale(0.34, 0.10, 0.34)*mat_translate(0, -0.5, 0)
	rl.DrawMesh(rd.mesh_cyl, rd.mat_gold, m)
}

draw_coin_glows :: proc(g: ^Game) {
	rl.BeginBlendMode(.ADDITIVE)
	for c in g.coins {
		x := f32(c.lane)*LANE_WIDTH
		y := 1.0 + math.sin(g.time*4 + c.z*0.5)*0.12
		pulse := 0.75 + 0.25*math.sin(g.time*6 + c.z)
		rl.DrawBillboard(rd.cam, rd.tex_glow, {x, y, c.z}, 0.85*pulse, rl.Fade({255, 190, 60, 255}, 0.22*pulse))
	}
	rl.EndBlendMode()
}

draw_player :: proc(g: ^Game) {
	p := g.player
	grounded := p.y <= 0.01
	phase := g.distance*2.2

	bob: f32
	if grounded && !p.sliding && g.state == .Playing do bob = abs(math.sin(phase))*0.1
	y := p.y + bob

	body := g.state == .Dead ? rl.Color{205, 60, 48, 255} : BODY_C

	// soft blob shadow
	ss := clamp(0.95/(1 + p.y*0.35), 0.3, 1.0)
	rd.mat_shadow.maps[0].color = {0, 0, 0, u8(150.0*ss)}
	rl.DrawMesh(rd.mesh_plane, rd.mat_shadow, mat_translate(p.x, 0.02, 0)*mat_scale(1.5*ss + 0.4, 1, 1.2*ss + 0.3))

	// lean into lane changes, slight forward tilt in the air
	lean := clamp((f32(p.lane)*LANE_WIDTH - p.x)*-0.14, -0.4, 0.4)
	tilt: f32 = grounded ? 0 : clamp(-p.vy*0.02, -0.25, 0.35)
	base := mat_translate(p.x, y, 0)*mat_rot_z(lean)*mat_rot_x(tilt)

	part :: proc(mesh: rl.Mesh, m: ^rl.Material, base: rl.Matrix, off, size: rl.Vector3, tint: rl.Color) {
		m.maps[0].color = tint
		rl.DrawMesh(mesh, m^, base*mat_ts(off, size))
	}

	if p.sliding {
		part(rd.mesh_cube, &rd.mat_flat, base, {0, 0.30, 0.1}, {0.8, 0.5, 1.0}, body)
		part(rd.mesh_sphere, &rd.mat_flat, base, {0, 0.62, -0.45}, {0.22, 0.22, 0.22}, SKIN_C)
	} else {
		lo := grounded ? math.sin(phase)*0.28 : 0.22
		part(rd.mesh_cube, &rd.mat_flat, base, {-0.18, 0.35, lo}, {0.22, 0.7, 0.22}, LIMB_C)
		part(rd.mesh_cube, &rd.mat_flat, base, {+0.18, 0.35, -lo}, {0.22, 0.7, 0.22}, LIMB_C)
		part(rd.mesh_cube, &rd.mat_flat, base, {0, 1.10, 0}, {0.72, 0.8, 0.45}, body)
		part(rd.mesh_cube, &rd.mat_flat, base, {-0.46, 1.15, -lo*0.8}, {0.16, 0.55, 0.16}, SKIN_C)
		part(rd.mesh_cube, &rd.mat_flat, base, {+0.46, 1.15, lo*0.8}, {0.16, 0.55, 0.16}, SKIN_C)
		part(rd.mesh_sphere, &rd.mat_flat, base, {0, 1.68, 0}, {0.23, 0.23, 0.23}, SKIN_C)
	}
}

// --- Per-frame visual effects driven by gameplay ------------------------------------

update_effects :: proc(g: ^Game, dt: f32) {
	p := g.player
	grounded := p.y <= 0.01

	// footstep dust: one half sine period per footfall
	step := int(g.distance*2.2/math.PI)
	if step != rd.last_step {
		rd.last_step = step
		if grounded && !p.sliding {
			spawn_dust({p.x, 0.05, 0.3}, 2, 1.2, 0.36)
		}
	}

	// slide dust trail
	if p.sliding && grounded {
		rd.dust_acc += dt
		if rd.dust_acc > 0.05 {
			rd.dust_acc = 0
			spawn_dust({p.x + (rand.float32() - 0.5)*0.7, 0.05, 0.5}, 2, 2.0, 0.35)
		}
	}

	update_particles(g.speed*dt, dt)
}

// --- Frame composition ----------------------------------------------------------------

draw_world :: proc(g: ^Game) {
	collect_torches(g)
	rd.cam = make_camera(g)
	apply_frame_uniforms()

	rl.BeginTextureMode(rd.rt)
	rl.ClearBackground(SKY_TOP) // also clears the depth buffer — required for 3D
	draw_sky(g)

	rl.BeginMode3D(rd.cam)
	draw_track(g)
	draw_torches(g)
	for ob in g.obstacles do draw_obstacle(ob)
	for c in g.coins do draw_coin_mesh(g, c)
	draw_player(g)
	draw_particles()
	draw_coin_glows(g)
	draw_torch_glows()
	rl.EndMode3D()
	rl.EndTextureMode()

	// post-process: grade + vignette + grain + speed-scaled chromatic aberration
	t := g.time
	rl.SetShaderValue(rd.post, rd.loc_ptime, &t, .FLOAT)
	ab := 0.003 + 0.011*clamp((g.speed - BASE_SPEED)/(MAX_SPEED - BASE_SPEED), 0, 1)
	if g.state == .Dead do ab = 0.015
	rl.SetShaderValue(rd.post, rd.loc_aberr, &ab, .FLOAT)

	rl.BeginShaderMode(rd.post)
	rl.DrawTextureRec(rd.rt.texture, {0, 0, WIN_W, -WIN_H}, {0, 0}, rl.WHITE)
	rl.EndShaderMode()
}

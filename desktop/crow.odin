package main

// cute little crow mascot that lives in the bottom left of the editor window
// ... you can even pet the crow. technology!

import project "../core/project"
import imgui "../vendor/imgui"
import "core:math"
import "core:math/rand"
import sdl "vendor:sdl3"

crow_tex: ^sdl.Texture

CrowBehavior :: enum {
	Idle,
	Step,
	Look,
	Pat,
}

CrowState :: struct {
	behavior:  CrowBehavior,
	x:         f32, // x offset from panel left edge (px)
	y:         f32, // y offset above panel bottom
	facing:    i32, // 1 = right, -1 = left
	// behavior progress
	rep:       i32, // remaining reps (steps / turns / pat bounces)
	rep_time:  f32,
	idle_left: f32, // seconds of idle remaining
	step_dir:  i32, // -1 left / +1 right for the step cycle
	pat_floor: f32, // y at pat start; bounces never go below it
}

crow: CrowState
crow_last_time: f32

crow_init :: proc(renderer: ^sdl.Renderer) -> bool {
	png := project.CrowBMP
	stream := sdl.IOFromConstMem(&png[0], len(png))
	if stream == nil {return false}
	surface := sdl.LoadBMP_IO(stream, true)
	if surface == nil {return false}
	defer sdl.DestroySurface(surface)
	crow_tex = sdl.CreateTextureFromSurface(renderer, surface)
	crow = CrowState {
		behavior  = .Idle,
		facing    = -1,
		idle_left = 3,
		step_dir  = 1,
	} 	// faces left
	return crow_tex != nil
}

crow_destroy :: proc() {
	if crow_tex != nil {
		sdl.DestroyTexture(crow_tex)
		crow_tex = nil
	}
}

// behavior transitions

crow_start_idle :: proc() {
	crow.behavior = .Idle
	crow.idle_left = 2 + f32(rand.int_max(5)) // 2-6s of resting
	crow.y = 0 // settle back to the ground
}

crow_start_step :: proc(dir: i32) {
	crow.behavior = .Step
	crow.step_dir = dir
	crow.facing = dir // face the way it's headed
	crow.rep = i32(1 + rand.int_max(3)) // 1-3 bounces
	crow.rep_time = 0
}

crow_start_look :: proc() {
	crow.behavior = .Look
	crow.rep = i32(1 + rand.int_max(3)) // 1-3 turns
	crow.rep_time = 0
	crow.facing = -crow.facing // first turn flips now
}

crow_start_pat :: proc() {
	crow.behavior = .Pat
	crow.rep = i32(2 + rand.int_max(2)) // 2-3 bounces
	crow.rep_time = 0
	crow.pat_floor = crow.y // keep current height; never drop below it
}

// per-frame update

crow_update :: proc(dt: f32, min_x, max_x: f32) {
	if crow_tex == nil {return}
	#partial switch crow.behavior {
	case .Idle:
		crow.idle_left -= dt
		if crow.idle_left <= 0 {
			switch rand.int_max(3) {
			case 0:
				crow_start_step(-1)
			case 1:
				crow_start_step(1)
			case 2:
				crow_start_look()
			}
		}
	case .Step:
		// one bounce per rep: 100ms up-and-down + sideways slide
		crow.rep_time += dt
		t := crow.rep_time / 0.1
		if t >= 1.0 {
			crow.rep -= 1
			if crow.rep <= 0 {crow_start_idle()} else {crow.rep_time = 0}
			return
		}
		crow.y = math.sin_f32(math.PI * t) * 5.0 // small hop up and back
		before := crow.x
		crow.x += f32(crow.step_dir) * 20.0 * dt
		crow.x = clamp(crow.x, min_x, max_x)
		// horizontal stops at the boundary (bounce still finishes); exit
		// the step cycle early once we've hit the wall
		if (crow.step_dir < 0 && crow.x <= min_x && before > min_x) ||
		   (crow.step_dir > 0 && crow.x >= max_x && before < max_x) {
			crow.rep = 1 // finish this bounce, then idle
		}
	case .Look:
		crow.rep_time += dt
		if crow.rep_time >= 0.5 {
			crow.rep -= 1
			if crow.rep <= 0 {
				crow_start_idle()
			} else {
				crow.rep_time = 0
				crow.facing = -crow.facing
			}
		}
	case .Pat:
		crow.rep_time += dt
		t := crow.rep_time / 0.35
		if t >= 1.0 {
			crow.rep -= 1
			if crow.rep <= 0 {crow_start_idle()} else {crow.rep_time = 0}
			return
		}
		// boing
		hop := math.sin_f32(math.PI * t) * 10.0
		crow.y = max(crow.pat_floor, crow.pat_floor + hop)
	}
}

// draw (also feeds clicks back into the behavior)

crow_draw :: proc(time: f32, size: f32, min_x, max_x: f32) {
	if crow_tex == nil {return}
	dt := time - crow_last_time
	crow_last_time = time
	if dt <= 0 || dt > 0.5 {dt = 1.0 / 60.0} 	// clamp after stalls
	crow_update(dt, min_x, max_x)
	win_h := imgui.GetWindowHeight()
	// bottom-left + x offset; y raises the crow off the ground
	pos := imgui.Vec2{min_x + crow.x, win_h - size - crow.y - 6}
	uv0 := imgui.Vec2{0, 0}
	uv1 := imgui.Vec2{1, 1}
	
	if crow.facing > 0 {
		uv0 = {1, 0}
		uv1 = {0, 1}
	}
	
	imgui.SetCursorScreenPos(imgui.GetWindowPos() + pos)
	imgui.Image(imgui.TextureRef{_TexID = u64(uintptr(crow_tex))}, {size, size}, uv0, uv1)
	if imgui.IsItemClicked() {
		crow_start_pat()
	}
}

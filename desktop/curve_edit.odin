package main

// curve editing widget

import dsp "../core/dsp"
import imgui "../vendor/imgui"
import core_math "core:math"

CurveEditState :: struct {
	hovered_idx:     i32,
	selected_idx:    i32,
	dragging:        bool,
	drag_point:      i32,
	editing_tangent: int, // 0 = move point, 1 = left handle, 2 = right handle
}

margin_left :: 36
margin_top :: 8
handle_rad :: 5

// ImGui colors are stored as ABGR (alpha << 24 | blue << 16 | green << 8 | red)

COLOR_GRID :: 0x20_00_FF_00 // subtle grid: a=100, b=0, g=20, r=0
COLOR_CURVE :: 0xFF_00_FF_00 // bright green line
COLOR_POINT :: 0xFF_00_FF_00 // same green as curve
COLOR_HANDLE :: 0xFF_00_FF_FF // yellow handles (a=255, b=0, g=255, r=255)
COLOR_HANDLE_DOT :: 0x66_00_FF_00 // faint green handle dot
COLOR_TANGENT_L :: 0x80_40_40_FF // red-ish left tangent (a=128, b=64, g=64, r=255)
COLOR_TANGENT_R :: 0x80_FF_40_40 // blue-ish right tangent (a=128, b=255, g=64, r=64)
COLOR_TEXT :: 0xA0_A0_A0_A0 // grey text labels
COLOR_BG :: 0xFF_0A_0A_05 // near-black bg (a=255, b=10, g=10, r=5)
COLOR_ZERO_LINE :: 0xFF_28_3C_28 // dim zero reference line

screen_to_curve :: proc(sx, sy, ml, mt, pw, ph: f32, curve: ^dsp.Curve) -> [2]f32 {
	x := core_math.max(f32(0), core_math.min(f32(1), (sx - ml) / pw))
	y_norm := f32(1) - (sy - mt) / ph
	val_range := curve.max_value - curve.min_value
	y_val := curve.min_value + y_norm * val_range
	return [2]f32{x, y_val}
}

curve_to_screen :: proc(cx, cy, ml, mt, pw, ph: f32, curve: ^dsp.Curve) -> [2]f32 {
	sx := ml + cx * pw
	val_range := curve.max_value - curve.min_value
	y_norm := (cy - curve.min_value) / val_range
	sy := mt + (f32(1) - y_norm) * ph
	return [2]f32{sx, sy}
}

point_screen_pos :: proc(idx: int, curve: ^dsp.Curve, gx, gy, gw, gh: f32) -> [2]f32 {
	cp := curve.points[idx].pos
	return curve_to_screen(cp[0], cp[1], gx, gy, gw, gh, curve)
}

hit_test_circle :: proc(ax, ay, bx, by, r: f32) -> bool {
	dx := ax - bx
	dy := ay - by
	return dx * dx + dy * dy < (r + f32(4)) * (r + f32(4))
}

get_span :: proc(idx: int, c: ^dsp.Curve) -> f32 {
	n := len(c.points)
	if idx == n - 1 {
		if idx > 0 {
			return c.points[idx].pos[0] - c.points[idx - 1].pos[0]
		}
		return f32(0.01)
	}
	return c.points[idx + 1].pos[0] - c.points[idx].pos[0]
}

draw_grid :: proc(dl: ^imgui.DrawList, ox, oy, gw, gh: f32, curve: ^dsp.Curve) {
	val_range := curve.max_value - curve.min_value
	if val_range <= f32(0) {val_range = f32(1)}
	// vertical lines: 10 divisions across x [0,1]
	for i in 0 ..= 10 {
		x := ox + (f32(i) / 10.0) * gw
		imgui.DrawList_AddLine(dl, [2]f32{x, oy}, [2]f32{x, oy + gh}, COLOR_GRID, f32(1))
	}
	// horizontal lines: 8 divisions across y [min,max]
	for i in 0 ..= 8 {
		v := curve.min_value + (f32(i) / 8.0) * val_range
		sp := curve_to_screen(f32(0), v, ox, oy, gw, gh, curve)
		imgui.DrawList_AddLine(dl, [2]f32{ox, sp[1]}, [2]f32{ox + gw, sp[1]}, COLOR_GRID, f32(1))
	}
	if curve.min_value <= f32(0) && curve.max_value >= f32(0) {
		sp := curve_to_screen(f32(0), f32(0), ox, oy, gw, gh, curve)
		imgui.DrawList_AddLine(
			dl,
			[2]f32{ox, sp[1]},
			[2]f32{ox + gw, sp[1]},
			COLOR_ZERO_LINE,
			f32(1),
		)
	}
}

// Y range is fixed per-curve (min_value/max_value)

CurveEditorWidget :: proc(name: cstring, curve: ^dsp.Curve, state: ^CurveEditState) {
	io := imgui.GetIO()
	wpos := imgui.GetWindowPos()
	wsz := imgui.GetWindowSize()

	gx := wpos.x + margin_left
	gy := wpos.y + margin_top
	gw := wsz.x - margin_left - f32(8)
	gh := wsz.y - margin_top - margin_top

	dl := imgui.GetWindowDrawList()
	imgui.DrawList_AddRectFilled(
		dl,
		[2]f32{wpos.x, wpos.y},
		[2]f32{wpos.x + wsz.x, wpos.y + wsz.y},
		COLOR_BG,
	)
	draw_grid(dl, gx, gy, gw, gh, curve)

	// precompute 256 sample points
	num_samples := 256
	samples_buf: [256][2]f32
	for i in 0 ..< num_samples {
		tx := f32(i) / f32(num_samples - 1)
		v := dsp.curve_sample(curve, tx)
		sp := curve_to_screen(tx, v, gx, gy, gw, gh, curve)
		samples_buf[i] = [2]f32{sp[0], sp[1]}
	}

	first_s := samples_buf[0]

	if len(curve.points) > 1 {
		imgui.DrawList_PathClear(dl)
		imgui.DrawList_PathLineTo(dl, first_s)
		for i in 1 ..< num_samples {
			imgui.DrawList_PathLineTo(dl, samples_buf[i])
		}
		imgui.DrawList_PathStroke(dl, COLOR_CURVE, f32(2), {})
	}

	// hit testing
	n_points := i32(len(curve.points))
	state.hovered_idx = -1
	hovered_tangent := int(0) // 0 none, 1 left, 2 right
	mouse_x := io.MousePos.x
	mouse_y := io.MousePos.y

	for pi := n_points - 1; pi >= 0; pi -= 1 {
		ps := point_screen_pos(int(pi), curve, gx, gy, gw, gh)
		if hit_test_circle(mouse_x, mouse_y, ps[0], ps[1], handle_rad) {
			state.hovered_idx = pi
			break
		}
	}

	if state.hovered_idx < 0 {
		for pi := n_points - 1; pi >= 0; pi -= 1 {
			if len(curve.points) < 2 {continue}
			pp := curve.points[int(pi)]
			p := pp.pos
			tl := pp.tangent_l
			tr := pp.tangent_r
			lhs := curve_to_screen(
				p[0] + f32(-0.02),
				p[1] + tl * f32(-0.02),
				gx,
				gy,
				gw,
				gh,
				curve,
			)
			rhs := curve_to_screen(p[0] + f32(0.02), p[1] + tr * f32(0.02), gx, gy, gw, gh, curve)
			if hit_test_circle(mouse_x, mouse_y, lhs[0], lhs[1], handle_rad) {
				state.hovered_idx = pi
				hovered_tangent = 1
				break
			}
			if hit_test_circle(mouse_x, mouse_y, rhs[0], rhs[1], handle_rad) {
				state.hovered_idx = pi
				hovered_tangent = 2
				break
			}
		}
	}

	selected_or_hovered_i32 := state.selected_idx
	if state.selected_idx < 0 && state.hovered_idx >= 0 {
		selected_or_hovered_i32 = state.hovered_idx
	}

	for pi in 0 ..< len(curve.points) {
		is_active := (pi == int(selected_or_hovered_i32))
		pp := curve.points[pi]
		px_val := pp.pos[0]
		py_val := pp.pos[1]
		pt_sp := curve_to_screen(px_val, py_val, gx, gy, gw, gh, curve)

		if len(curve.points) >= 2 {
			tr := pp.tangent_r
			hex := px_val + f32(0.02)
			hey := py_val + tr * f32(0.02)
			hsp := curve_to_screen(hex, hey, gx, gy, gw, gh, curve)
			imgui.DrawList_AddLine(dl, pt_sp, hsp, COLOR_TANGENT_R, f32(1.5))
			imgui.DrawList_AddCircleFilled(dl, hsp, handle_rad, COLOR_HANDLE_DOT, 8)

			tl := pp.tangent_l
			lx := px_val + f32(-0.02)
			ly := py_val + tl * f32(-0.02)
			lsp := curve_to_screen(lx, ly, gx, gy, gw, gh, curve)
			imgui.DrawList_AddLine(dl, pt_sp, lsp, COLOR_TANGENT_L, f32(1.5))
			imgui.DrawList_AddCircleFilled(dl, lsp, handle_rad, COLOR_HANDLE_DOT, 8)
		}

		filled_color: u32 = COLOR_POINT
		if is_active && hovered_tangent == 0 {
			filled_color = COLOR_HANDLE
		}
		imgui.DrawList_AddCircleFilled(dl, pt_sp, handle_rad, filled_color, 12)
	}

	clicked := io.MouseClicked[0]
	released := io.MouseReleased[0]

	// shift+click to add point, plain click selects/drags
	if clicked && io.KeyShift && !state.dragging && state.hovered_idx < 0 {
		undo_push(doc_voices[:], doc_chain[:], doc_rate^, doc_active^)
		new_pt := screen_to_curve(mouse_x, mouse_y, gx, gy, gw, gh, curve)
		new_pt[0] = core_math.clamp(new_pt[0], 0.001, 0.999)
		new_pt[1] = core_math.clamp(new_pt[1], curve.min_value, curve.max_value)

		// slope from neighbors so the new point keeps the curve continuous
		tl, tr := f32(0), f32(0)
		for j in 0 ..< len(curve.points) {
			if curve.points[j].pos[0] < new_pt[0] {
				tl = (new_pt[1] - curve.points[j].pos[1]) / (new_pt[0] - curve.points[j].pos[0])
			} else if curve.points[j].pos[0] > new_pt[0] {
				tr = (curve.points[j].pos[1] - new_pt[1]) / (curve.points[j].pos[0] - new_pt[0])
				break
			}
		}
		dsp.curve_add_point(curve, new_pt, tl, tr)
		state.selected_idx = -1
	}

	// right-click to remove point
	if io.MouseClicked[1] {
		for pi in 1 ..< len(curve.points) - 1 {
			ps := point_screen_pos(pi, curve, gx, gy, gw, gh)
			if hit_test_circle(mouse_x, mouse_y, ps[0], ps[1], handle_rad) {
				undo_push(doc_voices[:], doc_chain[:], doc_rate^, doc_active^)
				dsp.curve_remove_point(curve, pi)
				state.selected_idx = -1
				break
			}
		}
	}

	if clicked && state.selected_idx < 0 && state.hovered_idx >= 0 && hovered_tangent == 0 {
		state.selected_idx = state.hovered_idx
	}

	if clicked && state.hovered_idx >= 0 {
		undo_push(doc_voices[:], doc_chain[:], doc_rate^, doc_active^)
		state.dragging = true
		state.drag_point = state.hovered_idx
		state.editing_tangent = hovered_tangent
	}

	if released && state.dragging {
		state.dragging = false
		state.editing_tangent = 0
	}

	if state.dragging && state.drag_point >= 0 && state.drag_point < i32(len(curve.points)) {
		idx := state.drag_point
		if state.editing_tangent == 0 {
			new_pt := screen_to_curve(mouse_x, mouse_y, gx, gy, gw, gh, curve)

			clamped_x: f32
			// endpoints are X-locked
			if idx == 0 {
				clamped_x = curve.points[0].pos[0]
			} else if idx == i32(len(curve.points)) - 1 {
				clamped_x = curve.points[int(idx)].pos[0]
			} else {
				min_x := curve.points[int(idx) - 1].pos[0] + f32(0.001)
				max_x := curve.points[int(idx) + 1].pos[0] - f32(0.001)
				clamped_x = core_math.clamp(new_pt[0], min_x, max_x)
			}
			clamped_y := core_math.clamp(new_pt[1], curve.min_value, curve.max_value)

			dsp.curve_set_point_position(curve, int(idx), [2]f32{clamped_x, clamped_y})
		} else {
			ps := point_screen_pos(int(state.drag_point), curve, gx, gy, gw, gh)
			dmx := mouse_x - ps[0]
			dmy := -(mouse_y - ps[1])
			slope := dmy / (gw * f32(0.02))
			if state.editing_tangent == 1 {
				curve.points[int(state.drag_point)].tangent_l = slope
			} else {
				curve.points[int(state.drag_point)].tangent_r = slope
			}
		}
	}
}

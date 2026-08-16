package dsp

// curve implementation based on my earlier game engine work
//
// cubic hermite interpolation with tangents, toggleable to linear fallback
// x range is always [0, 1]; Y values act as multipliers on the base slider value

import "core:math"
import "core:sort"

CurveInterp :: enum {
	Hermite,
	Linear,
}

CurvePoint :: struct {
	pos:       [2]f32, // x in [0,1], y = value / multiplier
	tangent_l: f32, // incoming slope
	tangent_r: f32, // outgoing slope
}

Curve :: struct {
	points:    [dynamic]CurvePoint,
	interp:    CurveInterp,
	min_value: f32,
	max_value: f32,
}

// lifecycle

curve_init :: proc(c: ^Curve) {
	c.points = make([dynamic]CurvePoint)
	c.interp = .Hermite
	c.max_value = 1.0
}

// per-curve-kind default display range consumed by any frontend
// (desktop make_voice, web wasm defaults)
CurveKind :: enum i32 {
	Vol,
	Freq,
	Wave,
	PM,
}

curve_default_range :: proc(kind: CurveKind) -> (min_value, max_value: f32) {
	switch kind {
	case .Vol:
		return 0, 1
	case .Freq:
		return 0, 2
	case .Wave:
		return -1, 1 // amplitude
	case .PM:
		return 0, 1
	}
	return 0, 1
}

curve_destroy :: proc(c: ^Curve) {
	delete(c.points)
}

curve_deep_copy :: proc(src: ^Curve) -> Curve {
	dst: Curve
	dst.points = make([dynamic]CurvePoint, len(src.points))
	dst.interp = src.interp
	dst.min_value = src.min_value
	dst.max_value = src.max_value
	for p, i in src.points {
		dst.points[i] = p
	}
	return dst
}

// factory helpers

curve_flat :: proc(val: f32) -> Curve {
	c: Curve
	curve_init(&c)
	curve_add_point(&c, [2]f32{0.0, val}, 0.0, 0.0)
	curve_add_point(&c, [2]f32{1.0, val}, 0.0, 0.0)
	return c
}

curve_linear_ramp :: proc(val_start, val_end: f32) -> Curve {
	c: Curve
	curve_init(&c)
	// tangent = y_end - y_start so Hermite slope matches the straight line
	t := val_end - val_start
	curve_add_point(&c, [2]f32{0.0, val_start}, t, t)
	curve_add_point(&c, [2]f32{1.0, val_end}, t, t)
	return c
}

curve_zero :: proc() -> Curve {
	return curve_flat(0.0)
}

// point editing

curve_add_point :: proc(c: ^Curve, pos: [2]f32, tangent_l, tangent_r: f32) {
	append(
		&c.points,
		CurvePoint {
			pos = [2]f32{math.clamp(pos.x, 0, 1), pos.y},
			tangent_l = tangent_l,
			tangent_r = tangent_r,
		},
	)
	curve_sort_points(c)
}

curve_remove_point :: proc(c: ^Curve, idx: int) {
	if idx >= 0 && idx < len(c.points) {
		ordered_remove(&c.points, idx)
	}
}

curve_set_point_position :: proc(c: ^Curve, idx: int, pos: [2]f32) {
	if idx >= 0 && idx < len(c.points) {
		c.points[idx].pos = [2]f32{math.clamp(pos.x, 0.0, 1.0), pos.y}
		curve_sort_points(c)
	}
}

curve_set_point_tangents :: proc(c: ^Curve, idx: int, left, right: f32) {
	if idx >= 0 && idx < len(c.points) {
		c.points[idx].tangent_l = left
		c.points[idx].tangent_r = right
	}
}

// sorting

curve_sort_points :: proc(c: ^Curve) {
	sort.quick_sort_proc(c.points[:], proc(a, b: CurvePoint) -> int {
		if a.pos.x < b.pos.x {return -1}
		if a.pos.x > b.pos.x {return 1}
		return 0
	})
}

// sampling

EPSILON :: 1e-9

curve_sample :: proc(c: ^Curve, x: f32) -> f32 {
	return math.clamp(curve_sample_raw(c, x), c.min_value, c.max_value)
}

curve_sample_raw :: proc(c: ^Curve, x: f32) -> f32 {
	if len(c.points) == 0 {return 0.0}
	if len(c.points) == 1 {return c.points[0].pos.y}

	tx := math.clamp(x, 0.0, 1.0)

	if tx <= c.points[0].pos.x {return c.points[0].pos.y}
	last := c.points[len(c.points) - 1]
	if tx >= last.pos.x {return last.pos.y}

	lo := 0
	for i in 0 ..< len(c.points) - 1 {
		if tx >= c.points[i].pos.x && tx <= c.points[i + 1].pos.x {
			lo = i
			break
		}
	}
	hi := lo + 1

	p0 := c.points[lo]
	p1 := c.points[hi]
	span := p1.pos.x - p0.pos.x

	t: f32
	if math.abs(span) > EPSILON {
		t = (tx - p0.pos.x) / span
	}

	if c.interp == .Linear {
		return p0.pos.y + (p1.pos.y - p0.pos.y) * t
	}
	return _hermite(p0.pos.y, p0.tangent_r * span, p1.pos.y, p1.tangent_l * span, t)
}

// cubic hermite basis
_hermite :: proc(y0, m0, y1, m1, t: f32) -> f32 {
	t2 := t * t
	t3 := t2 * t
	h00 := 2.0 * t3 - 3.0 * t2 + 1.0
	h10 := t3 - 2.0 * t2 + t
	h01 := -2.0 * t3 + 3.0 * t2
	h11 := t3 - t2
	return h00 * y0 + h10 * m0 + h01 * y1 + h11 * m1
}

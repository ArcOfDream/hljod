package project

// schema:
//
// hljod-project version=1 {
//   sample-rate 44100
//   voice "Voice" {
//     length 0.5
//     start-offset 0
//     osc "main" {
//       kind 1
//       freq 440
//       volume 80
//       offset 0
//       pm_blend 0
//       reverse false
//       freq-curve {
//         interp 0
//         min 0
//         max 1
//         pt x y tl tr
//       }
//       vol-curve { ... }
//       pm-curve { ... }
//       wave-curve { ... }
//     }
//     osc "freq" { ... }
//     osc "volu" { ... }
//   }
//   effect kind=Reverb enabled=true {
//     param 0 0.5
//   }
// }

import "core:strings"
import dsp "../dsp"
import fx "../effects"
import kdl "../kdl"

MAX_VOICES :: 8
MAX_CHAIN  :: 8

Voice :: struct {
	name:        [64]byte,
	main_p:      dsp.OscParams,
	freq_p:      dsp.OscParams,
	volu_p:      dsp.OscParams,
	length:      f32,
	start_offset: f32,
	active:      bool,
}

Project :: struct {
	sample_rate: i32,
	voices:      [dynamic]Voice,
	chain:       [dynamic]fx.EffectNode,
}

EFFECT_KIND_NAMES := [fx.EffectKind]string{
	.None       = "None",
	.Delay      = "Delay",
	.Overdrive  = "Overdrive",
	.Reverb     = "Reverb",
	.Distortion = "Distortion",
	.LowPass    = "LowPass",
	.Chorus     = "Chorus",
	.Bitcrusher = "Bitcrusher",
	.PitchShift = "PitchShift",
}

// ownership helpers

// all 12 curves of one voice, in osc-major order (main/freq/volu)
voice_oscs :: proc(v: ^Voice) -> [3]^dsp.OscParams {
	return [3]^dsp.OscParams{&v.main_p, &v.freq_p, &v.volu_p}
}

osc_curves :: proc(o: ^dsp.OscParams) -> [4]^dsp.Curve {
	return [4]^dsp.Curve{&o.freq_curve, &o.vol_curve, &o.wave_curve, &o.pm_curve}
}

voice_destroy :: proc(v: ^Voice) {
	for o in voice_oscs(v) {
		for c in osc_curves(o) { dsp.curve_destroy(c) }
	}
}

// copy into an empty dst 
voice_copy :: proc(dst: ^Voice, src: ^Voice) {
	dst^ = src^
	for i in 0 ..< 3 {
		dc := osc_curves(voice_oscs(dst)[i])
		sc := osc_curves(voice_oscs(src)[i])
		for j in 0 ..< 4 {
			dc[j]^ = dsp.curve_deep_copy(sc[j])
		}
	}
}

// copy into an empty dst (params array is freshly allocated)
effect_node_copy :: proc(dst: ^fx.EffectNode, src: ^fx.EffectNode) {
	dst^ = src^
	dst.params = make([dynamic]f32, len(src.params))
	copy(dst.params[:], src.params[:])
}

project_destroy :: proc(p: ^Project) {
	for &v in p.voices { voice_destroy(&v) }
	for e in p.chain { delete(e.params) }
	delete(p.voices)
	delete(p.chain)
}

// number formatting (no core:fmt - it crashes on js_wasm32)

write_f32 :: proc(b: ^strings.Builder, v_in: f32) {
	v := v_in
	if v < 0 { strings.write_byte(b, '-'); v = -v }
	whole := i32(v)
	write_i32(b, whole)
	frac := v - f32(whole)
	if frac != 0 {
		strings.write_byte(b, '.')
		for i := 0; i < 6; i += 1 {
			frac *= 10
			d := i32(frac)
			strings.write_byte(b, byte('0' + d))
			frac -= f32(d)
			if frac == 0 { break }
		}
	}
}

write_i32 :: proc(b: ^strings.Builder, v_in: i32) {
	v := v_in
	if v == 0 { strings.write_byte(b, '0'); return }
	if v < 0 { strings.write_byte(b, '-'); v = -v }
	digits: [12]byte
	n := 0
	for v > 0 { digits[n] = byte('0' + v % 10); v /= 10; n += 1 }
	for i := n - 1; i >= 0; i -= 1 { strings.write_byte(b, digits[i]) }
}

parse_f32 :: proc(s: string) -> f32 {
	v: f32 = 0
	neg := false
	i := 0
	if i < len(s) && s[i] == '-' { neg = true; i += 1 }
	for i < len(s) && s[i] >= '0' && s[i] <= '9' { v = v * 10 + f32(s[i] - '0'); i += 1 }
	if i < len(s) && s[i] == '.' {
		i += 1
		frac: f32 = 0.1
		for i < len(s) && s[i] >= '0' && s[i] <= '9' { v += f32(s[i] - '0') * frac; frac *= 0.1; i += 1 }
	}
	if neg { v = -v }
	return v
}

// save

write_kdl_curve :: proc(b: ^strings.Builder, c: ^dsp.Curve, indent: string) {
	strings.write_string(b, indent)
	strings.write_string(b, "interp "); write_i32(b, i32(c.interp)); strings.write_string(b, "\n")
	strings.write_string(b, indent)
	strings.write_string(b, "min "); write_f32(b, c.min_value); strings.write_string(b, "\n")
	strings.write_string(b, indent)
	strings.write_string(b, "max "); write_f32(b, c.max_value); strings.write_string(b, "\n")
	for p in c.points {
		strings.write_string(b, indent)
		strings.write_string(b, "pt ")
		write_f32(b, p.pos.x); strings.write_string(b, " ")
		write_f32(b, p.pos.y); strings.write_string(b, " ")
		write_f32(b, p.tangent_l); strings.write_string(b, " ")
		write_f32(b, p.tangent_r)
		strings.write_string(b, "\n")
	}
}

write_kdl_osc :: proc(b: ^strings.Builder, o: ^dsp.OscParams, label: string, indent: string) {
	ci := strings.builder_make(); defer strings.builder_destroy(&ci)
	strings.write_string(&ci, indent); strings.write_string(&ci, "  ")
	cindent := strings.to_string(ci)
	bi := strings.builder_make(); defer strings.builder_destroy(&bi)
	strings.write_string(&bi, indent); strings.write_string(&bi, "    ")
	bindent := strings.to_string(bi)

	strings.write_string(b, indent); strings.write_string(b, "osc \""); strings.write_string(b, label); strings.write_string(b, "\" {\n")
	strings.write_string(b, cindent); strings.write_string(b, "kind "); write_i32(b, i32(o.kind)); strings.write_string(b, "\n")
	strings.write_string(b, cindent); strings.write_string(b, "freq "); write_f32(b, o.freq); strings.write_string(b, "\n")
	strings.write_string(b, cindent); strings.write_string(b, "volume "); write_f32(b, o.volume); strings.write_string(b, "\n")
	strings.write_string(b, cindent); strings.write_string(b, "offset "); write_f32(b, o.offset); strings.write_string(b, "\n")
	strings.write_string(b, cindent); strings.write_string(b, "pm_blend "); write_f32(b, o.pm_blend); strings.write_string(b, "\n")
	strings.write_string(b, cindent); strings.write_string(b, "reverse "); strings.write_string(b, o.reverse ? "true" : "false"); strings.write_string(b, "\n")
	names := [4]string{"freq-curve", "vol-curve", "pm-curve", "wave-curve"}
	for i in 0 ..< 4 {
		strings.write_string(b, cindent); strings.write_string(b, names[i]); strings.write_string(b, " {\n")
		write_kdl_curve(b, osc_curves(o)[i], bindent)
		strings.write_string(b, cindent); strings.write_string(b, "}\n")
	}
	strings.write_string(b, indent); strings.write_string(b, "}\n")
}

// reads borrowed slices - caller keeps ownership of all curve arrays and params
project_save :: proc(b: ^strings.Builder, sample_rate: i32, voices: []Voice, chain: []fx.EffectNode) {
	strings.write_string(b, "hljod-project version=1 {\n")
	strings.write_string(b, "  sample-rate "); write_i32(b, sample_rate); strings.write_string(b, "\n")
	for &v in voices {
		strings.write_string(b, "  voice \"")
		name_len := 0
		for name_len < 64 && v.name[name_len] != 0 { name_len += 1 }
		if name_len > 0 {
			for i in 0 ..< name_len { strings.write_byte(b, v.name[i]) }
		} else {
			strings.write_string(b, "Voice")
		}
		strings.write_string(b, "\" {\n")
		strings.write_string(b, "    length "); write_f32(b, v.length); strings.write_string(b, "\n")
		strings.write_string(b, "    start-offset "); write_f32(b, v.start_offset); strings.write_string(b, "\n")
		write_kdl_osc(b, &v.main_p, "main", "    ")
		write_kdl_osc(b, &v.freq_p, "freq", "    ")
		write_kdl_osc(b, &v.volu_p, "volu", "    ")
		strings.write_string(b, "  }\n")
	}
	for &e in chain {
		strings.write_string(b, "  effect kind=")
		strings.write_string(b, EFFECT_KIND_NAMES[e.kind])
		strings.write_string(b, e.enabled ? " enabled=true {\n" : " enabled=false {\n")
		for pi in 0 ..< len(e.params) {
			strings.write_string(b, "    param "); write_i32(b, i32(pi)); strings.write_string(b, " "); write_f32(b, e.params[pi]); strings.write_string(b, "\n")
		}
		strings.write_string(b, "  }\n")
	}
	strings.write_string(b, "}\n")
}

// total project duration = max(start_offset + length) across active voices
render_duration :: proc(voices: []Voice) -> f32 {
	td := f32(0.01)
	for &v in voices {
		if !v.active || v.length <= 0 { continue }
		if e := v.start_offset + v.length; e > td { td = e }
	}
	return td
}

// renders the whole project (mix + offsets + fx chain) into a caller buffer
// returns the sample count written; buf is capped by its own length
render :: proc(
	sample_rate: i32,
	voices: []Voice,
	chain: []fx.EffectNode,
	duration: f32,
	buf: []f32,
	effects_bypass: bool,
) -> int {
	sps := sample_rate
	n := int(dsp.sample_count(sps, duration))
	if n > len(buf) { n = len(buf) }
	for i in 0 ..< n { buf[i] = 0 }

	for &v in voices {
		if !v.active || v.length <= 0 { continue }
		samples := dsp.render(&v.main_p, &v.freq_p, &v.volu_p, v.length, sps)
		start_smpl := int(v.start_offset * f32(sps))
		if start_smpl >= n {
			delete(samples)
			continue
		}
		copy_len := min(n - start_smpl, len(samples))
		for i in 0 ..< copy_len {
			buf[start_smpl + i] += samples[i]
		}
		delete(samples)
	}

	for i in 0 ..< n {
		if buf[i] >  1.0 { buf[i] =  1.0 }
		if buf[i] < -1.0 { buf[i] = -1.0 }
	}

	// apply effect chain (in-place stereo processing)
	if !effects_bypass && len(chain) > 0 {
		stereo := make([]f32, n * 2)
		defer delete(stereo)
		for i in 0 ..< n {
			stereo[i*2]   = buf[i]
			stereo[i*2+1] = buf[i]
		}
		fx.process_chain(stereo, chain, sps)
		for i in 0 ..< n {
			buf[i] = (stereo[i*2] + stereo[i*2+1]) * 0.5
		}
	}
	return n
}

// load

LoadCtx :: struct {
	state: ^Project,
	cur_voice: i32,
	cur_osc: ^dsp.OscParams,
	cur_curve: ^dsp.Curve,
	cur_effect: ^fx.EffectNode,
	curve_pt_field: i32,  // 0=x,1=y,2=tl,3=tr during curve point parse
	param_field: i32,     // 0=index,1=value during param node parse
	cur_prop: string,     // pending property name for osc param parsing
}

load_event_cb :: proc(ctx: rawptr, ev: kdl.Event) -> bool {
	c := cast(^LoadCtx)ctx
	#partial switch ev.type {
	case .Start_Node:
		switch ev.name {
		case "hljod-project": // root
		case "voice":
			if len(c.state.voices) >= MAX_VOICES { return true }
			append(&c.state.voices, Voice{active = true})
			c.cur_voice = i32(len(c.state.voices) - 1)
			c.cur_prop = "voice"  // next Argument is the name
		case "osc":
			c.cur_osc = nil
			c.cur_prop = "osc"  // wait for Argument to set the slot
		case "freq-curve": c.cur_curve = c.cur_osc != nil ? &c.cur_osc.freq_curve : nil
		case "vol-curve":  c.cur_curve = c.cur_osc != nil ? &c.cur_osc.vol_curve : nil
		case "wave-curve": c.cur_curve = c.cur_osc != nil ? &c.cur_osc.wave_curve : nil
		case "pm-curve":   c.cur_curve = c.cur_osc != nil ? &c.cur_osc.pm_curve : nil
		case "pt":
			// KDL child node for each curve point
			if c.cur_curve != nil {
				append(&c.cur_curve.points, dsp.CurvePoint{})
				c.curve_pt_field = 0
			}
		case "kind", "freq", "volume", "offset", "pm_blend", "interp", "min", "max":
			c.cur_prop = ev.name
		case "sample-rate":
			c.cur_prop = ev.name
		case "reverse":
			c.cur_prop = ev.name
		case "length", "start-offset":
			c.cur_prop = ev.name
		case "param":
			c.cur_prop = ev.name
			c.param_field = 0
		case "effect":
			if len(c.state.chain) < MAX_CHAIN {
				append(&c.state.chain, fx.EffectNode{enabled = true, params = make([dynamic]f32)})
				c.cur_effect = &c.state.chain[len(c.state.chain) - 1]
			}
		}
	case .Property:
		switch ev.name {
		case "version": // ignore
		case "kind":
			if c.cur_effect != nil {
				for name, ek in EFFECT_KIND_NAMES {
					if name == ev.value.raw_text { c.cur_effect.kind = ek; break }
				}
			}
		case "enabled":
			if c.cur_effect != nil { c.cur_effect.enabled = ev.value.raw_text == "true" }
		}
	case .Argument:
		// voice name (string argument like `voice "Voice"`), set on Start_Node
		if c.cur_prop == "voice" && c.cur_voice >= 0 {
			name := &c.state.voices[c.cur_voice].name
			for i in 0 ..< min(len(name), len(ev.value.raw_text)) {
				name[i] = ev.value.raw_text[i]
			}
			c.cur_prop = ""
		}
		// osc label (string argument like "main", "freq", "volu")
		if c.cur_prop == "osc" && c.cur_voice >= 0 {
			switch ev.value.raw_text {
			case "main": c.cur_osc = &c.state.voices[c.cur_voice].main_p
			case "freq": c.cur_osc = &c.state.voices[c.cur_voice].freq_p
			case "volu": c.cur_osc = &c.state.voices[c.cur_voice].volu_p
			}
			c.cur_prop = ""
		}
		if ev.value.type_ == .Number {
			val := parse_f32(ev.value.raw_text)
			// curve metadata (interp mode, y range) - written before pts in save
			if c.cur_curve != nil && (c.cur_prop == "interp" || c.cur_prop == "min" || c.cur_prop == "max") {
				switch c.cur_prop {
				case "interp": c.cur_curve.interp = dsp.CurveInterp(i32(val))
				case "min":    c.cur_curve.min_value = val
				case "max":    c.cur_curve.max_value = val
				}
				c.cur_prop = ""
			} else if c.cur_effect != nil && c.cur_prop == "param" {
				// param node carries index + value - keep the value only
				if c.param_field == 1 { append(&c.cur_effect.params, val) }
				c.param_field += 1
			} else if c.cur_prop == "sample-rate" {
				c.state.sample_rate = i32(val)
				c.cur_prop = ""
			} else if c.cur_osc != nil && c.cur_prop != "" {
				switch c.cur_prop {
				case "kind":   c.cur_osc.kind = dsp.WaveKind(i32(val))
				case "freq":   c.cur_osc.freq = val
				case "volume": c.cur_osc.volume = val
				case "offset": c.cur_osc.offset = val
				case "pm_blend": c.cur_osc.pm_blend = val
				}
			}
			// voice-level properties
			if c.cur_voice >= 0 && c.cur_prop != "" {
				switch c.cur_prop {
				case "length": c.state.voices[c.cur_voice].length = val
				case "start-offset": c.state.voices[c.cur_voice].start_offset = val
				}
			}
			// curve point fields
			if c.cur_curve != nil && len(c.cur_curve.points) > 0 {
				last := &c.cur_curve.points[len(c.cur_curve.points) - 1]
				switch c.curve_pt_field {
				case 0: last.pos.x = val; c.curve_pt_field = 1
				case 1: last.pos.y = val; c.curve_pt_field = 2
				case 2: last.tangent_l = val; c.curve_pt_field = 3
				case 3: last.tangent_r = val; c.curve_pt_field = 4
				}
			}
		} else if ev.value.type_ == .Boolean {
			if c.cur_osc != nil && c.cur_prop == "reverse" {
				c.cur_osc.reverse = ev.value.raw_text == "true"
			}
		}
	case .End_Node:
		switch ev.name {
		case "osc": c.cur_osc = nil; c.cur_prop = ""
		case "kind", "freq", "volume", "offset", "reverse", "param", "length", "start-offset", "interp", "min", "max", "sample-rate": c.cur_prop = ""
		case "freq-curve", "vol-curve", "wave-curve", "pm-curve":
			if c.cur_curve != nil {
				dsp.curve_sort_points(c.cur_curve)
				c.cur_curve = nil
			}
		case "effect": c.cur_effect = nil
		}
	}
	return true
}

project_load :: proc(text: string, p: ^Project) -> bool {
	ctx := LoadCtx{state = p}
	ok, err := kdl.parse(text, load_event_cb, &ctx)
	_ = err
	return ok
}

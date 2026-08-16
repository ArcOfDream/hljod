#+feature dynamic-literals
package main

// Web/WASM entry point

import "base:runtime"
import dsp "../core/dsp"
import fx "../core/effects"
import project "../core/project"
import "core:strings"

// fixed-capacity state

MAX_VOICES :: project.MAX_VOICES
MAX_CHAIN  :: project.MAX_CHAIN
MAX_SAMPLES :: 48000 * 10  // 10 seconds at 48 kHz (mono)

OscState :: dsp.OscParams
VoiceState :: project.Voice

WebState :: struct {
	voices:       [MAX_VOICES]VoiceState,
	voice_count:  i32,
	chain:        [MAX_CHAIN]fx.EffectNode,
	chain_count:  i32,
	sample_rate:  i32,
	render_buf:   [MAX_SAMPLES]f32,
	render_len:   i32,
	effects_bypass: bool,
}

gs: WebState

osc_default :: proc() -> OscState {
	o := OscState{
		kind   = .Sine,
		freq   = 440,
		volume = 80,
	}
	o.freq_curve = dsp.curve_flat(1.0)
	o.vol_curve  = dsp.curve_linear_ramp(1.0, 0.0)
	o.wave_curve = dsp.curve_zero()
	o.pm_curve   = dsp.curve_flat(1.0)
	// display ranges come from core
	o.freq_curve.min_value, o.freq_curve.max_value = dsp.curve_default_range(.Freq)
	o.vol_curve.min_value,  o.vol_curve.max_value  = dsp.curve_default_range(.Vol)
	o.wave_curve.min_value, o.wave_curve.max_value = dsp.curve_default_range(.Wave)
	o.pm_curve.min_value,   o.pm_curve.max_value   = dsp.curve_default_range(.PM)
	return o
}

// internal lookups
// curve slot order matches core dsp.CurveKind (vol=0, freq=1, wave=2, pm=3)

voice_ptr :: proc(idx: i32) -> ^VoiceState {
	if idx >= 0 && idx < gs.voice_count {
		return &gs.voices[idx]
	}
	return nil
}

osc_ptr :: proc(v: ^VoiceState, idx: i32) -> ^OscState {
	switch idx {
	case 0: return &v.main_p
	case 1: return &v.freq_p
	case 2: return &v.volu_p
	}
	return nil
}

curve_ptr :: proc(o: ^OscState, which: dsp.CurveKind) -> ^dsp.Curve {
	switch which {
	case .Vol:  return &o.vol_curve
	case .Freq: return &o.freq_curve
	case .Wave: return &o.wave_curve
	case .PM:   return &o.pm_curve
	}
	return nil
}

osc_for :: proc(voice, osc: i32) -> ^OscState {
	if v := voice_ptr(voice); v != nil { return osc_ptr(v, osc) }
	return nil
}

curve_for :: proc(voice, osc, which: i32) -> ^dsp.Curve {
	if o := osc_for(voice, osc); o != nil { return curve_ptr(o, dsp.CurveKind(which)) }
	return nil
}

// public C-ABI exports

@(export)
web_init :: proc "c" (sample_rate: i32) {
	context = runtime.default_context()
	gs.sample_rate = sample_rate
	gs.voice_count = 0
	gs.chain_count  = 0
	gs.render_len   = 0
}

@(export)
web_add_voice :: proc "c" () -> i32 {
	context = runtime.default_context()
	if gs.voice_count >= MAX_VOICES { return -1 }
	idx := gs.voice_count
	v := &gs.voices[idx]
	v^ = {}
	v.main_p = osc_default()
	v.freq_p  = osc_default()
	v.volu_p  = osc_default()
	v.length  = 0.5
	v.active  = true
	gs.voice_count += 1
	return idx
}

@(export)
web_remove_voice :: proc "c" (idx: i32) {
	context = runtime.default_context()
	if idx < 0 || idx >= gs.voice_count { return }
	v := &gs.voices[idx]
	project.voice_destroy(v)
	for i := idx + 1; i < gs.voice_count; i += 1 {
		gs.voices[i - 1] = gs.voices[i]
	}
	gs.voices[gs.voice_count - 1] = {}
	gs.voice_count -= 1
}

@(export)
web_set_voice_length :: proc "c" (idx: i32, length: f32) {
	context = runtime.default_context()
	if idx >= 0 && idx < gs.voice_count {
		gs.voices[idx].length = max(0.01, length)
	}
}

@(export)
web_set_voice_offset :: proc "c" (idx: i32, offset: f32) {
	context = runtime.default_context()
	if idx >= 0 && idx < gs.voice_count {
		gs.voices[idx].start_offset = max(0, offset)
	}
}

// voice name is a fixed [64]byte; copy from JS memory on set,
// return a pointer to the buffer on get (JS reads via wasmMemory)
@(export)
web_set_voice_name :: proc "c" (idx: i32, ptr: i32, len: i32) {
	context = runtime.default_context()
	if idx < 0 || idx >= gs.voice_count || ptr == 0 { return }
	n := min(int(len), 63)
	name := &gs.voices[idx].name
	for i in 0 ..< n {
		name[i] = byte((^byte)(uintptr(ptr + i32(i)))^)
	}
	name[n] = 0
}

@(export)
web_get_voice_name :: proc "c" (idx: i32) -> i32 {
	if idx >= 0 && idx < gs.voice_count {
		return i32(uintptr(&gs.voices[idx].name[0]))
	}
	return 0
}

// oscillator param setters

@(export)
web_set_osc_kind :: proc "c" (voice, osc: i32, kind: i32) {
	context = runtime.default_context()
	if o := osc_for(voice, osc); o != nil {
		o.kind = dsp.WaveKind(kind)
	}
}

@(export)
web_set_osc_freq :: proc "c" (voice, osc: i32, freq: f32) {
	context = runtime.default_context()
	if o := osc_for(voice, osc); o != nil {
		o.freq = freq
	}
}

@(export)
web_set_osc_volume :: proc "c" (voice, osc: i32, volume: f32) {
	context = runtime.default_context()
	if o := osc_for(voice, osc); o != nil {
		o.volume = volume
	}
}

@(export)
web_set_osc_reverse :: proc "c" (voice, osc: i32, reverse: i32) {
	context = runtime.default_context()
	if o := osc_for(voice, osc); o != nil {
		o.reverse = reverse != 0
	}
}

@(export)
web_set_osc_offset :: proc "c" (voice, osc: i32, offset: f32) {
	context = runtime.default_context()
	if o := osc_for(voice, osc); o != nil {
		o.offset = offset
	}
}

@(export)
web_set_osc_pm_blend :: proc "c" (voice, osc: i32, blend: f32) {
	context = runtime.default_context()
	if o := osc_for(voice, osc); o != nil {
		o.pm_blend = blend
	}
}

// curve editing

@(export)
web_add_curve_point :: proc "c" (voice, osc, which: i32, x, y, tl, tr: f32) -> i32 {
	context = runtime.default_context()
	if c := curve_for(voice, osc, which); c != nil {
		dsp.curve_add_point(c, [2]f32{x, y}, tl, tr)
		return 1
	}
	return 0
}

@(export)
web_remove_curve_point :: proc "c" (voice, osc, which, idx: i32) {
	context = runtime.default_context()
	if c := curve_for(voice, osc, which); c != nil {
		dsp.curve_remove_point(c, int(idx))
	}
}

@(export)
web_set_curve_point_pos :: proc "c" (voice, osc, which, idx: i32, x, y: f32) {
	context = runtime.default_context()
	if c := curve_for(voice, osc, which); c != nil {
		dsp.curve_set_point_position(c, int(idx), [2]f32{x, y})
	}
}

@(export)
web_set_curve_point_tangents :: proc "c" (voice, osc, which, idx: i32, tl, tr: f32) {
	context = runtime.default_context()
	if c := curve_for(voice, osc, which); c != nil {
		dsp.curve_set_point_tangents(c, int(idx), tl, tr)
	}
}

@(export)
web_set_curve_interp :: proc "c" (voice, osc, which, interp: i32) {
	context = runtime.default_context()
	if c := curve_for(voice, osc, which); c != nil {
		c.interp = dsp.CurveInterp(interp)
	}
}

@(export)
web_get_curve_interp :: proc "c" (voice, osc, which: i32) -> i32 {
	context = runtime.default_context()
	if c := curve_for(voice, osc, which); c != nil {
		return i32(c.interp)
	}
	return 0
}

@(export)
web_get_curve_min :: proc "c" (voice, osc, which: i32) -> f32 {
	context = runtime.default_context()
	if c := curve_for(voice, osc, which); c != nil {
		return c.min_value
	}
	return 0
}

@(export)
web_get_curve_max :: proc "c" (voice, osc, which: i32) -> f32 {
	context = runtime.default_context()
	if c := curve_for(voice, osc, which); c != nil {
		return c.max_value
	}
	return 0
}

@(export)
web_set_curve_range :: proc "c" (voice, osc, which: i32, min_val, max_val: f32) {
	context = runtime.default_context()
	if c := curve_for(voice, osc, which); c != nil {
		c.min_value = min_val
		c.max_value = max_val
	}
}

@(export)
web_curve_point_count :: proc "c" (voice, osc, which: i32) -> i32 {
	context = runtime.default_context()
	if c := curve_for(voice, osc, which); c != nil {
		return i32(len(c.points))
	}
	return 0
}

@(export)
web_voice_count :: proc "c" () -> i32 {
	return gs.voice_count
}

// effect chain

@(export)
web_add_effect :: proc "c" (kind: i32, p0, p1, p2, p3, p4: f32) {
	context = runtime.default_context()
	if gs.chain_count >= MAX_CHAIN { return }
	node := fx.EffectNode{
		kind    = fx.EffectKind(kind),
		enabled = true,
		params  = make([dynamic]f32),
	}
	#partial switch fx.EffectKind(kind) {
	case .Delay:       node.params = {p0, p1, p2, p3}
	case .Overdrive, .Distortion: node.params = {p0, p1, p2}
	case .Reverb:      node.params = {p0, p1, p2, p3, p4}
	case .LowPass:     node.params = {p0, p1}
	case .Chorus:      node.params = {p0, p1, p2, p3, p4}
	case .Bitcrusher:  node.params = {p0, p1, p2}
	case .PitchShift:  node.params = {p0, p1}
	}
	gs.chain[gs.chain_count] = node
	gs.chain_count += 1
}

@(export)
web_clear_effects :: proc "c" () {
	context = runtime.default_context()
	for i in 0 ..< gs.chain_count {
		delete(gs.chain[i].params)
	}
	gs.chain_count = 0
}

@(export)
web_effect_count :: proc "c" () -> i32 {
	return gs.chain_count
}

@(export)
web_get_effect_kind :: proc "c" (idx: i32) -> i32 {
	if idx >= 0 && idx < gs.chain_count {
		return i32(gs.chain[idx].kind)
	}
	return 0
}

@(export)
web_get_effect_enabled :: proc "c" (idx: i32) -> i32 {
	if idx >= 0 && idx < gs.chain_count && gs.chain[idx].enabled {
		return 1
	}
	return 0
}

@(export)
web_toggle_effect :: proc "c" (idx: i32) {
	context = runtime.default_context()
	if idx >= 0 && idx < gs.chain_count {
		gs.chain[idx].enabled = !gs.chain[idx].enabled
	}
}

// move effect one slot: up=-1 (toward front), down=+1 (toward back)
@(export)
web_move_effect :: proc "c" (idx, dir: i32) {
	context = runtime.default_context()
	other := idx + dir
	if idx < 0 || other < 0 || other >= gs.chain_count { return }
	tmp := gs.chain[idx]
	gs.chain[idx] = gs.chain[other]
	gs.chain[other] = tmp
}

@(export)
web_remove_effect :: proc "c" (idx: i32) {
	context = runtime.default_context()
	if idx >= 0 && idx < gs.chain_count {
		delete(gs.chain[idx].params)
		for i := idx + 1; i < gs.chain_count; i += 1 {
			gs.chain[i - 1] = gs.chain[i]
		}
		gs.chain_count -= 1
	}
}

@(export)
web_set_effect_param :: proc "c" (idx, param: i32, value: f32) {
	context = runtime.default_context()
	if idx >= 0 && idx < gs.chain_count {
		n := &gs.chain[idx]
		if param >= 0 && param < i32(len(n.params)) {
			n.params[param] = value
		}
	}
}

@(export)
web_get_effect_param :: proc "c" (idx, param: i32) -> f32 {
	if idx >= 0 && idx < gs.chain_count {
		n := &gs.chain[idx]
		if param >= 0 && param < i32(len(n.params)) {
			return n.params[param]
		}
	}
	return 0
}

@(export)
web_set_effects_bypass :: proc "c" (bypass: i32) {
	gs.effects_bypass = bypass != 0
}

// oscillator param getters

@(export)
web_get_osc_kind :: proc "c" (voice, osc: i32) -> i32 {
	context = runtime.default_context()
	if o := osc_for(voice, osc); o != nil { return i32(o.kind) }
	return 0
}

@(export)
web_get_osc_freq :: proc "c" (voice, osc: i32) -> f32 {
	context = runtime.default_context()
	if o := osc_for(voice, osc); o != nil { return o.freq }
	return 0
}

@(export)
web_get_osc_volume :: proc "c" (voice, osc: i32) -> f32 {
	context = runtime.default_context()
	if o := osc_for(voice, osc); o != nil { return o.volume }
	return 0
}

@(export)
web_get_osc_pm_blend :: proc "c" (voice, osc: i32) -> f32 {
	context = runtime.default_context()
	if o := osc_for(voice, osc); o != nil { return o.pm_blend }
	return 0
}

@(export)
web_get_osc_offset :: proc "c" (voice, osc: i32) -> f32 {
	context = runtime.default_context()
	if o := osc_for(voice, osc); o != nil { return o.offset }
	return 0
}

@(export)
web_get_osc_reverse :: proc "c" (voice, osc: i32) -> i32 {
	context = runtime.default_context()
	if o := osc_for(voice, osc); o != nil { return o.reverse ? 1 : 0 }
	return 0
}

@(export)
web_get_voice_length :: proc "c" (voice: i32) -> f32 {
	context = runtime.default_context()
	if v := voice_ptr(voice); v != nil { return v.length }
	return 0
}

@(export)
web_get_voice_offset :: proc "c" (voice: i32) -> f32 {
	context = runtime.default_context()
	if v := voice_ptr(voice); v != nil { return v.start_offset }
	return 0
}

// curve point getter: writes one point into a shared buffer, returns 1 on success
_px_pt: dsp.CurvePoint

@(export)
web_get_curve_point :: proc "c" (voice, osc, which, idx: i32) -> i32 {
	context = runtime.default_context()
	if c := curve_for(voice, osc, which); c != nil {
		if idx >= 0 && idx < i32(len(c.points)) {
			_px_pt = c.points[idx]
			return 1
		}
	}
	return 0
}

@(export)
web_get_curve_point_x :: proc "c" () -> f32 { return _px_pt.pos.x }
@(export)
web_get_curve_point_y :: proc "c" () -> f32 { return _px_pt.pos.y }
@(export)
web_get_curve_point_tl :: proc "c" () -> f32 { return _px_pt.tangent_l }
@(export)
web_get_curve_point_tr :: proc "c" () -> f32 { return _px_pt.tangent_r }
// shared buffer for WAV export
EXPORT_BUF_SIZE :: MAX_SAMPLES * 2 + 64
export_buf: [EXPORT_BUF_SIZE]byte
export_len: i32

@(export)
web_export_wav :: proc "c" () -> i32 {
    context = runtime.default_context()
    if gs.render_len <= 0 { return 0 }
    samples := gs.render_buf[:gs.render_len]
    wav := dsp.wav_write(samples, gs.sample_rate)
    // copy into fixed buffer for JS to read
    copy_len := min(len(wav), EXPORT_BUF_SIZE)
    for i in 0 ..< copy_len { export_buf[i] = wav[i] }
    export_len = i32(copy_len)
    delete(wav)
    return i32(uintptr(&export_buf[0]))
}

@(export)
web_export_wav_len :: proc "c" () -> i32 { return export_len }

@(export)
web_render :: proc "c" (duration: f32) -> i32 {
	context = runtime.default_context()
	// duration computed from voices (shared core helper); param kept for ABI
	td := project.render_duration(gs.voices[:gs.voice_count])
	gs.render_len = i32(project.render(
		gs.sample_rate,
		gs.voices[:gs.voice_count],
		gs.chain[:gs.chain_count],
		td,
		gs.render_buf[:],
		gs.effects_bypass,
	))
	return i32(uintptr(&gs.render_buf[0]))
}

@(export)
web_render_len :: proc "c" () -> i32 {
	context = runtime.default_context()
	return gs.render_len
}

@(export)
web_sample_rate :: proc "c" () -> i32 {
	context = runtime.default_context()
	return gs.sample_rate
}

// entry point (required by js_wasm32 target)

main :: proc() {}

// KDL project save/load

save_buf: [16 * 1024]byte  // 16KB for project text
save_len: i32

@(export)
web_save_project :: proc "c" () -> i32 {
	context = runtime.default_context()
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	project.project_save(&b, gs.sample_rate, gs.voices[:gs.voice_count], gs.chain[:gs.chain_count])

	text := strings.to_string(b)
	n := min(len(text), len(save_buf) - 1)
	for i in 0 ..< n { save_buf[i] = text[i] }
	save_buf[n] = 0
	save_len = i32(n)
	return i32(uintptr(&save_buf[0]))
}

@(export)
web_save_project_len :: proc "c" () -> i32 { return save_len }

@(export)
web_load_project :: proc "c" (data_ptr: i32, data_len: i32) -> i32 {
	context = runtime.default_context()
	if data_ptr == 0 || data_len <= 0 { return 0 }

	// read KDL text from JS memory
	src := make([]byte, data_len)
	defer delete(src)
	for i in 0 ..< data_len {
		src[i] = byte((^byte)(uintptr(data_ptr + i))^)
	}
	text := string(src)

	// clear existing state
	old_sr := gs.sample_rate
	web_clear_state()
	gs.sample_rate = old_sr

	p: project.Project
	if !project.project_load(text, &p) {
		project.project_destroy(&p)
		return 0
	}
	gs.sample_rate = p.sample_rate
	for &v in p.voices {
		if gs.voice_count >= MAX_VOICES { break }
		project.voice_copy(&gs.voices[gs.voice_count], &v)
		gs.voice_count += 1
	}
	for &e in p.chain {
		if gs.chain_count >= MAX_CHAIN { break }
		project.effect_node_copy(&gs.chain[gs.chain_count], &e)
		gs.chain_count += 1
	}
	project.project_destroy(&p)
	return 1
}

web_clear_state :: proc() {
	for i in 0 ..< gs.voice_count {
		project.voice_destroy(&gs.voices[i])
	}
	for i in 0 ..< gs.chain_count { delete(gs.chain[i].params) }
	gs = {}
	gs.sample_rate = 44100
}

@(export)
web_new_project :: proc "c" () {
	context = runtime.default_context()
	web_clear_state()
	web_add_voice()
}

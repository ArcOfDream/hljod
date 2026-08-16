package main

// voice = project.Voice (3 named oscs main/freq/volu, each
// carrying its 4 curves) + per-osc edit state.

import dsp "../core/dsp"
import fx "../core/effects"
import project "../core/project"
import "core:fmt"
import "core:os"
import "core:strings"

// rename text buffer
rename_buf: [128]byte
last_rename_voice: i32 = -1
// auto-increment counter so default names stay unique
voice_seq: i32
// cached wave-info line
wave_info_buf: string
wave_info_n: int
wave_info_rate: i32

// packaged builds put fonts/ beside the exe,
// dev builds keep them at desktop/fonts/
font_path :: proc(base, file: string) -> string {
	packaged := strings.concatenate({base, "fonts/", file})
	if os.exists(packaged) {return packaged}
	delete(packaged)
	return strings.concatenate({base, "desktop/fonts/", file})
}

Voice :: struct {
	using pv:   project.Voice,
	edit_state: [dsp.NUM_OSCS][dsp.NUM_CURVES]CurveEditState,
}

rename_voice :: proc(v: ^Voice, new_name: string) {
	for i in 0 ..< 64 {v.name[i] = 0}
	copy(v.name[:], new_name)
}

// curve index -> dsp.Curve on one osc (order vol/freq/wave/pm)
osc_curve :: proc(o: ^dsp.OscParams, ci: int) -> ^dsp.Curve {
	switch ci {
	case 0:
		return &o.vol_curve
	case 1:
		return &o.freq_curve
	case 2:
		return &o.wave_curve
	case 3:
		return &o.pm_curve
	}
	return nil
}

make_voice :: proc() -> Voice {
	v: Voice
	v.active = true
	v.length = 0.5
	voice_seq += 1
	rename_voice(&v, fmt.tprint("voice ", voice_seq))
	v.main_p = {
		kind   = .Sine,
		freq   = 440,
		volume = 80,
	}
	v.freq_p = {
		kind   = .Saw,
		freq   = 220,
		volume = 40,
	}
	v.volu_p = {
		kind   = .Rect,
		freq   = 110,
		volume = 40,
	}
	for oi in 0 ..< dsp.NUM_OSCS {
		o := osc_for(&v, oi)
		for ci in 0 ..< dsp.NUM_CURVES {
			lo, hi := dsp.curve_default_range(dsp.CurveKind(ci))
			dsp.curve_init(osc_curve(o, ci))
			osc_curve(o, ci).min_value = lo
			osc_curve(o, ci).max_value = hi
		}
		// vol/freq multipliers flat at 1, wave/pm depth flat at 0
		dsp.curve_add_point(&o.freq_curve, [2]f32{0, 1}, 0, 0)
		dsp.curve_add_point(&o.freq_curve, [2]f32{1, 1}, 0, 0)
		dsp.curve_add_point(&o.vol_curve, [2]f32{0, 1}, 0, 0)
		dsp.curve_add_point(&o.vol_curve, [2]f32{1, 1}, 0, 0)
		dsp.curve_add_point(&o.wave_curve, [2]f32{0, 0}, 0, 0)
		dsp.curve_add_point(&o.wave_curve, [2]f32{1, 0}, 0, 0)
		dsp.curve_add_point(&o.pm_curve, [2]f32{0, 0}, 0, 0)
		dsp.curve_add_point(&o.pm_curve, [2]f32{1, 0}, 0, 0)
	}
	return v
}

// osc index -> dsp.OscParams (main/freq/volu)
osc_for :: proc(v: ^Voice, oi: int) -> ^dsp.OscParams {
	switch oi {
	case 0:
		return &v.main_p
	case 1:
		return &v.freq_p
	case 2:
		return &v.volu_p
	}
	return nil
}

// osc+curve index -> dsp.Curve (order vol/freq/wave/pm)
curve_for :: proc(v: ^Voice, oi, ci: int) -> ^dsp.Curve {
	if o := osc_for(v, oi); o != nil {
		return osc_curve(o, ci)
	}
	return nil
}

free_voice :: proc(v: ^Voice) {
	project.voice_destroy(&v.pv)
}

// deep copy (curves are dynamic, shallow copy would alias+double-free)
dup_voice :: proc(src: ^Voice) -> Voice {
	dst: Voice
	project.voice_copy(&dst.pv, &src.pv)
	dst.edit_state = src.edit_state
	return dst
}

// mix voices -> apply fx chain -> store into *out (caller-freed).
// any successful render reflects the current state, so it clears the stale flag.
do_render :: proc(
	out: ^[]f32,
	voices: []Voice,
	chain: []fx.EffectNode,
	rate: i32,
	fx_bypass: bool,
) {
	render_dirty = false
	if len(out^) > 0 {delete(out^)}
	if len(voices) == 0 {out^ = make([]f32, 0); return}
	pv := make([]project.Voice, len(voices))
	defer delete(pv)
	for i in 0 ..< len(voices) {pv[i] = voices[i].pv}
	td := project.render_duration(pv)
	n := dsp.sample_count(rate, td)
	buf := make([]f32, n)
	project.render(rate, pv, chain, td, buf, fx_bypass)
	out^ = buf
}

// stop if playing, else re-render (if stale) and play.
// the rendered buffer can go stale while playing (edits are not re-rendered
// mid-play), so play re-renders first whenever the dirty flag is set.
toggle_playback :: proc(
	rendered: ^[]f32,
	voices: []Voice,
	chain: []fx.EffectNode,
	rate: i32,
	bypass: bool,
) {
	if player_playing {
		stop_playback()
	} else {
		if render_dirty {
			do_render(rendered, voices, chain, rate, bypass)
		}
		if !play_samples(rendered^) {/* no audio device */}
	}
}

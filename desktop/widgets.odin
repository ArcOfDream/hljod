package main

// imgui widgets for building the hljod panels: osc groups, effect rack,
// waveform preview, plus the name/param tables they share.

import dsp "../core/dsp"
import fx "../core/effects"
import imgui "../vendor/imgui"
import "core:math"

CURVE_NAMES := [?]cstring{"Volume", "Frequency", "Waveform", "PM Depth"}
OSC_NAMES := [?]cstring{"Main", "Freq (FM)", "Volu (AM)"}
WAVE_NAMES := [?]cstring {
	"None",
	"Sine",
	"Saw",
	"Rect",
	"Random",
	"Saw2",
	"Rect2",
	"Tri",
	"Random2",
	"Rect3",
	"Rect4",
	"Rect8",
	"Rect12",
	"Rect16",
	"Saw3",
	"Saw4",
	"Saw6",
	"Saw8",
	"Curve",
}
EFFECT_NAMES := [?]cstring {
	"None",
	"Delay",
	"Overdrive",
	"Reverb",
	"Distortion",
	"LowPass",
	"Chorus",
	"Bitcrusher",
	"PitchShift",
}
// per-kind param names + (min,max), mirroring web's EFFECT_PARAMS
EFFECT_PARAMS := [9][]ParamDef {
	{},
	{{"Time", 0, 2}, {"Fb", 0, 1}, {"Wet", 0, 1}, {"LP", 0, 1}},
	{{"Drive", 0, 10}, {"Tone", 0, 1}, {"Mix", 0, 1}},
	{{"Room", 0, 1}, {"Damp", 0, 1}, {"Wet", 0, 1}, {"Width", 0, 1}, {"Dry", 0, 1}},
	{{"Drive", 0, 10}, {"Tone", 0, 1}, {"Mix", 0, 1}},
	{{"Cut", 0, 1}, {"Q", 0, 1}},
	{{"Time", 1, 50}, {"Depth", 0, 1}, {"Rate", 0.1, 5}, {"Fb", 0, 1}, {"Mix", 0, 1}},
	{{"Bits", 1, 16}, {"Down", 0.01, 1}, {"Mix", 0, 1}},
	{{"Shift", 0.5, 2}, {"Mix", 0, 1}},
}

ParamDef :: struct {
	name:     cstring,
	min, max: f32,
}

// layout helpers for right-aligned widget clusters (top bar, voice tab,
// render bar). measure the group width, then right_align() jumps the
// cursor so the cluster ends flush with the window's right edge.
button_w :: proc(label: cstring) -> f32 {
	return imgui.CalcTextSize(label).x + imgui.GetStyle().FramePadding.x * 2
}

checkbox_w :: proc(label: cstring) -> f32 {
	st := imgui.GetStyle()
	return(
		imgui.GetFrameHeight() +
		imgui.CalcTextSize(label).x +
		st.FramePadding.x * 2 +
		st.ItemInnerSpacing.x \
	)
}

right_align :: proc(group_w: f32) {
	imgui.SameLine(imgui.GetCursorPos().x + imgui.GetContentRegionAvail().x - group_w)
}

bar_center :: proc(bar_h: f32, item_h: f32 = 0) {
	h := item_h
	if h <= 0 {h = imgui.GetFrameHeight()}
	y := (bar_h - h) * 0.5
	if y > 0 {imgui.SetCursorPosY(y)}
}

// log-scaled freq slider: slider 0..10000 maps exp across 20..20000Hz
LOG_SLIDER_MAX :: 10000.0
LOG_FREQ_MIN :: 20.0
LOG_FREQ_MAX :: 20000.0

slider_to_freq :: proc(v: f32) -> f32 {
	if v <= 0 {return 0}
	return LOG_FREQ_MIN * math.pow(LOG_FREQ_MAX / LOG_FREQ_MIN, v / LOG_SLIDER_MAX)
}
freq_to_slider :: proc(f: f32) -> f32 {
	if f <= 0 {return 0}
	return(
		math.ln_f32(f / LOG_FREQ_MIN) /
		math.ln_f32(LOG_FREQ_MAX / LOG_FREQ_MIN) *
		LOG_SLIDER_MAX \
	)
}

// osc_param_row: a labeled slider + precise InputFloat on one line
// the label doubles as a selector
osc_param_row :: proc(
	oi: int,
	label: cstring,
	which: int,
	slider_tag, input_tag: cstring,
	v: ^f32,
	vmin, vmax: f32,
	is_log: bool,
	osc_idx, curve_idx: ^i32,
) -> bool {
	imgui.PushIDInt(i32(oi))
	ts := imgui.CalcTextSize(label)
	imgui.Selectable(
		label,
		osc_idx^ == i32(oi) && curve_idx^ == i32(which),
		{},
		{ts.x + imgui.GetStyle().FramePadding.x * 2, 0},
	)
	jumped := imgui.IsItemClicked()
	imgui.SameLine()
	imgui.SetNextItemWidth(-70)
	if is_log {
		slider_v := freq_to_slider(v^)
		imgui.SliderFloat(slider_tag, &slider_v, 0, LOG_SLIDER_MAX, "")
		v^ = slider_to_freq(slider_v)
	} else {
		imgui.SliderFloat(slider_tag, v, vmin, vmax, "")
	}
	undo_mark() // capture pre-edit / commit on slider gesture end
	imgui.SameLine()
	imgui.SetNextItemWidth(56)
	imgui.InputFloat(input_tag, v)
	undo_mark() // capture pre-edit / commit on keyboard input end
	imgui.PopID()
	return jumped
}

// osc_group: one collapsible osc block
osc_group :: proc(oi: int, o: ^dsp.OscParams, osc_idx, curve_idx: ^i32) {
	imgui.PushIDInt(1000 + i32(oi))
	if imgui.CollapsingHeader(cstring(OSC_NAMES[oi])) {
		// Wave label acts as the waveform-curve selector
		imgui.Selectable(
			"Wave",
			osc_idx^ == i32(oi) && curve_idx^ == 2,
			{},
			{imgui.CalcTextSize("Wave").x + imgui.GetStyle().FramePadding.x * 2, 0},
		)
		if imgui.IsItemClicked() {
			osc_idx^ = i32(oi); curve_idx^ = 2
		}
		imgui.SameLine()
		imgui.SetNextItemWidth(-1)
		if imgui.BeginCombo("##wave", cstring(WAVE_NAMES[o.kind])) {
			for i in 0 ..< len(WAVE_NAMES) {
				if imgui.Selectable(cstring(WAVE_NAMES[i]), o.kind == dsp.WaveKind(i)) {
					undo_push(doc_voices[:], doc_chain[:], doc_rate^, doc_active^) // before mutating kind
					o.kind = dsp.WaveKind(i)
				}
			}
			imgui.EndCombo()
		} else {
			// closed combo: mouse wheel cycles the wave kind (undo-aware)
			io := imgui.GetIO()
			if imgui.IsItemHovered() && io.MouseWheel != 0 {
				undo_push(doc_voices[:], doc_chain[:], doc_rate^, doc_active^)
				o.kind = dsp.WaveKind((i32(o.kind) + i32(io.MouseWheel)) %% i32(len(WAVE_NAMES)))
			}
		}
		imgui.Checkbox("Reverse", &o.reverse)
		undo_mark()
		// Off: plain row, no curve selector
		imgui.PushIDInt(i32(oi))
		imgui.TextUnformatted("Off")
		imgui.SameLine()
		imgui.SetNextItemWidth(-70)
		imgui.SliderFloat("##osl", &o.offset, 0, 1, "")
		undo_mark()
		imgui.SameLine()
		imgui.SetNextItemWidth(56)
		imgui.InputFloat("##oin", &o.offset)
		undo_mark()
		imgui.PopID()
		imgui.Separator()
		// freq (log), vol, pm
		if osc_param_row(
			oi,
			"Freq",
			1,
			"##fsl",
			"##fin",
			&o.freq,
			0,
			20000,
			true,
			osc_idx,
			curve_idx,
		) {
			osc_idx^ = i32(oi); curve_idx^ = 1
		}
		if osc_param_row(
			oi,
			"Vol",
			0,
			"##vsl",
			"##vin",
			&o.volume,
			0,
			200,
			false,
			osc_idx,
			curve_idx,
		) {
			osc_idx^ = i32(oi); curve_idx^ = 0
		}
		if osc_param_row(
			oi,
			"PM",
			3,
			"##psl",
			"##pin",
			&o.pm_blend,
			0,
			1,
			false,
			osc_idx,
			curve_idx,
		) {
			osc_idx^ = i32(oi); curve_idx^ = 3
		}
	}
	imgui.PopID()
}

combo_wheel :: proc(count: i32, idx: ^i32) {
	io := imgui.GetIO()
	if imgui.IsItemHovered() && io.MouseWheel != 0 {
		idx^ = (idx^ + i32(io.MouseWheel)) %% count
	}
}

effect_rack :: proc(chain: ^[dynamic]fx.EffectNode, kind_sel: ^i32) {
	imgui.TextUnformatted("Effect Chain")
	imgui.ComboChar("##addkind", kind_sel, raw_data(EFFECT_NAMES[:]), 9)
	combo_wheel(9, kind_sel)
	imgui.SameLine()
	if imgui.Button("+ Add") && kind_sel^ > 0 {
		undo_push(doc_voices[:], doc_chain[:], doc_rate^, doc_active^)
		n := len(chain^)
		append(chain, fx.EffectNode{kind = fx.EffectKind(kind_sel^), enabled = true})
		append(&chain[n].params, f32(0.5), f32(0.5), f32(0.5), f32(0.5), f32(0.5))
	}
	if len(chain^) == 0 {
		imgui.TextDisabledUnformatted("no effects")
		return
	}
	imgui.Separator()
	// first added on top
	for i := 0; i < len(chain^); i += 1 {
		node := &chain[i]
		imgui.PushIDInt(i32(i))
		if imgui.Checkbox("##on", &node.enabled) {}
		imgui.SameLine()
		imgui.TextUnformatted(EFFECT_NAMES[node.kind])
		imgui.SameLine()
		// up = toward top of stack = lower index
		if imgui.SmallButton("^") && i > 0 {
			undo_push(doc_voices[:], doc_chain[:], doc_rate^, doc_active^)
			tmp := chain[i]
			chain[i] = chain[i - 1]
			chain[i - 1] = tmp
		}
		imgui.SameLine()
		if imgui.SmallButton("v") && i < len(chain^) - 1 {
			undo_push(doc_voices[:], doc_chain[:], doc_rate^, doc_active^)
			tmp := chain[i]
			chain[i] = chain[i + 1]
			chain[i + 1] = tmp
		}
		imgui.SameLine()
		if imgui.SmallButton("X") {
			undo_push(doc_voices[:], doc_chain[:], doc_rate^, doc_active^)
			delete(node.params)
			ordered_remove(chain, i)
			i -= 1 // element shifted into this slot; don't skip it
			imgui.PopID()
			continue
		}
		pdefs := EFFECT_PARAMS[node.kind]
		for pi in 0 ..< len(pdefs) {
			if pi >= len(node.params) {append(&node.params, 0.5)}
			imgui.PushIDInt(i32(pi))
			imgui.TextUnformatted(pdefs[pi].name)
			imgui.SameLine()
			imgui.SetNextItemWidth(-56)
			imgui.SliderFloat("##p", &node.params[pi], pdefs[pi].min, pdefs[pi].max, "")
			undo_mark()
			imgui.SameLine()
			imgui.SetNextItemWidth(44)
			imgui.InputFloat("##v", &node.params[pi])
			undo_mark()
			imgui.PopID()
		}
		imgui.PopID()
	}
}

// downsample N samples onto a rect and stroke CRT-green (mirror web).
draw_waveform :: proc(dl: ^imgui.DrawList, ox, oy, ow, oh: f32, samples: []f32) {
	imgui.DrawList_AddRectFilled(dl, [2]f32{ox, oy}, [2]f32{ox + ow, oy + oh}, 0xFF_0A_0A_05)
	mid := oy + oh * 0.5
	imgui.DrawList_AddLine(dl, [2]f32{ox, mid}, [2]f32{ox + ow, mid}, 0xFF_00_22_00)
	if len(samples) == 0 {
		imgui.DrawList_AddText(dl, [2]f32{ox + ow * 0.5 - 20, mid - 8}, 0xFF_00_77_00, "no data")
		return
	}
	imgui.DrawList_PathClear(dl)
	for x := 0; x < int(ow); x += 1 {
		i := min(x * int(len(samples)) / max(1, int(ow)), len(samples) - 1)
		s := clamp_audio(samples[i])
		y := mid - s * (oh * 0.4)
		imgui.DrawList_PathLineTo(dl, [2]f32{ox + f32(x), y})
	}
	imgui.DrawList_PathStroke(dl, 0xFF_00_FF_00, 1.5, {})
}

clamp_audio :: proc(s: f32) -> f32 {
	if s > 1 {return 1}
	if s < -1 {return -1}
	return s
}

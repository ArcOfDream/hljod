package main

import dsp "../core/dsp"
import fx "../core/effects"
import imgui "../vendor/imgui"
import imgui_impl_sdl3 "../vendor/imgui/imgui_impl_sdl3"
import imgui_impl_sdlrenderer3 "../vendor/imgui/imgui_impl_sdlrenderer3"
import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

main :: proc() {
	init_ok := sdl.Init({.VIDEO, .AUDIO})
	assert(init_ok)
	defer sdl.Quit()

	window := sdl.CreateWindow("hljod", 1100, 720, {.RESIZABLE})
	assert(window != nil)
	defer sdl.DestroyWindow(window)

	// default renderer (gpu/gl) may be unavailable
	renderer := sdl.CreateRenderer(window, nil)
	if renderer == nil {
		renderer = sdl.CreateRenderer(window, "software")
	}
	assert(renderer != nil)
	defer sdl.DestroyRenderer(renderer)
	sdl.SetRenderVSync(renderer, 1)

	crow_init(renderer)
	defer crow_destroy()

	imgui.CHECKVERSION()
	imgui.CreateContext()

	dpi_scale := sdl.GetWindowDisplayScale(window)
	if dpi_scale < 1.0 {dpi_scale = 1.0}
	base := string(sdl.GetBasePath())
	reg_path := font_path(base, "IBMPlexSans-Regular.ttf")
	bold_path := font_path(base, "IBMPlexSans-Bold.ttf")
	defer delete(reg_path)
	defer delete(bold_path)
	atlas := imgui.GetIO().Fonts
	imgui.FontAtlas_AddFontFromFileTTF(atlas, cstring(raw_data(reg_path)), 15.0 * dpi_scale)
	imgui.FontAtlas_AddFontFromFileTTF(atlas, cstring(raw_data(bold_path)), 15.0 * dpi_scale)
	theme_win98(dpi_scale)
	defer imgui.DestroyContext()
	io := imgui.GetIO()
	io.ConfigFlags += {.DockingEnable}

	imgui_impl_sdl3.InitForSDLRenderer(window, renderer)
	defer imgui_impl_sdl3.Shutdown()
	imgui_impl_sdlrenderer3.Init(renderer)
	defer imgui_impl_sdlrenderer3.Shutdown()

	// data model
	voices: [dynamic]Voice
	active_voice := i32(0)
	append(&voices, make_voice())

	// animation/editing selection
	curve_idx := i32(0)
	osc_idx := i32(0)

	// effects chain + left-panel view tab
	fx_chain: [dynamic]fx.EffectNode
	fx_kind := i32(1)
	left_tab := i32(0)

	rate: i32 = 44100
	rendered: []f32 // last Render output, drawn in the waveform panel
	prev_editing := false
	fx_bypass := false
	undo_bind(&voices, &fx_chain, &rate, &active_voice)
	player_init(rate)
	defer player_destroy()
	kdl_pending_mutex = sdl.CreateMutex()
	defer sdl.DestroyMutex(kdl_pending_mutex)
	running := true
	for running {
		// apply any KDL load path picked by the file dialog (main thread)
		sdl.LockMutex(kdl_pending_mutex)
		load_path := kdl_pending_path
		kdl_pending_path = ""
		sdl.UnlockMutex(kdl_pending_mutex)
		if load_path != "" {
			undo_push(voices[:], fx_chain[:], rate, active_voice)
			kdl_load_apply(load_path, &voices, &fx_chain, &rate)
			delete(load_path)
			voice_seq = 0
			if len(voices) == 0 {append(&voices, make_voice())}
			if active_voice >= i32(len(voices)) {active_voice = i32(len(voices)) - 1}
			if len(rendered) > 0 {delete(rendered)}
			do_render(&rendered, voices[:], fx_chain[:], rate, fx_bypass)
		}
		e: sdl.Event
		for sdl.PollEvent(&e) {
			imgui_impl_sdl3.ProcessEvent(&e)
			#partial switch e.type {
			case .QUIT:
				running = false
			case .KEY_DOWN:
				if (e.key.mod & sdl.KMOD_CTRL) == sdl.KMOD_CTRL {
					#partial switch e.key.scancode {
					case .Z:
						if (e.key.mod & sdl.KMOD_SHIFT) == sdl.KMOD_SHIFT {
							redo_action(
								&rendered,
								&voices,
								&fx_chain,
								&rate,
								&active_voice,
								fx_bypass,
							)
						} else {
							undo_action(
								&rendered,
								&voices,
								&fx_chain,
								&rate,
								&active_voice,
								fx_bypass,
							)
						}
					case .Y:
						redo_action(&rendered, &voices, &fx_chain, &rate, &active_voice, fx_bypass)
					case .S:
						kdl_save_start(window, voices[:], fx_chain[:], rate)
					case .L:
						f := [1]sdl.DialogFileFilter{{"hljod project", "hljod"}}
						sdl.ShowOpenFileDialog(open_kdl_cb, nil, window, &f[0], 1, nil, false)
					}
				} else if e.key.scancode == .SPACE {
					toggle_playback(&rendered, voices[:], fx_chain[:], rate, fx_bypass)
				}
			}
		}

		imgui_impl_sdlrenderer3.NewFrame()
		imgui_impl_sdl3.NewFrame()
		imgui.NewFrame()
		player_poll()

		vp := imgui.GetMainViewport()
		work := vp.WorkPos
		size := vp.WorkSize

		// toolbar: app label + file ops + undo/redo (left-aligned)
		imgui.SetNextWindowPos(work, {}, {})
		imgui.SetNextWindowSize({size.x, 32}, {})
		if imgui.Begin("toolbar", nil, FIXED_FLAGS) {
			bar_center(32)
			imgui.AlignTextToFramePadding()
			imgui.TextUnformatted("hljod - sfx gen")
			// order: New Save Load | Undo Redo (mirror web toolbar)
			imgui.SameLine(0, 12)
			if imgui.Button("New") {
				undo_push(voices[:], fx_chain[:], rate, active_voice)
				for &v in voices {free_voice(&v)}
				clear(&voices)
				voice_seq = 0
				append(&voices, make_voice())
				active_voice = 0
				for &n in fx_chain {delete(n.params)}
				clear(&fx_chain)
				do_render(&rendered, voices[:], fx_chain[:], rate, fx_bypass)
				last_rename_voice = -1
			}
			imgui.SameLine()
			if imgui.Button("Save") {
				kdl_save_start(window, voices[:], fx_chain[:], rate)
			}
			imgui.SameLine()
			if imgui.Button("Load") {
				f := [1]sdl.DialogFileFilter{{"hljod project", "hljod"}}
				sdl.ShowOpenFileDialog(open_kdl_cb, nil, window, &f[0], 1, nil, false)
			}
			imgui.SameLine()
			imgui.TextUnformatted("|")
			imgui.SameLine()
			if imgui.Button("Undo") {
				undo_action(&rendered, &voices, &fx_chain, &rate, &active_voice, fx_bypass)
			}
			imgui.SameLine()
			if imgui.Button("Redo") {
				redo_action(&rendered, &voices, &fx_chain, &rate, &active_voice, fx_bypass)
			}
		}
		imgui.End()

		// voice selector + add, copy/del right-aligned
		row2_h := f32(30)
		imgui.SetNextWindowPos({work.x, work.y + 32}, {}, {})
		imgui.SetNextWindowSize({size.x, row2_h}, {})
		// seed rename buffer when the active voice changes
		if last_rename_voice != active_voice {
			last_rename_voice = active_voice
			for i in 0 ..< 128 {
				rename_buf[i] = 0
			}
			for i in 0 ..< 64 {
				if voices[active_voice].name[i] == 0 {break}
				rename_buf[i] = voices[active_voice].name[i]
			}
		}
		if imgui.Begin("toolbar2", nil, FIXED_FLAGS) {
			bar_center(row2_h)
			imgui.AlignTextToFramePadding()
			imgui.TextUnformatted("Voices")
			for i in 0 ..< len(voices) {
				imgui.SameLine()
				imgui.Selectable(cstring(&voices[i].name[0]), active_voice == i32(i), {}, {60, 0})
				if imgui.IsItemClicked() {active_voice = i32(i)}
			}
			imgui.SameLine()
			if imgui.Button("+") {
				undo_push(voices[:], fx_chain[:], rate, active_voice)
				append(&voices, make_voice())
				active_voice = i32(len(voices) - 1)
			}
			// copy/del at the right edge of the voice selector row
			sp := imgui.GetStyle().ItemSpacing.x
			right_align(button_w("copy") + sp + button_w("del"))
			if imgui.Button("copy") {
				undo_push(voices[:], fx_chain[:], rate, active_voice)
				append(&voices, dup_voice(&voices[active_voice]))
				active_voice = i32(len(voices) - 1)
			}
			imgui.SameLine()
			if imgui.Button("del") && len(voices) > 1 {
				undo_push(voices[:], fx_chain[:], rate, active_voice)
				free_voice(&voices[active_voice])
				ordered_remove(&voices, int(active_voice))
				voices[len(voices)] = {} // zero vacated slot (stale curve pointers)
				if active_voice >= i32(len(voices)) {active_voice = i32(len(voices)) - 1}
			}
		}
		imgui.End()

		// left: osc panel or effects rack
		left_w := f32(240)
		body_y := work.y + 32 + row2_h
		body_h := size.y - 32 - row2_h
		imgui.SetNextWindowPos({work.x, body_y}, {}, {})
		imgui.SetNextWindowSize({left_w, body_h}, {})
		if imgui.Begin("left", nil, PANEL_FLAGS) {
			// view tab lives with the panel it swaps, not the global toolbar
			if imgui.Selectable("Voices", left_tab == 0, {}, {64, 0}) {left_tab = 0}
			imgui.SameLine()
			if imgui.Selectable("Effects", left_tab == 1, {}, {64, 0}) {left_tab = 1}
			imgui.Separator()
			if left_tab == 0 {
				// rename active voice (double-click unreliable in imgui; field here)
				imgui.TextUnformatted("Name")
				imgui.SameLine()
				imgui.SetNextItemWidth(-1)
				if imgui.InputText("##rename", cstring(&rename_buf[0]), 128) {
					n := 0
					for n < 128 && rename_buf[n] != 0 {n += 1}
					rename_voice(&voices[active_voice], string(rename_buf[:n]))
				}
				undo_mark()
				imgui.Separator()
				av := &voices[active_voice]
				imgui.TextUnformatted("Dur")
				imgui.SameLine()
				imgui.SetNextItemWidth(90)
				imgui.InputFloat("##dur", &av.length, 0.01, 0.1, "%.2f")
				imgui.TextUnformatted("Off")
				imgui.SameLine()
				imgui.SetNextItemWidth(90)
				imgui.InputFloat("##off", &av.start_offset, 0.01, 0.1, "%.2f")
				imgui.Separator()
				for oi in 0 ..< dsp.NUM_OSCS {
					osc_group(oi, osc_for(av, oi), &osc_idx, &curve_idx)
				}
			} else {
				effect_rack(&fx_chain, &fx_kind)
			}
			// mascot
			left_w_win := imgui.GetWindowWidth()
			crow_draw(f32(sdl.GetTicks()) / 1000.0, 36, 6, left_w_win - 36 - 6)
		}
		imgui.End()

		// center column: curve toolbar + curve editor
		center_x := work.x + left_w
		center_w := size.x - left_w
		center_h := body_h
		render_bar_h := f32(30)
		wave_h := min(f32(140), max(f32(60), center_h * 0.15)) // fixed-ish
		curve_h := center_h - render_bar_h - wave_h
		tb_h := f32(30)
		av := &voices[active_voice]

		// curve-toolbar strip, CRT-themed like the curve editor below
		imgui.SetNextWindowPos({center_x, body_y}, {}, {})
		imgui.SetNextWindowSize({center_w, tb_h}, {})
		crt_style_push()
		if imgui.Begin("curve-tb", nil, FIXED_FLAGS) {
			bar_center(tb_h)
			cur := curve_for(av, int(osc_idx), int(curve_idx))
			imgui.AlignTextToFramePadding()
			imgui.TextUnformatted("Osc")
			imgui.SameLine()
			imgui.SetNextItemWidth(90)
			imgui.ComboChar("##osc", &osc_idx, raw_data(OSC_NAMES[:]), 3)
			combo_wheel(3, &osc_idx)
			imgui.SameLine()
			imgui.TextUnformatted("Curve")
			imgui.SameLine()
			imgui.SetNextItemWidth(110)
			imgui.ComboChar("##curve", &curve_idx, raw_data(CURVE_NAMES[:]), 4)
			imgui.SameLine()
			imgui.TextUnformatted("Min")
			imgui.SameLine()
			imgui.SetNextItemWidth(48)
			imgui.InputFloat("##min", &cur.min_value)
			undo_mark()
			imgui.SameLine()
			imgui.TextUnformatted("Max")
			imgui.SameLine()
			imgui.SetNextItemWidth(48)
			imgui.InputFloat("##max", &cur.max_value)
			undo_mark()
			imgui.SameLine()
			if imgui.Button(cur.interp == .Hermite ? "H" : "L") {
				undo_push(voices[:], fx_chain[:], rate, active_voice) // before toggling interp
				cur.interp = dsp.CurveInterp.Hermite if cur.interp == .Linear else .Linear
			}
		}
		imgui.End()
		crt_style_pop()

		imgui.SetNextWindowPos({center_x, body_y + tb_h}, {}, {})
		imgui.SetNextWindowSize({center_w, curve_h - tb_h}, {})
		if imgui.Begin("curve", nil, PANEL_FLAGS) {
			CurveEditorWidget(
				"curve",
				curve_for(av, int(osc_idx), int(curve_idx)),
				&av.edit_state[int(osc_idx)][int(curve_idx)],
			)
		}
		imgui.End()

		// render bar: save wav left; fx bypass / play / stat right
		imgui.SetNextWindowPos({center_x, body_y + curve_h}, {}, {})
		imgui.SetNextWindowSize({center_w, render_bar_h}, {})
		if imgui.Begin("renderbar", nil, FIXED_FLAGS) {
			bar_center(render_bar_h)
			// save wav stays left...
			if imgui.Button("Save WAV") && len(rendered) > 0 {
				wav := dsp.wav_write(rendered, rate)
				save_file_dialog(window, wav, ".wav", "WAV audio", "wav")
			}
			// wave info (mirror web): N samples @ rate Hz (duration)
			if wave_info_n != len(rendered) || wave_info_rate != rate {
				wave_info_n = len(rendered)
				wave_info_rate = rate
				wave_info_buf = fmt.tprintf("%d samples @ %d Hz", len(rendered), rate)
			}
			// sample stat | fx bypass | play
			st := imgui.GetStyle()
			sp := st.ItemSpacing.x
			frame_h := imgui.GetFrameHeight()
			play_h := f32(26)
			play_w :=
				max(imgui.CalcTextSize("Play").x, imgui.CalcTextSize("Stop").x) +
				st.FramePadding.x * 2 +
				60
			stat_w := imgui.CalcTextSize(cstring(raw_data(wave_info_buf))).x
			right_w := stat_w + sp + checkbox_w("FX bypass") + sp + play_w
			right_align(right_w)
			
			imgui.TextUnformatted(cstring(raw_data(wave_info_buf)))
			imgui.SameLine()
			if imgui.Checkbox("FX bypass", &fx_bypass) {
				render_dirty = true
			}
			imgui.SameLine()

			imgui.SetCursorPosY(imgui.GetCursorPosY() - (play_h - frame_h) * 0.5)
			if imgui.Button(player_playing ? "Stop" : "Play", {play_w, play_h}) {
				toggle_playback(&rendered, voices[:], fx_chain[:], rate, fx_bypass)
			}
		}
		imgui.End()

		// waveform preview
		wave_top := body_y + curve_h + render_bar_h
		imgui.SetNextWindowPos({center_x, wave_top}, {}, {})
		imgui.SetNextWindowSize({center_w, wave_h}, {})
		if imgui.Begin("waveform", nil, PANEL_FLAGS) {
			dl := imgui.GetWindowDrawList()
			wpos := imgui.GetWindowPos()
			wsz := imgui.GetWindowSize()
			draw_waveform(dl, wpos.x, wpos.y, wsz.x, wsz.y, rendered)
		}
		imgui.End()

		// re-render once when an edit gesture ends
		editing := imgui.IsAnyMouseDown() || imgui.IsAnyItemActive()
		if !player_playing && prev_editing && !editing {
			do_render(&rendered, voices[:], fx_chain[:], rate, fx_bypass)
		}
		prev_editing = editing

		imgui.Render()
		sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
		sdl.RenderClear(renderer)
		imgui_impl_sdlrenderer3.RenderDrawData(imgui.GetDrawData(), renderer)
		sdl.RenderPresent(renderer)
	}

	for &v in voices {
		free_voice(&v)
	}
	delete(voices)
	if len(rendered) > 0 {delete(rendered)}
	for &node in fx_chain {
		delete(node.params)
	}
	delete(fx_chain)
	history_destroy()
}

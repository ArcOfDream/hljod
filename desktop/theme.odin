package main

// 98.css color scheme ported to imgui style colors. chrome is silver/3d-dark
// like classic windows; navy for title/tabs. CRC green stays only on curve canvas.

import imgui "../vendor/imgui"

PANEL_FLAGS :: imgui.WindowFlags {
	.NoTitleBar,
	.NoResize,
	.NoMove,
	.NoCollapse,
	.NoBringToFrontOnFocus,
	.NoScrollbar,
}
// fixed-size panels (toolbars, curve selector, play bar)
FIXED_FLAGS :: PANEL_FLAGS | {.NoScrollWithMouse}

theme_win98 :: proc(dpi_scale: f32) {
	st := imgui.GetStyle()
	st.WindowRounding = 0
	st.ChildRounding = 0
	st.FrameRounding = 0
	st.PopupRounding = 0
	st.FrameBorderSize = 1
	st.WindowBorderSize = 1
	st.WindowMinSize = {32, 1} // default (32,32) clamps short bars up to 32px, breaking bar_center math
	st.AntiAliasedLines = false
	st.AntiAliasedFill = false

	if dpi_scale > 1.0 {
		imgui.Style_ScaleAllSizes(st, dpi_scale)
	}

	win := imgui.Vec4{0.75, 0.75, 0.75, 1.0} // #c0c0c0 silver
	face := imgui.Vec4{0.87, 0.87, 0.87, 1.0} // #dfdfdf button face
	hl := imgui.Vec4{1.0, 1.0, 1.0, 1.0} // #ffffff highlight
	shadow := imgui.Vec4{0.50, 0.50, 0.50, 1.0} // #808080
	navy := imgui.Vec4{0.0, 0.0, 0.5, 1.0} // #000080 header/title
	dktext := imgui.Vec4{0.0, 0.0, 0.0, 1.0}
	dis := imgui.Vec4{0.5, 0.5, 0.5, 1.0}

	st.Colors[imgui.Col.WindowBg] = win
	st.Colors[imgui.Col.ChildBg] = win
	st.Colors[imgui.Col.PopupBg] = face
	st.Colors[imgui.Col.Border] = shadow
	st.Colors[imgui.Col.BorderShadow] = shadow
	st.Colors[imgui.Col.FrameBg] = face
	st.Colors[imgui.Col.FrameBgHovered] = hl
	st.Colors[imgui.Col.FrameBgActive] = win
	st.Colors[imgui.Col.TitleBg] = navy
	st.Colors[imgui.Col.TitleBgActive] = navy
	st.Colors[imgui.Col.TitleBgCollapsed] = shadow
	st.Colors[imgui.Col.MenuBarBg] = face
	st.Colors[imgui.Col.ScrollbarBg] = win
	st.Colors[imgui.Col.ScrollbarGrab] = win
	st.Colors[imgui.Col.ScrollbarGrabHovered] = hl
	st.Colors[imgui.Col.ScrollbarGrabActive] = shadow
	st.Colors[imgui.Col.CheckMark] = dktext
	st.Colors[imgui.Col.SliderGrab] = win
	st.Colors[imgui.Col.SliderGrabActive] = shadow
	st.Colors[imgui.Col.Button] = face
	st.Colors[imgui.Col.ButtonHovered] = hl
	st.Colors[imgui.Col.ButtonActive] = win
	st.Colors[imgui.Col.Header] = hl
	st.Colors[imgui.Col.HeaderHovered] = face
	st.Colors[imgui.Col.HeaderActive] = face
	st.Colors[imgui.Col.Separator] = shadow
	st.Colors[imgui.Col.ResizeGrip] = shadow
	st.Colors[imgui.Col.ResizeGripHovered] = hl
	st.Colors[imgui.Col.ResizeGripActive] = navy
	st.Colors[imgui.Col.Tab] = win
	st.Colors[imgui.Col.TabHovered] = hl
	st.Colors[imgui.Col.TabSelected] = face
	st.Colors[imgui.Col.TabSelectedOverline] = navy
	st.Colors[imgui.Col.Text] = dktext
	st.Colors[imgui.Col.TextDisabled] = dis
	st.Colors[imgui.Col.TextSelectedBg] = hl
}

// crt panel theme
crt_style_push :: proc() {
	imgui.PushStyleVar(.WindowBorderSize, 0)
	imgui.PushStyleVar(.FrameBorderSize, 0)
	imgui.PushStyleColor(.WindowBg, 0xFF_0A_0A_05)
	imgui.PushStyleColor(.PopupBg, 0xFF_0A_0A_05)
	imgui.PushStyleColor(.Border, 0xFF_00_40_00)
	imgui.PushStyleColor(.Text, 0xFF_00_FF_00)
	imgui.PushStyleColor(.TextDisabled, 0xFF_00_55_00)
	imgui.PushStyleColor(.FrameBg, 0xFF_08_18_08)
	imgui.PushStyleColor(.FrameBgHovered, 0xFF_10_2A_10)
	imgui.PushStyleColor(.FrameBgActive, 0xFF_0A_0A_05)
	imgui.PushStyleColor(.Button, 0xFF_08_18_08)
	imgui.PushStyleColor(.ButtonHovered, 0xFF_14_30_14)
	imgui.PushStyleColor(.ButtonActive, 0xFF_0A_0A_05)
	imgui.PushStyleColor(.Header, 0xFF_0A_28_0A)
	imgui.PushStyleColor(.HeaderHovered, 0xFF_10_30_10)
	imgui.PushStyleColor(.HeaderActive, 0xFF_0A_0A_05)
}

crt_style_pop :: proc() {
	imgui.PopStyleColor(14)
	imgui.PopStyleVar(2)
}

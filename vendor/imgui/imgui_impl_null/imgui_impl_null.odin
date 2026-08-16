package imgui_impl_null

import imgui "../"

when      ODIN_OS == .Windows { foreign import lib "../imgui_windows_x64.lib" }
else when ODIN_OS == .Linux   { foreign import lib "../imgui_linux_x64.a" }
else when ODIN_OS == .Darwin  {
	when ODIN_ARCH == .amd64 { foreign import lib "../imgui_darwin_x64.a" } else { foreign import lib "../imgui_darwin_arm64.a" }
}

// imgui_impl_null.h
// Last checked `v1.92.8-docking` (b885382)

// This is designed if you need to use a blind Dear Imgui context with no input and no output.
@(link_prefix="ImGui_ImplNull_")
foreign lib {
// Null = NullPlatform + NullRender
	Init     :: proc() -> bool ---
	Shutdown :: proc() ---
	NewFrame :: proc() ---
}

@(link_prefix="ImGui_ImplNull")
foreign lib {
	// Null platform only (single screen, fixed timestep, no inputs)
	Platform_Init     :: proc() -> bool ---
	Platform_Shutdown :: proc() ---
	Platform_NewFrame :: proc() ---

	// Null renderer only (no output)
	Render_Init           :: proc() -> bool ---
	Render_Shutdown       :: proc() ---
	Render_NewFrame       :: proc() ---
	Render_RenderDrawData :: proc(draw_data: ^imgui.DrawData) ---
}

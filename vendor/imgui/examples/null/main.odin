package imgui_example_null

// This is a copy of the "null" example from ImGui
// https://github.com/ocornut/imgui/blob/docking/examples/example_null/main.cpp
// Based on the above at tag `v1.92.8-docking` (506f7e)

import imgui "../.."
import "../../imgui_impl_null"

import "core:fmt"

main :: proc() {
	imgui.CHECKVERSION()

	imgui.CreateContext()
	defer {
		fmt.println("DestroyContext()")
		imgui.DestroyContext()
	}
	io := imgui.GetIO()

	imgui_impl_null.Platform_Init()
	defer imgui_impl_null.Platform_Shutdown()
	imgui_impl_null.Render_Init()
	defer imgui_impl_null.Render_Shutdown()

	for i in 0..<20 {
		fmt.printf("NewFrame() {}\n", i)
		imgui_impl_null.Platform_NewFrame()
		imgui_impl_null.Render_NewFrame()
		imgui.NewFrame()

		@(static) f: f32
		imgui.Text("Hello, world!")
		imgui.SliderFloat("float", &f, 0, 1)
		imgui.Text("Application average %.3f ms/frame (%.1f FPS)", 1000.0 / io.Framerate, io.Framerate)
		imgui.ShowDemoWindow()

		imgui.Render()
	}
}

package imgui_example_sdl3_sdlrenderer3

// This is an example of using the bindings with SDL3 and SDL_Renderer3
// For a more complete example with comments, see:
// https://github.com/ocornut/imgui/blob/docking/examples/example_sdl3_sdlrenderer3/main.cpp
// Based on the above at tag `v1.92.8-docking` (3fb22b8)

import imgui "../.."
import "../../imgui_impl_sdl3"
import "../../imgui_impl_sdlrenderer3"

import sdl "vendor:sdl3"

main :: proc() {
	init_ok := sdl.Init({.VIDEO, .GAMEPAD})
	assert(init_ok)
	defer sdl.Quit()

	main_scale := sdl.GetDisplayContentScale(sdl.GetPrimaryDisplay())
	window_flags := sdl.WindowFlags {.RESIZABLE, .HIDDEN, .HIGH_PIXEL_DENSITY}
	window := sdl.CreateWindow("Dear ImGui SDL3+SDL_Renderer example", i32(1280 * main_scale), i32(800 * main_scale), window_flags)
	assert(window != nil)
	defer sdl.DestroyWindow(window)

	renderer := sdl.CreateRenderer(window, nil)
	assert(renderer != nil)
	defer sdl.DestroyRenderer(renderer)
	sdl.SetRenderVSync(renderer, 1)
	sdl.SetWindowPosition(window, sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED)
	sdl.ShowWindow(window)

	// Setup Dear ImGui context
	imgui.CHECKVERSION()
	imgui.CreateContext()
	defer imgui.DestroyContext()
	io := imgui.GetIO()
	io.ConfigFlags += {.NavEnableKeyboard, .NavEnableGamepad, .DockingEnable}

	imgui.StyleColorsDark()

	style := imgui.GetStyle()
	imgui.Style_ScaleAllSizes(style, main_scale)
	style.FontScaleDpi = main_scale

	imgui_impl_sdl3.InitForSDLRenderer(window, renderer)
	defer imgui_impl_sdl3.Shutdown()
	imgui_impl_sdlrenderer3.Init(renderer)
	defer imgui_impl_sdlrenderer3.Shutdown()

	running := true
	for running {
		e: sdl.Event
		for sdl.PollEvent(&e) {
			imgui_impl_sdl3.ProcessEvent(&e)

			#partial switch e.type {
			case .QUIT: running = false
			}
		}

		imgui_impl_sdlrenderer3.NewFrame()
		imgui_impl_sdl3.NewFrame()
		imgui.NewFrame()

		imgui.ShowDemoWindow()

		if imgui.Begin("Window containing a quit button") {
			if imgui.Button("The quit button in question") {
				running = false
			}
		}
		imgui.End()

		imgui.Render()
		sdl.SetRenderScale(renderer, io.DisplayFramebufferScale.x, io.DisplayFramebufferScale.y)
		sdl.SetRenderDrawColor(renderer, 0, 0, 0, 255)
		sdl.RenderClear(renderer)
		imgui_impl_sdlrenderer3.RenderDrawData(imgui.GetDrawData(), renderer)
		sdl.RenderPresent(renderer)
	}
}

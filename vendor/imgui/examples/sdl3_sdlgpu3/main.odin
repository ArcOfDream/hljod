package imgui_example_sdl3_sdlgpu3

// This is an example of using the bindings with SDL3 and SDL GPU
// For a more complete example with comments, see:
// https://github.com/ocornut/imgui/blob/docking/examples/example_sdl3_sdlgpu3/main.cpp
// Based on the above at tag `v1.92.8-docking` (3fb22b8)

import imgui "../.."
import "../../imgui_impl_sdl3"
import "../../imgui_impl_sdlgpu3"

import sdl "vendor:sdl3"

main :: proc() {
	init_ok := sdl.Init({.VIDEO, .GAMEPAD})
	assert(init_ok)
	defer sdl.Quit()

	main_scale := sdl.GetDisplayContentScale(sdl.GetPrimaryDisplay())
	window_flags := sdl.WindowFlags {.RESIZABLE, .HIDDEN, .HIGH_PIXEL_DENSITY}
	window := sdl.CreateWindow("Dear ImGui SDL3+SDL_GPU example", i32(1280 * main_scale), i32(800 * main_scale), window_flags)
	assert(window != nil)
	defer sdl.DestroyWindow(window)
	sdl.SetWindowPosition(window, sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED)
	sdl.ShowWindow(window)

	gpu_device := sdl.CreateGPUDevice({.SPIRV, .DXIL, .MSL, .METALLIB}, true, nil)
	assert(gpu_device != nil)
	defer sdl.DestroyGPUDevice(gpu_device)

	got_window := sdl.ClaimWindowForGPUDevice(gpu_device, window)
	assert(got_window)
	defer sdl.ReleaseWindowFromGPUDevice(gpu_device, window)

	// Setup Dear ImGui context
	imgui.CHECKVERSION()
	imgui.CreateContext()
	defer imgui.DestroyContext()
	io := imgui.GetIO()
	io.ConfigFlags += {.NavEnableKeyboard, .NavEnableGamepad, .DockingEnable, .ViewportsEnable}

	imgui.StyleColorsDark()

	style := imgui.GetStyle()
	imgui.Style_ScaleAllSizes(style, main_scale)
	style.FontScaleDpi = main_scale
	io.ConfigDpiScaleFonts = true
	io.ConfigDpiScaleViewports = true

	if .ViewportsEnable in io.ConfigFlags {
		style.WindowRounding = 0
		style.Colors[imgui.Col.WindowBg].w = 1
	}

	imgui_impl_sdl3.InitForSDLGPU(window)
	defer imgui_impl_sdl3.Shutdown()

	init_info := imgui_impl_sdlgpu3.InitInfo {
		Device               = gpu_device,
		ColorTargetFormat    = sdl.GetGPUSwapchainTextureFormat(gpu_device, window),
		MSAASamples          = ._1,
		SwapchainComposition = .SDR,
		PresentMode          = .VSYNC,
	}
	imgui_impl_sdlgpu3.Init(&init_info)
	defer imgui_impl_sdlgpu3.Shutdown()

	running := true
	for running {
		e: sdl.Event
		for sdl.PollEvent(&e) {
			imgui_impl_sdl3.ProcessEvent(&e)

			#partial switch e.type {
			case .QUIT: running = false
			}
		}

		imgui_impl_sdlgpu3.NewFrame()
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
		draw_data := imgui.GetDrawData()
		is_minimized := draw_data.DisplaySize.x == 0 || draw_data.DisplaySize.y == 0

		command_buffer := sdl.AcquireGPUCommandBuffer(gpu_device)
		swapchain_texture: ^sdl.GPUTexture
		swapchain_texture_ok := sdl.WaitAndAcquireGPUSwapchainTexture(command_buffer, window, &swapchain_texture, nil, nil)
		assert(swapchain_texture_ok)

		if swapchain_texture != nil && !is_minimized {
			imgui_impl_sdlgpu3.PrepareDrawData(draw_data, command_buffer)

			target_info := sdl.GPUColorTargetInfo {
				texture = swapchain_texture,
				clear_color = { 0, 0, 0, 1 },
				load_op = .CLEAR,
				store_op = .STORE,
			}
			render_pass := sdl.BeginGPURenderPass(command_buffer, &target_info, 1, nil)

			imgui_impl_sdlgpu3.RenderDrawData(draw_data, command_buffer, render_pass, nil)

			sdl.EndGPURenderPass(render_pass)
		}

		if .ViewportsEnable in io.ConfigFlags {
			imgui.UpdatePlatformWindows()
			imgui.RenderPlatformWindowsDefault()
		}

		submit_ok := sdl.SubmitGPUCommandBuffer(command_buffer)
		assert(submit_ok)
	}

	wait_ok := sdl.WaitForGPUIdle(gpu_device)
	assert(wait_ok)
}


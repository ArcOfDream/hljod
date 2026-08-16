#+build windows
package imgui_impl_dx11

import imgui "../"
import "vendor:directx/d3d11"

when      ODIN_OS == .Windows { foreign import lib "../imgui_windows_x64.lib" }
else when ODIN_OS == .Linux   { foreign import lib "../imgui_linux_x64.a" }
else when ODIN_OS == .Darwin  {
	when ODIN_ARCH == .amd64 { foreign import lib "../imgui_darwin_x64.a" } else { foreign import lib "../imgui_darwin_arm64.a" }
}

// imgui_impl_dx11.h
// Last checked `v1.92.8-docking` (a310715)
@(link_prefix="ImGui_ImplDX11_")
foreign lib {
	Init           :: proc(device: ^d3d11.IDevice, device_context: ^d3d11.IDeviceContext) -> bool ---
	Shutdown       :: proc() ---
	NewFrame       :: proc() ---
	RenderDrawData :: proc(draw_data: ^imgui.DrawData) ---

	// Use if you want to reset your rendering device without losing Dear ImGui state.
	CreateDeviceObjects     :: proc() -> bool ---
	InvalidateDeviceObjects :: proc() ---

	// (Advanced) Use e.g. if you need to precisely control the timing of texture updates (e.g. for staged rendering), by setting ImDrawData::Textures = nullptr to handle this manually.
	UpdateTexture :: proc(tex: ^imgui.TextureData) ---
}

// [BETA] Selected render state data shared with callbacks.
// This is temporarily stored in GetPlatformIO().Renderer_RenderState during the ImGui_ImplDX11_RenderDrawData() call.
// (Please open an issue if you feel you need access to more data)
RenderState :: struct {
    Device:               ^d3d11.IDevice,
    DeviceContext:        ^d3d11.IDeviceContext,
	VertexConstantBuffer: ^d3d11.IBuffer,
    SamplerLinear:        ^d3d11.ISamplerState, // Use ImDrawList::AddCallback(ImGui::GetPlatform().DrawCallback_SetSamplerLinear)
    SamplerNearest:       ^d3d11.ISamplerState, // Use ImDrawList::AddCallback(ImGui::GetPlatform().DrawCallback_SetSamplerNearest)
}

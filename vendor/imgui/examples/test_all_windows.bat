@echo off

odin run glfw_opengl3
@rem TODO[TS]: We should probably just have the native version of this available as well..
@rem odin run glfw_wgpu
odin run null
odin run sdl2_directx11
odin run sdl2_opengl3
@rem odin run sdl2_sdlrenderer2 (odin version too old)
odin run sdl3_sdlrenderer3
odin run sdl3_sdlgpu3

@rem These should be tested separately as they are more complicated to set up.
@rem cd js_webgl && ./build.sh (doesn't compile on my machine?)
@rem cd ..
@rem cd js_wgpu && ./build.sh
@rem cd ..

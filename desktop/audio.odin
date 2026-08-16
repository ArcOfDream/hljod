package main

// sticking to pure SDL here and using it's Audio API

import "core:c"
import sdl "vendor:sdl3"

player_stream: ^sdl.AudioStream
player_playing: bool

player_init :: proc(rate: i32) {
	spec := sdl.AudioSpec {
		format   = sdl.AudioFormat.F32,
		channels = 1,
		freq     = c.int(rate),
	}
	player_stream = sdl.OpenAudioDeviceStream(sdl.AUDIO_DEVICE_DEFAULT_PLAYBACK, &spec, nil, nil)
	if player_stream != nil {
		sdl.ResumeAudioStreamDevice(player_stream)
	}
}

// play rendered samples, or return early if there's no backend
play_samples :: proc(samples: []f32) -> bool {
	if player_stream == nil {return false}
	sdl.ClearAudioStream(player_stream)
	if len(samples) > 0 {
		sdl.PutAudioStreamData(
			player_stream,
			raw_data(samples),
			c.int(len(samples) * size_of(f32)),
		)
	}
	sdl.ResumeAudioStreamDevice(player_stream)
	player_playing = true
	return true
}

// reset play state after stream ends
player_poll :: proc() {
	if player_playing && player_stream != nil && sdl.GetAudioStreamQueued(player_stream) == 0 {
		player_playing = false
	}
}

stop_playback :: proc() {
	if player_stream != nil {
		sdl.PauseAudioStreamDevice(player_stream)
		sdl.ClearAudioStream(player_stream)
	}
	player_playing = false
}

player_destroy :: proc() {
	if player_stream != nil {
		sdl.DestroyAudioStream(player_stream)
		player_stream = nil
	}
}

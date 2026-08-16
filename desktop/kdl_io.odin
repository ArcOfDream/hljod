package main

// KDL project save/load

import fx "../core/effects"
import project "../core/project"
import "base:runtime"
import "core:os"
import "core:strings"
import sdl "vendor:sdl3"

// dialog plumbing (shared with wav save)

save_file_ctx :: struct {
	data: []byte,
	ext:  string,
}

save_file_cb :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: i32) {
	context = runtime.default_context()
	ctx := cast(^save_file_ctx)userdata
	if ctx != nil && filelist != nil && filelist[0] != nil && len(ctx.data) > 0 {
		path := string(filelist[0])
		if !strings.has_suffix(path, ctx.ext) {path = strings.concatenate({path, ctx.ext})}
		_ = os.write_entire_file(path, ctx.data)
	}
	if ctx != nil {
		delete(ctx.data)
		free(ctx)
	}
}

// path picked by the open dialog, drained on the main thread
// one path at a time (allow_many=false)
kdl_pending_mutex: ^sdl.Mutex
kdl_pending_path: string

open_kdl_cb :: proc "c" (userdata: rawptr, filelist: [^]cstring, filter: i32) {
	context = runtime.default_context()
	if filelist == nil || filelist[0] == nil {return}
	sdl.LockMutex(kdl_pending_mutex)
	kdl_pending_path = strings.clone(string(filelist[0]))
	sdl.UnlockMutex(kdl_pending_mutex)
}

// open native save dialog for already-encoded bytes (wav / kdl share this)
save_file_dialog :: proc(
	window: ^sdl.Window,
	data: []byte,
	ext: string,
	filter_name, filter: cstring,
) {
	ctx := new(save_file_ctx)
	ctx.data = data
	ctx.ext = ext
	filters := [1]sdl.DialogFileFilter{{filter_name, filter}}
	sdl.ShowSaveFileDialog(save_file_cb, ctx, window, &filters[0], 1, nil)
}

// build serialized project text from current state, then open save dialog
kdl_save_start :: proc(window: ^sdl.Window, voices: []Voice, chain: []fx.EffectNode, rate: i32) {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	pv := make([]project.Voice, len(voices))
	defer delete(pv)
	for i in 0 ..< len(voices) {pv[i] = voices[i].pv}
	project.project_save(&b, rate, pv, chain)
	text := strings.to_string(b)
	data := make([]byte, len(text))
	copy(data, text)
	save_file_dialog(window, data, ".hljod", "hljod project", "hljod")
}

// free current state + replace from a loaded file (main thread only)
kdl_load_apply :: proc(
	path: string,
	voices: ^[dynamic]Voice,
	chain: ^[dynamic]fx.EffectNode,
	rate: ^i32,
) {
	text, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {return}
	defer delete(text)

	p: project.Project
	if !project.project_load(string(text), &p) {
		project.project_destroy(&p)
		return
	}
	rate^ = p.sample_rate

	// replace voices (move project.Voice into the embedded wrapper)
	for &v in voices {free_voice(&v)}
	clear(voices)
	for &pv in p.voices {
		append(voices, Voice{pv = pv})
	}
	clear(&p.voices)

	// replace fx chain
	for &n in chain {delete(n.params)}
	clear(chain)
	for &e in p.chain {
		append(chain, e)
	}
	clear(&p.chain)

	project.project_destroy(&p)
}

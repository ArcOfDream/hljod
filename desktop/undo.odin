package main

// snapshots are taken right before the data changes

import fx "../core/effects"
import imgui "../vendor/imgui"

MAX_HISTORY :: 64

HistoryEntry :: struct {
	voices:       [dynamic]Voice,
	chain:        [dynamic]fx.EffectNode,
	rate:         i32,
	active_voice: i32,
}

undo_stack: [dynamic]HistoryEntry
redo_stack: [dynamic]HistoryEntry

// every undo-tracked mutation marks the rendered buffer stale; 
// do_render clears it. play re-renders first when stale
// (edits made during playback are not re-rendered until the next play)
render_dirty := true

// copy current state into a fresh entry
history_clone :: proc(voices: []Voice, chain: []fx.EffectNode, rate, active: i32) -> HistoryEntry {
	e := HistoryEntry {
		rate         = rate,
		active_voice = active,
	}
	for &v in voices {
		append(&e.voices, dup_voice(&v))
	}
	for &n in chain {
		node := n
		node.params = make([dynamic]f32, len(n.params))
		copy(node.params[:], n.params[:])
		append(&e.chain, node)
	}
	return e
}

history_free :: proc(e: ^HistoryEntry) {
	for &v in e.voices {free_voice(&v)}
	delete(e.voices)
	for &n in e.chain {delete(n.params)}
	delete(e.chain)
}

undo_can :: proc() -> bool {return len(undo_stack) > 0}
redo_can :: proc() -> bool {return len(redo_stack) > 0}

// shared undo/redo entry (buttons + Ctrl+Z/Y)
undo_action :: proc(
	rendered: ^[]f32,
	voices: ^[dynamic]Voice,
	chain: ^[dynamic]fx.EffectNode,
	rate: ^i32,
	active_voice: ^i32,
	bypass: bool,
) {
	if !undo_can() {return}
	if av := undo_step(voices, chain, rate); av >= 0 {active_voice^ = av}
	do_render(rendered, voices[:], chain[:], rate^, bypass)
}

redo_action :: proc(
	rendered: ^[]f32,
	voices: ^[dynamic]Voice,
	chain: ^[dynamic]fx.EffectNode,
	rate: ^i32,
	active_voice: ^i32,
	bypass: bool,
) {
	if !redo_can() {return}
	if av := redo_step(voices, chain, rate); av >= 0 {active_voice^ = av}
	do_render(rendered, voices[:], chain[:], rate^, bypass)
}

// drop redo branch, cap history, append entry
undo_commit :: proc(e: HistoryEntry) {
	for &er in redo_stack {history_free(&er)}
	clear(&redo_stack)
	if len(undo_stack) >= MAX_HISTORY {
		history_free(&undo_stack[0])
		ordered_remove(&undo_stack, 0)
	}
	append(&undo_stack, e)
	render_dirty = true
}

// call BEFORE the data changes
undo_push :: proc(voices: []Voice, chain: []fx.EffectNode, rate, active: i32) {
	undo_commit(history_clone(voices, chain, rate, active))
}

// restore the given snapshot onto live state, then free it
// returns the snapshot's active_voice.
restore_snapshot :: proc(
	voices: ^[dynamic]Voice,
	chain: ^[dynamic]fx.EffectNode,
	rate: ^i32,
	e: ^HistoryEntry,
) -> i32 {
	for &v in voices {free_voice(&v)}
	clear(voices)
	for &v in e.voices {append(voices, v)} 	// transfer element ownership
	delete(e.voices)

	for &n in chain {delete(n.params)}
	clear(chain)
	for &n in e.chain {append(chain, n)} 	// transfer element ownership
	delete(e.chain)

	rate^ = e.rate
	return e.active_voice
}

undo_step :: proc(voices: ^[dynamic]Voice, chain: ^[dynamic]fx.EffectNode, rate: ^i32) -> i32 {
	if len(undo_stack) == 0 {return -1}
	e := pop(&undo_stack)
	append(&redo_stack, history_clone(voices[:], chain[:], rate^, e.active_voice))
	av := restore_snapshot(voices, chain, rate, &e)
	return av
}

redo_step :: proc(voices: ^[dynamic]Voice, chain: ^[dynamic]fx.EffectNode, rate: ^i32) -> i32 {
	if len(redo_stack) == 0 {return -1}
	e := pop(&redo_stack)
	undo_commit(history_clone(voices[:], chain[:], rate^, e.active_voice))
	av := restore_snapshot(voices, chain, rate, &e)
	return av
}

history_destroy :: proc() {
	for &e in undo_stack {history_free(&e)}
	for &e in redo_stack {history_free(&e)}
	delete(undo_stack)
	delete(redo_stack)
}

doc_voices: ^[dynamic]Voice
doc_chain: ^[dynamic]fx.EffectNode
doc_rate: ^i32
doc_active: ^i32

undo_bind :: proc(v: ^[dynamic]Voice, c: ^[dynamic]fx.EffectNode, r: ^i32, a: ^i32) {
	doc_voices, doc_chain, doc_rate, doc_active = v, c, r, a
}

// pre-edit state captured when an item first becomes active; committed to
// history when that item's edit ends. lets undo restore the pre-drag state
// even though the widget mutates the value every frame during an edit.
undo_pending: HistoryEntry
undo_has_pending := false

undo_mark :: proc() {
	if doc_voices == nil {return}
	if imgui.IsItemActivated() {
		if undo_has_pending {history_free(&undo_pending)}
		undo_pending = history_clone(doc_voices[:], doc_chain[:], doc_rate^, doc_active^)
		undo_has_pending = true
	}
	if imgui.IsItemDeactivatedAfterEdit() && undo_has_pending {
		undo_commit(undo_pending)
		undo_has_pending = false
	}
}

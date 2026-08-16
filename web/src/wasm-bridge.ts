// typed wrapper around the wasm module exports
// all web_* functions are defined in web/main.odin
export interface WasmExports {
  _start(): void;
  web_init(sps: number): number;
  web_sample_rate(): number;

  web_add_voice(): number;
  web_remove_voice(idx: number): void;
  web_voice_count(): number;

  web_set_osc_kind(vi: number, oi: number, k: number): void;
  web_set_osc_freq(vi: number, oi: number, f: number): void;
  web_set_osc_volume(vi: number, oi: number, v: number): void;
  web_set_osc_reverse(vi: number, oi: number, r: number): void;
  web_get_osc_kind(vi: number, oi: number): number;
  web_get_osc_freq(vi: number, oi: number): number;
  web_get_osc_volume(vi: number, oi: number): number;
  web_set_osc_offset(vi: number, oi: number, offset: number): void;
  web_get_osc_offset(vi: number, oi: number): number;
  web_set_osc_pm_blend(vi: number, oi: number, blend: number): void;
  web_get_osc_pm_blend(vi: number, oi: number): number;
  web_get_osc_reverse(vi: number, oi: number): number;

  web_set_voice_length(vi: number, len: number): void;
  web_set_voice_offset(vi: number, off: number): void;
  web_get_voice_length(vi: number): number;
  web_get_voice_offset(vi: number): number;
  web_set_voice_name(vi: number, ptr: number, len: number): void;
  web_get_voice_name(vi: number): number;

  web_curve_point_count(vi: number, oi: number, wi: number): number;
  web_add_curve_point(
    vi: number,
    oi: number,
    wi: number,
    x: number,
    y: number,
    tl: number,
    tr: number,
  ): void;
  web_remove_curve_point(vi: number, oi: number, wi: number, pi: number): void;
  web_set_curve_point_pos(
    vi: number,
    oi: number,
    wi: number,
    pi: number,
    x: number,
    y: number,
  ): void;
  web_set_curve_point_tangents(
    vi: number,
    oi: number,
    wi: number,
    pi: number,
    tl: number,
    tr: number,
  ): void;
  web_set_curve_interp(
    vi: number,
    oi: number,
    wi: number,
    interp: number,
  ): void;
  web_set_curve_range(
    vi: number,
    oi: number,
    wi: number,
    min: number,
    max: number,
  ): void;
  web_get_curve_point(vi: number, oi: number, wi: number, pi: number): number;
  web_get_curve_point_x(): number;
  web_get_curve_point_y(): number;
  web_get_curve_point_tl(): number;
  web_get_curve_point_tr(): number;
  web_get_curve_interp(vi: number, oi: number, wi: number): number;
  web_get_curve_min(vi: number, oi: number, wi: number): number;
  web_get_curve_max(vi: number, oi: number, wi: number): number;

  web_render(duration: number): number;
  web_render_len(): number;
  web_export_wav(): number;
  web_export_wav_len(): number;
  web_save_project(): number;
  web_save_project_len(): number;
  web_load_project(ptr: number, len: number): number;

  web_effect_count(): number;
  web_get_effect_kind(idx: number): number;
  web_get_effect_enabled(idx: number): number;
  web_get_effect_param(idx: number, pi: number): number;
  web_set_effect_param(idx: number, pi: number, v: number): void;
  web_add_effect(
    kind: number,
    p0: number,
    p1: number,
    p2: number,
    p3: number,
    p4: number,
  ): void;
  web_remove_effect(idx: number): void;
  web_toggle_effect(idx: number): void;
  web_move_effect(idx: number, dir: number): void;
  web_clear_effects(): void;
  web_new_project(): void;
  web_set_effects_bypass(bp: number): void;
}

export let wasm: WasmExports | null = null;
export let wasmMemory: WebAssembly.Memory | null = null;

import type { Curve } from "./state.js";

// load and instantiate hljod.wasm
export async function loadWasm(): Promise<void> {
  const resp = await fetch("hljod.wasm");
  const buf = await resp.arrayBuffer();
  const memory = new WebAssembly.Memory({ initial: 256 });
  wasmMemory = memory;
  const imports = {
    odin_env: {
      write: (_fd: number, _ptr: number, _len: number) => {},
      rand_bytes: (ptr: number, len: number) => {
        crypto.getRandomValues(new Uint8Array(memory.buffer, ptr, len));
      },
      sin: Math.sin,
      cos: Math.cos,
      pow: Math.pow,
    },
    env: { memory },
  };
  const module = await WebAssembly.instantiate(buf, imports);
  wasm = module.instance.exports as unknown as WasmExports;
  if (wasm._start) wasm._start();
  wasm.web_init(44100);
}

// read a Float32Array from wasm linear memory
export function readSamples(ptr: number, len: number): Float32Array {
  return new Float32Array(wasmMemory!.buffer, ptr, len);
}

// rebuild one curve's points in wasm (remove-all -> re-add -> interp/range)
export function pushCurveToWasm(
  vi: number,
  oi: number,
  wi: number,
  c: Curve,
): void {
  if (!wasm) return;
  const cnt = wasm.web_curve_point_count(vi, oi, wi);
  for (let i = cnt - 1; i >= 0; i--) wasm.web_remove_curve_point(vi, oi, wi, i);
  for (let i = 0; i < c.points.length; i++)
    wasm.web_add_curve_point(
      vi,
      oi,
      wi,
      c.points[i].x,
      c.points[i].y,
      c.points[i].tl,
      c.points[i].tr,
    );
  wasm.web_set_curve_interp(vi, oi, wi, c.interp);
  wasm.web_set_curve_range(vi, oi, wi, c.min, c.max);
}

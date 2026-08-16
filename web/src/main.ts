import {
  state,
  createDefaultVoice,
  pushSnapshot,
  undo,
  redo,
  CURVE_KEYS,
  CURVE_INDEX,
  WAVE_NAMES,
  type Voice,
} from "./state.js";
import {
  wasm,
  wasmMemory,
  loadWasm,
  readSamples,
  pushCurveToWasm,
} from "./wasm-bridge.js";
import {
  drawCurve,
  getActiveCurve,
  initCurveEditor,
} from "./widgets/curve-editor.js";
import { drawWaveform } from "./widgets/waveform.js";
import { renderEffectList } from "./widgets/effect-rack.js";
import { setScheduleRender, syncSiblingInputs } from "./events.js";
import {
  isPlaying,
  playSamples,
  stopPlayback,
  renderedSamples,
  renderedSampleRate,
  setRenderedSamples,
  setRenderedSampleRate,
} from "./audio.js";

// render + play

let renderTimeout: number | null = null;

function _scheduleRender(): void {
  if (renderTimeout) clearTimeout(renderTimeout);
  renderTimeout = window.setTimeout(_doRender, 200);
}

function refreshAll(): void {
  syncWasmAll();
  renderTabs();
  renderOscPanel();
  drawCurve();
  _scheduleRender();
}

function _doRender(): void {
  if (!wasm) return;
  // duration computed in wasm (project.render_duration)
  const ptr = wasm.web_render(0);
  const len = wasm.web_render_len();
  const arr = readSamples(ptr, len);
  const s = new Float32Array(arr);
  setRenderedSamples(s);
  setRenderedSampleRate(wasm.web_sample_rate());
  drawWaveform(s);
  const info = document.getElementById("waveInfo")!;
  info.textContent = `${s.length} samples @ ${renderedSampleRate} Hz (${(s.length / renderedSampleRate).toFixed(3)}s)`;
}

function togglePlay(): void {
  if (isPlaying) {
    stopPlayback();
    updatePlayBtn();
  } else if (renderedSamples && renderedSamples.length > 0) {
    playSamples(renderedSamples, renderedSampleRate).then(() =>
      updatePlayBtn(),
    );
    updatePlayBtn();
  }
}

function updatePlayBtn(): void {
  const btn = document.getElementById("btnPlay")!;
  if (isPlaying) {
    btn.textContent = "■ Stop";
    btn.classList.add("playing");
  } else {
    btn.textContent = "▶ Play";
    btn.classList.remove("playing");
  }
}

function downloadWav(): void {
  if (!wasm || !renderedSamples || renderedSamples.length === 0) return;
  const ptr = wasm.web_export_wav();
  if (!ptr) return;
  const len = wasm.web_export_wav_len();
  if (!len) return;
  const bytes = new Uint8Array(wasmMemory!.buffer, ptr, len);
  const dur = renderedSamples.length / renderedSampleRate;
  const blob = new Blob([bytes], { type: "audio/wav" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "hljod_" + dur.toFixed(2).replace(".", "_") + "s.wav";
  a.click();
  URL.revokeObjectURL(a.href);
}

// voice management

function syncWasmVoice(vi: number): void {
  if (!wasm) return;
  const v = state.voices[vi];
  for (let oi = 0; oi < 3; oi++) {
    const o = v.osc[oi];
    wasm.web_set_osc_kind(vi, oi, o.kind);
    wasm.web_set_osc_freq(vi, oi, o.freq);
    wasm.web_set_osc_volume(vi, oi, o.vol);
    wasm.web_set_osc_reverse(vi, oi, o.rev ? 1 : 0);
    wasm.web_set_osc_offset(vi, oi, o.offset);
    wasm.web_set_osc_pm_blend(vi, oi, o.pmBlend);
    for (const which of CURVE_KEYS) {
      const c = o.curve[which];
      pushCurveToWasm(vi, oi, CURVE_INDEX[which], c);
    }
  }
  wasm.web_set_voice_length(vi, v.length);
  wasm.web_set_voice_offset(vi, v.start_offset);
  // label -> wasm name (fixed 64-byte buffer; scratch at 2MB like save/load)
  const enc = new TextEncoder();
  const nb = enc.encode(v.label);
  const mem = new Uint8Array(wasmMemory!.buffer);
  for (let i = 0; i < nb.length; i++) mem[2 * 1024 * 1024 + i] = nb[i];
  wasm.web_set_voice_name(vi, 2 * 1024 * 1024, nb.length);
}

function syncWasmAll(): void {
  for (let vi = 0; vi < state.voices.length; vi++) syncWasmVoice(vi);
}

function renderTabs(): void {
  const tc = document.getElementById("tabContainer")!;
  let h = "";
  for (let i = 0; i < state.voices.length; i++)
    h += `<button class="voice-tab${i === state.activeVoice ? " active" : ""}" data-idx="${i}">${state.voices[i].label}</button>`;
  tc.innerHTML = h;
}

let _renameInput: HTMLInputElement | null = null;

function startRename(idx: number): void {
  if (_renameInput) return;
  const v = state.voices[idx];
  const tab = document.querySelector(
    `.voice-tab[data-idx="${idx}"]`,
  ) as HTMLElement;
  if (!tab) return;

  const inp = document.createElement("input");
  inp.type = "text";
  inp.value = v.label;
  inp.className = "voice-rename-input";
  inp.dataset.idx = String(idx);

  tab.textContent = "";
  tab.appendChild(inp);
  inp.focus();
  inp.select();
  _renameInput = inp;

  const finish = (save: boolean) => {
    if (save && inp.value.trim()) {
      v.label = inp.value.trim();
    }
    _renameInput = null;
    renderTabs();
  };
  inp.addEventListener("blur", () => finish(true));
  inp.addEventListener("keydown", (e) => {
    if (e.key === "Enter") finish(true);
    else if (e.key === "Escape") finish(false);
  });
}

function selectVoice(idx: number): void {
  state.activeVoice = idx;
  const v = state.voices[idx];
  if (v) {
    const durEl = document.getElementById("inputDuration") as HTMLInputElement;
    const offEl = document.getElementById("inputOffset") as HTMLInputElement;
    durEl.value = v.length.toString();
    offEl.value = v.start_offset.toString();
  }
  renderTabs();
  renderOscPanel();
  drawCurve();
}

// expose for toolbar callbacks
export { selectVoice };

function addVoice(): void {
  pushSnapshot();
  const v = createDefaultVoice();
  v.label = "Voice " + (state.voices.length + 1);
  state.voices.push(v);
  if (wasm) wasm.web_add_voice();
  state.activeVoice = state.voices.length - 1;
  if (wasm) syncWasmVoice(state.activeVoice);
  renderTabs();
  renderOscPanel();
  drawCurve();
}

function newProject(): void {
  if (!wasm) return;
  pushSnapshot();
  wasm.web_new_project();
  reloadStateFromWasm();
  renderTabs();
  renderOscPanel();
  drawCurve();
  renderEffectList();
  _scheduleRender();
}

function dupVoice(): void {
  if (state.voices.length === 0) return;
  pushSnapshot();
  const src = state.voices[state.activeVoice];
  const dup = JSON.parse(JSON.stringify(src)) as Voice;
  dup.label = src.label + " copy";
  state.voices.push(dup);
  if (wasm) wasm.web_add_voice();
  state.activeVoice = state.voices.length - 1;
  if (wasm) syncWasmVoice(state.activeVoice);
  renderTabs();
  renderOscPanel();
  drawCurve();
}

function removeVoice(): void {
  if (state.voices.length <= 1) return;
  pushSnapshot();
  const i = state.activeVoice;
  if (wasm) wasm.web_remove_voice(i);
  state.voices.splice(i, 1);
  if (state.activeVoice >= state.voices.length)
    state.activeVoice = state.voices.length - 1;
  renderTabs();
  renderOscPanel();
  drawCurve();
}

// osc panel

function renderOscPanel(): void {
  const op = document.getElementById("oscPanel")!;
  const v = state.voices[state.activeVoice];
  if (!v) {
    op.innerHTML = "";
    return;
  }

  const labels = ["main", "freq (FM)", "volu (AM)"];
  let h = "";
  for (let oi = 0; oi < 3; oi++) {
    const o = v.osc[oi];
    const isActive = (which: string) =>
      state.curveOsc === oi && state.curveWhich === which;
    h += `<div class="osc-group"><div class="head"><span>${labels[oi]}</span></div><div class="body">`;
    // group 1 - wave kind, reverse, offset (static/display)
    h += `<div class="param-row"><label class="clickable${isActive("wave") ? " active-curve" : ""}" data-jump-oi="${oi}" data-jump-curve="wave">Wave</label>`;
    h += `<select data-oi="${oi}" data-param="kind">${WAVE_NAMES.map((n, i) => '<option value="' + i + '"' + (i === o.kind ? " selected" : "") + ">" + n + "</option>").join("")}</select></div>`;
    h += `<label class="check-row"><input type="checkbox" data-oi="${oi}" data-param="rev"${o.rev ? " checked" : ""}> Reverse</label>`;
    h += `<div class="param-row"><label>Off</label>`;
    h += `<input type="range" min="0" max="1" step="0.01" value="${o.offset}" data-oi="${oi}" data-param="offset" style="flex:1;height:3px;min-width:40px">`;
    h += `<input type="number" class="val-input" value="${o.offset}" data-oi="${oi}" data-param="offset" min="0" max="1" step="0.01"></div>`;
    // group 2 - modulation with curve labels
    h += `<hr style="border:none;border-top:1px solid var(--line-dark);margin:6px 0">`;
    // freq
    h += `<div class="param-row"><label class="clickable${isActive("freq") ? " active-curve" : ""}" data-jump-oi="${oi}" data-jump-curve="freq">Freq</label>`;
    h += `<input type="range" min="0" max="10000" value="${_freqToSlider(o.freq)}" data-oi="${oi}" data-param="freq">`;
    h += `<input type="number" class="val-input" value="${o.freq}" data-oi="${oi}" data-param="freq" min="0" max="20000"></div>`;
    // vol
    h += `<div class="param-row"><label class="clickable${isActive("vol") ? " active-curve" : ""}" data-jump-oi="${oi}" data-jump-curve="vol">Vol</label>`;
    h += `<input type="range" min="0" max="200" value="${o.vol}" data-oi="${oi}" data-param="vol">`;
    h += `<input type="number" class="val-input" value="${o.vol}" data-oi="${oi}" data-param="vol" min="0" max="200"></div>`;
    // pm
    h += `<div class="param-row"><label class="clickable${isActive("pm") ? " active-curve" : ""}" data-jump-oi="${oi}" data-jump-curve="pm">PM</label>`;
    h += `<input type="range" min="0" max="1" step="0.01" value="${o.pmBlend}" data-oi="${oi}" data-param="pmBlend" style="flex:1;height:3px;min-width:40px">`;
    h += `<input type="number" class="val-input" value="${o.pmBlend}" data-oi="${oi}" data-param="pmBlend" min="0" max="1" step="0.01"></div>`;
    h += `</div></div>`;
  }
  op.innerHTML = h;

  // wire events
  op.querySelectorAll("select[data-param]").forEach((el) =>
    el.addEventListener("change", onOscChange),
  );
  op.querySelectorAll("input[type=range][data-param]").forEach((el) => {
    el.addEventListener("input", onOscChange);
    el.addEventListener("change", onOscChange);
  });
  op.querySelectorAll("input.val-input").forEach((el) =>
    el.addEventListener("change", onOscChange),
  );
  op.querySelectorAll("input[type=checkbox][data-param]").forEach((el) =>
    el.addEventListener("change", onOscChange),
  );
  op.querySelectorAll("[data-jump-oi]").forEach((el) =>
    el.addEventListener("click", () =>
      jumpToCurve(
        parseInt((el as HTMLElement).dataset.jumpOi!),
        (el as HTMLElement).dataset.jumpCurve!,
      ),
    ),
  );
}

function syncCurveRangeInputs(c: { min: number; max: number }): void {
  const cMin = document.getElementById("curveMin") as HTMLInputElement;
  const cMax = document.getElementById("curveMax") as HTMLInputElement;
  if (cMin) cMin.value = String(c.min);
  if (cMax) cMax.value = String(c.max);
}

function jumpToCurve(oi: number, which: string): void {
  state.curveOsc = oi;
  state.curveWhich = which as "freq" | "vol" | "wave" | "pm";
  (document.getElementById("curveOscSelect") as HTMLSelectElement).value =
    oi.toString();
  (document.getElementById("curveSelect") as HTMLSelectElement).value = which;
  const c = getActiveCurve();
  if (c) {
    state.curveInterp = c.interp;
    const bh = document.getElementById("btnHermite")!;
    const bl = document.getElementById("btnLinear")!;
    bh.classList.toggle("active", c.interp === 0);
    bl.classList.toggle("active", c.interp === 1);
    syncCurveRangeInputs(c);
  }
  renderOscPanel();
  drawCurve();
}

const LOG_SLIDER_MAX = 10000;
const LOG_FREQ_MIN = 20;
const LOG_FREQ_MAX = 20000;

function _sliderToFreq(v: number): number {
  return v <= 0
    ? 0
    : LOG_FREQ_MIN * Math.pow(LOG_FREQ_MAX / LOG_FREQ_MIN, v / LOG_SLIDER_MAX);
}
function _freqToSlider(f: number): number {
  return f <= 0
    ? 0
    : (Math.log(f / LOG_FREQ_MIN) / Math.log(LOG_FREQ_MAX / LOG_FREQ_MIN)) *
        LOG_SLIDER_MAX;
}

function onOscChange(e: Event): void {
  if (e.type === "change") pushSnapshot();
  const el = e.target as HTMLElement;
  const oi = parseInt(el.dataset.oi!),
    param = el.dataset.param!;
  const o = state.voices[state.activeVoice].osc[oi];
  if (param === "kind") o.kind = parseInt((el as HTMLSelectElement).value);
  else if (param === "freq") {
    const isSlider = (el as HTMLInputElement).type === "range";
    o.freq = isSlider
      ? _sliderToFreq(parseFloat((el as HTMLInputElement).value) || 0)
      : parseFloat((el as HTMLInputElement).value) || 0;
    el.parentElement!.querySelectorAll("input").forEach((s) => {
      if (s !== el)
        (s as HTMLInputElement).value = isSlider
          ? Math.round(o.freq).toString()
          : _freqToSlider(o.freq).toString();
    });
  } else if (param === "vol") {
    o.vol = parseFloat((el as HTMLInputElement).value) || 0;
    syncSiblingInputs(el, o.vol.toString());
  } else if (param === "rev") o.rev = (el as HTMLInputElement).checked;
  else if (param === "offset") {
    o.offset = parseFloat((el as HTMLInputElement).value) || 0;
    syncSiblingInputs(el, String(o.offset));
  } else if (param === "pmBlend") {
    o.pmBlend = parseFloat((el as HTMLInputElement).value) || 0;
    syncSiblingInputs(el, String(o.pmBlend));
  }
  if (wasm) {
    const name = {
      kind: "kind",
      freq: "freq",
      vol: "volume",
      rev: "reverse",
      offset: "offset",
      pmBlend: "pm_blend",
    }[param]!;
    const val = param === "rev" ? (o.rev ? 1 : 0) : (o as any)[param];
    (wasm as any)["web_set_osc_" + name](state.activeVoice, oi, val);
  }
  drawCurve();
  _scheduleRender();
}

// project save/load

function saveProject(): void {
  if (!wasm) return;
  const statusEl = document.getElementById("status")!;
  statusEl.textContent = "Saving...";
  const ptr = wasm.web_save_project();
  if (!ptr) {
    statusEl.textContent = "Save: no ptr";
    return;
  }
  const len = wasm.web_save_project_len();
  if (!len) {
    statusEl.textContent = "Save: no len";
    return;
  }
  const bytes = new Uint8Array(wasmMemory!.buffer.slice(ptr, ptr + len));
  const blob = new Blob([bytes], { type: "text/plain" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "hljod_project.hljod";
  document.body.appendChild(a);
  a.click();
  document.body.removeChild(a);
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
  statusEl.textContent = "Saved (" + len + " bytes)";
}

function loadProject(): void {
  if (!wasm) return;
  const fi = document.getElementById("fileInput") as HTMLInputElement;
  const file = fi.files?.[0];
  if (!file) return;
  const reader = new FileReader();
  reader.onload = (e) => {
    const text = e.target!.result as string;
    const enc = new TextEncoder();
    const buf = enc.encode(text);
    const OFFSET = 2 * 1024 * 1024;
    const mem = new Uint8Array(wasmMemory!.buffer);
    for (let i = 0; i < buf.length; i++) mem[OFFSET + i] = buf[i];
    const ok = wasm!.web_load_project(OFFSET, buf.length);
    if (ok) {
      reloadStateFromWasm();
      renderTabs();
      renderOscPanel();
      drawCurve();
      _scheduleRender();
      document.getElementById("status")!.textContent = "Project loaded";
    } else {
      document.getElementById("status")!.textContent = "Load failed";
    }
  };
  reader.readAsText(file);
}

function reloadStateFromWasm(): void {
  if (!wasm) return;
  const cnt = wasm.web_voice_count();
  state.voices = [];
  for (let vi = 0; vi < cnt; vi++) {
    const v = createDefaultVoice();
    for (let oi = 0; oi < 3; oi++) {
      const o = v.osc[oi];
      o.kind = wasm.web_get_osc_kind(vi, oi);
      o.freq = wasm.web_get_osc_freq(vi, oi);
      o.vol = wasm.web_get_osc_volume(vi, oi);
      o.rev = wasm.web_get_osc_reverse(vi, oi) === 1;
      o.offset = wasm.web_get_osc_offset(vi, oi);
      o.pmBlend = wasm.web_get_osc_pm_blend(vi, oi);
      for (const which of CURVE_KEYS) {
        const wi = CURVE_INDEX[which];
        const cc = wasm.web_curve_point_count(vi, oi, wi);
        const curve = o.curve[which];
        curve.points = [];
        curve.interp = wasm.web_get_curve_interp(vi, oi, wi);
        curve.min = wasm.web_get_curve_min(vi, oi, wi);
        curve.max = wasm.web_get_curve_max(vi, oi, wi);
        for (let pi = 0; pi < cc; pi++) {
          if (wasm.web_get_curve_point(vi, oi, wi, pi)) {
            curve.points.push({
              x: wasm.web_get_curve_point_x(),
              y: wasm.web_get_curve_point_y(),
              tl: wasm.web_get_curve_point_tl(),
              tr: wasm.web_get_curve_point_tr(),
            });
          }
        }
      }
    }
    v.length = wasm.web_get_voice_length(vi);
    v.start_offset = wasm.web_get_voice_offset(vi);
    // name from wasm (KDL round-trip): read the 64-byte buffer up to NUL
    const np = wasm.web_get_voice_name(vi);
    if (np) {
      const nmem = new Uint8Array(wasmMemory!.buffer);
      let nlen = 0;
      while (nlen < 64 && nmem[np + nlen] !== 0) nlen++;
      const name = new TextDecoder().decode(nmem.slice(np, np + nlen)).trim();
      if (name) v.label = name;
    }
    state.voices.push(v);
  }
  state.activeVoice = 0;
  for (let vi = 0; vi < state.voices.length; vi++) syncWasmVoice(vi);
  pushSnapshot();
}

// init

async function init(): Promise<void> {
  setScheduleRender(_scheduleRender);
  const statusEl = document.getElementById("status")!;
  statusEl.textContent = "loading WASM...";
  try {
    await loadWasm();
    statusEl.textContent = "WASM loaded (" + wasm!.web_sample_rate() + " Hz)";
  } catch (e) {
    statusEl.textContent = "WASM failed - UI-only mode";
    console.warn("WASM load failed:", e);
  }

  // seed initial voice
  state.voices.push(createDefaultVoice());
  if (wasm) {
    wasm.web_add_voice();
    syncWasmVoice(0);
  }
  pushSnapshot();

  // wire toolbar buttons
  const byId = (id: string) => document.getElementById(id)!;
  byId("btnAddVoice").addEventListener("click", addVoice);
  byId("btnDupVoice").addEventListener("click", dupVoice);
  byId("btnRemoveVoice").addEventListener("click", removeVoice);
  byId("inputDuration").addEventListener("change", () => {
    pushSnapshot();
    const d =
      parseFloat((byId("inputDuration") as HTMLInputElement).value) || 0.5;
    const v = state.voices[state.activeVoice];
    if (v) {
      v.length = d;
      if (wasm) wasm.web_set_voice_length(state.activeVoice, d);
    }
    _scheduleRender();
  });
  byId("inputOffset").addEventListener("change", () => {
    pushSnapshot();
    const o = parseFloat((byId("inputOffset") as HTMLInputElement).value) || 0;
    const v = state.voices[state.activeVoice];
    if (v) {
      v.start_offset = o;
      if (wasm) wasm.web_set_voice_offset(state.activeVoice, o);
    }
    _scheduleRender();
  });

  // render + play buttons
  byId("btnRender").addEventListener("click", _doRender);
  byId("btnPlay").addEventListener("click", togglePlay);
  byId("btnDownloadWav").addEventListener("click", downloadWav);

  // project save/load
  byId("btnSaveProject").addEventListener("click", saveProject);
  byId("btnNewProject").addEventListener("click", newProject);
  byId("btnLoadProject").addEventListener("click", () =>
    (byId("fileInput") as HTMLInputElement).click(),
  );
  byId("fileInput").addEventListener("change", loadProject);

  // undo/redo
  byId("btnUndo").addEventListener("click", () => {
    if (undo()) refreshAll();
  });
  byId("btnRedo").addEventListener("click", () => {
    if (redo()) refreshAll();
  });

  // view tabs
  let currentView = "voices";
  document.querySelectorAll(".view-tab").forEach((t) => {
    t.addEventListener("click", () => {
      document
        .querySelectorAll(".view-tab")
        .forEach((x) => x.classList.remove("active"));
      t.classList.add("active");
      currentView = (t as HTMLElement).dataset.view!;
      (byId("voicesPanel") as HTMLElement).style.display =
        currentView === "voices" ? "" : "none";
      (byId("effectsPanel") as HTMLElement).style.display =
        currentView === "effects" ? "" : "none";
      if (currentView === "effects") renderEffectList();
    });
  });

  // effects bypass
  const eB = byId("effectsBypass") as HTMLInputElement;
  eB.addEventListener("change", () => {
    byId("bypassWrap").classList.toggle("off", !eB.checked);
    if (wasm) wasm.web_set_effects_bypass(eB.checked ? 0 : 1);
  });

  // add effect
  byId("btnAddEffect").addEventListener("click", () => {
    if (!wasm) return;
    pushSnapshot();
    const k = parseInt((byId("effectTypeSelect") as HTMLSelectElement).value);
    const defaults: Record<number, number[]> = {
      1: [0.3, 0.4, 0.5, 0.5, 0],
      2: [1.5, 0.5, 0.7, 0, 0],
      3: [0.5, 0.5, 0.7, 0.7, 0.3],
      4: [2.5, 0.3, 1.0, 0, 0],
      5: [0.5, 0.5, 0, 0, 0],
    };
    const d = defaults[k] || [0.5, 0.5, 0.7, 0, 0];
    wasm.web_add_effect(k, d[0], d[1], d[2], d[3], d[4]);
    renderEffectList();
    _scheduleRender();
  });
  byId("btnClearEffects").addEventListener("click", () => {
    if (!wasm) return;
    pushSnapshot();
    wasm.web_clear_effects();
    renderEffectList();
    _scheduleRender();
  });

  // curve toolbar
  const cS = byId("curveSelect") as HTMLSelectElement;
  const cO = byId("curveOscSelect") as HTMLSelectElement;
  cS.addEventListener("change", () => {
    state.curveWhich = cS.value as "freq" | "vol" | "wave" | "pm";
    const c = getActiveCurve();
    if (c) syncCurveRangeInputs(c);
    renderOscPanel();
    drawCurve();
  });
  cO.addEventListener("change", () => {
    state.curveOsc = parseInt(cO.value);
    const c = getActiveCurve();
    if (c) {
      state.curveInterp = c.interp;
      byId("btnHermite").classList.toggle("active", c.interp === 0);
      byId("btnLinear").classList.toggle("active", c.interp === 1);
      syncCurveRangeInputs(c);
    }
    renderOscPanel();
    drawCurve();
  });
  const cMin = byId("curveMin") as HTMLInputElement;
  const cMax = byId("curveMax") as HTMLInputElement;
  cMin.addEventListener("change", () => {
    pushSnapshot();
    const c = getActiveCurve();
    if (c) {
      c.min = parseFloat(cMin.value) || -1;
      syncWasmVoice(state.activeVoice);
      drawCurve();
    }
  });
  cMax.addEventListener("change", () => {
    pushSnapshot();
    const c = getActiveCurve();
    if (c) {
      c.max = parseFloat(cMax.value) || 1;
      syncWasmVoice(state.activeVoice);
      drawCurve();
    }
  });
  byId("btnHermite").addEventListener("click", () => {
    pushSnapshot();
    state.curveInterp = 0;
    byId("btnHermite").classList.add("active");
    byId("btnLinear").classList.remove("active");
    const c = getActiveCurve();
    if (c) {
      c.interp = 0;
      syncWasmVoice(state.activeVoice);
    }
    drawCurve();
  });
  byId("btnLinear").addEventListener("click", () => {
    pushSnapshot();
    state.curveInterp = 1;
    byId("btnLinear").classList.add("active");
    byId("btnHermite").classList.remove("active");
    const c = getActiveCurve();
    if (c) {
      c.interp = 1;
      syncWasmVoice(state.activeVoice);
    }
    drawCurve();
  });

  // init curve editor canvas events
  initCurveEditor();

  // window resize
  window.addEventListener("resize", () => {
    drawCurve();
    if (renderedSamples) drawWaveform(renderedSamples);
  });

  // initial render
  renderTabs();
  renderOscPanel();
  drawCurve();

  // delegation: voice tab click/dblclick (survives re-renders)
  const tc = byId("tabContainer");
  tc.addEventListener("click", (e) => {
    const btn = (e.target as HTMLElement).closest(".voice-tab") as HTMLElement;
    if (btn) selectVoice(parseInt(btn.dataset.idx!));
  });
  tc.addEventListener("dblclick", (e) => {
    const btn = (e.target as HTMLElement).closest(".voice-tab") as HTMLElement;
    if (btn) startRename(parseInt(btn.dataset.idx!));
  });

  // undo/redo keyboard shortcuts
  document.addEventListener("keydown", (e) => {
    if (e.ctrlKey && e.key === "z" && !e.shiftKey) {
      e.preventDefault();
      if (undo()) refreshAll();
    }
    if (e.ctrlKey && (e.key === "y" || (e.key === "z" && e.shiftKey))) {
      e.preventDefault();
      if (redo()) refreshAll();
    }
  });
}

init();

import { wasm } from "../wasm-bridge.js";
import { scheduleRender, syncSiblingInputs } from "../events.js";

const EFFECT_NAMES = [
  "None",
  "Delay",
  "Overdrive",
  "Reverb",
  "Distortion",
  "LowPass",
  "Chorus",
  "Bitcrusher",
  "PitchShift",
];
const EFFECT_PARAMS: { n: string; min: number; max: number; step: number }[][] =
  [
    [],
    [
      { n: "Time", min: 0, max: 2, step: 0.01 },
      { n: "Fb", min: 0, max: 1, step: 0.01 },
      { n: "Wet", min: 0, max: 1, step: 0.01 },
      { n: "LP", min: 0, max: 1, step: 0.01 },
    ],
    [
      { n: "Drive", min: 0, max: 10, step: 0.1 },
      { n: "Tone", min: 0, max: 1, step: 0.01 },
      { n: "Mix", min: 0, max: 1, step: 0.01 },
    ],
    [
      { n: "Room", min: 0, max: 1, step: 0.01 },
      { n: "Damp", min: 0, max: 1, step: 0.01 },
      { n: "Wet", min: 0, max: 1, step: 0.01 },
      { n: "Width", min: 0, max: 1, step: 0.01 },
      { n: "Dry", min: 0, max: 1, step: 0.01 },
    ],
    [
      { n: "Drive", min: 0, max: 10, step: 0.1 },
      { n: "Tone", min: 0, max: 1, step: 0.01 },
      { n: "Mix", min: 0, max: 1, step: 0.01 },
    ],
    [
      { n: "Cut", min: 0, max: 1, step: 0.01 },
      { n: "Q", min: 0, max: 1, step: 0.01 },
    ],
    [
      { n: "Time", min: 1, max: 50, step: 1 },
      { n: "Depth", min: 0, max: 1, step: 0.01 },
      { n: "Rate", min: 0.1, max: 5, step: 0.1 },
      { n: "Fb", min: 0, max: 1, step: 0.01 },
      { n: "Mix", min: 0, max: 1, step: 0.01 },
    ],
    [
      { n: "Bits", min: 1, max: 16, step: 1 },
      { n: "Down", min: 0.01, max: 1, step: 0.01 },
      { n: "Mix", min: 0, max: 1, step: 0.01 },
    ],
    [
      { n: "Shift", min: 0.5, max: 2, step: 0.01 },
      { n: "Mix", min: 0, max: 1, step: 0.01 },
    ],
  ];

// a little messy, but it'll do
export function renderEffectList(): void {
  const c = document.getElementById("effectList")!;
  if (!wasm) {
    c.innerHTML =
      '<div style="color:var(--text-dim);font-size:11px">WASM not loaded</div>';
    return;
  }
  const n = wasm.web_effect_count();
  if (n === 0) {
    c.innerHTML =
      '<div style="color:var(--text-dim);font-size:11px;padding:12px 0">No effects.</div>';
    return;
  }

  let h = "";
  for (let i = 0; i < n; i++) {
    const k = wasm.web_get_effect_kind(i);
    const en = wasm.web_get_effect_enabled(i);
    const na = EFFECT_NAMES[k] || "Unknown";
    const pa = EFFECT_PARAMS[k] || [];
    h += `<div class="effect-card"><div class="head">`;
    h += `<button data-eidx="${i}" data-action="toggle" style="background:var(--surface);color:${en ? "var(--text)" : "var(--text-dim)"};padding:2px 8px;font-size:10px;min-height:20px">${en ? "ON" : "OFF"}</button>`;
    h += `<span style="font-size:12px;font-weight:500;color:#fff;text-transform:none">${na}</span>`;
    h += `<span style="flex:1"></span>`;
    h += `<button data-eidx="${i}" data-action="moveup" style="background:transparent;border:none;color:#fff;cursor:pointer;font-size:13px;padding:0 2px;box-shadow:none;min-height:auto">&#9650;</button>`;
    h += `<button data-eidx="${i}" data-action="movedown" style="background:transparent;border:none;color:#fff;cursor:pointer;font-size:13px;padding:0 2px;box-shadow:none;min-height:auto">&#9660;</button>`;
    h += `<button data-eidx="${i}" data-action="remove" style="background:transparent;border:none;color:#fff;cursor:pointer;font-size:13px;padding:0 2px;box-shadow:none;min-height:auto">&times;</button>`;
    h += `</div><div class="body">`;
    for (let pi = 0; pi < pa.length; pi++) {
      const p = pa[pi];
      const v = wasm.web_get_effect_param(i, pi);
      h += `<div class="param-row">`;
      h += `<span class="plabel">${p.n}</span>`;
      h += `<input type="range" min="${p.min}" max="${p.max}" step="${p.step}" value="${v}" data-eidx="${i}" data-pidx="${pi}" style="flex:1;height:3px;min-width:40px">`;
      h += `<input type="number" value="${v}" data-eidx="${i}" data-pidx="${pi}" style="width:42px;background:#fff;color:#000;border:2px solid;border-color:var(--line-dark) var(--surface-light) var(--surface-light) var(--line-dark);padding:1px 3px;font-size:10px;font-family:Tahoma,sans-serif;text-align:right;height:18px">`;
      h += `</div>`;
    }
    h += `</div></div>`;
  }
  c.innerHTML = h;

  // hook up events
  c.querySelectorAll('[data-action="toggle"]').forEach((b) =>
    b.addEventListener("click", () => {
      if (!wasm) return;
      wasm.web_toggle_effect(parseInt((b as HTMLElement).dataset.eidx!));
      renderEffectList();
      scheduleRender();
    }),
  );
  c.querySelectorAll('[data-action="remove"]').forEach((b) =>
    b.addEventListener("click", () => {
      if (!wasm) return;
      wasm.web_remove_effect(parseInt((b as HTMLElement).dataset.eidx!));
      renderEffectList();
      scheduleRender();
    }),
  );
  c.querySelectorAll('[data-action="moveup"]').forEach((b) =>
    b.addEventListener("click", () => {
      if (!wasm) return;
      wasm.web_move_effect(parseInt((b as HTMLElement).dataset.eidx!), -1);
      renderEffectList();
      scheduleRender();
    }),
  );
  c.querySelectorAll('[data-action="movedown"]').forEach((b) =>
    b.addEventListener("click", () => {
      if (!wasm) return;
      wasm.web_move_effect(parseInt((b as HTMLElement).dataset.eidx!), 1);
      renderEffectList();
      scheduleRender();
    }),
  );
  const onParamChange = (e: Event) => {
    if (!wasm) return;
    const el = e.target as HTMLElement;
    const ei = parseInt(el.dataset.eidx!),
      pi = parseInt(el.dataset.pidx!);
    const v = parseFloat((el as HTMLInputElement).value) || 0;
    wasm.web_set_effect_param(ei, pi, v);
    syncSiblingInputs(el, String(v));
    scheduleRender();
  };
  c.querySelectorAll("input[type=range][data-eidx]").forEach((el) =>
    el.addEventListener("input", onParamChange),
  );
  c.querySelectorAll("input[type=number][data-eidx]").forEach((el) =>
    el.addEventListener("change", onParamChange),
  );
}

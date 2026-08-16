// curve point with hermite tangent handles
export interface CurvePoint {
  x: number;
  y: number;
  tl: number;
  tr: number;
}

export interface Curve {
  points: CurvePoint[];
  interp: number; // 0=hermite, 1=linear
  min: number;
  max: number;
}

export interface OscParams {
  kind: number;
  freq: number;
  vol: number;
  rev: boolean;
  offset: number;
  pmBlend: number;
  label?: string;
  curve: { freq: Curve; vol: Curve; wave: Curve; pm: Curve };
}

export interface Voice {
  label: string;
  osc: [OscParams, OscParams, OscParams];
  length: number;
  start_offset: number;
}

export interface AppState {
  voices: Voice[];
  activeVoice: number;
  curveOsc: number;
  curveWhich: CurveKey;
  curveInterp: number;
}

export const WAVE_NAMES = [
  "None",
  "Sine",
  "Saw",
  "Rect",
  "Random",
  "Saw2",
  "Rect2",
  "Tri",
  "Random2",
  "Rect3",
  "Rect4",
  "Rect8",
  "Rect12",
  "Rect16",
  "Saw3",
  "Saw4",
  "Saw6",
  "Saw8",
  "Curve",
];

// iteration order matches CURVE_INDEX / core dsp.CurveKind (vol=0, freq=1, wave=2, pm=3)
export const CURVE_KEYS = ["vol", "freq", "wave", "pm"] as const;
export type CurveKey = (typeof CURVE_KEYS)[number];
// curve slot order matches core dsp.CurveKind (vol=0, freq=1, wave=2, pm=3)
export const CURVE_INDEX: Record<CurveKey, number> = {
  vol: 0,
  freq: 1,
  wave: 2,
  pm: 3,
};

function makeCurve(): Curve {
  return {
    points: [
      { x: 0, y: 1, tl: 0, tr: 0 },
      { x: 1, y: 1, tl: 0, tr: 0 },
    ],
    interp: 0,
    min: 0,
    max: 2,
  };
}

function makeOsc(label: string): OscParams {
  return {
    label: label as any,
    kind: 1,
    freq: 440,
    vol: 80,
    rev: false,
    offset: 0,
    pmBlend: 0,
    curve: {
      freq: makeCurve(),
      vol: makeCurve(),
      wave: makeCurve(),
      pm: makeCurve(),
    },
  };
}

export function createDefaultVoice(): Voice {
  return {
    label: "Voice",
    osc: [makeOsc("main"), makeOsc("freq"), makeOsc("volu")],
    length: 0.5,
    start_offset: 0,
  };
}

export const state: AppState = {
  voices: [],
  activeVoice: 0,
  curveOsc: 0,
  curveWhich: "vol",
  curveInterp: 0,
};

// undo / redo

const MAX_UNDO = 64;
const history: AppState[] = [];
let historyPos = -1; // index in history[] that matches current state
let historyLen = 0; // number of populated entries

function clone(): AppState {
  return JSON.parse(JSON.stringify(state));
}

export function pushSnapshot(): void {
  // truncate any redo branch past current position
  if (historyPos + 1 < historyLen) {
    history.length = historyPos + 1;
  }
  // trim oldest when full
  if (historyLen >= MAX_UNDO) {
    history.shift();
    historyPos--;
    historyLen--;
  }
  history.push(clone());
  historyPos++;
  historyLen++;
}

function _restore(pos: number): boolean {
  if (pos < 0 || pos >= historyLen) return false;
  const snap = JSON.parse(JSON.stringify(history[pos])) as AppState;
  for (const k of Object.keys(snap) as (keyof AppState)[]) {
    (state as any)[k] = snap[k];
  }
  historyPos = pos;
  return true;
}

export function undo(): boolean {
  return _restore(historyPos - 1);
}

export function redo(): boolean {
  return _restore(historyPos + 1);
}

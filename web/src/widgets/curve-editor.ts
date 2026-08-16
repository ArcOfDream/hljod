import {
  state,
  pushSnapshot,
  CURVE_INDEX,
  type Curve,
  type CurvePoint,
} from "../state.js";
import { wasm, pushCurveToWasm } from "../wasm-bridge.js";
import { scheduleRender } from "../events.js";

// CRT green color palette
const GRN = {
  bg: "#000000",
  grid: "#004400",
  trace: "#00ff00",
  dim: "#002200",
  label: "#007700",
  point: "#00ff00",
  pointEnd: "#33aa33",
  pointDrag: "#ffff00",
  handle: "rgba(0,255,0,0.25)",
  handleDot: "rgba(0,255,0,0.4)",
};

let curveDragIdx = -1;
let curveDragPart: "point" | "tl" | "tr" = "point";
let curveDragOffX = 0;
let curveDragOffY = 0;

// yR must be passed in since the callbacks capture it dynamically

export function getActiveCurve(): Curve | null {
  const v = state.voices[state.activeVoice];
  if (!v) return null;
  return v.osc[state.curveOsc].curve[state.curveWhich];
}

function canvasMousePos(
  canvas: HTMLCanvasElement,
  e: MouseEvent,
): { x: number; y: number } {
  const r = canvas.getBoundingClientRect();
  return { x: e.clientX - r.left, y: e.clientY - r.top };
}

export function drawCurve(): void {
  const canvas = document.getElementById("curveCanvas") as HTMLCanvasElement;
  const wrap = document.getElementById("curveCanvasWrap") as HTMLElement;
  if (!canvas || !wrap) return;

  const rect = wrap.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  canvas.width = rect.width * dpr;
  canvas.height = rect.height * dpr;
  canvas.style.width = rect.width + "px";
  canvas.style.height = rect.height + "px";

  const ctx = canvas.getContext("2d")!;
  ctx.scale(dpr, dpr);
  const W = rect.width,
    H = rect.height;
  const pad = 24,
    drawW = W - pad * 2,
    drawH = H - pad * 2;

  ctx.fillStyle = GRN.bg;
  ctx.fillRect(0, 0, W, H);

  const c = getActiveCurve();
  if (!c || c.points.length < 2) return;
  const yMin = c.min,
    yMax = c.max,
    yR = yMax - yMin || 1;
  const toY = (y: number) => pad + drawH - ((y - yMin) / yR) * drawH;

  // grid lines
  ctx.strokeStyle = GRN.grid;
  ctx.lineWidth = 1;
  for (let i = 0; i <= 10; i++) {
    const x = pad + (i / 10) * drawW;
    ctx.beginPath();
    ctx.moveTo(x, pad);
    ctx.lineTo(x, pad + drawH);
    ctx.stroke();
  }
  for (let i = 0; i <= 8; i++) {
    const y = toY(yMin + (i / 8) * yR);
    ctx.beginPath();
    ctx.moveTo(pad, y);
    ctx.lineTo(pad + drawW, y);
    ctx.stroke();
  }

  // labels
  ctx.fillStyle = GRN.label;
  ctx.font = '9px "Fixedsys Excelsior",monospace';
  ctx.textAlign = "center";
  ctx.fillText("0", pad, pad + drawH + 12);
  ctx.fillText("1", pad + drawW, pad + drawH + 12);
  ctx.textAlign = "right";
  ctx.fillText(yMax.toFixed(1), pad - 4, toY(yMax) + 3);
  ctx.fillText(yMin.toFixed(1), pad - 4, toY(yMin) + 3);

  // zero line
  if (yMin < 0 && yMax > 0) {
    ctx.strokeStyle = GRN.dim;
    ctx.beginPath();
    ctx.moveTo(pad, toY(0));
    ctx.lineTo(pad + drawW, toY(0));
    ctx.stroke();
    ctx.textAlign = "left";
    ctx.fillText("0", pad + drawW + 4, toY(0) + 3);
  }

  // project points to pixel space
  const pts = c.points.map((p) => ({
    x: pad + p.x * drawW,
    y: toY(p.y),
    tl: p.tl,
    tr: p.tr,
    orig: p,
  }));

  // curve path
  ctx.strokeStyle = GRN.trace;
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  ctx.moveTo(pts[0].x, pts[0].y);
  if (c.interp === 1) {
    for (let i = 1; i < pts.length; i++) ctx.lineTo(pts[i].x, pts[i].y);
  } else {
    for (let i = 0; i < pts.length - 1; i++) {
      const p0 = c.points[i],
        p1 = c.points[i + 1];
      const span = p1.x - p0.x;
      if (span < 1e-9) {
        ctx.lineTo(pts[i + 1].x, pts[i + 1].y);
        continue;
      }
      ctx.bezierCurveTo(
        pts[i].x + (drawW * span) / 3,
        pts[i].y - (((p0.tr * drawH) / yR) * span) / 3,
        pts[i + 1].x - (drawW * span) / 3,
        pts[i + 1].y + (((p1.tl * drawH) / yR) * span) / 3,
        pts[i + 1].x,
        pts[i + 1].y,
      );
    }
  }
  ctx.stroke();

  // tangent handles
  ctx.strokeStyle = GRN.handle;
  ctx.lineWidth = 1;
  for (let i = 0; i < pts.length; i++) {
    const p = pts[i];
    if (i < pts.length - 1) {
      const sp = c.points[i + 1].x - c.points[i].x;
      if (sp > 1e-9) {
        ctx.beginPath();
        ctx.moveTo(p.x, p.y);
        ctx.lineTo(
          p.x + (drawW * sp) / 3,
          p.y - (p.orig.tr * drawH * sp) / yR / 3,
        );
        ctx.stroke();
      }
    }
    if (i > 0) {
      const sp = c.points[i].x - c.points[i - 1].x;
      if (sp > 1e-9) {
        ctx.beginPath();
        ctx.moveTo(p.x, p.y);
        ctx.lineTo(
          p.x - (drawW * sp) / 3,
          p.y + (p.orig.tl * drawH * sp) / yR / 3,
        );
        ctx.stroke();
      }
    }
  }

  // tangent dots
  ctx.fillStyle = GRN.handleDot;
  for (let i = 0; i < pts.length; i++) {
    const p = pts[i];
    if (i < pts.length - 1) {
      const sp = c.points[i + 1].x - c.points[i].x;
      if (sp > 1e-9) {
        const tx = p.x + (drawW * sp) / 3,
          ty = p.y - (p.orig.tr * drawH * sp) / yR / 3;
        ctx.beginPath();
        ctx.arc(tx, ty, 3, 0, Math.PI * 2);
        ctx.fill();
      }
    }
    if (i > 0) {
      const sp = c.points[i].x - c.points[i - 1].x;
      if (sp > 1e-9) {
        const tx = p.x - (drawW * sp) / 3,
          ty = p.y + (p.orig.tl * drawH * sp) / yR / 3;
        ctx.beginPath();
        ctx.arc(tx, ty, 3, 0, Math.PI * 2);
        ctx.fill();
      }
    }
  }

  // point dots
  for (let i = 0; i < pts.length; i++) {
    const fl = i === 0 || i === pts.length - 1;
    ctx.fillStyle = fl
      ? GRN.pointEnd
      : i === curveDragIdx
        ? GRN.pointDrag
        : GRN.point;
    ctx.beginPath();
    ctx.arc(pts[i].x, pts[i].y, fl ? 4 : 5, 0, Math.PI * 2);
    ctx.fill();
    if (!fl) {
      ctx.strokeStyle = GRN.point;
      ctx.lineWidth = 1;
      ctx.stroke();
    }
  }
}

function syncCurveToWasm(): void {
  if (!wasm) return;
  const c = getActiveCurve();
  if (!c) return;
  pushCurveToWasm(
    state.activeVoice,
    state.curveOsc,
    CURVE_INDEX[state.curveWhich],
    c,
  );
  scheduleRender();
}

export function initCurveEditor(): void {
  const canvas = document.getElementById("curveCanvas") as HTMLCanvasElement;
  if (!canvas) return;

  canvas.addEventListener("mousedown", (e) => {
    const c = getActiveCurve();
    if (!c) return;
    const pos = canvasMousePos(canvas, e);
    const wrap = document.getElementById("curveCanvasWrap") as HTMLElement;
    const rect = wrap.getBoundingClientRect();
    const W = rect.width,
      H = rect.height,
      pad = 24,
      dW = W - pad * 2,
      dH = H - pad * 2;
    const yR = c.max - c.min || 1;

    // tangent handle hit test
    for (let i = 0; i < c.points.length; i++) {
      const p = c.points[i],
        px = pad + p.x * dW,
        py = pad + dH - ((p.y - c.min) / yR) * dH;
      if (i < c.points.length - 1) {
        const sp = c.points[i + 1].x - c.points[i].x;
        if (sp > 1e-9) {
          const tx = px + (dW * sp) / 3,
            ty = py - (p.tr * dH * sp) / yR / 3;
          if (Math.hypot(pos.x - tx, pos.y - ty) < 10) {
            curveDragIdx = i;
            curveDragPart = "tr";
            curveDragOffX = pos.x - tx;
            curveDragOffY = pos.y - ty;
            return;
          }
        }
      }
      if (i > 0) {
        const sp = c.points[i].x - c.points[i - 1].x;
        if (sp > 1e-9) {
          const tx = px - (dW * sp) / 3,
            ty = py + (p.tl * dH * sp) / yR / 3;
          if (Math.hypot(pos.x - tx, pos.y - ty) < 10) {
            curveDragIdx = i;
            curveDragPart = "tl";
            curveDragOffX = pos.x - tx;
            curveDragOffY = pos.y - ty;
            return;
          }
        }
      }
    }

    // point hit test
    for (let i = 0; i < c.points.length; i++) {
      const p = c.points[i],
        px = pad + p.x * dW,
        py = pad + dH - ((p.y - c.min) / yR) * dH;
      if (Math.hypot(pos.x - px, pos.y - py) < 10) {
        curveDragIdx = i;
        curveDragPart = "point";
        curveDragOffX = pos.x - px;
        curveDragOffY = pos.y - py;
        return;
      }
    }

    // shift-click to add point
    if (e.shiftKey) {
      pushSnapshot();
      let nx = Math.max(0.001, Math.min(0.999, (pos.x - pad) / dW));
      const nv = c.min + ((pad + dH - pos.y) / dH) * yR;
      const cy = Math.max(c.min, Math.min(c.max, nv));
      let prev: CurvePoint | null = null,
        next: CurvePoint | null = null;
      for (const pt of c.points) {
        if (pt.x < nx) prev = pt;
        if (pt.x > nx && !next) next = pt;
      }
      let tl = 0,
        tr = 0;
      if (prev && next && next.x - prev.x > 1e-9) {
        const s = (next.y - prev.y) / (next.x - prev.x);
        tl = s;
        tr = s;
      } else if (prev) {
        tl = (cy - prev.y) / (nx - prev.x);
        tr = tl;
      } else if (next) {
        tr = (next.y - cy) / (next.x - nx);
        tl = tr;
      }
      c.points.push({ x: nx, y: cy, tl, tr });
      c.points.sort((a, b) => a.x - b.x);
      syncCurveToWasm();
      drawCurve();
    }
  });

  canvas.addEventListener("mousemove", (e) => {
    if (curveDragIdx < 0) return;
    const c = getActiveCurve();
    if (!c) return;
    const pos = canvasMousePos(canvas, e);
    const wrap = document.getElementById("curveCanvasWrap") as HTMLElement;
    const rect = wrap.getBoundingClientRect();
    const W = rect.width,
      H = rect.height,
      pad = 24,
      dW = W - pad * 2,
      dH = H - pad * 2;
    const yR = c.max - c.min || 1;
    const p = c.points[curveDragIdx];
    const fl = curveDragIdx === 0 || curveDragIdx === c.points.length - 1;

    if (curveDragPart === "point") {
      let nx = (pos.x - curveDragOffX - pad) / dW;
      let ny = c.min + ((pad + dH - (pos.y - curveDragOffY)) / dH) * yR;
      if (fl) nx = p.x;
      else {
        if (curveDragIdx > 0)
          nx = Math.max(nx, c.points[curveDragIdx - 1].x + 0.001);
        if (curveDragIdx < c.points.length - 1)
          nx = Math.min(nx, c.points[curveDragIdx + 1].x - 0.001);
      }
      nx = Math.max(0, Math.min(1, nx));
      ny = Math.max(c.min, Math.min(c.max, ny));
      p.x = nx;
      p.y = ny;
      if (wasm) {
        const wi = CURVE_INDEX[state.curveWhich];
        wasm.web_set_curve_point_pos(
          state.activeVoice,
          state.curveOsc,
          wi,
          curveDragIdx,
          p.x,
          p.y,
        );
      }
    } else {
      const px = pad + p.x * dW,
        py = pad + dH - ((p.y - c.min) / yR) * dH;
      const hx = pos.x - curveDragOffX,
        hy = pos.y - curveDragOffY;
      let sp = 0;
      if (curveDragPart === "tl" && curveDragIdx > 0)
        sp = c.points[curveDragIdx].x - c.points[curveDragIdx - 1].x;
      else if (curveDragPart === "tr" && curveDragIdx < c.points.length - 1)
        sp = c.points[curveDragIdx + 1].x - c.points[curveDragIdx].x;
      const tan = sp > 1e-9 ? ((py - hy) * 3 * yR) / (dH * sp) : 0;
      if (curveDragPart === "tl") p.tl = -tan;
      else p.tr = tan;
      if (wasm) {
        const wi = CURVE_INDEX[state.curveWhich];
        wasm.web_set_curve_point_tangents(
          state.activeVoice,
          state.curveOsc,
          wi,
          curveDragIdx,
          p.tl,
          p.tr,
        );
      }
    }
    drawCurve();
  });

  canvas.addEventListener("mouseup", () => {
    if (curveDragIdx >= 0) {
      syncCurveToWasm();
      pushSnapshot();
    }
    curveDragIdx = -1;
    curveDragPart = "point";
  });

  canvas.addEventListener("mouseleave", () => {
    if (curveDragIdx >= 0) {
      syncCurveToWasm();
      pushSnapshot();
    }
    curveDragIdx = -1;
    curveDragPart = "point";
  });

  // right-click to delete point
  canvas.addEventListener("contextmenu", (e) => {
    e.preventDefault();
    const c = getActiveCurve();
    if (!c || c.points.length <= 2) return;
    const pos = canvasMousePos(canvas, e);
    const wrap = document.getElementById("curveCanvasWrap") as HTMLElement;
    const rect = wrap.getBoundingClientRect();
    const W = rect.width,
      H = rect.height,
      pad = 24,
      dW = W - pad * 2,
      dH = H - pad * 2;
    const yR = c.max - c.min || 1;
    for (let i = 1; i < c.points.length - 1; i++) {
      const p = c.points[i];
      const px = pad + p.x * dW,
        py = pad + dH - ((p.y - c.min) / yR) * dH;
      if (Math.hypot(pos.x - px, pos.y - py) < 12) {
        pushSnapshot();
        c.points.splice(i, 1);
        if (wasm) {
          const wi = CURVE_INDEX[state.curveWhich];
          wasm.web_remove_curve_point(state.activeVoice, state.curveOsc, wi, i);
        }
        drawCurve();
        scheduleRender();
        break;
      }
    }
  });
}

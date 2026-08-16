export function drawWaveform(samples: Float32Array | null): void {
  const canvas = document.getElementById("waveformCanvas") as HTMLCanvasElement;
  const wrap = document.getElementById("waveformWrap") as HTMLElement;
  if (!canvas || !wrap) return;

  const r = wrap.getBoundingClientRect();
  const dpr = window.devicePixelRatio || 1;
  canvas.width = r.width * dpr;
  canvas.height = r.height * dpr;
  canvas.style.width = r.width + "px";
  canvas.style.height = r.height + "px";

  const ctx = canvas.getContext("2d")!;
  ctx.scale(dpr, dpr);
  const W = r.width,
    H = r.height,
    mid = H / 2;

  // bg
  ctx.fillStyle = "#000000";
  ctx.fillRect(0, 0, W, H);

  if (!samples || samples.length === 0) {
    ctx.fillStyle = "#007700";
    ctx.font = '12px "Fixedsys Excelsior",monospace';
    ctx.textAlign = "center";
    ctx.fillText("no data", W / 2, H / 2 + 4);
    return;
  }

  // green trace
  ctx.strokeStyle = "#00ff00";
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  for (let x = 0; x < W; x++) {
    const i = Math.min(
      Math.floor((x * samples.length) / W),
      samples.length - 1,
    );
    const samp = Math.max(-1, Math.min(1, samples[i]));
    const y = mid - samp * H * 0.4;
    x === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
  }
  ctx.stroke();

  // center line
  ctx.strokeStyle = "#002200";
  ctx.beginPath();
  ctx.moveTo(0, mid);
  ctx.lineTo(W, mid);
  ctx.stroke();
}

let audioCtx: AudioContext | null = null;
export let isPlaying = false;
export let renderedSamples: Float32Array | null = null;
export let renderedSampleRate = 44100;

export function setRenderedSamples(s: Float32Array): void {
  renderedSamples = s;
}
export function setRenderedSampleRate(sr: number): void {
  renderedSampleRate = sr;
}

function getAudioCtx(): AudioContext {
  if (!audioCtx) audioCtx = new AudioContext();
  return audioCtx;
}

// play buffered samples through web audio
export function playSamples(samples: Float32Array, sr: number): Promise<void> {
  const ctx = getAudioCtx();
  if (ctx.state === "suspended") ctx.resume();
  const buf = ctx.createBuffer(1, samples.length, sr);
  // copy samples into the audio buffer (plain array copy avoids type issues)
  const ch = buf.getChannelData(0);
  for (let i = 0; i < samples.length; i++) ch[i] = samples[i];
  const src = ctx.createBufferSource();
  src.buffer = buf;
  src.connect(ctx.destination);
  src.start(0);
  isPlaying = true;
  return new Promise((resolve) => {
    src.onended = () => {
      isPlaying = false;
      resolve();
    };
  });
}

export function stopPlayback(): void {
  if (audioCtx) audioCtx.close();
  audioCtx = null;
  isPlaying = false;
}

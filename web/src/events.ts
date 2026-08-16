// shared callback - set by main.ts during init
// widgets call this to trigger a re-render after state changes
let _fn: (() => void) | null = null;

export function setScheduleRender(fn: () => void): void {
  _fn = fn;
}

export function scheduleRender(): void {
  _fn?.();
}

// keep a slider/number-input pair in sync (both edit the same value)
export function syncSiblingInputs(el: HTMLElement, value: string): void {
  el.parentElement!.querySelectorAll("input").forEach((s) => {
    if (s !== el) (s as HTMLInputElement).value = value;
  });
}

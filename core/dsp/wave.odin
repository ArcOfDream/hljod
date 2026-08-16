package dsp

// wavekind enum, OscParams, and waveform-sampling helpers
// waveforms follow ptCollage's model:
//   Saw2   = additive 16-harmonic sawtooth
//   Rect2  = additive 8-odd-harmonic square-like wave
//   RectN  = duty-cycle rectangular (N segments)
//   SawN   = stepped saw approximation (N segments)

import "core:math"

WaveKind :: enum i32 {
	None = 0,
	Sine,
	Saw,
	Rect,
	Random,
	Saw2,
	Rect2,
	Tri,
	Random2,
	Rect3,
	Rect4,
	Rect8,
	Rect12,
	Rect16,
	Saw3,
	Saw4,
	Saw6,
	Saw8,
	Curve, // custom waveform defined by wave_curve
}

NUM_OSCS :: 3 // main / freq / volu
NUM_CURVES :: 4 // vol / freq / wave / pm

OscParams :: struct {
	kind:       WaveKind,
	freq:       f32,
	volume:     f32,
	offset:     f32,
	reverse:    bool,
	pm_blend:   f32, // 0 = pure fm, 1 = pure pm (phase modulation)
	freq_curve: Curve, // freq multiplier over time  (x=0..1 = duration)
	vol_curve:  Curve, // vol multiplier over time  (x=0..1 = duration)
	wave_curve: Curve, // custom waveform shape     (x=0..1 = phase)
	pm_curve:   Curve, // pm depth multiplier over time (x=0..1 = duration)
}

sample_for_kind :: proc(kind: WaveKind, phase: f32, sample_index: i32) -> f32 {
	#partial switch kind {
	case .Sine:
		return math.sin_f32(phase * 2.0 * math.PI)
	case .Saw:
		return 2.0 * phase - 1.0
	case .Rect:
		return rect01(phase)
	case .Saw2:
		return saw_add(phase, 16)
	case .Rect2:
		return rect_add(phase, 8)
	case .Tri:
		return 4.0 * abs(phase - 0.5) - 1.0
	case .Rect3:
		return rectN(phase, 3.0)
	case .Rect4:
		return rectN(phase, 4.0)
	case .Rect8:
		return rectN(phase, 8.0)
	case .Rect12:
		return rectN(phase, 12.0)
	case .Rect16:
		return rectN(phase, 16.0)
	case .Saw3:
		return sawN(phase, 3.0)
	case .Saw4:
		return sawN(phase, 4.0)
	case .Saw6:
		return sawN(phase, 6.0)
	case .Saw8:
		return sawN(phase, 8.0)
	case .Curve:
		return 0.0 // handled by caller; kept here so switch is exhaustive
	}
	return 0.0
}

rect01 :: proc(phase: f32) -> f32 {
	if phase < 0.5 {return 1.0}
	return -1.0
}

rect_add :: proc(phase: f32, odd_count: i32) -> f32 {
	// square-like additive: first `odd_count` odd harmonics, 1/k rolloff
	y: f32 = 0.0
	for k := i32(1); k < odd_count * 2; k += 2 {
		y += math.sin_f32(phase * 2.0 * math.PI * f32(k)) / f32(k)
	}
	return y * 4.0 / math.PI
}

saw_add :: proc(phase: f32, harmonic_count: i32) -> f32 {
	// additive sawtooth: first `harmonic_count` harmonics, 1/k rolloff
	y: f32 = 0.0
	for k := i32(1); k <= harmonic_count; k += 1 {
		y += math.sin_f32(phase * 2.0 * math.PI * f32(k)) / f32(k)
	}
	return y * 2.0 / math.PI
}

rectN :: proc(phase: f32, n: f32) -> f32 {
	// n equal-width segments per cycle, first segment is high, rest are low
	// duty cycle = 1/n so there's exactly one rising edge per cycle
	if phase < 1.0 / n {return 1.0}
	return -1.0
}

sawN :: proc(phase: f32, n: f32) -> f32 {
	// n equal-width segments ramping 1 -> -1 across the cycle (stepped saw)
	k := i32(phase * n)
	if k < 0 {k = 0}
	if k > i32(n) - 1 {k = i32(n) - 1}
	return 1.0 - 2.0 * f32(k) / (n - 1.0)
}

frac :: proc(x: f32) -> f32 {
	return x - math.floor(x)
}

uint_hash :: proc(x: u32) -> u32 {
	h := x
	h = ((h >> 16) ~ h) * 0x045d9f3b
	h = ((h >> 16) ~ h) * 0x045d9f3b
	h = (h >> 16) ~ h
	return h
}

sample_at_index :: proc(sample_index: i32) -> f32 {
	u := uint_hash(u32(sample_index))
	return f32(i32(u)) * (1.0 / 2147483648.0)
}

// NoiseState tracks per-oscillator noise state for cycle-boundary detection
// matches ptCollage's rdm_start / rdm_margin / rdm_index pattern:
//   - at each oscillator cycle boundary, pick a new random value
//   - Random (_RANDOM_Saw):  linearly interpolate prev-curr across the cycle
//   - Random2 (_RANDOM_Rect): hold curr constant for the cycle
NoiseState :: struct {
	prev_val:   f32,
	curr_val:   f32,
	last_phase: f32,
}

noise_init :: proc(s: ^NoiseState) {
	s.prev_val = 0.0
	s.curr_val = 0.0
	s.last_phase = 0.0
}

// noise_sample returns one noise sample with cycle-boundary-aware state
//
// cycle boundaries are detected by phase wrapping from high to low
// (phase < last_phase && last_phase > 0.5)
//
// at each boundary, prev_val takes the old curr_val and curr_val gets
// a fresh random value
//
// smooth=true  - Random:  linear interpolation (triangle-modulated, less harsh)
// smooth=false - Random2: sample-and-hold (stepped, harsher)
noise_sample :: proc(s: ^NoiseState, phase: f32, sample_index: i32, smooth: bool) -> f32 {
	// detect cycle boundary: phase wrapped from high to low
	if phase < s.last_phase && s.last_phase > 0.5 {
		s.prev_val = s.curr_val
		s.curr_val = sample_at_index(sample_index)
	}
	s.last_phase = phase

	if smooth {
		// linear interpolation between prev and curr (matches _RANDOM_Saw)
		return s.prev_val + (s.curr_val - s.prev_val) * phase
	}
	// sample-and-hold (matches _RANDOM_Rect)
	return s.curr_val
}

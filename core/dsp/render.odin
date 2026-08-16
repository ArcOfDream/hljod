package dsp

// standalone renderer

import "core:math"

// sample count for a duration at a rate (min 1 sample, floor 10ms)
sample_count :: proc(sample_rate: i32, duration: f32) -> i32 {
	return max(1, i32(f32(sample_rate) * max(0.01, duration)))
}

render :: proc(
	main_p: ^OscParams,
	freq_p: ^OscParams,
	volu_p: ^OscParams,
	duration: f32,
	sample_rate: i32,
) -> []f32 {
	sps := sample_rate
	n := sample_count(sps, duration)
	out := make([]f32, n)

	// continuous phase accumulators - integrate freq(t)*dt per sample
	ph_main := frac(main_p.offset)
	ph_freq := frac(freq_p.offset)
	ph_vol := frac(volu_p.offset)

	// noise state - one per oscillator, tracks cycle boundaries for
	// random (smooth) and random2 (stepped) wave types
	noise_main: NoiseState
	noise_freq: NoiseState
	noise_vol: NoiseState
	noise_init(&noise_main)
	noise_init(&noise_freq)
	noise_init(&noise_vol)

	for i in 0 ..< n {
		t := f32(i) / f32(sps)
		norm_t := t / duration

		// base carrier frequency (modulated by freq_curve)
		freq_mult := curve_sample(&main_p.freq_curve, norm_t)
		carrier_freq := max(1.0, main_p.freq * freq_mult)

		// volume envelope
		vol_mult := curve_sample(&main_p.vol_curve, norm_t)
		eff_vol := main_p.volume * vol_mult

		// fm: freq oscillator modulates carrier frequency
		fm_freq := carrier_freq
		pm_contrib: f32 = 0
		if freq_p.freq > 0 {
			fm_freq_mult := curve_sample(&freq_p.freq_curve, norm_t)
			fm_vol_mult := curve_sample(&freq_p.vol_curve, norm_t)

			eff_fm_freq := max(1.0, freq_p.freq * fm_freq_mult)
			eff_fm_vol := freq_p.volume * fm_vol_mult

			// advance fm modulator phase
			ph_freq += freq_p.reverse ? -eff_fm_freq / f32(sps) : eff_fm_freq / f32(sps)
			ph_freq = frac(ph_freq)

			fm_val: f32
			if freq_p.kind == .Curve {
				fm_val = curve_sample(&freq_p.wave_curve, ph_freq)
			} else if freq_p.kind == .Random || freq_p.kind == .Random2 {
				fm_val = noise_sample(&noise_freq, ph_freq, i, freq_p.kind == .Random)
			} else {
				fm_val = sample_for_kind(freq_p.kind, ph_freq, i)
			}

			blend := clamp(freq_p.pm_blend, 0, 1)
			pm_mult := curve_sample(&freq_p.pm_curve, norm_t)
			eff_blend := clamp(blend * pm_mult, 0, 1)
			total_mod := fm_val * (eff_fm_vol * 0.01)

			// fm: modulator changes carrier frequency
			fm_contrib := total_mod * (1.0 - eff_blend) * carrier_freq
			fm_freq = max(1.0, carrier_freq + fm_contrib)

			// fm-pm contribution
			pm_contrib += total_mod * eff_blend * 1.0
		}

		// pm from each oscillator (self-pm on main, pm from volu)
		// main self-pm: sample main at current phase, feed back
		if main_p.pm_blend > 0 {
			sv: f32
			if main_p.kind == .Curve {
				sv = curve_sample(&main_p.wave_curve, ph_main)
			} else if main_p.kind == .Random || main_p.kind == .Random2 {
				sv = noise_sample(&noise_main, ph_main, i, main_p.kind == .Random)
			} else {
				sv = sample_for_kind(main_p.kind, ph_main, i)
			}
			pm_mult := curve_sample(&main_p.pm_curve, norm_t)
			pm_contrib += sv * clamp(main_p.pm_blend, 0, 1) * pm_mult * 0.3
		}
		// volu oscillator - sample once, share between pm and am
		volu_val: f32 = 0
		am_val: f32 = 0
		am_depth: f32 = 0
		volu_active := volu_p.freq > 0
		if volu_active {
			am_freq_mult := curve_sample(&volu_p.freq_curve, norm_t)
			am_vol_mult := curve_sample(&volu_p.vol_curve, norm_t)
			eff_am_freq := max(1.0, volu_p.freq * am_freq_mult)
			eff_am_vol := volu_p.volume * am_vol_mult
			ph_vol += volu_p.reverse ? -eff_am_freq / f32(sps) : eff_am_freq / f32(sps)
			ph_vol = frac(ph_vol)
			if volu_p.kind == .Random || volu_p.kind == .Random2 {
				volu_val = noise_sample(&noise_vol, ph_vol, i, volu_p.kind == .Random)
			} else if volu_p.kind == .Curve {
				volu_val = curve_sample(&volu_p.wave_curve, ph_vol)
			} else {
				volu_val = sample_for_kind(volu_p.kind, ph_vol, i)
			}

			if volu_p.pm_blend > 0 {
				pm_mult := curve_sample(&volu_p.pm_curve, norm_t)
				pm_contrib +=
					volu_val * (eff_am_vol * 0.01) * clamp(volu_p.pm_blend, 0, 1) * pm_mult * 0.5
			}

			am_val = volu_val
			am_depth = min(eff_am_vol * 0.01, 1.0)
		}
		// advance main carrier phase (includes fm deviation)
		ph_main += main_p.reverse ? -fm_freq / f32(sps) : fm_freq / f32(sps)
		ph_main = frac(ph_main)

		// sample phase - apply pm offset on top of accumulated phase
		sample_phase := frac(ph_main + pm_contrib)

		sample: f32
		if main_p.kind == .Curve {
			sample = curve_sample(&main_p.wave_curve, sample_phase)
		} else if main_p.kind == .Random || main_p.kind == .Random2 {
			sample = noise_sample(&noise_main, sample_phase, i, main_p.kind == .Random)
		} else {
			sample = sample_for_kind(main_p.kind, sample_phase, i)
		}
		sample *= eff_vol * 0.01

		// am (amplitude modulation) - uses volu sample computed above
		if volu_active {
			am_uni := am_val * 0.5 + 0.5
			sample = sample * (1.0 - am_depth + am_depth * am_uni)
		}

		// clamp
		if sample > 1.0 {sample = 1.0}
		if sample < -1.0 {sample = -1.0}
		out[i] = sample
	}

	return out
}

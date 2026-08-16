package effects

// effect chain processing for standalone sfx output
//
// reverb room/damp scaling and chorus LFO model based on
// the Synthesis ToolKit (STK) by Perry R. Cook and Gary P. Scavone.
// https://ccrma.stanford.edu/software/stk/

import "core:math"

// format: [L0, R0, L1, R1, ...]

// delay

DelayParams :: struct {
    time:       f32,
    feedback:   f32,
    wet:        f32,
    lowpass:    f32,
}

process_delay :: proc(buf: []f32, p: DelayParams, sr: i32) {
    max_delay := min(len(buf)/2, int(sr * 2))
    delay_len := i32(p.time * f32(max_delay))
    if delay_len < 1 { return }
    feedback := p.feedback
    wet      := p.wet
    lpf      := max(0.0, min(1.0, p.lowpass))
    hist: [dynamic]f32
    defer delete(hist)
    hist = make([dynamic]f32, delay_len)

    hist_idx := 0
    lpf_state: f32 = 0.0
    for i := 0; i < len(buf); i += 2 {
        delayed := hist[hist_idx]
        lpf_state += (delayed - lpf_state) * (1.0 - lpf)
        out_l := buf[i]   * (1.0 - wet) + lpf_state * wet
        out_r := buf[i+1] * (1.0 - wet) + lpf_state * wet
        hist[hist_idx] = out_l * feedback
        buf[i]   = out_l
        buf[i+1] = out_r
        hist_idx = hist_idx + 1
        if hist_idx >= int(delay_len) { hist_idx = 0 }
    }
}

// overdrive / distortion

OverdriveParams :: struct {
    drive: f32,
    tone:  f32,
    mix:   f32,
}

sign :: proc(x: f32) -> f32 {
    if x > 0 { return  1.0 }
    if x < 0 { return -1.0 }
    return 0.0
}

process_overdrive :: proc(buf: []f32, p: OverdriveParams) {
    drive := p.drive
    tone  := max(0.0, min(1.0, p.tone))
    mix   := p.mix
    lpf: f32 = 0.0
    for i := 0; i < len(buf); i += 2 {
        for c in 0 ..< 2 {
            s_in := buf[i+c]
            x := s_in * drive
            s := tanh_approx(x)  // soft clip: unity gain at low levels
            lpf += (s - lpf) * (1.0 - tone)
            wet := lpf
            buf[i+c] = s_in * (1.0 - mix) + wet * mix
        }
    }
}

// reverb

FreeverbParams :: struct {
    roomsize: f32,
    damp:     f32,
    wet:      f32,
    width:    f32,
    dry:      f32,
}

comb_feedback :: proc(
    input: f32,
    buf: []f32,
    idx: ^int,
    lpf_state: ^f32,
    damp: f32,
    feedback: f32,
) -> f32 {
    out := buf[idx^]
    lpf := lpf_state^ + (out - lpf_state^) * (1.0 - damp)
    lpf_state^ = lpf
    buf[idx^] = input + lpf * feedback
    idx^ = idx^ + 1
    if idx^ >= len(buf) { idx^ = 0 }
    return input + lpf * feedback
}

allpass_process :: proc(old_out: f32, buf: []f32, idx: ^int, inp: f32) -> f32 {
    bufout := old_out
    output := -inp + bufout * 0.5
    buf[idx^] = inp + bufout * 0.5
    idx^ = idx^ + 1
    if idx^ >= len(buf) { idx^ = 0 }
    return output
}

freeverb_process_stereo :: proc(buf: []f32, p: FreeverbParams) {
    // STK-style scaling: feedback = 0.7 + roomsize * 0.28 (range 0.7..0.98)
    roomsize := 0.7 + p.roomsize * 0.28
    damp     := p.damp * 0.4     // STK scaleDamp
    wet      := p.wet
    width    := p.width
    dry_gain := p.dry

    comb_tune_l := []int{1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617}
    comb_tune_r := []int{1116 + 23, 1188 + 23, 1277 + 23, 1356 + 23, 1422 + 23, 1491 + 23, 1557 + 23, 1617 + 23}
    ap_tune_l   := []int{556, 441, 341, 225}
    ap_tune_r   := []int{556 + 23, 441 + 23, 341 + 23, 225 + 23}

    comb_l_bufs := make([dynamic][]f32, len(comb_tune_l))
    defer delete(comb_l_bufs)
    comb_r_bufs := make([dynamic][]f32, len(comb_tune_r))
    defer delete(comb_r_bufs)
    ap_l_bufs := make([dynamic][]f32, len(ap_tune_l))
    defer delete(ap_l_bufs)
    ap_r_bufs := make([dynamic][]f32, len(ap_tune_r))
    defer delete(ap_r_bufs)

    comb_l_idx := make([dynamic]int, len(comb_tune_l))
    comb_r_idx := make([dynamic]int, len(comb_tune_r))
    ap_l_idx   := make([dynamic]int, len(ap_tune_l))
    ap_r_idx   := make([dynamic]int, len(ap_tune_r))

    for i in 0 ..< len(comb_tune_l) {
        comb_l_bufs[i] = make([]f32, comb_tune_l[i])
        comb_r_bufs[i] = make([]f32, comb_tune_r[i])
    }
    for i in 0 ..< len(ap_tune_l) {
        ap_l_bufs[i] = make([]f32, ap_tune_l[i])
        ap_r_bufs[i] = make([]f32, ap_tune_r[i])
    }

    gain := f32(0.1)
    lpf_l: f32 = 0.0
    lpf_r: f32 = 0.0

    // stereo spread: width=0 - mono mix, width=1 - full L/R separation
    wet_mix := wet * (width * 0.5 + 0.5)

    for i := 0; i < len(buf); i += 2 {
        l := buf[i]
        r := buf[i+1]

        // sum all comb filter outputs, then pass through allpass chain
        comb_out_l: f32 = 0.0
        comb_out_r: f32 = 0.0
        for c in 0 ..< len(comb_tune_l) {
            comb_out_l += comb_feedback(l, comb_l_bufs[c], &comb_l_idx[c], &lpf_l, damp, roomsize)
            comb_out_r += comb_feedback(r, comb_r_bufs[c], &comb_r_idx[c], &lpf_r, damp, roomsize)
        }
        comb_out_l *= gain
        comb_out_r *= gain

        for c in 0 ..< len(ap_tune_l) {
            comb_out_l = allpass_process(ap_l_bufs[c][ap_l_idx[c]], ap_l_bufs[c], &ap_l_idx[c], comb_out_l)
            comb_out_r = allpass_process(ap_r_bufs[c][ap_r_idx[c]], ap_r_bufs[c], &ap_r_idx[c], comb_out_r)
        }

        buf[i]   = comb_out_l * wet_mix + buf[i]   * dry_gain
        buf[i+1] = comb_out_r * wet_mix + buf[i+1] * dry_gain
    }
}

// simplified mono reverb wrapper
process_reverb :: proc(buf: []f32, p: FreeverbParams) { freeverb_process_stereo(buf, p) }

// lowpass (resonant biquad, RBJ cookbook)

LowPassParams :: struct {
    cutoff: f32,  // 0..1 maps to 20..20k Hz
    q:      f32,  // 0..1 maps to 0.5..20 resonance
}

process_lowpass :: proc(buf: []f32, p: LowPassParams) {
    sr   := f32(44100)
    freq := 20.0 * math.pow(1000.0, p.cutoff)   // 20..~20k Hz
    freq  = min(freq, sr * 0.45)                // anti-alias guard
    q_val := 0.5 + p.q * 19.5                   // 0.5..20

    w0 := 2.0 * math.PI * freq / sr
    cos_w0 := math.cos_f32(w0)
    sin_w0 := math.sin_f32(w0)
    alpha  := sin_w0 / (2.0 * q_val)

    b0 := (1.0 - cos_w0) * 0.5 / (1.0 + alpha)
    b1 := (1.0 - cos_w0)       / (1.0 + alpha)
    b2 := (1.0 - cos_w0) * 0.5 / (1.0 + alpha)
    a1 := -2.0 * cos_w0        / (1.0 + alpha)
    a2 := (1.0 - alpha)        / (1.0 + alpha)

    x1_l, x2_l: f32 = 0, 0
    y1_l, y2_l: f32 = 0, 0
    x1_r, x2_r: f32 = 0, 0
    y1_r, y2_r: f32 = 0, 0

    for i := 0; i < len(buf); i += 2 {
        in_l := buf[i]
        out_l := b0 * in_l + b1 * x1_l + b2 * x2_l - a1 * y1_l - a2 * y2_l
        x2_l, x1_l = x1_l, in_l
        y2_l, y1_l = y1_l, out_l
        buf[i] = out_l

        in_r := buf[i+1]
        out_r := b0 * in_r + b1 * x1_r + b2 * x2_r - a1 * y1_r - a2 * y2_r
        x2_r, x1_r = x1_r, in_r
        y2_r, y1_r = y1_r, out_r
        buf[i+1] = out_r
    }
}

// chorus / flanger (modulated delay)

ChorusParams :: struct {
    time:     f32,  // base delay in ms (1-50)
    depth:    f32,  // modulation depth 0-1
    rate:     f32,  // LFO rate in Hz
    feedback: f32,  // feedback 0-1
    mix:      f32,  // wet/dry mix 0-1
}

process_chorus :: proc(buf: []f32, p: ChorusParams, sr: i32) {
    base_smp      := f32(sr) * p.time / 1000.0
    depth_smp     := base_smp * p.depth * 0.8
    fb            := max(0, min(0.95, p.feedback))
    mix           := max(0, min(1, p.mix))
    sr_f := f32(sr)

    // history must cover the max reachable delay: base + full depth swing
    max_delay_smp := int(base_smp + depth_smp) + 2
    if max_delay_smp < 4 { max_delay_smp = 4 }

    hist := make([]f32, max_delay_smp)
    defer delete(hist)
    hist_idx := 0
    phase: f32 = 0.0
    phase_delta := p.rate / sr_f

    for i := 0; i < len(buf); i += 2 {
        for c in 0 ..< 2 {
            s_in := buf[i+c]
            // LFO: sin(2*pi*phase), range 0..1
            lfo := 0.5 + 0.5 * math.sin_f32(2.0 * math.PI * phase)
            delay_smp := base_smp + depth_smp * lfo
            delay_int := int(delay_smp)
            if delay_int >= len(hist) - 1 { delay_int = len(hist) - 2 } // guard
            delay_frac := delay_smp - f32(delay_int)

            // read from delay line with linear interpolation
            read_idx := hist_idx - delay_int
            if read_idx < 0 { read_idx += len(hist) }
            read_idx2 := read_idx - 1
            if read_idx2 < 0 { read_idx2 += len(hist) }

            delayed := hist[read_idx] * (1.0 - delay_frac) + hist[read_idx2] * delay_frac

            // write with feedback
            hist[hist_idx] = s_in + delayed * fb

            // output
            out := s_in * (1.0 - mix) + delayed * mix
            buf[i+c] = out
            hist_idx += 1
            if hist_idx >= len(hist) { hist_idx = 0 }
        }
        phase += phase_delta
        if phase >= 1.0 { phase -= 1.0 }
    }
}

// bitcrusher (quantizer + sample-and-hold decimator)
// musicdsp 139 lo-fi crusher by David Lowenfels
// bits 1..16; downsample 0..1 = normfreq (freq/sample_rate, 1 = no decimation)

BitcrusherParams :: struct {
    bits:       f32,
    downsample: f32,
    mix:        f32,
}

process_bitcrusher :: proc(buf: []f32, p: BitcrusherParams) {
    step := 1.0 / math.pow(2.0, max(1.0, min(16.0, p.bits)))
    normfreq := max(0.001, min(1.0, p.downsample))
    mix := max(0.0, min(1.0, p.mix))
    phasor: f32 = 0
    last: [2]f32
    for i := 0; i < len(buf); i += 2 {
        phasor += normfreq
        if phasor >= 1.0 {
            phasor -= 1.0
            for c in 0 ..< 2 {
                last[c] = step * math.floor(buf[i + c] / step + 0.5)
            }
        }
        for c in 0 ..< 2 {
            buf[i + c] = last[c] * mix + buf[i + c] * (1.0 - mix)
        }
    }
}

// pitch shift (STK PitShift, delay line with triangular crossfade)
// shift is a ratio: 1.0 = none, <1 = down, >1 = up (STK rate = 1 - shift)
// per-call delay line state matches the other effects (one render pass = one buffer)

PitchShiftParams :: struct {
    shift: f32,
    mix:   f32,
}

PITCH_MAX_DELAY :: 5024
PITCH_LENGTH   :: PITCH_MAX_DELAY - 24
PITCH_HALF     :: PITCH_LENGTH / 2

pitch_read :: proc(hist: []f32, write: int, delay: f32) -> f32 {
    n := len(hist)
    pos := f32(write) - delay
    fl := math.floor(pos)
    i0 := int(fl) % n
    if i0 < 0 { i0 += n }
    frac := pos - fl
    i1 := i0 + 1
    if i1 >= n { i1 = 0 }
    return hist[i0] + (hist[i1] - hist[i0]) * frac
}

process_pitchshift :: proc(buf: []f32, p: PitchShiftParams) {
    rate := 1.0 - p.shift
    mix := max(0.0, min(1.0, p.mix))
    hist := make([]f32, PITCH_MAX_DELAY)
    defer delete(hist)
    write := 0
    delay0 := f32(12)
    for i := 0; i < len(buf); i += 2 {
        for c in 0 ..< 2 {
            delay0 += rate
            for delay0 > f32(PITCH_MAX_DELAY - 12) { delay0 -= PITCH_LENGTH }
            for delay0 < 12 { delay0 += PITCH_LENGTH }
            delay1 := delay0 + PITCH_HALF
            for delay1 > f32(PITCH_MAX_DELAY - 12) { delay1 -= PITCH_LENGTH }
            for delay1 < 12 { delay1 += PITCH_LENGTH }
            env1 := math.abs((delay0 - PITCH_HALF + 12) * (1.0 / f32(PITCH_HALF + 12)))
            env0 := 1.0 - env1
            tap1 := pitch_read(hist, write, delay1)
            tap0 := pitch_read(hist, write, delay0)
            hist[write] = buf[i + c]
            write += 1
            if write >= PITCH_MAX_DELAY { write = 0 }
            out := env1 * tap1 + env0 * tap0
            buf[i + c] = out * mix + buf[i + c] * (1.0 - mix)
        }
    }
}

// chain runner

get_param :: proc(params: []f32, idx: int, def: f32) -> f32 {
    if idx >= 0 && idx < len(params) { return params[idx] }
    return def
}

process_chain :: proc(buf: []f32, chain: []EffectNode, sr: i32) -> []f32 {
    for node in chain {
        if !node.enabled { continue }
        #partial switch node.kind {
        case .Delay:
            p := DelayParams{
                time     = get_param(node.params[:], 0, 0.3),
                feedback = get_param(node.params[:], 1, 0.4),
                wet      = get_param(node.params[:], 2, 0.5),
                lowpass  = get_param(node.params[:], 3, 0.5),
            }
            process_delay(buf, p, sr)
        case .Overdrive:
            p := OverdriveParams{
                drive = get_param(node.params[:], 0, 1.5),
                tone  = get_param(node.params[:], 1, 0.5),
                mix   = get_param(node.params[:], 2, 0.7),
            }
            process_overdrive(buf, p)
        case .Reverb:
            p := FreeverbParams{
                roomsize = get_param(node.params[:], 0, 0.5),
                damp     = get_param(node.params[:], 1, 0.5),
                wet      = get_param(node.params[:], 2, 0.7),
                width    = get_param(node.params[:], 3, 0.7),
                dry      = get_param(node.params[:], 4, 0.3),
            }
            process_reverb(buf, p)
        case .LowPass:
            p := LowPassParams{
                cutoff = get_param(node.params[:], 0, 0.5),
                q      = get_param(node.params[:], 1, 0.5),
            }
            process_lowpass(buf, p)
        case .Distortion:
            p := OverdriveParams{
                drive = get_param(node.params[:], 0, 2.5),
                tone  = get_param(node.params[:], 1, 0.3),
                mix   = get_param(node.params[:], 2, 1.0),
            }
            process_overdrive(buf, p)
        case .Chorus:
            p := ChorusParams{
                time     = get_param(node.params[:], 0, 5.0),
                depth    = get_param(node.params[:], 1, 0.5),
                rate     = get_param(node.params[:], 2, 0.5),
                feedback = get_param(node.params[:], 3, 0.3),
                mix      = get_param(node.params[:], 4, 0.5),
            }
            process_chorus(buf, p, sr)
        case .Bitcrusher:
            p := BitcrusherParams{
                bits       = get_param(node.params[:], 0, 8.0),
                downsample = get_param(node.params[:], 1, 0.5),
                mix        = get_param(node.params[:], 2, 0.7),
            }
            process_bitcrusher(buf, p)
        case .PitchShift:
            p := PitchShiftParams{
                shift = get_param(node.params[:], 0, 1.5),
                mix   = get_param(node.params[:], 1, 0.5),
            }
            process_pitchshift(buf, p)
        case:
        }
    }
    return buf
}

EffectKind :: enum {
    None,
    Delay,
    Overdrive,
    Reverb,
    Distortion,
    LowPass,
    Chorus,
    Bitcrusher,
    PitchShift,
}

EffectNode :: struct {
    kind:    EffectKind,
    enabled: bool,
    params:  [dynamic]f32,
}

// fast tanh approximation
// Pade approximant from https://mathr.co.uk/blog/2017-09-06_approximating_hyperbolic_tangent.html
tanh_approx :: proc(x: f32) -> f32 {
    ax := abs(x)
    if ax > 4.5 { return sign(x) }  // hard clip beyond ~4.5
    x2 := x * x
    // pade approximant: tanh(x) ~ x*(27+x2)/(27+9*x2)  good to ~|x|<3
    // extend to ~4.5 with a scaled version
    return x * (27.0 + x2) / (27.0 + 9.0 * x2)
}

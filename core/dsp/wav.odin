package dsp

import "core:math"

wav_write :: proc(samples: []f32, sample_rate: i32) -> []byte {
	data_size := len(samples) * 2 // 16-bit samples
	file_size := 44 + data_size
	buf := make([]byte, file_size)

	// RIFF header
	buf[0] = 'R'; buf[1] = 'I'; buf[2] = 'F'; buf[3] = 'F'
	buf[4] = byte(
		file_size - 8,
	); buf[5] = byte((file_size - 8) >> 8); buf[6] = byte((file_size - 8) >> 16); buf[7] = byte((file_size - 8) >> 24)
	buf[8] = 'W'; buf[9] = 'A'; buf[10] = 'V'; buf[11] = 'E'
	// fmt chunk
	buf[12] = 'f'; buf[13] = 'm'; buf[14] = 't'; buf[15] = ' '
	buf[16] = 16; buf[17] = 0; buf[18] = 0; buf[19] = 0
	buf[20] = 1; buf[21] = 0 // PCM
	buf[22] = 1; buf[23] = 0 // mono
	buf[24] = byte(
		sample_rate,
	); buf[25] = byte(sample_rate >> 8); buf[26] = byte(sample_rate >> 16); buf[27] = byte(sample_rate >> 24)
	byte_rate := sample_rate * 2
	buf[28] = byte(
		byte_rate,
	); buf[29] = byte(byte_rate >> 8); buf[30] = byte(byte_rate >> 16); buf[31] = byte(byte_rate >> 24)
	buf[32] = 2; buf[33] = 0 // block align
	buf[34] = 16; buf[35] = 0 // bits per sample
	// data chunk
	buf[36] = 'd'; buf[37] = 'a'; buf[38] = 't'; buf[39] = 'a'
	buf[40] = byte(
		data_size,
	); buf[41] = byte(data_size >> 8); buf[42] = byte(data_size >> 16); buf[43] = byte(data_size >> 24)
	// samples
	for s, i in samples {
		val := i16(clamp(s, -1.0, 1.0) * 32767.0)
		off := 44 + i * 2
		buf[off] = byte(val)
		buf[off + 1] = byte(val >> 8)
	}
	return buf
}

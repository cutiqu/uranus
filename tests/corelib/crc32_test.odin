package corelib_tests

import lib "../../corelib"

import "core:testing"

@(test)
crc32_matches_the_standard_check_values :: proc(t: ^testing.T) {
	// The catalogue check value for CRC-32/ISO-HDLC, and the empty message.
	testing.expect_value(t, lib.crc32(transmute([]byte)string("123456789")), 0xCBF4_3926)
	testing.expect_value(t, lib.crc32(nil), 0)
	testing.expect_value(t, lib.crc32(transmute([]byte)string("a")), 0xE8B7_BE43)
}

@(test)
crc32_can_be_computed_in_pieces :: proc(t: ^testing.T) {
	data: [1000]byte
	for i in 0 ..< len(data) { data[i] = byte(i * 7 + i / 13) }
	whole := lib.crc32(data[:])
	for split in ([?]int{0, 1, 3, 499, 999, 1000}) {
		testing.expect_value(t, lib.crc32(data[split:], lib.crc32(data[:split])), whole)
	}
}

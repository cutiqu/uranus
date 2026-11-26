package corelib

// CRC-32 as used by zip, PNG, and every ROM database: reflected, polynomial
// 0xEDB88320, initial value and final XOR 0xFFFFFFFF.
//
// A 16-entry table (one nibble at a time) instead of the usual 256: ROMs are
// hashed once per load, so speed doesn't matter, and the table stays small
// enough to read at a glance.
@(private = "file", rodata)
CRC32_NIBBLE := [16]u32{
	0x00000000, 0x1DB71064, 0x3B6E20C8, 0x26D930AC,
	0x76DC4190, 0x6B6B51F4, 0x4DB26158, 0x5005713C,
	0xEDB88320, 0xF00F9344, 0xD6D6A3E8, 0xCB61B38C,
	0x9B64C2B0, 0x86D3D2D4, 0xA00AE278, 0xBDBDF21C,
}

// The CRC-32 of `data`. To hash in pieces, pass the previous result as `crc`:
// crc32(b, crc32(a)) == crc32(a ++ b).
crc32 :: proc "contextless" (data: []byte, crc: u32 = 0) -> u32 {
	c := ~crc
	for b in data {
		c = CRC32_NIBBLE[(c ~ u32(b)) & 0xF] ~ (c >> 4)
		c = CRC32_NIBBLE[(c ~ u32(b >> 4)) & 0xF] ~ (c >> 4)
	}
	return ~c
}

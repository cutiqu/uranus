package host

// A fixed-capacity ring of 16-bit samples that sits between the thread that
// runs the core and the audio device's callback thread. It does NO locking of
// its own: the frontend wraps push/pop in the device lock (SDL_LockAudioDevice
// and friends), which keeps this simple and obviously correct.
//
// Procs are "contextless" because the audio callback thread has no Odin context.

Ring :: struct {
	data:  []i16,
	read:  int, // index of the oldest sample
	count: int, // samples currently stored
}

ring_make :: proc(capacity_samples: int) -> Ring {
	return Ring{data = make([]i16, capacity_samples)}
}

ring_destroy :: proc(r: ^Ring) {
	delete(r.data)
	r^ = {}
}

// Append samples. On overflow the OLDEST samples are dropped, so latency stays
// bounded instead of growing. Returns how many samples were dropped.
ring_push :: proc "contextless" (r: ^Ring, samples: []i16) -> (dropped: int) {
	src := samples
	if len(src) > len(r.data) { // pathological: keep only the newest capacity-worth
		dropped += len(src) - len(r.data)
		src = src[len(src) - len(r.data):]
	}
	overflow := r.count + len(src) - len(r.data)
	if overflow > 0 {
		r.read = (r.read + overflow) % len(r.data)
		r.count -= overflow
		dropped += overflow
	}
	write := (r.read + r.count) % len(r.data)
	for s in src {
		r.data[write] = s
		write += 1
		if write == len(r.data) { write = 0 }
	}
	r.count += len(src)
	return
}

// Copy up to len(out) samples out, oldest first. Returns the number copied.
ring_pop :: proc "contextless" (r: ^Ring, out: []i16) -> int {
	n := min(len(out), r.count)
	for i in 0 ..< n {
		out[i] = r.data[r.read]
		r.read += 1
		if r.read == len(r.data) { r.read = 0 }
	}
	r.count -= n
	return n
}

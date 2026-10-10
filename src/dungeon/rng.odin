package dungeon

// Small self-contained splitmix64 generator. The dungeon must be reproducible
// from its seed alone, so generation never touches core:math/rand.
Rng :: struct {
	state: u64,
}

rng_make :: proc(seed: u64) -> Rng {
	return {state = seed}
}

rng_next :: proc(r: ^Rng) -> u64 {
	r.state += 0x9E3779B97F4A7C15
	z := r.state
	z = (z ~ (z >> 30)) * 0xBF58476D1CE4E5B9
	z = (z ~ (z >> 27)) * 0x94D049BB133111EB
	return z ~ (z >> 31)
}

// Uniform integer in [0, n). Returns 0 when n <= 0.
rng_int :: proc(r: ^Rng, n: int) -> int {
	if n <= 0 {
		return 0
	}
	return int(rng_next(r) % u64(n))
}

// Uniform integer in [lo, hi], both inclusive.
rng_range :: proc(r: ^Rng, lo, hi: int) -> int {
	if hi <= lo {
		return lo
	}
	return lo + rng_int(r, hi - lo + 1)
}

// Uniform float in [0, 1).
rng_float :: proc(r: ^Rng) -> f32 {
	return f32(rng_next(r) >> 40) / f32(1 << 24)
}

rng_chance :: proc(r: ^Rng, probability: f32) -> bool {
	return rng_float(r) < probability
}

// Stateless hash used where a value has to depend on a cell, not on draw order.
hash_cell :: proc(seed: u64, x, y: int, salt: u64 = 0) -> u64 {
	r := rng_make(seed ~ (u64(x) * 0x9E3779B97F4A7C15) ~ (u64(y) * 0xC2B2AE3D27D4EB4F) ~ (salt * 0x165667B19E3779F9))
	return rng_next(&r)
}

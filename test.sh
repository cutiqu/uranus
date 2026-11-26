#!/usr/bin/env bash
# One command for everything checkable.
#   ./test.sh            unit tests, firewall, and the Saturn smoke / disc-image /
#                        save-state checks (synthetic BIOS, no ROM downloads)
cd "$(dirname "$0")"
set -o pipefail   # a compile failure must fail the gate, not just the pipeline's last command
fail=0
export HOME=$(mktemp -d)   # tests must never touch the real config or saves
export XDG_DATA_HOME= XDG_CONFIG_HOME=

echo "== unit tests"
for t in corelib host input saturn; do
	printf '%-8s ' "$t"
	odin test tests/$t -o:speed 2>&1 | grep -E "Finished|failed" | sed 's/^.*Finished/Finished/' || fail=1
done

echo; echo "== core/frontend firewall"
./tools/check_cores.sh || fail=1

echo; echo "== Saturn smoke test (synthetic BIOS: NBG0 stripes + VBlank interrupt)"
if command -v python3 >/dev/null; then
	python3 tests/saturn/make_synth_bios.py "$HOME/synth_bios.bin" >/dev/null &&
	./build/uranus "$HOME/synth_bios.bin" --core saturn --headless 5 --dump "$HOME/synth.ppm" >/dev/null 2>&1 &&
	python3 tests/saturn/check_synth_frame.py "$HOME/synth.ppm" && echo "saturn smoke: PASS" || { echo "saturn smoke: FAIL"; fail=1; }
else
	echo "(skipped: needs python3)"
fi

echo; echo "== Saturn disc images (cue, every CHD codec, rejects) through the real session"
(
	# A throwaway HOME so a real BIOS in the user's system directory is never touched.
	export HOME="$(mktemp -d)"
	if command -v python3 >/dev/null; then
		mkdir -p "$HOME/.local/share/uranus/system"
		python3 tests/saturn/make_synth_bios.py "$HOME/.local/share/uranus/system/sega_101.bin" >/dev/null
		ok=1
		for img in tests/host/fixtures/disc.cue tests/host/fixtures/disc_cdlz.chd tests/host/fixtures/disc_cdzl.chd \
			tests/host/fixtures/disc_none.chd tests/host/fixtures/disc_default.chd; do
			./build/uranus "$img" --core saturn --headless 3 >/dev/null 2>&1 || { echo "  FAIL loading $img"; ok=0; }
		done
		head -c 40960 /dev/zero > "$HOME/zeros.iso"
		./build/uranus "$HOME/zeros.iso" --core saturn --headless 3 >/dev/null 2>&1 && { echo "  FAIL: a non-Saturn image was accepted"; ok=0; }
		[ $ok = 1 ] && echo "saturn discs: PASS"
		[ $ok = 1 ] || exit 1
	else
		echo "(skipped: needs python3)"
	fi
) || fail=1

echo; echo "== Saturn save states (determinism + fuzzing: bare synthetic BIOS, then each disc image)"
(
	export HOME="$(mktemp -d)"
	if command -v python3 >/dev/null; then
		mkdir -p "$HOME/.local/share/uranus/system"
		python3 tests/saturn/make_synth_bios.py "$HOME/.local/share/uranus/system/sega_101.bin" >/dev/null
		python3 tests/saturn/make_synth_bios.py "$HOME/synth_bios.bin" >/dev/null
		ok=1
		for img in "$HOME/synth_bios.bin" tests/host/fixtures/disc.cue tests/host/fixtures/disc_cdlz.chd tests/host/fixtures/disc_default.chd; do
			printf '%-20s ' "$(basename "$img")"
			out=$(./build/uranus "$img" --core saturn --check-determinism 100 200 --fuzz-state 200 2>&1)
			echo "$out" | grep -E "determinism:|fuzz:" | tr '\n' ' '; echo
			echo "$out" | grep -q "determinism: PASS" || ok=0
		done
		[ $ok = 1 ] || exit 1
	else
		echo "(skipped: needs python3)"
	fi
) || fail=1

exit $fail

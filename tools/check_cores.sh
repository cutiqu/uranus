#!/usr/bin/env sh
# Enforces the core/frontend firewall mechanically. All three checks must pass.
#
#  1. A core imports only: the API package, corelib, compiler intrinsics.
#     No `foreign` code. (Test files live under tests/, never in core.)
#  2. Nothing but the registry imports a core. Frontends, host, config and the
#     app reach cores only through api.Core, a struct of procedure pointers.
#  3. Each core, compiled ON ITS OWN, still imports nothing from the OS but the
#     compiler's memcpy/memmove/memset and thread-local helper: no files, no
#     terminal, no clocks, no threads, no allocation. (The real executable links
#     SDL, so the proof has to be done on the core in isolation.)
cd "$(dirname "$0")/.."
status=0

# 1 ---------------------------------------------------------------------------
bad=$(grep -nE '^[[:space:]]*(import|foreign)' core/*.odin \
	| grep -vE 'import( [A-Za-z_]+)? "(base:intrinsics|\.\./api|\.\./corelib)"')
if [ -n "$bad" ]; then
	echo "FAIL (1): forbidden imports in core source:"; echo "$bad"; status=1
else
	echo "1. cores import only api / corelib / intrinsics, no foreign code"
fi

# 2 ---------------------------------------------------------------------------
leak=$(grep -rnE '^[[:space:]]*import.*"[./]*/?core/' app frontend host config 2>/dev/null)
if [ -n "$leak" ]; then
	echo "FAIL (2): these files import a core directly (only registry/ may):"; echo "$leak"; status=1
else
	echo "2. only registry/ imports cores; frontends see just api.Core"
fi

# 3 ---------------------------------------------------------------------------
tmp=$(mktemp -d)
for dir in core/; do
	name=$(basename "$dir")
	if ! odin build "$dir" -build-mode:shared -default-to-nil-allocator -o:speed -out:"$tmp/$name.so" 2>"$tmp/err"; then
		echo "FAIL (3): core '$name' does not build in isolation:"; cat "$tmp/err"; status=1; continue
	fi
	extra=$(nm -D "$tmp/$name.so" | awk '$1=="U"{print $2}' | sed 's/@.*//' \
		| grep -vxE '__tls_get_addr|memcpy|memmove|memset|__cxa_finalize|_ITM_[A-Za-z]+|__gmon_start__')
	if [ -n "$extra" ]; then
		echo "FAIL (3): core '$name' imports: $extra"; status=1
	else
		echo "3. core '$name' in isolation: imports only memcpy/memmove/memset/TLS"
	fi
done
rm -rf "$tmp"
exit $status

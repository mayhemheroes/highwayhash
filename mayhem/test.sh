#!/usr/bin/env bash
#
# highwayhash/mayhem/test.sh — build and RUN highwayhash's OWN known-answer test suite with NORMAL
# (non-sanitizer) flags and emit a CTRF summary. exit 0 iff every test passed.
#
# PATCH-grade oracle: highwayhash ships real known-answer tests. highwayhash_test verifies the
# HighwayHash output against hard-coded expected hashes for every supported CPU target; sip_hash_test
# checks SipHash / SipHash13 against the reference vectors; vector_test exercises the SIMD vector
# wrappers. They assert BYTE-EXACT hash results, so a no-op / "return 0" patch (or any change that
# alters the computed hash) cannot pass. This script builds the tests in a clean tree (so the verdict
# is independent of the fuzz build) and RUNS them.
#
# BEHAVIORAL oracle: we capture each test binary's stdout and grep for expected output strings.
# A neutered binary (LD_PRELOAD exit(0)) produces NO output, so the grep fails — the oracle detects it.
# Expected output:
#   highwayhash_test prints "Portable: OK" (at minimum) for each CPU target
#   sip_hash_test   prints "VerifySipHash succeeded."
#   vector_test     prints "Portable: done" (at minimum)
#
# SIMD note: built via upstream's own Makefile, which compiles the AVX2/SSE4.1 TUs with -mavx2 /
# -msse4.1 (isolated TUs only) — never -march=native — and the tests dispatch by CPUID at runtime, so
# they run on any baseline x86-64 host.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Build the test binaries with NORMAL flags (clean of sanitizer/UB instrumentation) via upstream's
# own Makefile. `make` builds, among others: bin/highwayhash_test bin/sip_hash_test bin/vector_test.
echo "=== building highwayhash test suite (normal flags) ==="
if ! env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
      make -j"$MAYHEM_JOBS" bin/highwayhash_test bin/sip_hash_test bin/vector_test; then
  echo "test build failed" >&2
  emit_ctrf "highwayhash-tests" 0 1 0; exit 2
fi

PASS=0; FAIL=0

# run_one <name> <bin> <expected-pattern>
# Captures stdout+stderr, checks exit code AND greps for expected output.
# A neutered binary (exit 0, no output) fails the grep → oracle detects it.
run_one() {
  local name="$1" bin="$2" pattern="$3"
  if [ ! -x "$bin" ]; then
    echo "MISSING $name ($bin)"; FAIL=$((FAIL+1)); return
  fi
  echo "=== running $name ==="
  local out
  out="$("$bin" 2>&1)"
  local rc=$?
  printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $name (exit $rc)"; FAIL=$((FAIL+1)); return
  fi
  if ! printf '%s\n' "$out" | grep -qF "$pattern"; then
    echo "FAIL $name (expected output not found: '$pattern')"; FAIL=$((FAIL+1)); return
  fi
  echo "PASS $name"; PASS=$((PASS+1))
}

# highwayhash_test prints "Portable: OK" for each CPU implementation it validates.
run_one highwayhash_test "$SRC/bin/highwayhash_test" "Portable: OK"
# sip_hash_test prints "VerifySipHash succeeded." on success.
run_one sip_hash_test    "$SRC/bin/sip_hash_test"    "VerifySipHash succeeded."
# vector_test prints "Portable: done" after running the vector wrapper tests.
run_one vector_test      "$SRC/bin/vector_test"      "Portable: done"

emit_ctrf "highwayhash-tests" "$PASS" "$FAIL" 0

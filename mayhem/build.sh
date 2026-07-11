#!/usr/bin/env bash
#
# highwayhash/mayhem/build.sh — build google/highwayhash's two OSS-Fuzz harnesses as sanitized
# libFuzzer targets (+ standalone reproducers).
#
# The fuzzed surface is highwayhash's HASH IMPLEMENTATIONS on attacker-controlled bytes:
#   highwayhash_fuzzer — reads 4x uint64 as the 256-bit HHKey, then feeds the remaining bytes to
#                        InstructionSets::Run<HighwayHash>(key, data, size, &result). The dispatcher
#                        picks the best CPU target at RUNTIME (Portable / SSE4.1 / AVX2 via CPUID),
#                        so the binary is portable and never executes an unsupported instruction.
#   sip_hash_fuzzer    — reads 2x uint64 as the 128-bit SipHash key, then feeds the remaining bytes
#                        to SipHash(key, data, size). Pure scalar, portable.
# Inputs are raw bytes: a key prefix followed by the message to hash.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). We compile the highwayhash library ITSELF with $SANITIZER_FLAGS so the
# hashing code (not just the harness) is instrumented.
#
# SIMD note: the X86 target-specific TUs (hh_avx2.cc / hh_sse41.cc) MUST be compiled with -mavx2 /
# -msse4.1 respectively, exactly as upstream's Makefile/CMake do — those flags only gate codegen for
# those isolated TUs, and the runtime dispatcher only ENTERS them when CPUID reports support. The
# top-level build never uses -march=native, so the resulting binaries run on any baseline x86-64
# fuzzing host without SIGILL.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

INC="-I$SRC"
CXXSTD="-std=c++11 -pthread"

BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"

# ── 1) Build each highwayhash TU WITH sanitizers. The X86 target-specific TUs get their own ISA
#       flag (and matching HH_TARGET_NAME for the portable TU), matching upstream exactly. ─────────
# name:extra-flags
declare -a HH_TUS=(
  "c_bindings.cc:"
  "arch_specific.cc:"
  "instruction_sets.cc:"
  "os_specific.cc:"
  "nanobenchmark.cc:"
  "sip_hash.cc:"
  "scalar_sip_tree_hash.cc:"
  "sip_tree_hash.cc:-mavx2"
  "hh_portable.cc:-DHH_TARGET_NAME=Portable"
  "hh_sse41.cc:-msse4.1"
  "hh_avx2.cc:-mavx2"
)

OBJS=()
for spec in "${HH_TUS[@]}"; do
  tu="${spec%%:*}"; extra="${spec#*:}"
  obj="$BUILD/${tu%.cc}.o"
  # shellcheck disable=SC2086
  $CXX $CXXSTD $SANITIZER_FLAGS $DEBUG_FLAGS $extra $INC -c "highwayhash/$tu" -o "$obj"
  OBJS+=("$obj")
done

LIBHH="$BUILD/libhighwayhash.a"
rm -f "$LIBHH"; ar rcs "$LIBHH" "${OBJS[@]}"

# Standalone driver object (the base ships LLVM's StandaloneFuzzTargetMain.c — no libFuzzer runtime,
# reads input files one by one). Compiled once, reused by every harness's -standalone build.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

# ── 2) Build each OSS-Fuzz harness twice: libFuzzer (-> /mayhem/<name>) + standalone reproducer ───
for harness in highwayhash_fuzzer sip_hash_fuzzer; do
  # libFuzzer target -> /mayhem/<name>
  # shellcheck disable=SC2086
  $CXX $CXXSTD $SANITIZER_FLAGS $DEBUG_FLAGS $INC \
      "highwayhash/$harness.cc" $LIB_FUZZING_ENGINE "$LIBHH" -lpthread \
      -o "/mayhem/$harness"

  # standalone reproducer (no libFuzzer runtime) -> /mayhem/<name>-standalone
  # shellcheck disable=SC2086
  $CXX $CXXSTD $SANITIZER_FLAGS $DEBUG_FLAGS $INC \
      "highwayhash/$harness.cc" "$BUILD/standalone_main.o" "$LIBHH" -lpthread \
      -o "/mayhem/$harness-standalone"

  echo "built $harness (+ standalone)"
done

echo "build.sh complete:"
ls -la /mayhem/highwayhash_fuzzer /mayhem/sip_hash_fuzzer \
       /mayhem/highwayhash_fuzzer-standalone /mayhem/sip_hash_fuzzer-standalone 2>&1 || true

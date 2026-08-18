#!/usr/bin/env bash
#
# fluidsynth/mayhem/test.sh -- RUN FluidSynth's own upstream ctest suite
# (built by mayhem/build.sh's NORMAL, non-sanitized CMake configure) AND a
# direct known-answer-test probe, then emit a CTRF summary. Exit 0 iff
# nothing failed.
#
# WHY BOTH, AND WHY THE KAT PROBE IS LOAD-BEARING (not just extra signal):
#
# FluidSynth's suite is ~40 SEPARATE small executables (one per
# ADD_FLUID_TEST(test_*) in test/CMakeLists.txt), each of which calls
# TEST_ASSERT -> abort() on failure and otherwise falls off the end of
# main() with an implicit `return 0`. ctest's own pass/fail bookkeeping is
# PURELY the child process's exit code: 0 = Passed, nonzero (signal or
# explicit) = Failed.
#
# verify-repo's anti-reward-hacking sabotage check LD_PRELOADs a shim whose
# constructor calls _exit(0) for every non-system executable BEFORE main()
# runs. Under that shim, all ~40 test binaries "succeed" -- not because they
# ran any assertion, but because they never got the chance to fail one. ctest
# would then report "100% tests passed, 0 tests failed" -- IDENTICAL to a
# clean run. This is the same reward-hackable shape as a statically-linked
# `go test`/`cargo test` binary surviving LD_PRELOAD (SPEC 6.3), just reached
# by a different mechanism: dynamic linking does not help when the judge is
# still just "did the child exit 0", because the shim make that trivially
# true regardless of whether any code the test author wrote ever executed.
#
# So `ctest` alone is NOT the sabotage-proof oracle here, even though every
# test binary is a normal dynamically-linked executable. The KAT PROBE below
# is what actually enforces "the program must have really run": it prints
# fixed `KAT_<NAME>=<value>` lines that can only appear if the real parsing
# code executed and returned specific values, and this script asserts those
# EXACT LINES against the probe's CAPTURED STDOUT via `grep -qxF`, run from
# bash -- a whitelisted, non-neuterable interpreter. A neutered probe prints
# NOTHING (killed before its first printf), so every `grep -qxF` below fails
# and this script exits non-zero. The failure signal lives in the ABSENCE of
# expected text, not in the probe's own exit code -- so it cannot be
# defeated the way the ctest aggregation can.
#
# ctest is still run and still contributes to the CTRF counts -- it is a
# real, valuable regression signal for FluidSynth's own correctness -- it
# just isn't trusted alone to prove non-reward-hackability.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
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

NORMDIR="$SRC/mayhem-build/normal"
KAT_BIN="$SRC/kat_probe"

TOTAL_FAIL=0

# ---- 1) ctest (FluidSynth's own suite; real signal, but see header re: sabotage) ----
CTEST_TOTAL=0
CTEST_FAILED=0
if [ -d "$NORMDIR" ]; then
  echo "=== running: ctest (FluidSynth's own suite, $NORMDIR) ==="
  CTEST_OUT="$(cd "$NORMDIR" && ctest --output-on-failure 2>&1)"
  printf '%s\n' "$CTEST_OUT"
  # Parse ctest's own summary line, e.g.: "100% tests passed, 0 tests failed out of 40"
  SUMMARY_LINE="$(printf '%s\n' "$CTEST_OUT" | grep -m1 -E '^[0-9]+% tests passed, [0-9]+ tests? failed out of [0-9]+')"
  if [ -n "$SUMMARY_LINE" ]; then
    CTEST_FAILED="$(printf '%s' "$SUMMARY_LINE" | sed -nE 's/.*, ([0-9]+) tests? failed out of.*/\1/p')"
    CTEST_TOTAL="$(printf '%s' "$SUMMARY_LINE" | sed -nE 's/.*out of ([0-9]+).*/\1/p')"
  fi
  : "${CTEST_FAILED:=0}" "${CTEST_TOTAL:=0}"
  if [ "$CTEST_TOTAL" -eq 0 ]; then
    echo "FAIL: ctest reported 0 total tests -- the suite did not execute" >&2
    CTEST_TOTAL=1
    CTEST_FAILED=1
  fi
else
  echo "FAIL: missing $NORMDIR -- run mayhem/build.sh first" >&2
  CTEST_TOTAL=1
  CTEST_FAILED=1
fi
CTEST_PASSED=$(( CTEST_TOTAL - CTEST_FAILED ))
TOTAL_FAIL=$(( TOTAL_FAIL + CTEST_FAILED ))

# ---- 2) direct KAT probe -- the sabotage-proof leg (see header) ----
echo "=== running: $KAT_BIN ==="
KAT_OUT=""
if [ -x "$KAT_BIN" ]; then
  KAT_OUT="$("$KAT_BIN" 2>&1)" || true
  printf '%s\n' "$KAT_OUT"
else
  echo "missing $KAT_BIN -- run mayhem/build.sh first" >&2
fi

# Exact-line assertions against the real, upstream-shipped fixtures
# (sf2/VintageDreamsWaves-v2.sf2, and the probe's own embedded 19-byte SMF --
# see mayhem/kat/kat_probe.c for how these numbers were derived). Every
# assertion is UNCONDITIONAL: a missing binary or empty output degrades to
# "line not found", never a skip.
KAT_NAMES=(
  "sf2 loader: loads OK"
  "sf2 loader: preset count == 136"
  "sf2 loader: first preset name == 'FM Bells 1'"
  "midi parser: division == 96"
  "midi parser: total ticks == 96"
)
KAT_LINES=(
  "KAT_SF2_LOAD=OK"
  "KAT_SF2_PRESET_COUNT=136"
  "KAT_SF2_PRESET0_NAME=FM Bells 1"
  "KAT_MID_DIVISION=96"
  "KAT_MID_TOTAL_TICKS=96"
)
KAT_FAILED=0
for i in "${!KAT_LINES[@]}"; do
  if printf '%s\n' "$KAT_OUT" | grep -qxF "${KAT_LINES[$i]}"; then
    echo "  PASS  ${KAT_NAMES[$i]}"
  else
    echo "  FAIL  ${KAT_NAMES[$i]} -- expected line not found: ${KAT_LINES[$i]}" >&2
    KAT_FAILED=$((KAT_FAILED + 1))
  fi
done
KAT_TOTAL=${#KAT_LINES[@]}
KAT_PASSED=$(( KAT_TOTAL - KAT_FAILED ))
TOTAL_FAIL=$(( TOTAL_FAIL + KAT_FAILED ))

echo "=== results: ctest $CTEST_PASSED/$CTEST_TOTAL passed ($CTEST_FAILED failed); KAT probe $KAT_PASSED/$KAT_TOTAL passed ($KAT_FAILED failed) ==="

emit_ctrf "fluidsynth-ctest+kat" "$((CTEST_PASSED + KAT_PASSED))" "$((CTEST_FAILED + KAT_FAILED))"

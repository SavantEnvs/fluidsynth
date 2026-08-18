#!/usr/bin/env bash
#
# fluidsynth/mayhem/build.sh -- build two libFuzzer harnesses over FluidSynth's
# two untrusted-input parsers (+ standalone reproducers), AND FluidSynth's own
# upstream ctest suite (built via CMake with NORMAL flags) plus a direct KAT
# probe for mayhem/test.sh:
#
#   fuzz_sf2  -- the SoundFont2 (.sf2) RIFF-chunk loader
#                (src/sfloader/fluid_sffile.c, fluid_defsfont.c): registers a
#                custom, in-memory fluid_sfloader_t (fluid_sfloader_set_callbacks)
#                and calls fluid_defsfloader_load() directly -- no filesystem
#                access, no fluid_synth_t/audio engine, no rendering. This is
#                the "richest surface": chunk headers, INFO/sdta/pdta, preset/
#                instrument/sample import, generator+modulator lists, and the
#                actual PCM sample-data extraction.
#   fuzz_midi -- the Standard MIDI File parser (src/midi/fluid_midi.c):
#                fluid_player_add_mem() (in-memory, no file path) followed by
#                ONE tiny fluid_synth_write_s16() call to trigger the player's
#                eager, up-front track parse (VLQ delta-times, running status,
#                meta/sysex events) -- capped to a handful of tiny render
#                calls so nothing ever turns into a real audio render.
#
# The FluidSynth LIBRARY itself is compiled here (not just the harness TUs) so
# the fuzzed decoder/parser code is instrumented -- and with
# -fsanitize=fuzzer-no-link UNCONDITIONALLY (independent of $SANITIZER_FLAGS)
# so SanitizerCoverage is always present in the library object files even
# under an explicit empty --build-arg SANITIZER_FLAGS= (no-sanitizer) build;
# without it Mayhem would see 0 edges from the library despite the harness TU
# itself being instrumented via $LIB_FUZZING_ENGINE at the final link.
#
# Audio/MIDI drivers, SF3 (libsndfile), signalsmith limiter/reverb, D-Bus,
# LADSPA, readline, network, etc. are all configured OFF -- our two targets
# only ever parse/load, never open a device or render audio, so none of that
# surface is needed, and disabling it keeps the dependency set (and the
# air-gap closure) minimal. The only non-toolchain dependency FluidSynth has
# left with all of that off is the header-only "gcem" library, which is
# normally a git submodule; §1 below vendors it once (self-healing) so the
# offline PATCH re-run never needs network.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) -- must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# Always ensure the LIBRARY gets SanitizerCoverage instrumentation, regardless of the base image's
# default or an empty override (see header comment).
case "$SANITIZER_FLAGS" in
  *fuzzer-no-link*) ;;  # already present
  *) SANITIZER_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link" ;;
esac
# DWARF <= 3 (SPEC 6.2 item 10): clang-19's plain -g emits DWARF-5; be explicit.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE STANDALONE_FUZZ_MAIN MAYHEM_JOBS
: "${SRC:=/mayhem}"
cd "$SRC"

# ── 0) Vendor gcem (header-only, normally a git submodule) ─────────────────
# `find_package(GCEM REQUIRED)` (CMakeLists.txt) looks for gcem/include/gcem.hpp
# under the source dir and, if absent, would try to `file(DOWNLOAD ...)` it
# itself during CMake *configure* -- which is exactly the kind of build-time
# network fetch SPEC 6.5 forbids for the air-gapped PATCH re-run. We do the
# same fetch ourselves, ONCE, guarded so the (offline) re-run is a no-op: the
# first, online CI build populates $SRC/gcem/include here, and that directory
# is then part of the built image's filesystem forever after -- the guard
# below sees it already present and skips the network entirely.
GCEM_REV=012ae73c6d0a2cb09ffe86475f5c6fba3926e200
if [ ! -f "$SRC/gcem/include/gcem.hpp" ]; then
  echo "vendoring gcem@$GCEM_REV (header-only CMake-required dependency)..."
  TMPZIP="$(mktemp)"
  TMPDIR_GCEM="$(mktemp -d)"
  curl -fsSL "https://github.com/kthohr/gcem/archive/${GCEM_REV}.zip" -o "$TMPZIP"
  unzip -q "$TMPZIP" -d "$TMPDIR_GCEM"
  mkdir -p "$SRC/gcem"
  cp -r "$TMPDIR_GCEM/gcem-${GCEM_REV}/include" "$SRC/gcem/include"
  rm -rf "$TMPZIP" "$TMPDIR_GCEM"
fi
[ -f "$SRC/gcem/include/gcem.hpp" ] || { echo "FATAL: gcem/include/gcem.hpp still missing after vendoring" >&2; exit 1; }

# CMake options shared by both configures: every audio/MIDI driver, SF3,
# signalsmith (needs its own submodule we don't vendor), D-Bus, LADSPA,
# readline, network, and OpenMP are all OFF -- our targets never open a
# device or render, so none of it is needed (see header comment).
COMMON_CMAKE_OPTS=(
  -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
  -DCMAKE_BUILD_TYPE=RelWithDebInfo
  -Denable-alsa=OFF -Denable-aufile=OFF -Denable-dbus=OFF -Denable-ipv6=OFF
  -Denable-jack=OFF -Denable-ladspa=OFF -Denable-libsndfile=OFF -Denable-midishare=OFF
  -Denable-network=OFF -Denable-oss=OFF -Denable-pulseaudio=OFF -Denable-pipewire=OFF
  -Denable-readline=OFF -Denable-sdl3=OFF -Denable-signalsmith=OFF -Denable-openmp=OFF
  -Denable-portaudio=OFF -Denable-opensles=OFF -Denable-oboe=OFF
)

SANDIR="$SRC/mayhem-build/sanitized"
NORMDIR="$SRC/mayhem-build/normal"
INC=(
  -I"$SANDIR" -I"$SANDIR/include"
  -I"$SRC" -I"$SRC/src" -I"$SRC/src/drivers" -I"$SRC/src/synth" -I"$SRC/src/rvoice"
  -I"$SRC/src/midi" -I"$SRC/src/utils" -I"$SRC/src/sfloader" -I"$SRC/src/bindings"
  -I"$SRC/include" -I"$SRC/gcem/include"
)

# ── 1) SANITIZED static libfluidsynth (fuzz harnesses link against this) ───
# A CMake configure/build (not a hand-rolled source list) so we automatically
# track upstream's own conditional file lists; -DBUILD_SHARED_LIBS=OFF gives
# us a plain .a to link into each harness. Written to its own build dir
# (mayhem-build/sanitized/), so it never collides with the NORMAL build (§3)
# that produces the oracle -- both configures/builds are naturally idempotent
# (CMake + make are mtime-driven), which is what makes the whole script safe
# to re-run on an already-built tree (SPEC 6.5).
cmake -S "$SRC" -B "$SANDIR" -G "Unix Makefiles" \
  "${COMMON_CMAKE_OPTS[@]}" \
  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
  -DBUILD_SHARED_LIBS=OFF
cmake --build "$SANDIR" --target libfluidsynth -j"$MAYHEM_JOBS"
LIBFLUID_SAN="$SANDIR/src/libfluidsynth.a"
[ -f "$LIBFLUID_SAN" ] || { echo "FATAL: sanitized libfluidsynth.a was not produced" >&2; exit 1; }

# Standalone driver object, built once, linked into every harness's -standalone binary.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c -x c "$STANDALONE_FUZZ_MAIN" -o "$SANDIR/standalone_main.o"

# ── 2) Build each harness TWICE: libFuzzer target -> /mayhem/<name>, standalone -> /mayhem/<name>-standalone ──
# clang++ drives the final link (not clang) because libfluidsynth.a contains
# C++ translation units (reverb/IIR-filter/sequencer bindings) that need
# libstdc++ -- even though both harnesses are plain C and only call
# FluidSynth's public/internal C API.
for h in fuzz_sf2 fuzz_midi; do
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "${INC[@]}" -c -x c "$SRC/mayhem/harnesses/$h.c" -o "$SANDIR/$h.o"

  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
      "$SANDIR/$h.o" "$LIBFLUID_SAN" -lpthread \
      -o "/mayhem/$h"

  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS \
      "$SANDIR/$h.o" "$SANDIR/standalone_main.o" "$LIBFLUID_SAN" -lpthread \
      -o "/mayhem/$h-standalone"

  echo "built $h (+ standalone)"
done

# ── 3) NORMAL build (separate dir, NORMAL flags, shared lib) -- the oracle ─
# Every audio/MIDI driver etc. stays off (same reasons as §1); NO sanitizer,
# NO -gdwarf-3 override here -- this is FluidSynth's own build as its authors
# ship it, which is what keeps mayhem/test.sh an honest functional oracle.
cmake -S "$SRC" -B "$NORMDIR" -G "Unix Makefiles" "${COMMON_CMAKE_OPTS[@]}"
# The `libfluidsynth` (shared) target is NOT a dependency of `check` -- every
# ADD_FLUID_TEST() executable links directly against the `libfluidsynth-OBJ`
# object library, not the `libfluidsynth` wrapper target, so `check` alone
# never produces libfluidsynth.so. Build it explicitly (the KAT probe below
# links against it).
cmake --build "$NORMDIR" --target libfluidsynth -j"$MAYHEM_JOBS"
# `check` builds every ADD_FLUID_TEST() executable (~40 small, EXCLUDE_FROM_ALL
# binaries) as a dependency and then runs ctest once as a side effect -- an
# extra safety net at image-build time. mayhem/test.sh re-runs ctest itself
# afresh (re-executing the same freshly-built binaries), so this doesn't
# violate "build.sh builds, test.sh runs": test.sh still does real work, and
# under the sabotage shim it observes the CURRENT (possibly neutered) process
# behavior, not a cached result from this step.
cmake --build "$NORMDIR" --target check -j"$MAYHEM_JOBS"
LIBFLUID_NORM="$NORMDIR/src/libfluidsynth.so"
[ -f "$LIBFLUID_NORM" ] || { echo "FATAL: normal libfluidsynth.so was not produced" >&2; exit 1; }

# ── 4) Direct KAT probe (see mayhem/test.sh for why ctest's own pass/fail is
# NOT sufficient as the sabotage-proof oracle) -- normal flags, dynamically
# linked against the NORMAL shared lib with an embedded rpath so test.sh
# doesn't need LD_LIBRARY_PATH plumbing. ─────────────────────────────────────
$CC "${INC[@]}" -I"$NORMDIR" -I"$NORMDIR/include" \
    "$SRC/mayhem/kat/kat_probe.c" \
    -L"$NORMDIR/src" -Wl,-rpath,"$NORMDIR/src" -lfluidsynth \
    -o "$SRC/kat_probe"
[ -x "$SRC/kat_probe" ] || { echo "FATAL: $SRC/kat_probe was not produced" >&2; exit 1; }

# Every runnable oracle binary MUST be dynamically linked so verify-repo's LD_PRELOAD sabotage
# shim can neuter it -- a statically-linked binary would survive sabotage and make
# mayhem/test.sh reward-hackable (SPEC 6.3). Plain clang/cc links dynamically by default;
# assert it so a toolchain change can't silently flip this and weaken the oracle.
for bin in "$SRC/kat_probe" "$NORMDIR/test/test_sfont_loading"; do
  if ! file "$bin" | grep -q 'dynamically linked'; then
    echo "FATAL: $bin is not dynamically linked -- the sabotage check could not neuter it," >&2
    echo "       which would make mayhem/test.sh a reward-hackable oracle." >&2
    file "$bin" >&2
    exit 1
  fi
done
echo "built kat_probe + confirmed the oracle binaries are dynamically linked"

echo "build.sh complete:"
ls -la /mayhem/fuzz_sf2 /mayhem/fuzz_midi \
       /mayhem/fuzz_sf2-standalone /mayhem/fuzz_midi-standalone \
       "$SRC/kat_probe" "$LIBFLUID_NORM" 2>&1 || true

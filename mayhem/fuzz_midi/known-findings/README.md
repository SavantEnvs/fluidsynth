# Known findings from `fuzz_midi`

Reproducer for a genuine upstream defect found within the first few thousand executions of a cold
`fuzz_midi` run. It lives HERE, not in `testsuite/`, on purpose -- committed seeds are replayed on
every run; a crashing seed would trip the sanitizer on every single run before any real fuzzing
happened.

## ubsan-shift-overflow-fluid_getlength.mid -- signed left-shift overflow in `fluid_getlength()`

- **Found:** 2026-08-17, by `fuzz_midi` within ~200 executions of a cold start (mutated from the
  harness's own 19-byte seed corpus, `testsuite/probe.mid`).
- **Location:** `src/midi/fluid_midi.c:435`, `fluid_getlength()`:
  ```c
  long
  fluid_getlength(const unsigned char *s)
  {
      long i = 0;
      i = s[3] | (s[2] << 8) | (s[1] << 16) | (s[0] << 24);
      return i;
  }
  ```
- **Cause:** `s[0]` is `unsigned char`, promoted to a (signed, 32-bit) `int` before the shift. When
  `s[0] >= 0x80` (as in this reproducer, `s[0] == 0x9d`), `s[0] << 24` sets the sign bit of a signed
  `int` via a shift whose result is not representable in the type -- undefined behavior per the C
  standard (C11 6.5.7p4), caught here by UBSan's `shift-base`/`signed-integer-overflow` check under
  `-fsanitize=undefined -fno-sanitize-recover=all`.
- **Reached from:** `fluid_midi_file_read_track()` -> the "skip an unrecognized chunk" path, which
  reads a 4-byte big-endian chunk length via `fluid_getlength()` for any RIFF-style sub-chunk in the
  SMF whose 4-byte ID is not literally `"MTrk"`.
- **Impact:** undefined behavior on attacker-controlled input reaching a widely embedded MIDI file
  parser (any application, plugin host, or game engine that loads untrusted `.mid` files through
  FluidSynth). On common two's-complement/UBSan-disabled builds this typically just produces a
  negative chunk length that is subsequently misused as a skip distance -- a further-reaching
  corruption is plausible but not required to trip the sanitizer; UBSan halts before that plays out,
  which is exactly the point of building the fuzz target with `-fsanitize=undefined
  -fno-sanitize-recover=all`.
- **A fix upstream would be one line:** perform the shift in an unsigned type, e.g.
  `i = (long)(((unsigned int)s[0] << 24) | ((unsigned int)s[1] << 16) | ((unsigned int)s[2] << 8) | s[3]);`
  (or use `fluid_isasciistring`-style explicit `(unsigned char)` casts before each shift).
- **Reproduce** (crashes immediately under ASan+UBSan):
  ```
  /mayhem/fuzz_midi-standalone mayhem/fuzz_midi/known-findings/ubsan-shift-overflow-fluid_getlength.mid
  ```
  Output:
  ```
  /mayhem/src/midi/fluid_midi.c:435:51: runtime error: left shift of 157 by 24 places cannot be represented in type 'int'
  SUMMARY: UndefinedBehaviorSanitizer: undefined-behavior /mayhem/src/midi/fluid_midi.c:435:51
  ```
- **Harness handling:** not guarded -- this is a normal crash the fuzzer recovers from (artifact
  recorded, process restarts, dedup keeps going), not a hang. Masking it with input validation the
  upstream code does not have would be reward-hacking our own coverage metric (see brief `6b`).

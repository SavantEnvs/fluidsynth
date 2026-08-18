/*
 * mayhem/kat/kat_probe.c -- direct known-answer-test probe for mayhem/test.sh.
 *
 * WHY THIS EXISTS (see mayhem/test.sh for the full story): FluidSynth's own
 * suite is ~40 separate ctest executables that each `abort()` on assertion
 * failure and otherwise fall off the end of main() with exit 0. Under the
 * gate's sabotage shim (LD_PRELOAD constructor that _exit(0)s every
 * non-system executable before main() runs), EVERY one of those binaries
 * "succeeds" -- ctest's own pass/fail bookkeeping is exit-code-only, so it
 * cannot tell "ran main() and returned 0" apart from "never reached main()".
 * That makes a test.sh built purely on `ctest` reward-hackable exactly like
 * the go-test/cargo-test static-binary trap, just via a different mechanism
 * (dynamic linking does not help if the judge is still just an exit code).
 *
 * This probe is deliberately judged differently: it PRINTS fixed-format
 * `KAT_<NAME>=<value>` lines that can only be produced by actually running
 * the real parsing code, and mayhem/test.sh greps the CAPTURED STDOUT TEXT
 * (via `grep -qxF`, from bash -- a whitelisted, non-neuterable interpreter)
 * for the exact expected lines. A neutered probe prints nothing at all, so
 * every `grep -qxF` fails and test.sh fails -- sabotage is caught by the
 * ABSENCE of expected text, not by trusting this binary's own exit code.
 *
 * Two independent known-answer checks, both parse-only (no audio render):
 *
 *  1. SF2 loader (fluid_synth_sfload over the real, upstream-shipped
 *     fixture sf2/VintageDreamsWaves-v2.sf2): asserts the exact preset
 *     count and the name of the first enumerated preset.
 *  2. SMF MIDI parser (fluid_player_add_mem over a hand-built, 19-byte,
 *     single-track MIDI file embedded below): asserts the exact division
 *     (from the MThd header) and total tick length (summed from the
 *     track's own delta-times) -- both computed purely by
 *     fluid_midi_file_load_tracks()/fluid_track_get_duration() during
 *     parsing, independent of any playback/render progress.
 */

#include <stdio.h>
#include <string.h>

#include "fluidsynth.h"

/* ---- 1) SF2 loader KAT ------------------------------------------------- */

static int run_sf2_kat(void)
{
    fluid_settings_t *settings = new_fluid_settings();

    if(settings == NULL)
    {
        printf("KAT_SF2_LOAD=FAIL_NO_SETTINGS\n");
        return 1;
    }

    fluid_synth_t *synth = new_fluid_synth(settings);

    if(synth == NULL)
    {
        printf("KAT_SF2_LOAD=FAIL_NO_SYNTH\n");
        delete_fluid_settings(settings);
        return 1;
    }

    /* Relative path -- test.sh runs us with cwd == $SRC (/mayhem), where the
     * upstream sf2/ directory (COPY'd in with everything else) lives. */
    int sfont_id = fluid_synth_sfload(synth, "sf2/VintageDreamsWaves-v2.sf2", 1);
    int rc = 0;

    if(sfont_id == FLUID_FAILED)
    {
        printf("KAT_SF2_LOAD=FAIL\n");
        rc = 1;
    }
    else
    {
        fluid_sfont_t *sfont = fluid_synth_get_sfont_by_id(synth, sfont_id);

        if(sfont == NULL)
        {
            printf("KAT_SF2_LOAD=FAIL_NO_SFONT\n");
            rc = 1;
        }
        else
        {
            int preset_count = 0;
            const char *first_name = NULL;

            fluid_sfont_iteration_start(sfont);
            fluid_preset_t *preset;

            while((preset = fluid_sfont_iteration_next(sfont)) != NULL)
            {
                if(preset_count == 0)
                {
                    first_name = fluid_preset_get_name(preset);
                }

                preset_count++;
            }

            printf("KAT_SF2_LOAD=OK\n");
            printf("KAT_SF2_PRESET_COUNT=%d\n", preset_count);
            printf("KAT_SF2_PRESET0_NAME=%s\n", first_name ? first_name : "(null)");
        }
    }

    delete_fluid_synth(synth);
    delete_fluid_settings(settings);
    return rc;
}

/* ---- 2) SMF MIDI parser KAT --------------------------------------------
 *
 * Hand-built Standard MIDI File, format 0, 1 track, division=96 ticks/quarter:
 *   MThd len=6 format=0 ntrks=1 division=96
 *   MTrk len=19
 *     delta=0   FF 51 03 09 27 C0     (meta: set tempo = 600000 us/quarter)
 *     delta=0   90 3C 64              (note on,  ch0, key 60, vel 100)
 *     delta=96  80 3C 00              (note off, ch0, key 60, vel 0)
 *     delta=0   FF 2F 00              (meta: end of track)
 * Total tick length (sum of deltas up to and including the last event) = 96.
 */
static const unsigned char kProbeMidi[] = {
    'M', 'T', 'h', 'd', 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x01, 0x00, 0x60,
    'M', 'T', 'r', 'k', 0x00, 0x00, 0x00, 0x13,
    0x00, 0xFF, 0x51, 0x03, 0x09, 0x27, 0xC0,
    0x00, 0x90, 0x3C, 0x64,
    0x60, 0x80, 0x3C, 0x00,
    0x00, 0xFF, 0x2F, 0x00,
};

static int run_midi_kat(void)
{
    fluid_settings_t *settings = new_fluid_settings();

    if(settings == NULL)
    {
        printf("KAT_MID_LOAD=FAIL_NO_SETTINGS\n");
        return 1;
    }

    fluid_settings_setstr(settings, "player.timing-source", "sample");

    fluid_synth_t *synth = new_fluid_synth(settings);

    if(synth == NULL)
    {
        printf("KAT_MID_LOAD=FAIL_NO_SYNTH\n");
        delete_fluid_settings(settings);
        return 1;
    }

    fluid_player_t *player = new_fluid_player(synth);
    int rc = 0;

    if(player == NULL)
    {
        printf("KAT_MID_LOAD=FAIL_NO_PLAYER\n");
        rc = 1;
    }
    else
    {
        fluid_player_set_loop(player, 1);
        fluid_player_add_mem(player, kProbeMidi, sizeof(kProbeMidi));
        fluid_player_play(player);

        /* Force the sample-timer callback to fire at least once -- this is
         * what triggers the actual parse (see fuzz_midi.c for the full
         * explanation). One tiny call is enough; the division/total-ticks
         * values are populated by the parse itself, not by playback
         * progress. */
        short buf[64];
        fluid_synth_write_s16(synth, 32, buf, 0, 2, buf, 1, 2);

        int division = fluid_player_get_division(player);
        int total_ticks = fluid_player_get_total_ticks(player);

        printf("KAT_MID_LOAD=OK\n");
        printf("KAT_MID_DIVISION=%d\n", division);
        printf("KAT_MID_TOTAL_TICKS=%d\n", total_ticks);

        fluid_player_stop(player);
        delete_fluid_player(player);
    }

    delete_fluid_synth(synth);
    delete_fluid_settings(settings);
    return rc;
}

int main(void)
{
    int rc = 0;
    rc |= run_sf2_kat();
    rc |= run_midi_kat();
    return rc;
}

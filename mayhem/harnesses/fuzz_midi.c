/*
 * mayhem/harnesses/fuzz_midi.c -- libFuzzer harness over FluidSynth's
 * Standard MIDI File parser (src/midi/fluid_midi.c: fluid_midi_file_read_*,
 * variable-length quantities, running status, meta events, sysex).
 *
 * IN-MEMORY ONLY: fluid_player_add_mem() takes ownership of a private copy
 * of the buffer -- no filesystem path is ever touched (SPEC 6.2 item 13 /
 * netnew-worker-prompt.md 3).
 *
 * PARSE, DO NOT RENDER (brief 6b): fluid_player_add_mem() only queues the
 * buffer; the actual SMF parse (fluid_midi_file_load_tracks ->
 * fluid_midi_file_read_track -> fluid_midi_file_read_event, which decodes
 * every VLQ delta-time, resolves running status, and reads meta/sysex
 * payloads for the WHOLE file up front into an in-memory track/event list)
 * only happens lazily, the first time the player's sample-timer callback
 * fires with no file loaded yet (fluid_player_callback -> load-on-demand
 * fluid_player_playlist_load -> fluid_player_load). We never attach a
 * SoundFont and never call a real audio driver -- we just need ONE tiny
 * fluid_synth_write_s16() call to advance the sample timer enough to fire
 * that first callback, which is what actually exercises the parser. We cap
 * the number of pumped render calls tightly (a few dozen frames total) so a
 * fuzzed tempo/looping MIDI file can never turn this into a real render --
 * we stop as soon as the player leaves the PLAYING state or the iteration
 * cap is hit, whichever comes first.
 */

#include <stddef.h>
#include <stdint.h>

#include "fluidsynth.h"

/* Keep the synth entirely off real time/threads: fluid_synth_write_s16()
 * drives the player's sample timer synchronously in-process. */
#define RENDER_FRAMES_PER_CALL 32
#define MAX_RENDER_CALLS 32

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if(size == 0)
    {
        return 0;
    }

    fluid_settings_t *settings = new_fluid_settings();

    if(settings == NULL)
    {
        return 0;
    }

    /* "sample" (the default) drives the player's clock from the audio
     * buffers we render ourselves, with no background thread -- keeps the
     * harness single-threaded and deterministic. Set explicitly so a future
     * upstream default change can't silently switch us to the real-time
     * system-timer path. */
    fluid_settings_setstr(settings, "player.timing-source", "sample");

    fluid_synth_t *synth = new_fluid_synth(settings);

    if(synth != NULL)
    {
        fluid_player_t *player = new_fluid_player(synth);

        if(player != NULL)
        {
            /* A single file, no looping -- one pass over the fuzzed bytes. */
            fluid_player_set_loop(player, 1);
            fluid_player_add_mem(player, data, size);
            fluid_player_play(player);

            short buf[RENDER_FRAMES_PER_CALL * 2]; /* stereo, interleaved */
            int i;

            for(i = 0; i < MAX_RENDER_CALLS; i++)
            {
                if(fluid_player_get_status(player) != FLUID_PLAYER_PLAYING)
                {
                    break;
                }

                fluid_synth_write_s16(synth, RENDER_FRAMES_PER_CALL,
                                       buf, 0, 2, buf, 1, 2);
            }

            fluid_player_stop(player);
            delete_fluid_player(player);
        }

        delete_fluid_synth(synth);
    }

    delete_fluid_settings(settings);
    return 0;
}

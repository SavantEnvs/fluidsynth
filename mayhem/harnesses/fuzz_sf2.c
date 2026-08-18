/*
 * mayhem/harnesses/fuzz_sf2.c -- libFuzzer harness over FluidSynth's SoundFont2
 * (.sf2) RIFF-chunk loader (src/sfloader/fluid_sffile.c + fluid_defsfont.c).
 *
 * This is the "richest surface" mentioned in the integration brief: the SF2
 * container is a RIFF-style chunk format with nested LIST chunks, an INFO
 * block, and the "sdta"/"pdta" hydra chunks that carry variable-length
 * preset/instrument/sample headers, generator and modulator lists, and the
 * raw PCM sample pool itself. `fluid_defsfont_load()` walks all of it: chunk
 * headers, preset/instrument/sample import (fluid_defpreset_import_sfont,
 * fluid_inst_import_sfont, fluid_sample_import_sfont), and finally the actual
 * sample PCM bytes via fluid_defsfont_load_all_sampledata() / the sample
 * cache -- so this harness exercises decode + preset-graph construction +
 * sample-data extraction with ZERO audio rendering.
 *
 * IN-MEMORY ONLY (SPEC 6.2 item 13 / netnew-worker-prompt.md 3): we register
 * a custom fluid_sfloader_t (fluid_sfloader_set_callbacks) whose open/read/
 * seek/tell/close operate purely on the fuzzer-provided byte buffer -- no
 * filesystem access at all, so there is no /dev/shm or relative-path
 * question for this target. We call the internal fluid_defsfloader_load()
 * directly (declared in the internal header src/sfloader/fluid_defsfont.h)
 * rather than going through fluid_synth_t/fluid_synth_sfload(), because that
 * skips creating an entire fluid_synth_t (audio engine, channels, voice
 * pool) for a pure parser fuzz target -- fluid_defsfloader_load() is exactly
 * what fluid_synth_sfload() calls internally once it has picked the default
 * loader, so this is a faithful, minimal harness over the real code path.
 *
 * Bounded / no rendering: nothing here ever calls a synth/voice/render
 * function, so there is no risk of a fuzzed "huge sample count" turning into
 * a long-running audio render loop (brief 6b) -- the worst case is bounded
 * by the input size (a malicious chunk can at most claim as many
 * presets/instruments/samples as fit self-consistently in the fuzzer's
 * buffer, since every read against our callbacks is bounds-checked and
 * fails past the end of the buffer).
 */

#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "fluidsynth.h"
#include "fluid_defsfont.h" /* internal: fluid_defsfloader_load(), fluid_defsfont_sfont_delete() */

/* The fuzzer hands us one buffer per call; the sfloader open callback only
 * receives a filename, so we stash the current input in file-scope statics.
 * The harness is single-threaded (libFuzzer runs one input at a time in a
 * given process), so this is safe. */
static const uint8_t *g_data;
static size_t g_size;
static size_t g_pos;

static void *mem_open(const char *filename)
{
    (void)filename;
    g_pos = 0;
    /* Any non-NULL, distinguishable value works as the "handle" -- we never
     * dereference it ourselves, only pass it back to our own callbacks. */
    return (void *)&g_pos;
}

static int mem_read(void *buf, fluid_long_long_t count, void *handle)
{
    (void)handle;

    if(count < 0)
    {
        return FLUID_FAILED;
    }

    if((fluid_long_long_t)(g_size - g_pos) < count)
    {
        /* Per the documented contract: leave buf unmodified on failure. */
        return FLUID_FAILED;
    }

    memcpy(buf, g_data + g_pos, (size_t)count);
    g_pos += (size_t)count;
    return FLUID_OK;
}

static int mem_seek(void *handle, fluid_long_long_t offset, int origin)
{
    fluid_long_long_t newpos;
    (void)handle;

    switch(origin)
    {
    case SEEK_SET:
        newpos = offset;
        break;
    case SEEK_CUR:
        newpos = (fluid_long_long_t)g_pos + offset;
        break;
    case SEEK_END:
        newpos = (fluid_long_long_t)g_size + offset;
        break;
    default:
        return FLUID_FAILED;
    }

    if(newpos < 0 || newpos > (fluid_long_long_t)g_size)
    {
        return FLUID_FAILED;
    }

    g_pos = (size_t)newpos;
    return FLUID_OK;
}

static fluid_long_long_t mem_tell(void *handle)
{
    (void)handle;
    return (fluid_long_long_t)g_pos;
}

static int mem_close(void *handle)
{
    (void)handle;
    return FLUID_OK;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
    if(size == 0)
    {
        return 0;
    }

    g_data = data;
    g_size = size;
    g_pos = 0;

    fluid_settings_t *settings = new_fluid_settings();

    if(settings == NULL)
    {
        return 0;
    }

    fluid_sfloader_t *loader = new_fluid_defsfloader(settings);

    if(loader != NULL)
    {
        fluid_sfloader_set_callbacks(loader, mem_open, mem_read, mem_seek, mem_tell, mem_close);

        fluid_sfont_t *sfont = fluid_defsfloader_load(loader, "mayhem-fuzz-input.sf2");

        if(sfont != NULL)
        {
            fluid_defsfont_sfont_delete(sfont);
        }

        delete_fluid_sfloader(loader);
    }

    delete_fluid_settings(settings);
    return 0;
}

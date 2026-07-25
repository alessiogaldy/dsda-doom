// Source lists from upstream src/CMakeLists.txt (libfluidsynth_SOURCES plus
// fluid_file_SOURCES). Headers are dropped.
//
// drivers/fluid_adriver.c and drivers/fluid_mdriver.c are the driver registries
// and are always compiled; with every enable-* option off their tables are
// empty, which is what we want -- dsda renders through fluid_synth_write_float
// and never opens a fluidsynth audio or MIDI device.
//
// The OSAL file is chosen in fluidsynth.zig: cpp11 rather than glib.

pub const c = [_][]const u8{
    "utils/fluid_conv.c",
    "utils/fluid_hash.c",
    "utils/fluid_list.c",
    "utils/fluid_ringbuffer.c",
    "utils/fluid_settings.c",
    "utils/fluid_sys.c",
    "sfloader/fluid_defsfont.c",
    "sfloader/fluid_sfont.c",
    "sfloader/fluid_sffile.c",
    "sfloader/fluid_samplecache.c",
    "rvoice/fluid_adsr_env.c",
    "rvoice/fluid_chorus.c",
    "rvoice/fluid_iir_filter.c",
    "rvoice/fluid_lfo.c",
    "rvoice/fluid_rvoice.c",
    "rvoice/fluid_rvoice_event.c",
    "rvoice/fluid_rvoice_mixer.c",
    "rvoice/fluid_rev.c",
    "synth/fluid_chan.c",
    "synth/fluid_event.c",
    "synth/fluid_gen.c",
    "synth/fluid_mod.c",
    "synth/fluid_synth.c",
    "synth/fluid_synth_monopoly.c",
    "synth/fluid_tuning.c",
    "synth/fluid_voice.c",
    "midi/fluid_midi.c",
    "midi/fluid_midi_router.c",
    "midi/fluid_seqbind.c",
    "midi/fluid_seq.c",
    "drivers/fluid_adriver.c",
    "drivers/fluid_mdriver.c",
    "bindings/fluid_cmd.c",
    "bindings/fluid_filerenderer.c",
    "bindings/fluid_ladspa.c",
};

pub const cpp = [_][]const u8{
    "gentables/fluid_ct2hz.cpp",
    "gentables/fluid_cb2amp.cpp",
    "gentables/fluid_concave.cpp",
    "gentables/fluid_convex.cpp",
    "gentables/fluid_pan.cpp",
    "gentables/fluid_interp_coeff.cpp",
    "gentables/fluid_interp_coeff_linear.cpp",
    "gentables/fluid_interp_coeff_sinc7.cpp",
    "rvoice/fluid_iir_filter_impl.cpp",
    "rvoice/fluid_rvoice_dsp.cpp",
    "midi/fluid_seqbind_notes.cpp",
    "midi/fluid_seq_queue.cpp",
    "utils/fluid_file.cpp",
};

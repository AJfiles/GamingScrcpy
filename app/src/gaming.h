#ifndef SC_GAMING_H
#define SC_GAMING_H

#include "common.h"

#include <stdbool.h>
#include <stdint.h>

#include <SDL3/SDL.h>

#include "coords.h"
#include "trait/frame_sink.h"
#include "util/thread.h"

struct AVFrame;
struct SwrContext;

/**
 * Host-side (PC-side) gaming presentation engine.
 *
 * Everything in this module operates on the picture after it has been decoded
 * on the host. It never changes the Android framebuffer, the capture size, or
 * the touch coordinate mapping, so game UI scaling and touch alignment stay
 * exactly as the device produces them.
 */

enum sc_osd_level {
    SC_OSD_OFF,
    SC_OSD_COMPACT, // fps + latency
    SC_OSD_FULL,    // fps, bitrate, latency, sizes, renderer
    SC_OSD_LEVEL_COUNT,
};

enum sc_upscale_filter {
    SC_UPSCALE_DEFAULT, // leave the SDL renderer default alone
    SC_UPSCALE_NEAREST, // 1:1 pixels, no additional latency
    SC_UPSCALE_LINEAR,  // bilinear, cheapest smooth filter
    SC_UPSCALE_PIXELART,    // highest quality path (anisotropic/bicubic)
};

// Runtime-usable post-processing filters, applied to the host copy of the
// decoded frame before it is uploaded to the GPU texture.
//
// Contrast, brightness and gamma share one 256-entry luma LUT with night-boost,
// so four of these filters still cost a single pass over the Y plane.
enum sc_postfx {
    SC_POSTFX_SHARPEN    = 1 << 0, // CAS-style luma sharpening
    SC_POSTFX_NIGHTBOOST = 1 << 1, // gamma + black level lift for dark games
    SC_POSTFX_SATURATION = 1 << 2, // colour grade strength
    SC_POSTFX_CONTRAST   = 1 << 3, // luma pivot around mid grey
    SC_POSTFX_BRIGHTNESS = 1 << 4, // luma offset
    SC_POSTFX_GAMMA      = 1 << 5, // luma transfer function
};

// The bitmap face the OSD paints with. Shared with the filter panel so the two
// windows use one typeface rather than two near-identical ones.
#define GLYPH_W 5
#define GLYPH_H 7
#define GLYPH_ADVANCE 6

// How many recent per-frame postfx costs are kept so the overlay's latency
// claim can be measured (nearest-rank percentiles) instead of asserted.
#define SC_POSTFX_SAMPLES 4096

#define SC_GAMING_MAX_TOUCH_POINTS 16
#define SC_GAMING_BRIDGE_QUEUE 2 // drop-oldest: the render path never blocks

struct sc_touch_point {
    float nx; // normalized [0..1] within the content rect
    float ny;
    bool active;
    sc_tick since; // used for the fade-out
};

enum sc_bridge_filter {
    SC_BRIDGE_FILTER_DEFAULT,  // bilinear, what the bridge used before
    SC_BRIDGE_FILTER_POINT,    // no interpolation
    SC_BRIDGE_FILTER_BILINEAR,
    SC_BRIDGE_FILTER_FAST_BILINEAR,
    SC_BRIDGE_FILTER_BICUBIC,  // true bicubic kernel
    SC_BRIDGE_FILTER_LANCZOS,  // true Lanczos(3) kernel
};

// High-quality resample of the frame that is actually presented, so the GPU
// blits 1:1 instead of stretching. Costs CPU on the render path, therefore
// off by default; the pointer mapping still uses the content rect, so touch
// alignment is unaffected.
enum sc_window_filter {
    SC_WINDOW_FILTER_OFF,
    SC_WINDOW_FILTER_POINT,
    SC_WINDOW_FILTER_BILINEAR,
    SC_WINDOW_FILTER_FAST_BILINEAR,
    SC_WINDOW_FILTER_BICUBIC,
    SC_WINDOW_FILTER_LANCZOS,
    SC_WINDOW_FILTER_COUNT,
};

struct sc_gaming_params {
    enum sc_osd_level osd;
    enum sc_upscale_filter upscale_filter;
    unsigned postfx;        // OR of enum sc_postfx
    unsigned sharpen;       // 0..100
    unsigned night_boost;   // 0..100
    unsigned saturation;    // 0..200, 100 = unchanged
    unsigned contrast;      // 0..200, 100 = unchanged (luma only)
    unsigned brightness;    // 0..200, 100 = unchanged (luma only)
    unsigned gamma;         // 25..200, 100 = unchanged (luma only)
    bool borderless_fullscreen;
    bool low_latency;       // disable presentation vsync
    bool telemetry_log;     // print the OSD numbers to stderr every second
    unsigned cursor_autohide_ms; // 0 = never hide
    bool touch_visualizer;
    bool always_on_top;
    const char *max_fps;    // CLI label shown in the OSD
    const char *frame_bridge; // path, '\\.\pipe\name' or '-' for stdout
    const char *audio_bridge;
    // host-side resample applied to the bridged/streamed frames only, so OBS
    // and encoders receive a clean 1080p/1440p/4K signal with a real
    // Lanczos/bicubic kernel. The mirrored window and its pointer mapping are
    // untouched.
    unsigned bridge_scale_w;
    unsigned bridge_scale_h;
    enum sc_bridge_filter bridge_filter;
    // Lanczos/bicubic resample of the presented frame (0 = off, GPU scaling)
    enum sc_window_filter window_filter;
    // real-time filter panel: a separate always-on-top window that changes the
    // grade above while the session runs. Off unless --game-filter-overlay.
    bool filter_overlay;
    bool filter_overlay_visible;   // open it at once instead of on the hotkey
    const char *overlay_hotkey;    // "super+alt+f"; NULL = the same default
    const char *overlay_profiles;  // profile file; NULL = nothing to save to
    bool overlay_spanish;          // label language of the panel itself
    // v4 §1.3: the grey-window failure mode is a session whose mirror never
    // presents a first frame. Give up loudly instead of hanging: milliseconds
    // to wait for that first frame, 0 = never give up.
    unsigned stall_timeout_ms;
};

struct sc_gaming {
    struct sc_gaming_params params;

    SDL_Window *window;
    SDL_Renderer *renderer;

    // --- first-frame watchdog ---
    SDL_Thread *stall_thread;
    SDL_AtomicInt stall_seen;   // set by the render path on the first frame
    SDL_AtomicInt stall_stop;   // set while the session is being torn down

    // --- OSD ---
    SDL_Surface *osd_surface;
    SDL_Texture *osd_texture;
    int osd_w;
    int osd_h;
    sc_tick osd_next_update;
    char osd_lines[4][96];
    unsigned osd_line_count;
    char max_fps_label[24];

    // --- telemetry ---
    uint64_t bytes_video;
    uint64_t bytes_audio;
    sc_tick telemetry_window_start;
    uint32_t kbps_video;
    uint32_t kbps_audio;
    // the byte totals that produced the two KB/s figures above, kept because an
    // integer KB/s reads 0 for a scene that really is quiet (a static screen
    // encoded as AV1 measured under 1 KB/s while presenting 30 fps), and a 0
    // alone cannot tell "quiet" from "nothing arrived".
    uint64_t bytes_window_video;
    uint64_t bytes_window_audio;
    unsigned rendered_frames;
    float fps;
    sc_tick fps_window_start;
    bool latency_known;
    uint32_t latency_ms;
    uint32_t latency_avg_ms;
    uint32_t latency_max_ms;
    // worst latency of each logged second, kept so the summary can give real
    // percentiles instead of only an exponential average
    uint32_t window_latency[128];
    unsigned window_latency_count;
    uint32_t window_lat_max;  // worst latency of the second being logged
    unsigned src_w;
    unsigned src_h;
    bool postfx_active;

    // receive timestamps pushed by the demuxer, popped once per rendered frame.
    // Used when the frame itself carries no recv date (video buffer disabled).
    sc_tick recv_fifo[128];
    unsigned recv_head;
    unsigned recv_count;

    // --- post processing ---
    struct AVFrame *work_frame; // host copy the filters may rewrite
    unsigned work_w;
    unsigned work_h;
    uint8_t *sharpen_tmp;
    uint8_t luma_lut[256];
    bool lut_valid;
    // false when the composed LUT is the identity: then the Y plane is left
    // alone instead of being walked for nothing
    bool lut_apply;

    // --- postfx cost census ---
    // the recent window of per-frame filter cost, so "the overlay must not
    // slow the mirror down" is a measurement and not a promise
    uint32_t postfx_us[SC_POSTFX_SAMPLES];
    unsigned postfx_us_count;
    unsigned postfx_us_head;   // ring position once the window is full
    uint64_t postfx_frames;    // frames filtered since the session started
    sc_tick postfx_total_us;

    // --- window resample (opt-in, render path) ---
    struct AVFrame *scaled_frame;
    struct SwsContext *win_sws;
    unsigned win_src_w;
    unsigned win_src_h;
    unsigned win_dst_w;   // current scaled_frame size
    unsigned win_dst_h;
    unsigned win_target_w; // requested content size, quantized
    unsigned win_target_h;
    bool win_broken;      // allocation failed: stay on the GPU path
    bool win_fmt_warned;  // the frames are not software YUV420P
    sc_tick win_total;
    uint64_t win_frames;
    uint64_t win_rebuilds;

    // --- window / display cache (refreshed by the event watch) ---
    SDL_FRect content_rect;
    float pixel_density;
    int window_x;
    int window_y;
    int window_w;
    int window_h;
    int display_x;
    int display_y;
    int display_w;
    int display_h;

    // --- touch visualizer ---
    struct sc_touch_point touches[SC_GAMING_MAX_TOUCH_POINTS];
    bool touch_visualizer_active;

    // --- cursor auto hide ---
    sc_tick cursor_last_move;
    bool cursor_hidden;

    // --- window state ---
    bool borderless_fullscreen_active;
    bool borderless_frame_checked; // one-time geometry diagnostic
    float content_aspect;     // video aspect, to re-lock the window on exit
    bool always_on_top_active;
    struct sc_size windowed_size;
    struct sc_point windowed_pos;
    bool windowed_size_saved;

    // --- bridges ---
    struct sc_byte_bridge *abridge;
    struct sc_video_bridge *vbridge;

    bool event_watch_installed;
};

bool
sc_gaming_init(struct sc_gaming *g, const struct sc_gaming_params *params,
               SDL_Window *window, SDL_Renderer *renderer);

void
sc_gaming_destroy(struct sc_gaming *g);

// The single active instance, used by the demuxer/audio hooks.
extern struct sc_gaming *sc_gaming_current;

// Quality of the host upscale applied to the video texture.
void
sc_gaming_apply_upscale(struct sc_gaming *g, SDL_Texture *texture);

// Called for every incoming elementary packet (demuxer thread).
void
sc_gaming_account_packet(struct sc_gaming *g, size_t size, bool video);

// Forward a raw (still encoded) audio packet to the audio bridge splitter.
void
sc_gaming_push_audio(struct sc_gaming *g, const uint8_t *data, size_t len);

// Copy a decoded audio frame to the PCM tap (--game-audio-pcm), converted to
// s16le / 48 kHz / stereo.
//
// It is a frame sink attached directly to the audio decoder, not a hook in the
// audio player, so the tap keeps working with --no-audio-playback: that is the
// useful "audio splitter" configuration (game audio only in the virtual cable,
// PC speakers silent). The sink is fed on the audio decoder thread and never
// blocks: like the other bridges it is drop-oldest.
struct sc_pcm_tap {
    struct sc_frame_sink frame_sink;
    struct sc_byte_bridge *bridge;
    struct SwrContext *swr;
    int in_rate;
    int in_channels;
    int in_format;
    uint8_t *buf;
    size_t buf_size;
    uint64_t pushed;
    bool broken;
};

// path is a file, "-" for stdout, or a \\.\pipe\ name. A NULL or empty path
// leaves the tap inert, so callers do not need to guard.
bool
sc_pcm_tap_init(struct sc_pcm_tap *tap, const char *path);

void
sc_pcm_tap_destroy(struct sc_pcm_tap *tap);

// Called on the audio decoder thread.
void
sc_pcm_tap_push(struct sc_pcm_tap *tap, const struct AVFrame *frame);

// Run the enabled filters on a decoded frame. Returns the frame to upload
// (either `frame` untouched, or the internal filtered copy), or NULL on error.
struct AVFrame *
sc_gaming_process_frame(struct sc_gaming *g, struct AVFrame *frame);

// Tell the engine how large the presented picture is, in device pixels of the
// window content area. Only used when --game-window-filter is enabled.
void
sc_gaming_set_window_target(struct sc_gaming *g, unsigned w, unsigned h);

// Resample a frame (post-filter or not) to that target with the configured
// high-quality kernel. Returns `frame` unchanged when disabled, when the size
// already matches, or if the resampler could not be set up.
struct AVFrame *
sc_gaming_resample_for_window(struct sc_gaming *g, struct AVFrame *frame);

// Called once per rendered frame: refreshes fps/latency/bitrate telemetry and
// feeds the frame bridge. `decoded` carries the receive timestamp, `output` is
// the frame actually presented (possibly the filtered copy) and is what gets
// bridged to OBS/FFmpeg.
void
sc_gaming_on_frame_rendered(struct sc_gaming *g, struct AVFrame *decoded,
                            struct AVFrame *output);

// Draw the OSD and the touch visualizer. Called from sc_screen_render() just
// before the frame is presented.
void
sc_gaming_render_overlay(struct sc_gaming *g, const SDL_FRect *content,
                         float pixel_density);

// Report a pointer/touch at a normalized position inside the content rect,
// used by the host-side touch visualizer.
void
sc_gaming_report_touch(struct sc_gaming *g, unsigned id, float nx, float ny,
                       bool down);

// Runtime toggles, bound to F1..F5 with the scrcpy shortcut modifier.
void
sc_gaming_toggle_osd(struct sc_gaming *g);
void
sc_gaming_toggle_borderless_fullscreen(struct sc_gaming *g);
// Re-assert the display-sized geometry after upstream has fitted the window to
// the video content. Does nothing while the mode is off.
void
sc_gaming_apply_borderless_geometry(struct sc_gaming *g);

// The aspect ratio the mirror window is normally locked to, remembered so that
// leaving borderless fullscreen restores it.
void
sc_gaming_note_content_aspect(struct sc_gaming *g, float aspect);

bool
sc_gaming_borderless_fullscreen_active(const struct sc_gaming *g);
void
sc_gaming_toggle_touch_visualizer(struct sc_gaming *g);
void
sc_gaming_toggle_cursor(struct sc_gaming *g);
void
sc_gaming_toggle_always_on_top(struct sc_gaming *g);

// Change the colour grade while a session is running. The engine rebuilds its
// one shared luma table on the next frame and applies it in the pass that is
// already there, so a slider costs a table build and nothing else: no new
// render pass, no new texture, no re-opened decoder. Call it from the thread
// that pumps SDL events, which is the thread that filters frames.
void
sc_gaming_set_postfx_grade(struct sc_gaming *g, const struct sc_gaming_params *p);

// The grade in effect right now, so a control panel shows reality instead of
// the flags the process was started with.
const struct sc_gaming_params *
sc_gaming_get_params(const struct sc_gaming *g);

// Rows of the 5x7 face, for anything that must draw text like the OSD does.
const uint8_t *
sc_gaming_glyph(char c);

#endif

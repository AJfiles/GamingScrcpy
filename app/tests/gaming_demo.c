// gaming_demo: host-side validation harness for the gaming presentation
// engine (app/src/gaming.c).
//
// It drives the real code path - post-processing, upscale filter selection, OSD
// overlay, touch visualizer, borderless-fullscreen toggle and both bridges -
// with synthetic YUV420P frames, so the engine can be verified on a machine
// without an Android device attached.
//
//   gamingdemo --frames=120 --width=720 --height=1280 --fx
//              --bridge=out.raw --audio=out.pcm --shot=shot.bmp

#include <inttypes.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <SDL3/SDL.h>
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libavutil/mem.h>
#include <libavutil/pixfmt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#include "gaming.h"
#include "overlay.h"
#include "util/log.h"
#include "util/tick.h"

#define BYTES_PER_FRAME_VIDEO (1920 * 1080 / 2) // fake packet size for bitrate

// one audio bridge packet sized to match a 60 fps video feed: 800 stereo
// frames of s16le at 48 kHz (16.7 ms), i.e. exactly what --audio-codec=raw
// carries on the wire
#define SINE_SAMPLES 800
#define SINE_BYTES (SINE_SAMPLES * 2 * 2)

static void
fill_pattern(AVFrame *f, unsigned frame_no, unsigned w, unsigned h) {
    // luma: a diagonal gradient plus a moving sharp bar, so sharpening,
    // shadow lift and scaling filters are all visible on screen
    for (unsigned y = 0; y < h; ++y) {
        uint8_t *row = f->data[0] + (size_t) y * f->linesize[0];
        for (unsigned x = 0; x < w; ++x) {
            uint8_t v = (uint8_t) ((x + y + frame_no * 4) & 0xFF);
            // keep most of the picture dark to exercise night-boost
            if (((x / 8) + (y / 8) + frame_no / 8) % 4) {
                v = (uint8_t) (v / 8);
            }
            row[x] = v;
        }
    }
    unsigned bx = (frame_no * 9) % (w - 40);
    for (unsigned y = h / 3; y < h / 3 + 120 && y < h; ++y) {
        uint8_t *row = f->data[0] + (size_t) y * f->linesize[0];
        memset(row + bx, 250, 40);
    }
    // chroma: static color bars
    for (unsigned y = 0; y < h / 2; ++y) {
        uint8_t *u = f->data[1] + (size_t) y * f->linesize[1];
        uint8_t *v = f->data[2] + (size_t) y * f->linesize[2];
        for (unsigned x = 0; x < w / 2; ++x) {
            u[x] = (uint8_t) (128 + 60 * (((x / (w / 16)) + y) % 3));
            v[x] = (uint8_t) (128 - 50 * (((x / (w / 16)) * 2 + y) % 3));
        }
    }
}

// Pixel-level readout of a frame: mean luma plus the spread of both chroma
// planes. tools/fx_pixel_test.sh compares these between a neutral run and a
// run with one filter moved, so "the contrast flag reaches the pixels" is a
// measurement and not a code read.
struct fx_stats {
    double luma_mean;
    double luma_var;
    double chroma_var;
};

static struct fx_stats
measure(const AVFrame *f) {
    struct fx_stats s = {0.0, 0.0, 0.0};
    unsigned w = f->width;
    unsigned h = f->height;
    double sum = 0.0, sq = 0.0;
    for (unsigned y = 0; y < h; ++y) {
        const uint8_t *row = f->data[0] + (size_t) y * f->linesize[0];
        for (unsigned x = 0; x < w; ++x) {
            sum += row[x];
            sq += (double) row[x] * row[x];
        }
    }
    double yn = (double) w * h;
    s.luma_mean = sum / yn;
    s.luma_var = sq / yn - s.luma_mean * s.luma_mean;

    unsigned cw = w / 2;
    unsigned ch = h / 2;
    double su = 0.0, sv = 0.0, qu = 0.0, qv = 0.0;
    for (unsigned y = 0; y < ch; ++y) {
        const uint8_t *u = f->data[1] + (size_t) y * f->linesize[1];
        const uint8_t *v = f->data[2] + (size_t) y * f->linesize[2];
        for (unsigned x = 0; x < cw; ++x) {
            su += u[x];
            sv += v[x];
            qu += (double) u[x] * u[x];
            qv += (double) v[x] * v[x];
        }
    }
    double n = (double) cw * ch;
    double mu = su / n;
    double mv = sv / n;
    s.chroma_var = (qu / n - mu * mu) + (qv / n - mv * mv);
    return s;
}

// Encode one filtered YUV420P frame to PNG for visual inspection.
static bool
save_png(const AVFrame *src, const char *path) {
    bool ok = false;
    char err[128];
    const AVCodec *enc = avcodec_find_encoder_by_name("png");
    AVCodecContext *c = enc ? avcodec_alloc_context3(enc) : NULL;
    AVFrame *pic = NULL;
    AVPacket *pkt = NULL;
    struct SwsContext *sws = NULL;
    FILE *fp = NULL;

    if (!c) {
        LOGE("png: no encoder available");
        goto done;
    }
    c->width = src->width;
    c->height = src->height;
    c->pix_fmt = AV_PIX_FMT_RGB24;
    // even a single-image encoder refuses to open without one
    c->time_base = (AVRational) { 1, 1 };
    int rc = avcodec_open2(c, enc, NULL);
    if (rc < 0) {
        av_strerror(rc, err, sizeof(err));
        LOGE("png: open failed: %s", err);
        goto done;
    }
    pic = av_frame_alloc();
    pic->format = AV_PIX_FMT_RGB24;
    pic->width = src->width;
    pic->height = src->height;
    if (av_frame_get_buffer(pic, 32) < 0) {
        LOGE("png: frame alloc failed");
        goto done;
    }
    sws = sws_getContext(src->width, src->height, AV_PIX_FMT_YUV420P,
                         src->width, src->height, AV_PIX_FMT_RGB24,
                         SWS_BILINEAR, NULL, NULL, NULL);
    pkt = av_packet_alloc();
    fp = fopen(path, "wb");
    if (!sws || !pkt || !fp) {
        LOGE("png: could not set up the dump for '%s'", path);
        goto done;
    }
    sws_scale(sws, (const uint8_t * const *) src->data, src->linesize, 0,
              src->height, pic->data, pic->linesize);
    if (avcodec_send_frame(c, pic) < 0) {
        LOGE("png: encode failed");
        goto done;
    }
    // an image encoder emits its one packet without needing a flush
    if (avcodec_receive_packet(c, pkt) == 0 && pkt->size > 0) {
        ok = fwrite(pkt->data, 1, pkt->size, fp) == (size_t) pkt->size;
        av_packet_unref(pkt);
    }

done:
    if (fp) {
        fclose(fp);
    }
    av_packet_free(&pkt);
    av_frame_free(&pic);
    sws_freeContext(sws);
    avcodec_free_context(&c);
    return ok;
}

int
main(int argc, char *argv[]) {
    unsigned frames = 120;
    unsigned w = 720;
    unsigned h = 1280;
    bool fx = false;
    const char *bridge = NULL;
    const char *audiobridge = NULL;
    const char *pcmtap = NULL;
    const char *shot = NULL;
    const char *driver = NULL;
    unsigned bscale_w = 0;
    unsigned bscale_h = 0;
    enum sc_bridge_filter bfilter = SC_BRIDGE_FILTER_DEFAULT;
    enum sc_window_filter wfilter = SC_WINDOW_FILTER_OFF;
    unsigned win_w = 0;
    unsigned win_h = 0;
    bool osd = true;
    // --bytes-video=: the per-packet size fed to the telemetry counter. The
    // default is a real picture; 9 makes a window quieter than 1 KB/s, which is
    // the AV1-static case that issue #44 had to be read out of a live device.
    size_t bytes_video = BYTES_PER_FRAME_VIDEO;
    bool sine = false;
    // per-filter values for --stats runs; the defaults keep the original
    // --fx behaviour (sharpen 60, night 40, sat 140) byte for byte
    unsigned fx_sharp = 60;
    unsigned fx_night = 40;
    unsigned fx_sat = 140;
    unsigned fx_contrast = 100;
    unsigned fx_bright = 100;
    unsigned fx_gamma = 100;
    unsigned fx_only = 0;
    bool stats = false;
    const char *png = NULL;
    // the real-time filter panel, driven here so gate 18 can compare a frame's
    // postfx cost with the panel open against the cost without it
    bool overlay = false;
    bool overlay_visible = false;
    const char *overlay_profiles = NULL;
    bool overlay_english = false;
    unsigned overlay_pulse = 0;
    unsigned overlay_toggle = 0;
    const char *overlay_shot = NULL;
    const char *overlay_hotkey = NULL;

    for (int i = 1; i < argc; ++i) {
        if (!strncmp(argv[i], "--frames=", 9)) {
            frames = (unsigned) atoi(argv[i] + 9);
        } else if (!strncmp(argv[i], "--width=", 8)) {
            w = (unsigned) atoi(argv[i] + 8);
        } else if (!strncmp(argv[i], "--height=", 9)) {
            h = (unsigned) atoi(argv[i] + 9);
        } else if (!strcmp(argv[i], "--fx")) {
            fx = true;
        } else if (!strncmp(argv[i], "--bridge=", 9)) {
            bridge = argv[i] + 9;
        } else if (!strncmp(argv[i], "--bridge-scale=", 15)) {
            if (sscanf(argv[i] + 15, "%ux%u", &bscale_w, &bscale_h) != 2) {
                LOGE("bad --bridge-scale (expected WxH)");
                return 2;
            }
        } else if (!strncmp(argv[i], "--bridge-filter=", 16)) {
            const char *f = argv[i] + 16;
            static const char *const NAMES[] = {"default", "point", "bilinear",
                                                "fast", "bicubic", "lanczos"};
            bool found = false;
            for (unsigned k = 0; k < sizeof(NAMES) / sizeof(*NAMES); ++k) {
                if (!strcmp(f, NAMES[k])) {
                    bfilter = (enum sc_bridge_filter) k;
                    found = true;
                    break;
                }
            }
            if (!found) {
                LOGE("bad --bridge-filter: %s", f);
                return 2;
            }
        } else if (!strncmp(argv[i], "--window-filter=", 16)) {
            const char *f = argv[i] + 16;
            static const char *const WNAMES[] = {"off", "point", "bilinear",
                                                 "fast", "bicubic", "lanczos"};
            bool found = false;
            for (unsigned k = 0; k < sizeof(WNAMES) / sizeof(*WNAMES); ++k) {
                if (!strcmp(f, WNAMES[k])) {
                    wfilter = (enum sc_window_filter) k;
                    found = true;
                    break;
                }
            }
            if (!found) {
                LOGE("bad --window-filter: %s", f);
                return 2;
            }
        } else if (!strncmp(argv[i], "--win-size=", 11)) {
            if (sscanf(argv[i] + 11, "%ux%u", &win_w, &win_h) != 2 || !win_w
                    || !win_h) {
                LOGE("bad --win-size (expected WxH)");
                return 2;
            }
        } else if (!strncmp(argv[i], "--audio=", 8)) {
            audiobridge = argv[i] + 8;
        } else if (!strncmp(argv[i], "--pcm-tap=", 10)) {
            pcmtap = argv[i] + 10;
        } else if (!strncmp(argv[i], "--shot=", 7)) {
            shot = argv[i] + 7;
        } else if (!strncmp(argv[i], "--png=", 6)) {
            png = argv[i] + 6;
        } else if (!strcmp(argv[i], "--stats")) {
            stats = true;
        } else if (!strncmp(argv[i], "--fx-sharp=", 11)) {
            fx_sharp = (unsigned) atoi(argv[i] + 11);
        } else if (!strncmp(argv[i], "--fx-night=", 11)) {
            fx_night = (unsigned) atoi(argv[i] + 11);
        } else if (!strncmp(argv[i], "--fx-sat=", 9)) {
            fx_sat = (unsigned) atoi(argv[i] + 9);
        } else if (!strncmp(argv[i], "--fx-contrast=", 14)) {
            fx_contrast = (unsigned) atoi(argv[i] + 14);
        } else if (!strncmp(argv[i], "--fx-bright=", 12)) {
            fx_bright = (unsigned) atoi(argv[i] + 12);
        } else if (!strncmp(argv[i], "--fx-gamma=", 11)) {
            fx_gamma = (unsigned) atoi(argv[i] + 11);
        } else if (!strncmp(argv[i], "--fx-only=", 10)) {
            static const char *const FN[] = {"sharp", "night", "sat",
                                             "contrast", "bright", "gamma"};
            static const unsigned FB[] = {SC_POSTFX_SHARPEN,
                                          SC_POSTFX_NIGHTBOOST,
                                          SC_POSTFX_SATURATION,
                                          SC_POSTFX_CONTRAST,
                                          SC_POSTFX_BRIGHTNESS,
                                          SC_POSTFX_GAMMA};
            char *dup = strdup(argv[i] + 10);
            char *saveptr = NULL;
            bool bad = false;
            for (char *tok = strtok_r(dup, ",", &saveptr); tok;
                 tok = strtok_r(NULL, ",", &saveptr)) {
                bool found = false;
                for (unsigned k = 0; k < sizeof(FN) / sizeof(*FN); ++k) {
                    if (!strcmp(tok, FN[k])) {
                        fx_only |= FB[k];
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    LOGE("bad --fx-only filter: %s", tok);
                    bad = true;
                }
            }
            free(dup);
            if (bad) {
                return 2;
            }
        } else if (!strncmp(argv[i], "--driver=", 9)) {
            driver = argv[i] + 9;
        } else if (!strncmp(argv[i], "--bytes-video=", 14)) {
            bytes_video = strtoull(&argv[i][14], NULL, 10);
            if (!bytes_video) {
                LOGE("bytes-video must be at least 1");
                return 1;
            }
        } else if (!strcmp(argv[i], "--no-osd")) {
            osd = false;
        } else if (!strcmp(argv[i], "--audio-sine")) {
            sine = true;
        } else if (!strcmp(argv[i], "--overlay")) {
            overlay = true;
        } else if (!strcmp(argv[i], "--overlay-visible")) {
            overlay = overlay_visible = true;
        } else if (!strncmp(argv[i], "--overlay-pulse=", 16)) {
            overlay = true;
            overlay_pulse = (unsigned) atoi(argv[i] + 16);
        } else if (!strncmp(argv[i], "--overlay-toggle=", 17)) {
            overlay = true;
            overlay_toggle = (unsigned) atoi(argv[i] + 17);
        } else if (!strncmp(argv[i], "--overlay-profiles=", 19)) {
            overlay = true;
            overlay_profiles = argv[i] + 19;
        } else if (!strcmp(argv[i], "--overlay-english")) {
            overlay_english = true;
        } else if (!strncmp(argv[i], "--overlay-shot=", 15)) {
            overlay = true;
            overlay_shot = argv[i] + 15;
        } else if (!strncmp(argv[i], "--overlay-hotkey=", 17)) {
            overlay = true;
            overlay_hotkey = argv[i] + 17;
        } else if (!strcmp(argv[i], "--help")) {
            printf("usage: gamingdemo [--frames=N] [--width=W] [--height=H]"
                   " [--fx] [--bridge=file] [--bridge-scale=WxH]"
                   " [--bridge-filter=default|point|bilinear|fast|bicubic|lanczos]"
                   " [--window-filter=off|point|bilinear|fast|bicubic|lanczos]"
                   " [--win-size=WxH] [--audio=file] [--audio-sine]"
                   " [--pcm-tap=file] [--shot=file.bmp] [--png=file.png]"
                   " [--stats] [--fx-only=sharp,night,sat,contrast,bright,gamma]"
                   " [--fx-sharp=N] [--fx-night=N] [--fx-sat=N]"
                   " [--fx-contrast=N] [--fx-bright=N] [--fx-gamma=N]"
                   " [--driver=direct3d11|opengl|vulkan] [--no-osd]"
                   " [--overlay [--overlay-visible] [--overlay-english]"
                   " [--overlay-pulse=N] [--overlay-toggle=N]"
                   " [--overlay-hotkey=super+alt+f]"
                   " [--overlay-shot=file.bmp]"
                   " [--overlay-profiles=file]]\n");
            return 0;
        }
    }

    if (driver) {
        SDL_SetHint(SDL_HINT_RENDER_DRIVER, driver);
    }
    if (!SDL_Init(SDL_INIT_VIDEO)) {
        LOGE("SDL_Init failed: %s", SDL_GetError());
        return 1;
    }

    SDL_Window *window =
        SDL_CreateWindow("gamingdemo", (int) w / 2, (int) h / 2,
                         SDL_WINDOW_HIGH_PIXEL_DENSITY |
                         SDL_WINDOW_RESIZABLE | SDL_WINDOW_ALWAYS_ON_TOP);
    if (!window) {
        LOGE("SDL_CreateWindow failed: %s", SDL_GetError());
        SDL_Quit();
        return 1;
    }
    SDL_Renderer *renderer = SDL_CreateRenderer(window, NULL);
    if (!renderer) {
        LOGE("SDL_CreateRenderer failed: %s", SDL_GetError());
        return 1;
    }
    SDL_SetWindowTitle(window, "GamingScrcpy presentation engine demo");
    if (win_w && win_h) {
        // measure a specific presentation size (e.g. a 4K monitor) without
        // having to drag the window by hand
        SDL_SetWindowSize(window, (int) win_w, (int) win_h);
    }
    SDL_ShowWindow(window);

    struct sc_gaming_params params = {
        .osd = osd ? SC_OSD_FULL : SC_OSD_OFF,
        .upscale_filter = SC_UPSCALE_PIXELART,
        .sharpen = fx_sharp,
        .night_boost = fx_night,
        .saturation = fx_sat,
        .contrast = fx_contrast,
        .brightness = fx_bright,
        .gamma = fx_gamma,
        .low_latency = true,
        .cursor_autohide_ms = 0,
        .touch_visualizer = true,
        .max_fps = "120",
        .frame_bridge = bridge,
        .audio_bridge = audiobridge,
        .bridge_scale_w = bscale_w,
        .bridge_scale_h = bscale_h,
        .bridge_filter = bfilter,
        .window_filter = wfilter,
    };
    bool fx_active = fx || fx_only;
    if (fx_only) {
        // isolate one filter for the pixel assertions
        params.postfx = fx_only;
    } else if (fx) {
        params.postfx = SC_POSTFX_SHARPEN | SC_POSTFX_NIGHTBOOST
                      | SC_POSTFX_SATURATION;
    }

    struct fx_stats in_stats = {0.0, 0.0, 0.0};
    struct fx_stats out_stats = {0.0, 0.0, 0.0};
    bool have_stats = false;
    bool png_written = false;

    struct sc_pcm_tap tap;
    if (!sc_pcm_tap_init(&tap, pcmtap)) {
        LOGE("sc_pcm_tap_init failed");
        return 1;
    }

    struct sc_gaming g;
    if (!sc_gaming_init(&g, &params, window, renderer)) {
        LOGE("sc_gaming_init failed");
        return 1;
    }
    LOGI("renderer backend: %s", SDL_GetRendererName(renderer));

    struct sc_gaming_overlay *ov = NULL;
    if (overlay) {
        struct sc_gaming_overlay_params op = {
            .title = "gamingdemo filter panel",
            .spanish = !overlay_english,
            .start_visible = overlay_visible,
            .hotkey = overlay_hotkey,
            .profiles_path = overlay_profiles,
            .parent = window,
        };
        ov = sc_gaming_overlay_create(&g, &op);
        if (!ov) {
            LOGE("the filter panel could not be created");
            return 1;
        }
    }
    unsigned ov_pulses = 0;
    unsigned ov_toggles = 0;
    unsigned ov_ticks = 0;
    unsigned ov_repaints = 0;
    sc_tick ov_tick_total = 0;
    sc_tick ov_tick_max = 0;

    // staging: an AVFrame the engine can rewrite, and an RGBA upload buffer
    AVFrame *frame = av_frame_alloc();
    frame->format = AV_PIX_FMT_YUV420P;
    frame->width = w;
    frame->height = h;
    if (av_frame_get_buffer(frame, 32) < 0) {
        LOGE("frame alloc failed");
        return 1;
    }
    uint8_t *rgba = malloc((size_t) w * h * 4);
    if (!rgba) {
        LOGE("rgba alloc failed");
        return 1;
    }
    uint8_t *rgba_planes[4] = { rgba, NULL, NULL, NULL };
    int rgba_stride[4] = { (int) w * 4, 0, 0, 0 };
    struct SwsContext *sws = sws_getContext(w, h, AV_PIX_FMT_YUV420P,
                                            w, h, AV_PIX_FMT_BGRA,
                                            SWS_BILINEAR, NULL, NULL, NULL);
    SDL_Texture *tex = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888,
                                         SDL_TEXTUREACCESS_STREAMING, w, h);
    if (!sws || !tex) {
        LOGE("demo setup failed: %s", SDL_GetError());
        return 1;
    }

    sc_tick fx_total = 0;
    sc_tick fx_max = 0;
    // a deliberately awkward input format for the PCM tap: 44.1 kHz mono FLT,
    // which the tap must convert to 48 kHz stereo s16le
    AVFrame *af = NULL;
    if (pcmtap) {
        af = av_frame_alloc();
        af->format = AV_SAMPLE_FMT_FLT;
        av_channel_layout_default(&af->ch_layout, 1);
        af->sample_rate = 44100;
        af->nb_samples = 882; // 20 ms
        if (av_frame_get_buffer(af, 0) < 0) {
            LOGE("audio frame alloc failed");
            return 1;
        }
        float *s = (float *) af->data[0];
        for (int k = 0; k < af->nb_samples; ++k) {
            s[k] = 0.5f * (float) sin(2.0 * M_PI * 1000.0 * k / 44100.0);
        }
    }
    uint8_t sine_packet[SINE_BYTES];
    if (sine) {
        // 1 kHz tone, both channels identical: decodable by ffmpeg as
        // -f s16le -ar 48000 -ac 2, and its length must match the video
        for (int k = 0; k < SINE_SAMPLES; ++k) {
            int16_t v = (int16_t) (12000.0 * sin(2.0 * M_PI * 1000.0 * k
                                                 / 48000.0));
            memcpy(sine_packet + k * 4, &v, sizeof(v));
            memcpy(sine_packet + k * 4 + 2, &v, sizeof(v));
        }
    }
    unsigned processed = 0;
    // frames actually handed to the GPU: `processed` only counts the post-FX
    // path, so it cannot measure presentation (without --fx it stays 0 and the
    // rate reads as "no frames presented" even for a perfect run)
    unsigned presented = 0;
    // the demo mirrors sc_texture_update(): the buffers follow the presented size
    unsigned tex_w = w;
    unsigned tex_h = h;
    unsigned seen_w = 0;
    unsigned seen_h = 0;
    unsigned distinct_sizes = 0;
    unsigned tex_rebuilds = 0;
    sc_tick loop_start = sc_tick_now();
    bool ok = true;

    for (unsigned i = 0; i < frames && ok; ++i) {
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
            if (ev.type == SDL_EVENT_QUIT) {
                i = frames;
            }
        }
        if (ov) {
            // exactly what the real client does: the panel is pumped from the
            // event loop, never from inside a frame. Idle it costs a flag test.
            sc_tick p0 = sc_tick_now();
            sc_gaming_overlay_tick();
            sc_tick pcost = sc_tick_now() - p0;
            ++ov_ticks;
            ov_tick_total += pcost;
            if (pcost > ov_tick_max) {
                ov_tick_max = pcost;
            }
            if (pcost > 200) {
                // a 496x400 software repaint is far above that, an idle tick
                // far below, so this counts repaints without guessing
                ++ov_repaints;
            }
            if (overlay_pulse && i && i % overlay_pulse == 0) {
                static const int DELTA[] = {15, -15, 40, -40, 5, -5, 25};
                int d = DELTA[ov_pulses % (sizeof(DELTA) / sizeof(DELTA[0]))];
                sc_gaming_overlay_demo_pulse(d);
                ++ov_pulses;
                // every delta here keeps contrast inside 0..200 without
                // clamping, so the engine must show exactly neutral + d
                if ((int) g.params.contrast != 100 + d) {
                    LOGE("overlay: pulse %+d did not reach the engine (got %u)",
                         d, g.params.contrast);
                    ok = false;
                }
            }
            if (overlay_toggle && i && i % overlay_toggle == 0) {
                unsigned before = g.params.contrast;
                // the same path the global hotkey takes
                sc_gaming_overlay_toggle(ov);
                ++ov_toggles;
                if (g.params.contrast != before) {
                    // show/hide must not touch the grade, or the latency run
                    // with the panel open would not be like for like
                    LOGE("overlay: a toggle changed the grade (%u -> %u)",
                         before, g.params.contrast);
                    ok = false;
                }
            }
        }

        av_frame_make_writable(frame);
        fill_pattern(frame, i, w, h);

        // simulate the demuxer: packet arrival feeds bitrate + latency
        sc_gaming_account_packet(&g, bytes_video, true);
        if (af) {
            sc_pcm_tap_push(&tap, af);
        }
        if (sine) {
            // a real 48 kHz stereo s16le stream (what scrcpy --audio-codec=raw
            // produces), so a consumer can decode and mux the audio bridge
            sc_gaming_push_audio(&g, sine_packet, sizeof(sine_packet));
            sc_gaming_account_packet(&g, sizeof(sine_packet), false);
        } else if (i % 2) {
            static uint8_t audio_packet[200];
            sc_gaming_account_packet(&g, sizeof(audio_packet), false);
            sc_gaming_push_audio(&g, audio_packet, sizeof(audio_packet));
        }
        sc_tick t0 = sc_tick_now();
        struct AVFrame *out = sc_gaming_process_frame(&g, frame);
        sc_tick cost = sc_tick_now() - t0;
        if (fx_active && out != frame) {
            fx_total += cost;
            if (cost > fx_max) {
                fx_max = cost;
            }
            ++processed;
        }
        if (stats && i == 0 && out) {
            // frame 0 is deterministic (fill_pattern is seeded by the index),
            // so the numbers below are comparable between runs
            in_stats = measure(frame);
            out_stats = measure(out);
            have_stats = true;
            if (png) {
                png_written = save_png(out, png);
                if (!png_written) {
                    LOGE("png dump failed");
                    ok = false;
                }
            }
        }
        if (!out) {
            LOGE("process_frame failed");
            ok = false;
            break;
        }

        // geometry first: exactly the sc_screen maths, so the resample target
        // is the content area in device pixels
        float density = SDL_GetWindowPixelDensity(window);
        if (density <= 0) {
            density = 1;
        }
        int ww = (int) w, hh = (int) h;
        SDL_GetWindowSize(window, &ww, &hh);
        float scale = density;
        float ratio = (float) w / h;
        SDL_FRect rect;
        rect.h = (float) hh;
        rect.w = rect.h * ratio;
        rect.x = (ww - rect.w) / 2.f;
        rect.y = 0;
        if (rect.w > ww) {
            rect.w = (float) ww;
            rect.h = rect.w / ratio;
            rect.y = (hh - rect.h) / 2.f;
        }
        SDL_FRect geom = { .x = rect.x * scale, .y = rect.y * scale,
                           .w = rect.w * scale, .h = rect.h * scale };

        sc_gaming_set_window_target(&g, (unsigned) (rect.w * scale),
                                    (unsigned) (rect.h * scale));
        struct AVFrame *pres = sc_gaming_resample_for_window(&g, out);
        if (!pres) {
            LOGE("resample_for_window failed");
            ok = false;
            break;
        }
        unsigned pw = (unsigned) pres->width;
        unsigned ph = (unsigned) pres->height;
        if (wfilter != SC_WINDOW_FILTER_OFF && pres != out) {
            unsigned want_w = (unsigned) (rect.w * scale);
            unsigned want_h = (unsigned) (rect.h * scale);
            if (pw % 2 || ph % 2) {
                LOGE("window filter: odd presented size %ux%u", pw, ph);
                ok = false;
            }
            if (pw + 16 < want_w || pw > want_w + 32
                    || ph + 16 < want_h || ph > want_h + 32) {
                LOGE("window filter: %ux%u does not track the content rect "
                     "%ux%u", pw, ph, want_w, want_h);
                ok = false;
            }
            if (pw != seen_w || ph != seen_h) {
                seen_w = pw;
                seen_h = ph;
                ++distinct_sizes;
            }
        }
        if (pw != tex_w || ph != tex_h) {
            // same behaviour as sc_texture_update(): a size change recreates
            // the texture, so a CPU-resampled frame needs no upstream surgery
            sws_freeContext(sws);
            SDL_DestroyTexture(tex);
            free(rgba);
            rgba = malloc((size_t) pw * ph * 4);
            if (!rgba) {
                LOGE("rgba realloc failed");
                ok = false;
                break;
            }
            rgba_planes[0] = rgba;
            rgba_stride[0] = (int) pw * 4;
            sws = sws_getContext(pw, ph, AV_PIX_FMT_YUV420P,
                                 pw, ph, AV_PIX_FMT_BGRA,
                                 SWS_BILINEAR, NULL, NULL, NULL);
            tex = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888,
                                    SDL_TEXTUREACCESS_STREAMING, (int) pw,
                                    (int) ph);
            if (!sws || !tex) {
                LOGE("texture rebuild failed: %s", SDL_GetError());
                ok = false;
                break;
            }
            tex_w = pw;
            tex_h = ph;
            ++tex_rebuilds;
        }

        sws_scale(sws, (const uint8_t * const *) pres->data, pres->linesize, 0,
                  (int) ph, rgba_planes, rgba_stride);
        if (!SDL_UpdateTexture(tex, NULL, rgba, (int) pw * 4)) {
            LOGE("update texture: %s", SDL_GetError());
            ok = false;
            break;
        }

        SDL_SetRenderDrawColor(renderer, 0, 0, 0, 255);
        SDL_RenderClear(renderer);
        if (!SDL_RenderTexture(renderer, tex, NULL, &geom)) {
            LOGE("render: %s", SDL_GetError());
        }
        sc_gaming_apply_upscale(&g, tex);

        // a moving touch marker, to prove the visualizer draws and fades
        float nx = (float) (i % 60) / 60.f;
        sc_gaming_report_touch(&g, i % 3, nx, 0.25f + (i % 3) * 0.2f,
                               (i % 40) < 20);

        sc_gaming_render_overlay(&g, &rect, scale);
        SDL_RenderPresent(renderer);
        ++presented;
        sc_gaming_on_frame_rendered(&g, frame, out);

        if (i == frames / 4 && wfilter != SC_WINDOW_FILTER_OFF && !win_w) {
            // drag the window: the presented picture must follow the new
            // content rect instead of being stretched by the GPU
            SDL_SetWindowSize(window, 420, 760);
        }
        if (i == frames / 3) {
            sc_gaming_toggle_borderless_fullscreen(&g);
        } else if (i == 2 * frames / 3) {
            sc_gaming_toggle_borderless_fullscreen(&g);
        }

        // present at a sane rate so the window is actually visible
        SDL_Delay(8);
    }

    if (shot && ok) {
        SDL_Surface *s = SDL_RenderReadPixels(renderer, NULL);
        if (s) {
            if (!SDL_SaveBMP(s, shot)) {
                LOGE("SDL_SaveBMP(%s): %s", shot, SDL_GetError());
            }
            SDL_DestroySurface(s);
        }
    }

    sc_tick elapsed = sc_tick_now() - loop_start;
    double real_fps = presented ? (double) presented * SC_TICK_FREQ
                                / (double) elapsed : 0;
    printf("gamingdemo: %u frames, backend=%s\n", frames,
           SDL_GetRendererName(renderer));
    // the rate is measured over what actually reached the GPU: a loaded machine
    // legitimately skips presents, and that must stay visible without changing
    // the frame count the surrounding scripts assert on
    printf("gamingdemo: presented=%u/%u\n", presented, frames);
    printf("gamingdemo: fps(present)=%.1f\n", real_fps);
    if (fx_active && processed) {
        printf("gamingdemo: postfx cpu cost avg=%.3fms max=%.3fms over %u "
               "frames (%ux%u)\n",
               (double) SC_TICK_TO_US(fx_total) / 1000.0 / processed,
               (double) SC_TICK_TO_US(fx_max) / 1000.0, processed, w, h);
    }
    if (stats && have_stats) {
        printf("gamingdemo: fx in luma_mean=%.4f luma_var=%.4f chroma_var=%.4f\n",
               in_stats.luma_mean, in_stats.luma_var, in_stats.chroma_var);
        printf("gamingdemo: fx out luma_mean=%.4f luma_var=%.4f "
               "chroma_var=%.4f\n",
               out_stats.luma_mean, out_stats.luma_var, out_stats.chroma_var);
        printf("gamingdemo: fx mask=%u applied=%s\n", params.postfx,
               g.postfx_active ? "yes" : "no");
    }
    if (stats && png && png_written) {
        FILE *fp = fopen(png, "rb");
        if (fp) {
            fseek(fp, 0, SEEK_END);
            printf("gamingdemo: png %s = %lld bytes\n", png,
                   (long long) ftell(fp));
            fclose(fp);
        }
    }
    // the OSD line is quoted as the user would read it, and the window's byte
    // total with it, so "0 KB/s" can be told apart from "nothing arrived"
    printf("gamingdemo: telemetry fps=%.1f latency=%u ms video=%u KB/s "
           "audio=%u KB/s v_bytes=%llu a_bytes=%llu osd[%s]\n",
           g.fps, g.latency_ms, g.kbps_video, g.kbps_audio,
           (unsigned long long) g.bytes_window_video,
           (unsigned long long) g.bytes_window_audio,
           g.osd_line_count > 1 ? g.osd_lines[1] : "");

    if (wfilter != SC_WINDOW_FILTER_OFF) {
        printf("gamingdemo: window filter %ux%u -> %ux%u, resampled=%" PRIu64
               " avg=%.3fms rebuilds=%" PRIu64 " distinct=%u tex_rebuilds=%u\n",
               w, h, seen_w, seen_h, g.win_frames,
               g.win_frames ? (double) SC_TICK_TO_US(g.win_total) / 1000.0
                                            / (double) g.win_frames : 0.0,
               g.win_rebuilds, distinct_sizes, tex_rebuilds);
        if (!g.win_frames || g.win_broken) {
            LOGE("window filter: no frame was resampled");
            ok = false;
        }
        if (frames > 8 && distinct_sizes < 2) {
            LOGE("window filter: presented size did not follow the window "
                 "resize (%u distinct)", distinct_sizes);
            ok = false;
        }
    }

    if (ov) {
        // is the panel reachable at all? either the global hotkey got the
        // combination, or the in-window fallback claims it
        SDL_Delay(150);
        SDL_Event hk;
        memset(&hk, 0, sizeof(hk));
        bool live = sc_gaming_overlay_hotkey_live(ov);
        hk.type = SDL_EVENT_KEY_DOWN;
        hk.key.scancode = SDL_SCANCODE_F;
        hk.key.mod = SDL_KMOD_ALT | SDL_KMOD_GUI;
        bool local_hit = sc_gaming_overlay_want_local_hotkey(ov, &hk);
        hk.key.mod = SDL_KMOD_ALT | SDL_KMOD_GUI | SDL_KMOD_SHIFT;
        bool extra_mod_hit = sc_gaming_overlay_want_local_hotkey(ov, &hk);
        printf("gamingdemo: overlay hotkey global=%s local-match=%s "
               "extra-mod-rejected=%s reachable=%s\n",
               live ? "live" : "taken", local_hit ? "yes" : "no",
               extra_mod_hit ? "no" : "yes",
               (live || local_hit || overlay_visible) ? "yes" : "no");
        if (!live && !local_hit && !overlay_visible) {
            // a panel nobody can open is the defect #20 class of bug: a control
            // that silently does nothing
            LOGE("overlay: no way to open the panel (global hotkey taken, the "
                 "local fallback did not match and it did not start visible)");
            ok = false;
        }
        printf("gamingdemo: overlay pulses=%u toggles=%u ticks=%u repaints=%u "
               "tick avg=%.3fus max=%.3fus window=%s\n",
               ov_pulses, ov_toggles, ov_ticks, ov_repaints,
               ov_ticks ? (double) SC_TICK_TO_US(ov_tick_total) / ov_ticks : 0.0,
               (double) SC_TICK_TO_US(ov_tick_max),
               sc_gaming_overlay_active_window_id() ? "live" : "gone");
        // the numbers below are the engine's live params: they prove the panel
        // reached the running session instead of editing a copy
        printf("gamingdemo: overlay->engine postfx=%u contrast=%u "
               "saturation=%u brightness=%u gamma=%u sharpen=%u night=%u\n",
               g.params.postfx, g.params.contrast, g.params.saturation,
               g.params.brightness, g.params.gamma, g.params.sharpen,
               g.params.night_boost);
        if (overlay_pulse && ov_pulses < 5) {
            LOGE("overlay: only %u slider pulses ran (need 5)", ov_pulses);
            ok = false;
        }
        if (overlay_toggle && ov_toggles < 5) {
            LOGE("overlay: only %u show/hide toggles ran (need 5)", ov_toggles);
            ok = false;
        }
        if (overlay_shot) {
            if (!sc_gaming_overlay_snapshot(ov, overlay_shot)) {
                LOGE("overlay: cannot write %s", overlay_shot);
                ok = false;
            } else {
                printf("gamingdemo: overlay shot %s\n", overlay_shot);
            }
        }
        sc_gaming_overlay_destroy(ov);
        if (overlay_profiles) {
            // the file must exist and carry the grade the session ended with
            FILE *pf = fopen(overlay_profiles, "r");
            char line[160] = {0};
            if (pf) {
                while (fgets(line, sizeof(line), pf)) {
                    if (!strncmp(line, "current ", 8)) {
                        break;
                    }
                }
                fclose(pf);
            }
            if (line[0] != 'c') {
                LOGE("overlay: no 'current' line in %s", overlay_profiles);
                ok = false;
            }
            printf("gamingdemo: overlay profiles stored: %s%s", line,
                   line[0] ? "" : "(none)");
        }
    }

    sc_gaming_destroy(&g);
    // joins the tap thread, so the file is complete from here on
    sc_pcm_tap_destroy(&tap);

    // the bridge is closed: the file size must be an exact multiple of the
    // frame size it was configured for, proving the resample happened
    if (ok && bridge && bscale_w && bscale_h && bridge[0] != '-'
            && strncmp(bridge, "\\\\.\\pipe\\", 9)) {
        FILE *fp = fopen(bridge, "rb");
        if (!fp) {
            LOGE("bridge file %s missing", bridge);
            ok = false;
        } else {
            fseek(fp, 0, SEEK_END);
            unsigned long long size = (unsigned long long) ftell(fp);
            fclose(fp);
            unsigned long long fsize = (unsigned long long) bscale_w * bscale_h * 4;
            printf("gamingdemo: bridge %s = %llu bytes, frame %ux%u = %llu "
                   "bytes, frames=%llu\n", bridge, size, bscale_w, bscale_h,
                   fsize, size / fsize);
            if (!size || size % fsize) {
                LOGE("bridge size %llu is not a whole number of %ux%u frames",
                     size, bscale_w, bscale_h);
                ok = false;
            }
        }
    }
    // the PCM tap must have produced 48 kHz stereo s16le for every frame:
    // 882 samples at 44.1 kHz -> 960 samples at 48 kHz -> 3840 bytes
    if (ok && af && pcmtap[0] != '-' && strncmp(pcmtap, "\\\\.\\pipe\\", 9)) {
        FILE *fp = fopen(pcmtap, "rb");
        if (!fp) {
            LOGE("pcm tap file %s missing", pcmtap);
            ok = false;
        } else {
            fseek(fp, 0, SEEK_END);
            unsigned long long size = (unsigned long long) ftell(fp);
            fclose(fp);
            unsigned long long expect = (unsigned long long) frames * 960 * 4;
            unsigned long long diff = size > expect ? size - expect
                                                    : expect - size;
            printf("gamingdemo: pcm tap %s = %llu B (expected ~%llu B of "
                   "48k/stereo/s16le)\n", pcmtap, size, expect);
            if (!size || size % 4 || diff * 10 > expect) {
                LOGE("pcm tap size %llu is not a plausible 48 kHz stereo "
                     "conversion of %u frames", size, frames);
                ok = false;
            }
        }
    }
    SDL_DestroyTexture(tex);
    sws_freeContext(sws);
    free(rgba);
    av_frame_free(&frame);
    av_frame_free(&af);
    SDL_Quit();
    printf("gamingdemo: %s\n", ok ? "PASS" : "FAIL");
    return ok ? 0 : 1;
}

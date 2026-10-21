#include "gaming.h"
#include "overlay.h"

#include <inttypes.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavutil/buffer.h>
#include <libavutil/channel_layout.h>
#include <libavutil/frame.h>
#include <libavutil/imgutils.h>
#include <libavutil/mem.h>
#include <libavutil/pixfmt.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>

#include "util/log.h"
#include "util/memory.h"
#include "util/tick.h"
#include "events.h"

static int
stall_watchdog_run(void *userdata);

#ifdef _WIN32
# include <windows.h>
#endif

#define OSD_PAD 6
#define OSD_LINE_SPACING 2
#define OSD_TEXT_SCALE 2
#define TOUCH_FADE SC_TICK_FROM_MS(500)
#define TELEMETRY_PERIOD SC_TICK_FROM_MS(1000)
#define OSD_REFRESH_PERIOD SC_TICK_FROM_MS(250)
#define LATENCY_EMA_ALPHA 0.25f
#define RECV_FIFO_SIZE 128

#ifndef M_PI
# define M_PI 3.14159265358979323846
#endif

struct sc_gaming *sc_gaming_current;

static char *
dup_path(const char *s) {
    size_t n = strlen(s) + 1;
    char *p = malloc(n);
    if (p) {
        memcpy(p, s, n);
    }
    return p;
}

static inline uint8_t
clamp_u8(int v) {
    return v < 0 ? 0 : (v > 255 ? 255 : (uint8_t) v);
}

static inline unsigned
uclamp(unsigned v, unsigned max) {
    return v > max ? max : v;
}

// ---------------------------------------------------------------------------
// built-in 5x7 bitmap font (row 0 = top, bit 4 = left column)
// ---------------------------------------------------------------------------

struct glyph {
    char c;
    uint8_t rows[GLYPH_H];
};

#define G(ch, r0, r1, r2, r3, r4, r5, r6) { ch, { r0, r1, r2, r3, r4, r5, r6 } }

static const struct glyph font5x7[] = {
    G(' ', 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00),
    G('0', 0x0E, 0x11, 0x13, 0x15, 0x19, 0x11, 0x0E),
    G('1', 0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E),
    G('2', 0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F),
    G('3', 0x0E, 0x11, 0x01, 0x02, 0x01, 0x11, 0x0E),
    G('4', 0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02),
    G('5', 0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E),
    G('6', 0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E),
    G('7', 0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08),
    G('8', 0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E),
    G('9', 0x0E, 0x11, 0x11, 0x0F, 0x01, 0x02, 0x0C),
    G('A', 0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11),
    G('B', 0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E),
    G('C', 0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E),
    G('D', 0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C),
    G('E', 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F),
    G('F', 0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10),
    G('G', 0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0E),
    G('H', 0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11),
    G('I', 0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E),
    G('J', 0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C),
    G('K', 0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11),
    G('L', 0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F),
    G('M', 0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11),
    G('N', 0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11),
    G('O', 0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E),
    G('P', 0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10),
    G('Q', 0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D),
    G('R', 0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11),
    G('S', 0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E),
    G('T', 0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04),
    G('U', 0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E),
    G('V', 0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04),
    G('W', 0x11, 0x11, 0x11, 0x15, 0x15, 0x1B, 0x11),
    G('X', 0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11),
    G('Y', 0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04),
    G('Z', 0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F),
    G('.', 0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C),
    G(',', 0x00, 0x00, 0x00, 0x00, 0x0C, 0x04, 0x08),
    G(':', 0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00),
    G('-', 0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00),
    G('_', 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F),
    G('/', 0x01, 0x02, 0x02, 0x04, 0x08, 0x08, 0x10),
    G('%', 0x18, 0x19, 0x02, 0x04, 0x08, 0x13, 0x03),
    G('+', 0x00, 0x04, 0x04, 0x1F, 0x04, 0x04, 0x00),
    G('=', 0x00, 0x00, 0x1F, 0x00, 0x1F, 0x00, 0x00),
    G('(', 0x02, 0x04, 0x08, 0x08, 0x08, 0x04, 0x02),
    G(')', 0x08, 0x04, 0x02, 0x02, 0x02, 0x04, 0x08),
    G('[', 0x0E, 0x08, 0x08, 0x08, 0x08, 0x08, 0x0E),
    G(']', 0x0E, 0x02, 0x02, 0x02, 0x02, 0x02, 0x0E),
    G('<', 0x02, 0x04, 0x08, 0x10, 0x08, 0x04, 0x02),
    G('>', 0x08, 0x04, 0x02, 0x01, 0x02, 0x04, 0x08),
    G('#', 0x0A, 0x1F, 0x0A, 0x0A, 0x0A, 0x1F, 0x0A),
    G('*', 0x00, 0x0A, 0x04, 0x1F, 0x04, 0x0A, 0x00),
    G('?', 0x0E, 0x11, 0x01, 0x02, 0x04, 0x00, 0x04),
    G('!', 0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04),
    G('@', 0x0E, 0x11, 0x17, 0x15, 0x17, 0x10, 0x0E),
};

static const uint8_t *
glyph_for(char c) {
    static const uint8_t box[GLYPH_H] = {
        0x1F, 0x11, 0x11, 0x11, 0x11, 0x11, 0x1F
    };
    if (c >= 'a' && c <= 'z') {
        c = (char) (c - 'a' + 'A');
    }
    for (size_t i = 0; i < sizeof(font5x7) / sizeof(font5x7[0]); ++i) {
        if (font5x7[i].c == c) {
            return font5x7[i].rows;
        }
    }
    return box;
}

// ---------------------------------------------------------------------------
// sinks: file, stdout or a Windows named pipe (client side)
// ---------------------------------------------------------------------------

// How long a bridge waits for its consumer to appear before giving up. The
// wait happens on the bridge thread, never on the mirror.
#define SC_GAMING_BRIDGE_CONNECT_MS 10000
#define SC_GAMING_BRIDGE_RETRY_MS 100

struct sc_sink {
    FILE *fp;
#ifdef _WIN32
    HANDLE pipe;
#endif
};

static bool
sink_is_pipe(const char *path) {
#ifdef _WIN32
    return !strncmp(path, "\\\\.\\pipe\\", 9);
#else
    (void) path;
    return false;
#endif
}

static void
sink_init(struct sc_sink *s) {
    s->fp = NULL;
#ifdef _WIN32
    s->pipe = INVALID_HANDLE_VALUE;
#endif
}

// Try once, without reporting: the bridge threads poll this while waiting for
// a consumer that may start after scrcpy.
static bool
sink_try_open(struct sc_sink *s, const char *path) {
    if (!strcmp(path, "-")) {
        s->fp = stdout;
        return true;
    }
#ifdef _WIN32
    if (sink_is_pipe(path)) {
        HANDLE h = CreateFileA(path, GENERIC_WRITE, 0, NULL, OPEN_EXISTING,
                               FILE_ATTRIBUTE_NORMAL, NULL);
        if (h == INVALID_HANDLE_VALUE) {
            return false;
        }
        s->pipe = h;
        return true;
    }
#endif
    s->fp = fopen(path, "wb");
    return s->fp != NULL;
}

static bool
sink_write(struct sc_sink *s, const uint8_t *data, size_t len) {
#ifdef _WIN32
    if (s->pipe != INVALID_HANDLE_VALUE) {
        size_t off = 0;
        while (off < len) {
            size_t chunk = len - off > (1u << 20) ? (1u << 20) : len - off;
            DWORD written = 0;
            if (!WriteFile(s->pipe, data + off, (DWORD) chunk, &written, NULL)
                    || !written) {
                return false;
            }
            off += written;
        }
        return true;
    }
#endif
    if (!s->fp) {
        return false;
    }
    return fwrite(data, 1, len, s->fp) == len;
}

static void
sink_close(struct sc_sink *s) {
#ifdef _WIN32
    if (s->pipe != INVALID_HANDLE_VALUE) {
        CloseHandle(s->pipe);
        s->pipe = INVALID_HANDLE_VALUE;
    }
#endif
    if (s->fp && s->fp != stdout) {
        fclose(s->fp);
    }
    s->fp = NULL;
}

// ---------------------------------------------------------------------------
// audio splitter: raw encoded audio packets, drop-oldest queue, own thread
// ---------------------------------------------------------------------------

struct sc_byte_bridge {
    sc_thread thread;
    sc_mutex mutex;
    sc_cond cond;

    uint8_t *slots[SC_GAMING_BRIDGE_QUEUE];
    size_t slot_len[SC_GAMING_BRIDGE_QUEUE];
    unsigned head;
    unsigned count;
    bool stopped;

    struct sc_sink sink;
    char *path;
    const char *label; // "audio bridge" or "pcm tap", for the logs
    bool sink_ready;
    uint64_t sent;
    uint64_t dropped;
};

static int
byte_bridge_run(void *data) {
    struct sc_byte_bridge *b = data;
    sc_tick deadline =
        sc_tick_now() + SC_TICK_FROM_MS(SC_GAMING_BRIDGE_CONNECT_MS);
    for (;;) {
        if (!b->sink_ready) {
            // see the comment in video_bridge_run: never block the mirror
            // waiting for a consumer that may not exist yet
            if (sink_try_open(&b->sink, b->path)) {
                b->sink_ready = true;
                LOGI("%s: consumer connected (%s)", b->label, b->path);
            } else if (sc_tick_now() >= deadline) {
                LOGE("%s: no consumer on '%s' after %d ms, disabled",
                     b->label, b->path, SC_GAMING_BRIDGE_CONNECT_MS);
                sc_mutex_lock(&b->mutex);
                b->stopped = true;
                sc_mutex_unlock(&b->mutex);
                return 0;
            } else {
                sc_mutex_lock(&b->mutex);
                while (b->count) {
                    free(b->slots[b->head]);
                    b->slots[b->head] = NULL;
                    b->head = (b->head + 1) % SC_GAMING_BRIDGE_QUEUE;
                    --b->count;
                    ++b->dropped;
                }
                bool stopped = b->stopped;
                sc_mutex_unlock(&b->mutex);
                if (stopped) {
                    return 0;
                }
                SDL_Delay(SC_GAMING_BRIDGE_RETRY_MS);
                continue;
            }
        }

        sc_mutex_lock(&b->mutex);
        while (!b->stopped && !b->count) {
            sc_cond_wait(&b->cond, &b->mutex);
        }
        if (b->stopped && !b->count) {
            sc_mutex_unlock(&b->mutex);
            break;
        }
        uint8_t *payload = b->slots[b->head];
        size_t len = b->slot_len[b->head];
        b->slots[b->head] = NULL;
        b->head = (b->head + 1) % SC_GAMING_BRIDGE_QUEUE;
        --b->count;
        sc_mutex_unlock(&b->mutex);

        bool ok = payload ? sink_write(&b->sink, payload, len) : true;
        free(payload);
        if (!ok) {
            LOGW("%s: consumer closed, splitter stopped", b->label);
            break;
        }
        ++b->sent;
    }
    return 0;
}

static struct sc_byte_bridge *
sc_byte_bridge_create(const char *path, const char *label) {
    struct sc_byte_bridge *b = calloc(1, sizeof(*b));
    if (!b) {
        return NULL;
    }
    sink_init(&b->sink);
    b->path = dup_path(path);
    b->label = label;
    if (!sc_mutex_init(&b->mutex) || !sc_cond_init(&b->cond)) {
        sink_close(&b->sink);
        free(b->path);
        free(b);
        return NULL;
    }
    if (!sc_thread_create(&b->thread, byte_bridge_run, "sc_bridge_a", b)) {
        sc_cond_destroy(&b->cond);
        sc_mutex_destroy(&b->mutex);
        sink_close(&b->sink);
        free(b->path);
        free(b);
        return NULL;
    }
    LOGI("%s: raw bytes -> %s", b->label, path);
    return b;
}

static void
sc_byte_bridge_push(struct sc_byte_bridge *b, const uint8_t *data, size_t len) {
    uint8_t *copy = malloc(len);
    if (!copy) {
        return;
    }
    memcpy(copy, data, len);

    sc_mutex_lock(&b->mutex);
    if (b->stopped) {
        sc_mutex_unlock(&b->mutex);
        free(copy);
        return;
    }
    unsigned tail;
    if (b->count == SC_GAMING_BRIDGE_QUEUE) {
        // drop the oldest chunk: the producer thread must never block
        tail = b->head;
        free(b->slots[tail]);
        ++b->dropped;
        b->head = (b->head + 1) % SC_GAMING_BRIDGE_QUEUE;
    } else {
        tail = (b->head + b->count) % SC_GAMING_BRIDGE_QUEUE;
        ++b->count;
    }
    b->slots[tail] = copy;
    b->slot_len[tail] = len;
    sc_cond_signal(&b->cond);
    sc_mutex_unlock(&b->mutex);
}

static void
sc_byte_bridge_destroy(struct sc_byte_bridge *b) {
    if (!b) {
        return;
    }
    sc_mutex_lock(&b->mutex);
    b->stopped = true;
    sc_cond_broadcast(&b->cond);
    sc_mutex_unlock(&b->mutex);
    sc_thread_join(&b->thread, NULL);

    for (unsigned i = 0; i < SC_GAMING_BRIDGE_QUEUE; ++i) {
        free(b->slots[i]);
    }
    sc_cond_destroy(&b->cond);
    sc_mutex_destroy(&b->mutex);
    sink_close(&b->sink);
    // both numbers, always: "26 chunks dropped" alone cannot tell a device that
    // sent nothing from a bridge that lost the stream
    LOGI("%s: %" PRIu64 " chunks sent, %" PRIu64 " dropped (%s)", b->label,
         b->sent, b->dropped, b->dropped ? "slow consumer" : "consumer kept up");
    free(b->path);
    free(b);
}

// ---------------------------------------------------------------------------
// frame bridge: decoded frames converted to RGBA off the render thread
// ---------------------------------------------------------------------------

struct sc_video_bridge {
    sc_thread thread;
    sc_mutex mutex;
    sc_cond cond;

    AVFrame *slots[SC_GAMING_BRIDGE_QUEUE];
    unsigned head;
    unsigned count;
    bool stopped;

    struct sc_sink sink;
    char *path;
    bool sink_ready;
    struct SwsContext *sws;
    uint8_t *rgba;
    uint8_t *rgba_planes[4];
    int rgba_stride[4];
    unsigned w;
    unsigned h;
    unsigned src_w;
    unsigned src_h;
    unsigned dst_w;
    unsigned dst_h;
    int sws_flags;
    uint64_t frames;
    uint64_t dropped;
    sc_tick scale_total;
    sc_tick write_total;
    bool meta_written;
};

static int
bridge_sws_flags(enum sc_bridge_filter filter) {
    switch (filter) {
        case SC_BRIDGE_FILTER_POINT:
            return SWS_POINT;
        case SC_BRIDGE_FILTER_BILINEAR:
            return SWS_BILINEAR;
        case SC_BRIDGE_FILTER_FAST_BILINEAR:
            return SWS_FAST_BILINEAR;
        case SC_BRIDGE_FILTER_BICUBIC:
            return SWS_BICUBIC;
        case SC_BRIDGE_FILTER_LANCZOS:
            return SWS_LANCZOS;
        case SC_BRIDGE_FILTER_DEFAULT:
            break;
    }
    return SWS_BILINEAR;
}

static int
window_sws_flags(enum sc_window_filter filter) {
    switch (filter) {
        case SC_WINDOW_FILTER_POINT:
            return SWS_POINT;
        case SC_WINDOW_FILTER_BILINEAR:
            return SWS_BILINEAR;
        case SC_WINDOW_FILTER_FAST_BILINEAR:
            return SWS_FAST_BILINEAR;
        case SC_WINDOW_FILTER_BICUBIC:
            return SWS_BICUBIC;
        case SC_WINDOW_FILTER_LANCZOS:
        case SC_WINDOW_FILTER_OFF:
        case SC_WINDOW_FILTER_COUNT:
            break;
    }
    return SWS_LANCZOS;
}

static const char *
window_filter_name(enum sc_window_filter filter) {
    switch (filter) {
        case SC_WINDOW_FILTER_POINT:
            return "point";
        case SC_WINDOW_FILTER_BILINEAR:
            return "bilinear";
        case SC_WINDOW_FILTER_FAST_BILINEAR:
            return "fast";
        case SC_WINDOW_FILTER_BICUBIC:
            return "bicubic";
        case SC_WINDOW_FILTER_LANCZOS:
            return "lanczos";
        case SC_WINDOW_FILTER_OFF:
        case SC_WINDOW_FILTER_COUNT:
            break;
    }
    return "off";
}

static void
video_bridge_write_meta(struct sc_video_bridge *vb) {
    if (vb->meta_written || !vb->w || !vb->h) {
        return;
    }
    // A sidecar describes the raw stream so a consumer (OBS custom ffmpeg
    // source, ffplay, a launcher helper) can pick it up without guessing.
    if (sink_is_pipe(vb->path) || !strcmp(vb->path, "-")) {
        vb->meta_written = true;
        return;
    }
    char meta[1024];
    snprintf(meta, sizeof(meta), "%s.meta.txt", vb->path);
    FILE *fp = fopen(meta, "w");
    if (fp) {
        fprintf(fp,
                "format=rawvideo\npix_fmt=rgba\nwidth=%u\nheight=%u\n"
                "read_as=rgba8888\n",
                // consume with:
                // ffplay -f rawvideo -pixel_format rgba -video_size WxH <path>
                vb->w, vb->h);
        fclose(fp);
    }
    vb->meta_written = true;
}

static int
video_bridge_run(void *data) {
    struct sc_video_bridge *vb = data;
    sc_tick deadline = sc_tick_now() + SC_TICK_FROM_MS(SC_GAMING_BRIDGE_CONNECT_MS);
    for (;;) {
        if (!vb->sink_ready) {
            // Connecting happens here, not in sc_gaming_init(): a named pipe
            // consumer (the OBS helper) is usually started after scrcpy, and
            // the mirror must not freeze while it waits. Frames produced in
            // the meantime are discarded, never queued, so the bridge cannot
            // pin decoder buffers while nobody is reading.
            if (sink_try_open(&vb->sink, vb->path)) {
                vb->sink_ready = true;
                LOGI("frame bridge: consumer connected (%s)", vb->path);
            } else if (sc_tick_now() >= deadline) {
                LOGE("frame bridge: no consumer on '%s' after %d ms, disabled",
                     vb->path, SC_GAMING_BRIDGE_CONNECT_MS);
                sc_mutex_lock(&vb->mutex);
                vb->stopped = true;
                sc_mutex_unlock(&vb->mutex);
                return 0;
            } else {
                sc_mutex_lock(&vb->mutex);
                while (vb->count) {
                    AVFrame *old = vb->slots[vb->head];
                    vb->slots[vb->head] = NULL;
                    vb->head = (vb->head + 1) % SC_GAMING_BRIDGE_QUEUE;
                    --vb->count;
                    ++vb->dropped;
                    av_frame_free(&old);
                }
                bool stopped = vb->stopped;
                sc_mutex_unlock(&vb->mutex);
                if (stopped) {
                    return 0;
                }
                SDL_Delay(SC_GAMING_BRIDGE_RETRY_MS);
                continue;
            }
        }

        sc_mutex_lock(&vb->mutex);
        while (!vb->stopped && !vb->count) {
            sc_cond_wait(&vb->cond, &vb->mutex);
        }
        if (vb->stopped && !vb->count) {
            sc_mutex_unlock(&vb->mutex);
            break;
        }
        AVFrame *frame = vb->slots[vb->head];
        vb->slots[vb->head] = NULL;
        vb->head = (vb->head + 1) % SC_GAMING_BRIDGE_QUEUE;
        --vb->count;
        sc_mutex_unlock(&vb->mutex);

        if (!frame) {
            break;
        }

        unsigned w = frame->width;
        unsigned h = frame->height;
        if (!w || !h) {
            av_frame_free(&frame);
            continue;
        }
        unsigned ow = vb->dst_w ? vb->dst_w : w;
        unsigned oh = vb->dst_h ? vb->dst_h : h;
        bool resized = ow != vb->w || oh != vb->h || w != vb->src_w
                       || h != vb->src_h;
        if (resized) {
            sws_freeContext(vb->sws);
            vb->sws = NULL;
            free(vb->rgba);
            vb->rgba = NULL;
            vb->w = vb->h = vb->src_w = vb->src_h = 0;
            if (frame->format != AV_PIX_FMT_YUV420P) {
                LOGW("frame bridge: unsupported pixel format, skipping");
                av_frame_free(&frame);
                continue;
            }
            vb->rgba = malloc((size_t) ow * oh * 4);
            if (!vb->rgba) {
                av_frame_free(&frame);
                break;
            }
            vb->rgba_planes[0] = vb->rgba;
            vb->rgba_stride[0] = (int) ow * 4;
            vb->sws = sws_getContext(w, h, AV_PIX_FMT_YUV420P,
                                     ow, oh, AV_PIX_FMT_RGBA,
                                     vb->sws_flags, NULL, NULL, NULL);
            if (!vb->sws) {
                av_frame_free(&frame);
                break;
            }
            vb->w = ow;
            vb->h = oh;
            vb->src_w = w;
            vb->src_h = h;
            vb->meta_written = false;
            LOGI("frame bridge: %ux%u -> %ux%u RGBA (ffplay -f rawvideo "
                 "-pixel_format rgba -video_size %ux%u \"%s\")",
                 w, h, ow, oh, ow, oh, vb->path);
        }

        video_bridge_write_meta(vb);

        const uint8_t *const *src = (const uint8_t *const *) frame->data;
        sc_tick t0 = sc_tick_now();
        int ret = sws_scale(vb->sws, src, frame->linesize, 0, (int) h,
                            vb->rgba_planes, vb->rgba_stride);
        sc_tick t1 = sc_tick_now();
        av_frame_free(&frame);
        if (ret < 0) {
            LOGW("frame bridge: scale failed (%d)", ret);
            continue;
        }
        size_t frame_bytes = (size_t) vb->w * vb->h * 4;
        bool written = sink_write(&vb->sink, vb->rgba, frame_bytes);
        sc_tick t2 = sc_tick_now();
        if (!written) {
            LOGW("frame bridge: consumer closed, bridge stopped");
            break;
        }
        vb->scale_total += t1 - t0;
        vb->write_total += t2 - t1;
        ++vb->frames;
    }
    return 0;
}

static struct sc_video_bridge *
sc_video_bridge_create(const char *path, unsigned dst_w, unsigned dst_h,
                       enum sc_bridge_filter filter) {
    struct sc_video_bridge *vb = calloc(1, sizeof(*vb));
    if (!vb) {
        return NULL;
    }
    sink_init(&vb->sink);
    vb->path = dup_path(path);
    vb->dst_w = dst_w;
    vb->dst_h = dst_h;
    vb->sws_flags = bridge_sws_flags(filter);
    if (!sc_mutex_init(&vb->mutex) || !sc_cond_init(&vb->cond)) {
        sink_close(&vb->sink);
        free(vb->path);
        free(vb);
        return NULL;
    }
    if (!sc_thread_create(&vb->thread, video_bridge_run, "sc_bridge_v", vb)) {
        sc_cond_destroy(&vb->cond);
        sc_mutex_destroy(&vb->mutex);
        sink_close(&vb->sink);
        free(vb->path);
        free(vb);
        return NULL;
    }
    if (dst_w && dst_h) {
        LOGI("frame bridge: enabled (%s), host resample to %ux%u",
             path, dst_w, dst_h);
    } else {
        LOGI("frame bridge: enabled (%s)%s", path,
             sink_is_pipe(path) ? ", waiting for a consumer" : "");
    }
    return vb;
}

static void
sc_video_bridge_push(struct sc_video_bridge *vb, const AVFrame *frame) {
    AVFrame *ref = av_frame_alloc();
    if (!ref) {
        return;
    }
    if (av_frame_ref(ref, frame) < 0) {
        av_frame_free(&ref);
        return;
    }

    sc_mutex_lock(&vb->mutex);
    if (vb->stopped) {
        sc_mutex_unlock(&vb->mutex);
        av_frame_free(&ref);
        return;
    }
    if (vb->count == SC_GAMING_BRIDGE_QUEUE) {
        // drop-oldest: presentation is never delayed by the bridge
        AVFrame *old = vb->slots[vb->head];
        vb->slots[vb->head] = NULL;
        ++vb->dropped;
        av_frame_free(&old);
        vb->slots[vb->head] = ref;
        vb->head = (vb->head + 1) % SC_GAMING_BRIDGE_QUEUE;
    } else {
        unsigned tail = (vb->head + vb->count) % SC_GAMING_BRIDGE_QUEUE;
        vb->slots[tail] = ref;
        ++vb->count;
    }
    sc_cond_signal(&vb->cond);
    sc_mutex_unlock(&vb->mutex);
}

static void
sc_video_bridge_destroy(struct sc_video_bridge *vb) {
    if (!vb) {
        return;
    }
    sc_mutex_lock(&vb->mutex);
    vb->stopped = true;
    sc_cond_broadcast(&vb->cond);
    sc_mutex_unlock(&vb->mutex);
    sc_thread_join(&vb->thread, NULL);

    for (unsigned i = 0; i < SC_GAMING_BRIDGE_QUEUE; ++i) {
        av_frame_free(&vb->slots[i]);
    }
    sc_cond_destroy(&vb->cond);
    sc_mutex_destroy(&vb->mutex);
    sws_freeContext(vb->sws);
    free(vb->rgba);
    sink_close(&vb->sink);
    if (vb->dropped) {
        LOGI("frame bridge: %" PRIu64 " frames dropped (slow consumer)",
             vb->dropped);
    }
    LOGI("frame bridge: %" PRIu64 " frames sent", vb->frames);
    if (vb->frames) {
        // the kernel cost only shows up against the write cost when both are
        // measured, since the raw feed is ~8MB per 1080p frame (sc_tick is µs)
        LOGI("frame bridge: resample avg=%.2fms, write avg=%.2fms per frame",
             (double) vb->scale_total / 1000.0 / vb->frames,
             (double) vb->write_total / 1000.0 / vb->frames);
    }
    free(vb->path);
    free(vb);
}

// ---------------------------------------------------------------------------
// post-processing (host copy of the decoded frame, YUV420P)
// ---------------------------------------------------------------------------

static double
clamp01(double v) {
    return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
}

// Compose the luma grade into one 256-entry table: brightness (offset), then
// contrast (pivot at mid grey), then gamma, then night-boost. Only the Y plane
// goes through it, so a grade never shifts hue.
//
// Returns false when every stage is the identity, so the caller can skip the
// pass instead of walking the plane for nothing.
static bool
build_luma_lut(uint8_t lut[static 256], const struct sc_gaming_params *p) {
    // a filter counts only when its bit is set, so an option struct left at 0
    // by a caller that enabled --game-postfx=gamma without a value stays inert,
    // and a value carried for another profile cannot grade the picture behind
    // the user's back
    double contrast = (p->postfx & SC_POSTFX_CONTRAST) ? p->contrast / 100.0
                                                       : 1.0;
    double bright = (p->postfx & SC_POSTFX_BRIGHTNESS)
                  ? ((double) p->brightness - 100.0) / 100.0 * 0.5 : 0.0;
    double gamma = 1.0;
    if (p->postfx & SC_POSTFX_GAMMA) {
        // percent/100, kept inside [0.25..2.0] whatever the caller asked for
        gamma = p->gamma / 100.0;
        gamma = gamma < 0.25 ? 0.25 : (gamma > 2.0 ? 2.0 : gamma);
    }
    double ng = 1.0;
    double lift = 0.0;
    if (p->postfx & SC_POSTFX_NIGHTBOOST) {
        ng = 1.0 + (p->night_boost / 100.0) * 1.5;
        lift = (p->night_boost / 100.0) * 0.15;
    }

    bool identity = contrast == 1.0 && bright == 0.0 && gamma == 1.0
                    && !p->night_boost;
    for (unsigned i = 0; i < 256; ++i) {
        if (identity) {
            lut[i] = (uint8_t) i;
            continue;
        }
        double v = i / 255.0 + bright;
        v = clamp01((v - 0.5) * contrast + 0.5);
        v = pow(v, 1.0 / gamma);
        v = pow(v, 1.0 / ng) * (1.0 - lift) + lift;
        lut[i] = clamp_u8((int) (clamp01(v) * 255.0 + 0.5));
    }
    return !identity;
}

static void
copy_plane(const uint8_t *src, int src_linesize, uint8_t *dst,
           int dst_linesize, unsigned w, unsigned h) {
    for (unsigned y = 0; y < h; ++y) {
        memcpy(dst + (size_t) y * dst_linesize,
               src + (size_t) y * src_linesize, w);
    }
}

// CAS-style luma sharpening: unsharp mask over a 4-neighbour Laplacian, always
// computed from an untouched source plane (in-place sharpening would compound).
static void
sharpen_luma(const uint8_t *src, int src_linesize, uint8_t *dst,
             int dst_linesize, unsigned w, unsigned h, unsigned strength) {
    const int k = (int) uclamp(strength, 100);

    for (unsigned x = 0; x < w; ++x) {
        dst[x] = src[x];
        dst[(size_t) (h - 1) * dst_linesize + x] =
            src[(size_t) (h - 1) * src_linesize + x];
    }
    for (unsigned y = 1; y + 1 < h; ++y) {
        const uint8_t *p = src + (size_t) y * src_linesize;
        const uint8_t *pu = p - src_linesize;
        const uint8_t *pd = p + src_linesize;
        uint8_t *o = dst + (size_t) y * dst_linesize;
        o[0] = p[0];
        o[w - 1] = p[w - 1];
        for (unsigned x = 1; x + 1 < w; ++x) {
            int c = p[x];
            int lap = 4 * c - p[x - 1] - p[x + 1] - pu[x] - pd[x];
            o[x] = clamp_u8(c + (lap * k * 4) / 500); // k=100 -> gain 0.8
        }
    }
}

static void
scale_chroma(uint8_t *plane, int linesize, unsigned w, unsigned h,
             unsigned percent) {
    for (unsigned y = 0; y < h; ++y) {
        uint8_t *row = plane + (size_t) y * linesize;
        for (unsigned x = 0; x < w; ++x) {
            row[x] = clamp_u8(128 + ((int) row[x] - 128) * (int) percent / 100);
        }
    }
}

static bool
ensure_work_frame(struct sc_gaming *g, const AVFrame *frame) {
    unsigned w = frame->width;
    unsigned h = frame->height;
    if (g->work_frame && g->work_w == w && g->work_h == h) {
        return true;
    }
    av_frame_free(&g->work_frame);
    free(g->sharpen_tmp);
    g->sharpen_tmp = NULL;
    g->work_frame = av_frame_alloc();
    if (!g->work_frame) {
        return false;
    }
    g->work_frame->format = AV_PIX_FMT_YUV420P;
    g->work_frame->width = frame->width;
    g->work_frame->height = frame->height;
    if (av_frame_get_buffer(g->work_frame, 32) < 0) {
        av_frame_free(&g->work_frame);
        return false;
    }
    g->sharpen_tmp = malloc((size_t) w * h);
    if (!g->sharpen_tmp) {
        av_frame_free(&g->work_frame);
        g->work_frame = NULL;
        return false;
    }
    g->work_w = w;
    g->work_h = h;
    g->lut_valid = false;
    return true;
}

// (Re)allocate the presentation buffer and resampler for the current window
// target. Rebuilding is the expensive part (Lanczos allocates filter tables per
// scale step), so the target is quantized by sc_gaming_set_window_target() and
// a dragged window does not rebuild on every mouse move.
static bool
ensure_scaled_frame(struct sc_gaming *g, const AVFrame *frame) {
    if (g->scaled_frame && g->win_dst_w == g->win_target_w
            && g->win_dst_h == g->win_target_h
            && g->win_src_w == (unsigned) frame->width
            && g->win_src_h == (unsigned) frame->height) {
        return true;
    }
    av_frame_free(&g->scaled_frame);
    sws_freeContext(g->win_sws);
    g->win_sws = NULL;
    g->win_dst_w = g->win_dst_h = g->win_src_w = g->win_src_h = 0;

    g->scaled_frame = av_frame_alloc();
    if (!g->scaled_frame) {
        return false;
    }
    g->scaled_frame->format = AV_PIX_FMT_YUV420P;
    g->scaled_frame->width = (int) g->win_target_w;
    g->scaled_frame->height = (int) g->win_target_h;
    if (av_frame_get_buffer(g->scaled_frame, 32) < 0) {
        av_frame_free(&g->scaled_frame);
        return false;
    }
    g->win_sws = sws_getContext(frame->width, frame->height, AV_PIX_FMT_YUV420P,
                                (int) g->win_target_w, (int) g->win_target_h,
                                AV_PIX_FMT_YUV420P,
                                window_sws_flags(g->params.window_filter),
                                NULL, NULL, NULL);
    if (!g->win_sws) {
        av_frame_free(&g->scaled_frame);
        return false;
    }
    g->win_dst_w = g->win_target_w;
    g->win_dst_h = g->win_target_h;
    g->win_src_w = frame->width;
    g->win_src_h = frame->height;
    ++g->win_rebuilds;
    LOGI("window filter: %s resample %ux%u -> %ux%u (rebuild #%" PRIu64 ")",
         window_filter_name(g->params.window_filter), g->win_src_w,
         g->win_src_h, g->win_dst_w, g->win_dst_h, g->win_rebuilds);
    return true;
}


// ---------------------------------------------------------------------------
// window / display helpers
// ---------------------------------------------------------------------------

static void
refresh_window_metrics(struct sc_gaming *g) {
    SDL_GetWindowSize(g->window, &g->window_w, &g->window_h);
    SDL_GetWindowPosition(g->window, &g->window_x, &g->window_y);
    g->pixel_density = SDL_GetWindowPixelDensity(g->window);
    if (g->pixel_density <= 0) {
        g->pixel_density = 1;
    }
    SDL_DisplayID display = SDL_GetDisplayForWindow(g->window);
    if (!display) {
        display = SDL_GetPrimaryDisplay();
    }
    SDL_Rect bounds;
    if (display && SDL_GetDisplayBounds(display, &bounds)) {
        g->display_x = bounds.x;
        g->display_y = bounds.y;
        g->display_w = bounds.w;
        g->display_h = bounds.h;
    }
}

static void
set_borderless_fullscreen(struct sc_gaming *g, bool on) {
    if (on == g->borderless_fullscreen_active) {
        return;
    }
    if (on) {
        if (!g->windowed_size_saved) {
            g->windowed_size.width = (uint32_t) g->window_w;
            g->windowed_size.height = (uint32_t) g->window_h;
            g->windowed_pos.x = g->window_x;
            g->windowed_pos.y = g->window_y;
            g->windowed_size_saved = true;
        }
        // Non-exclusive fullscreen: no DWM border, but still a normal window so
        // OBS "Window Capture" sees it and Alt+Tab keeps working.
        if (!SDL_SetWindowBordered(g->window, false)) {
            LOGW("borderless: SDL_SetWindowBordered failed: %s", SDL_GetError());
        }
        g->borderless_fullscreen_active = true;
        sc_gaming_apply_borderless_geometry(g);
        int rw = 0, rh = 0;
        SDL_GetWindowSize(g->window, &rw, &rh);
        LOGI("borderless: requested %dx%d, SDL reports %dx%d flags=0x%x",
             g->display_w, g->display_h, rw, rh,
             (unsigned) SDL_GetWindowFlags(g->window));
        if (rw != g->display_w || rh != g->display_h) {
            // The promise is a window the size of the display, so say out loud
            // when the window manager kept a different size.
            LOGW("borderless: the window is %dx%d, not the display %dx%d",
                 rw, rh, g->display_w, g->display_h);
        } else {
            LOGI("Borderless fullscreen on (%dx%d)", g->display_w,
                 g->display_h);
        }
    } else {
        SDL_SetWindowBordered(g->window, true);
        if (g->windowed_size_saved) {
            SDL_SetWindowPosition(g->window, g->windowed_pos.x,
                                  g->windowed_pos.y);
            SDL_SetWindowSize(g->window, (int) g->windowed_size.width,
                              (int) g->windowed_size.height);
        }
        g->borderless_fullscreen_active = false;
        if (g->content_aspect > 0.f) {
            // Back to a normal window: lock it to the video again, since the
            // letterbox that made the lock unnecessary is gone.
            SDL_SetWindowAspectRatio(g->window, g->content_aspect,
                                     g->content_aspect);
        }
        LOGI("Borderless fullscreen off");
    }
    refresh_window_metrics(g);
}

void
sc_gaming_apply_borderless_geometry(struct sc_gaming *g) {
    if (!g->borderless_fullscreen_active) {
        return;
    }
    // The window belongs to the display and the video is letterboxed into the
    // content rect, so the aspect lock has to go: with it, SDL kept the
    // requested height and clamped the width to the video aspect (measured on
    // an S23 Ultra: 1366x768 requested, 358x768 obtained).
    SDL_SetWindowAspectRatio(g->window, 0.0f, 0.0f);
    SDL_SyncWindow(g->window);
    SDL_SetWindowPosition(g->window, g->display_x, g->display_y);
    SDL_SetWindowSize(g->window, g->display_w, g->display_h);
    SDL_SyncWindow(g->window);
    refresh_window_metrics(g);
}

void
sc_gaming_note_content_aspect(struct sc_gaming *g, float aspect) {
    if (aspect > 0.f) {
        g->content_aspect = aspect;
    }
}

bool
sc_gaming_borderless_fullscreen_active(const struct sc_gaming *g) {
    return g->borderless_fullscreen_active;
}

static bool
pointer_to_content(struct sc_gaming *g, float px, float py, float *nx,
                   float *ny) {
    const SDL_FRect *c = &g->content_rect;
    if (!c->w || !c->h) {
        return false;
    }
    // window coordinates (logical pixels) -> normalized position in the
    // rendered content rect, so the marker follows the picture, not the window
    float x = (px - c->x) / c->w;
    float y = (py - c->y) / c->h;
    if (x < 0.f || x > 1.f || y < 0.f || y > 1.f) {
        return false;
    }
    *nx = x;
    *ny = y;
    return true;
}

void
sc_gaming_report_touch(struct sc_gaming *g, unsigned id, float nx, float ny,
                       bool down) {
    struct sc_touch_point *t = &g->touches[id % SC_GAMING_MAX_TOUCH_POINTS];
    if (down) {
        t->nx = nx;
        t->ny = ny;
        t->active = true;
    } else if (t->active) {
        t->active = false;
    }
    t->since = sc_tick_now();
}

// ---------------------------------------------------------------------------
// runtime toggles (installed through an SDL event watch so no upstream input
// dispatch code has to be modified)
// ---------------------------------------------------------------------------

void
sc_gaming_toggle_osd(struct sc_gaming *g) {
    g->params.osd = (g->params.osd + 1) % SC_OSD_LEVEL_COUNT;
    g->osd_next_update = 0;
    LOGI("Game OSD: %s",
         g->params.osd == SC_OSD_OFF ? "off"
       : g->params.osd == SC_OSD_COMPACT ? "compact" : "full");
}

void
sc_gaming_toggle_borderless_fullscreen(struct sc_gaming *g) {
    set_borderless_fullscreen(g, !g->borderless_fullscreen_active);
}

void
sc_gaming_toggle_touch_visualizer(struct sc_gaming *g) {
    g->touch_visualizer_active = !g->touch_visualizer_active;
    LOGI("Touch visualizer: %s",
         g->touch_visualizer_active ? "on" : "off");
}

void
sc_gaming_toggle_cursor(struct sc_gaming *g) {
    g->cursor_hidden = !g->cursor_hidden;
    (!g->cursor_hidden ? SDL_ShowCursor() : SDL_HideCursor());
    LOGI("Cursor: %s", g->cursor_hidden ? "hidden" : "shown");
}

void
sc_gaming_toggle_always_on_top(struct sc_gaming *g) {
    g->always_on_top_active = !g->always_on_top_active;
    SDL_SetWindowAlwaysOnTop(g->window, g->always_on_top_active);
    LOGI("Always on top: %s",
         g->always_on_top_active ? "enabled" : "disabled");
}

static bool
is_shortcut_mod(SDL_Keymod mod) {
    // same spirit as scrcpy: Super (Windows key) on Windows/Linux, or Alt
    return (mod & (SDL_KMOD_GUI | SDL_KMOD_LALT | SDL_KMOD_RALT)) != 0;
}

static bool
gaming_event_watch(void *userdata, SDL_Event *event) {
    struct sc_gaming *g = userdata;

    switch (event->type) {
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EVENT_MOUSE_BUTTON_UP:
        case SDL_EVENT_MOUSE_MOTION:
        case SDL_EVENT_FINGER_DOWN:
        case SDL_EVENT_FINGER_MOTION:
        case SDL_EVENT_FINGER_UP:
            // The panel is a second window and event watches see every window.
            // Without this, a press on a slider would light the touch
            // visualizer, which is meant to mirror what the device receives.
            if (sc_gaming_event_is_for_overlay(event)) {
                return true;
            }
            break;
        default:
            break;
    }

    switch (event->type) {
        case SDL_EVENT_KEY_DOWN:
            if (!is_shortcut_mod(event->key.mod)) {
                break;
            }
            switch (event->key.key) {
                case SDLK_F1:
                    sc_gaming_toggle_osd(g);
                    return false;
                case SDLK_F2:
                    sc_gaming_toggle_borderless_fullscreen(g);
                    return false;
                case SDLK_F3:
                    sc_gaming_toggle_touch_visualizer(g);
                    return false;
                case SDLK_F4:
                    sc_gaming_toggle_cursor(g);
                    return false;
                case SDLK_F5:
                    sc_gaming_toggle_always_on_top(g);
                    return false;
                default:
                    break;
            }
            break;
        case SDL_EVENT_MOUSE_MOTION:
            g->cursor_last_move = sc_tick_now();
            if (g->params.cursor_autohide_ms && g->cursor_hidden) {
                g->cursor_hidden = false;
                SDL_ShowCursor();
            }
            break;
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
            if (g->touch_visualizer_active) {
                float nx, ny;
                if (pointer_to_content(g, event->button.x, event->button.y,
                                       &nx, &ny)) {
                    sc_gaming_report_touch(g, 0, nx, ny, true);
                }
            }
            break;
        case SDL_EVENT_MOUSE_BUTTON_UP:
            sc_gaming_report_touch(g, 0, 0, 0, false);
            break;
        case SDL_EVENT_FINGER_DOWN:
        case SDL_EVENT_FINGER_MOTION:
        case SDL_EVENT_FINGER_UP: {
            if (!g->touch_visualizer_active) {
                break;
            }
            // SDL reports touch coordinates normalized to the display; convert
            // to window-local logical pixels first
            float dw = g->display_w / g->pixel_density;
            float dh = g->display_h / g->pixel_density;
            float ox = (g->window_x - g->display_x) / g->pixel_density;
            float oy = (g->window_y - g->display_y) / g->pixel_density;
            float px = event->tfinger.x * dw - ox;
            float py = event->tfinger.y * dh - oy;
            float nx, ny;
            bool down = event->type != SDL_EVENT_FINGER_UP;
            unsigned id = (unsigned) (event->tfinger.fingerID & 0xF);
            if (down && pointer_to_content(g, px, py, &nx, &ny)) {
                sc_gaming_report_touch(g, id, nx, ny, true);
            } else if (!down) {
                sc_gaming_report_touch(g, id, 0, 0, false);
            }
            break;
        }
        case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
        case SDL_EVENT_WINDOW_MOVED:
            refresh_window_metrics(g);
            break;
        default:
            break;
    }
    // never swallow events that the gaming module does not handle
    return true;
}

// ---------------------------------------------------------------------------
// OSD
// ---------------------------------------------------------------------------

// A quiet scene really does read under 1 KB/s: a static screen encoded as AV1
// measured 900 B/s while still presenting 30 fps (§5.1b9). On the OSD a bare 0
// says "the stream died" to whoever is watching it, and the integer cannot tell
// that apart from nothing having arrived. The bytes that made the figure are
// known, so when they are not zero, say so.
static void
osd_rate_text(char *out, size_t n, uint32_t kbps, uint64_t window_bytes) {
    if (!kbps && window_bytes) {
        snprintf(out, n, "<1 KB/S");
        return;
    }
    snprintf(out, n, "%u KB/S", kbps);
}

static void
osd_recompute(struct sc_gaming *g, const SDL_FRect *content) {
    g->osd_line_count = 0;
    if (g->params.osd == SC_OSD_OFF) {
        return;
    }

    if (g->params.osd == SC_OSD_COMPACT) {
        g->osd_line_count = 1;
        snprintf(g->osd_lines[0], sizeof(g->osd_lines[0]),
                 "FPS %u.%u  LAT %u MS",
                 (unsigned) g->fps, ((unsigned) (g->fps * 10.f)) % 10,
                 g->latency_known ? g->latency_ms : 0);
        return;
    }

    const char *renderer = SDL_GetRendererName(g->renderer);
    g->osd_line_count = 4;
    snprintf(g->osd_lines[0], sizeof(g->osd_lines[0]),
             "FPS %u.%u  TARGET %s",
             (unsigned) g->fps, ((unsigned) (g->fps * 10.f)) % 10,
             g->max_fps_label[0] ? g->max_fps_label : "NONE");
    char vid[24], aud[24];
    osd_rate_text(vid, sizeof vid, g->kbps_video, g->bytes_window_video);
    osd_rate_text(aud, sizeof aud, g->kbps_audio, g->bytes_window_audio);
    snprintf(g->osd_lines[1], sizeof(g->osd_lines[1]),
             "VID %s  AUD %s", vid, aud);
    snprintf(g->osd_lines[2], sizeof(g->osd_lines[2]),
             "SRC %ux%u  ON %ux%u", g->src_w, g->src_h,
             (unsigned) content->w, (unsigned) content->h);
    snprintf(g->osd_lines[3], sizeof(g->osd_lines[3]),
             "LAT %u AVG %u MAX %u MS%s%s%s",
             g->latency_known ? g->latency_ms : 0, g->latency_avg_ms,
             g->latency_max_ms,
             g->vbridge ? " BRIDGE" : "",
             g->postfx_active ? " FX" : "",
             g->params.window_filter != SC_WINDOW_FILTER_OFF && !g->win_broken
                 && g->win_frames ? " WIN" : "");
    (void) renderer;
}

static void
osd_render(struct sc_gaming *g) {
    unsigned cols = 0;
    for (unsigned i = 0; i < g->osd_line_count; ++i) {
        unsigned len = (unsigned) strlen(g->osd_lines[i]);
        if (len > cols) {
            cols = len;
        }
    }
    int scale = OSD_TEXT_SCALE;
    int w = (int) cols * GLYPH_ADVANCE * scale + 2 * OSD_PAD;
    int h = (int) (g->osd_line_count * (GLYPH_H + OSD_LINE_SPACING)) * scale
          + 2 * OSD_PAD;

    if (!g->osd_surface || g->osd_w != w || g->osd_h != h) {
        SDL_DestroySurface(g->osd_surface);
        SDL_DestroyTexture(g->osd_texture);
        g->osd_texture = NULL;
        g->osd_surface = SDL_CreateSurface(w, h, SDL_PIXELFORMAT_RGBA32);
        g->osd_w = w;
        g->osd_h = h;
        if (!g->osd_surface) {
            LOGW("OSD: surface allocation failed: %s", SDL_GetError());
            return;
        }
    }

    SDL_Surface *s = g->osd_surface;
    const SDL_PixelFormatDetails *details =
        SDL_GetPixelFormatDetails(s->format);
    if (!details) {
        LOGW("OSD: unknown surface format: %s", SDL_GetError());
        return;
    }
    const Uint32 bg = SDL_MapRGBA(details, NULL, 8, 8, 12, 170);
    const Uint32 fg = SDL_MapRGBA(details, NULL, 255, 232, 96, 255);
    SDL_FillSurfaceRect(s, NULL, bg);

    uint8_t *pixels = s->pixels;
    for (unsigned line = 0; line < g->osd_line_count; ++line) {
        const char *text = g->osd_lines[line];
        unsigned col = 0;
        for (const char *p = text; *p; ++p, ++col) {
            const uint8_t *rows = glyph_for(*p);
            for (int r = 0; r < GLYPH_H; ++r) {
                for (int c = 0; c < GLYPH_W; ++c) {
                    if (!(rows[r] & (1 << (GLYPH_W - 1 - c)))) {
                        continue;
                    }
                    for (int sy = 0; sy < scale; ++sy) {
                        int py = OSD_PAD
                               + (int) (line * (GLYPH_H + OSD_LINE_SPACING) + r)
                               * scale + sy;
                        if (py < 0 || py >= s->h) {
                            continue;
                        }
                        uint8_t *row = pixels + (size_t) py * s->pitch;
                        for (int sx = 0; sx < scale; ++sx) {
                            int px = OSD_PAD
                                   + (int) (col * GLYPH_ADVANCE + c) * scale
                                   + sx;
                            if (px < 0 || px >= s->w) {
                                continue;
                            }
                            *(Uint32 *) (row + (size_t) px * 4) = fg;
                        }
                    }
                }
            }
        }
    }

    if (!g->osd_texture) {
        g->osd_texture = SDL_CreateTextureFromSurface(g->renderer, s);
    } else if (!SDL_UpdateTexture(g->osd_texture, NULL, s->pixels,
                                  s->pitch)) {
        LOGW("OSD: texture update failed: %s", SDL_GetError());
    }
    if (g->osd_texture) {
        SDL_SetTextureBlendMode(g->osd_texture, SDL_BLENDMODE_BLEND);
    }
}

static void
draw_disc(SDL_Renderer *renderer, float cx, float cy, float radius,
          uint8_t alpha) {
    const int segments = 20;
    SDL_Vertex vertices[segments + 2];
    SDL_FColor fill = {0.35f, 0.75f, 1.0f, alpha / 255.f * 0.45f};
    vertices[0].position.x = cx;
    vertices[0].position.y = cy;
    vertices[0].color = fill;
    vertices[0].tex_coord.x = 0;
    vertices[0].tex_coord.y = 0;
    for (int i = 0; i <= segments; ++i) {
        double a = 2.0 * M_PI * i / segments;
        vertices[i + 1].position.x = cx + radius * (float) cos(a);
        vertices[i + 1].position.y = cy + radius * (float) sin(a);
        vertices[i + 1].color = fill;
        vertices[i + 1].tex_coord.x = 0;
        vertices[i + 1].tex_coord.y = 0;
    }
    SDL_RenderGeometry(renderer, NULL, vertices, segments + 2, NULL, 0);

    SDL_SetRenderDrawBlendMode(renderer, SDL_BLENDMODE_BLEND);
    SDL_SetRenderDrawColor(renderer, 90, 190, 255, alpha);
    SDL_FPoint ring[segments + 1];
    for (int i = 0; i <= segments; ++i) {
        double a = 2.0 * M_PI * i / segments;
        ring[i].x = cx + radius * (float) cos(a);
        ring[i].y = cy + radius * (float) sin(a);
    }
    SDL_RenderLines(renderer, ring, segments + 1);
}

// ---------------------------------------------------------------------------
// public API
// ---------------------------------------------------------------------------

bool
sc_gaming_init(struct sc_gaming *g, const struct sc_gaming_params *params,
               SDL_Window *window, SDL_Renderer *renderer) {
    memset(g, 0, sizeof(*g));
    g->params = *params;
    g->window = window;
    g->renderer = renderer;

    g->touch_visualizer_active = params->touch_visualizer;
    g->always_on_top_active = params->always_on_top;

    if (params->max_fps) {
        snprintf(g->max_fps_label, sizeof(g->max_fps_label), "%s",
                 params->max_fps);
    }

    refresh_window_metrics(g);

    if (params->low_latency) {
        if (!SDL_SetRenderVSync(renderer, 0)) {
            LOGW("low-latency: could not disable vsync: %s", SDL_GetError());
        } else {
            LOGI("Low latency: presentation vsync disabled");
        }
    }

    if (params->borderless_fullscreen) {
        set_borderless_fullscreen(g, true);
    }

    if (params->postfx) {
        g->lut_apply = build_luma_lut(g->luma_lut, params);
        g->lut_valid = true;
        LOGI("Host post-processing enabled (sharpen=%u night=%u sat=%u "
             "contrast=%u brightness=%u gamma=%u)",
             params->sharpen, params->night_boost, params->saturation,
             params->contrast, params->brightness, params->gamma);
    }

    if (params->window_filter != SC_WINDOW_FILTER_OFF) {
        LOGI("Window filter: %s host resample of the presented frame "
             "(adds CPU cost to the render path)",
             window_filter_name(params->window_filter));
    }

    if (params->frame_bridge) {
        unsigned bw = 0, bh = 0;
        if (params->bridge_scale_w && params->bridge_scale_h) {
            bw = params->bridge_scale_w;
            bh = params->bridge_scale_h;
        }
        g->vbridge = sc_video_bridge_create(params->frame_bridge, bw, bh,
                                           params->bridge_filter);
    }
    if (params->audio_bridge) {
        g->abridge = sc_byte_bridge_create(params->audio_bridge,
                                           "audio bridge");
    }
    if ((params->bridge_scale_w || params->bridge_scale_h)
            && !params->frame_bridge) {
        LOGW("--game-bridge-scale has no effect without --game-frame-bridge");
    }

    if (!SDL_AddEventWatch(gaming_event_watch, g)) {
        LOGW("gaming: could not install the event watch: %s", SDL_GetError());
    } else {
        g->event_watch_installed = true;
    }

    sc_tick now = sc_tick_now();
    g->telemetry_window_start = now;
    g->fps_window_start = now;
    g->cursor_last_move = now;
    if (params->borderless_fullscreen) {
        // Only the Super+F2 toggle used to call this, so the startup flag was
        // stored and never applied: the window came up captioned and sized to
        // the content instead of borderless over the display.
        SDL_DisplayID id = SDL_GetDisplayForWindow(g->window);
        SDL_Rect bounds;
        if (SDL_GetDisplayBounds(id, &bounds)) {
            g->display_x = bounds.x;
            g->display_y = bounds.y;
            g->display_w = bounds.w;
            g->display_h = bounds.h;
            set_borderless_fullscreen(g, true);
        } else {
            LOGW("borderless fullscreen: display bounds unavailable (%s)",
                 SDL_GetError());
        }
    }

    if (params->stall_timeout_ms) {
        // Started here, watched from its own thread: the failure this guards
        // against is a main thread that stops pumping events, so a check
        // inside the event loop could never run.
        SDL_SetAtomicInt(&g->stall_seen, 0);
        SDL_SetAtomicInt(&g->stall_stop, 0);
        g->stall_thread = SDL_CreateThread(stall_watchdog_run, "sc-stall", g);
        if (!g->stall_thread) {
            LOGW("stall watchdog: thread failed to start: %s", SDL_GetError());
        } else {
            LOGI("stall watchdog: first frame must arrive within %u ms",
                 params->stall_timeout_ms);
        }
    }

    sc_gaming_current = g;
    return true;
}

static int
stall_watchdog_run(void *userdata) {
    struct sc_gaming *g = userdata;
    const sc_tick start = sc_tick_now();
    const unsigned timeout = g->params.stall_timeout_ms;

    while (!SDL_GetAtomicInt(&g->stall_stop)) {
        if (SDL_GetAtomicInt(&g->stall_seen)) {
            // one job only: after the first picture the stream may legitimately
            // go quiet (the phone screen is off), and killing that would be a
            // worse bug than the one being guarded
            return 0;
        }
        if (SC_TICK_TO_MS(sc_tick_now() - start) < timeout) {
            SDL_Delay(100);
            continue;
        }
        LOGE("video-stalled: no frame %" PRIu64 " ms after the mirror opened, "
             "the decoder never delivered", (uint64_t) timeout);
        // Ask the main thread to end the session properly. If the main thread
        // is the blocked one -- which is what this looks like from outside --
        // nothing consumes the event, so end the process here rather than
        // leave the user a grey window they have to kill from Task Manager.
        // Pushed directly because the device-free demo harness links gaming.c
        // without events.c; sc_push_event() only adds the name to the log.
        SDL_Event quit;
        memset(&quit, 0, sizeof(quit));
        quit.type = SC_EVENT_DECODER_ERROR;
        SDL_PushEvent(&quit);
        SDL_Delay(2000);
        if (!SDL_GetAtomicInt(&g->stall_stop)) {
            LOGE("video-stalled: the session did not close, exiting now");
            exit(1);
        }
        return 0;
    }
    return 0;
}

static int
cmp_u32(const void *a, const void *b) {
    uint32_t x = *(const uint32_t *) a;
    uint32_t y = *(const uint32_t *) b;
    return x < y ? -1 : (x > y ? 1 : 0);
}

// nearest-rank percentile of an ascending array: the smallest value whose rank
// is at least pctl %
static uint32_t
percentile_u32(const uint32_t *sorted, unsigned count, unsigned pctl) {
    unsigned idx = (pctl * count + 99) / 100;
    if (!idx) {
        idx = 1;
    }
    if (idx > count) {
        idx = count;
    }
    return sorted[idx - 1];
}

void
sc_gaming_destroy(struct sc_gaming *g) {
    if (g->stall_thread) {
        SDL_SetAtomicInt(&g->stall_stop, 1);
        SDL_WaitThread(g->stall_thread, NULL);
        g->stall_thread = NULL;
    }
    if (sc_gaming_current == g) {
        sc_gaming_current = NULL;
    }
    if (g->event_watch_installed) {
        SDL_RemoveEventWatch(gaming_event_watch, g);
    }
    sc_video_bridge_destroy(g->vbridge);
    g->vbridge = NULL;
    sc_byte_bridge_destroy(g->abridge);
    g->abridge = NULL;

    if (g->cursor_hidden) {
        SDL_ShowCursor();
        g->cursor_hidden = false;
    }
    SDL_DestroyTexture(g->osd_texture);
    SDL_DestroySurface(g->osd_surface);
    av_frame_free(&g->work_frame);
    free(g->sharpen_tmp);
    if (g->win_frames) {
        // sc_tick is µs: this is the cost added to every presented frame
        LOGI("window filter: %" PRIu64 " frames resampled, avg=%.2fms "
             "(%u rebuilds)", g->win_frames,
             (double) g->win_total / 1000.0 / g->win_frames,
             (unsigned) g->win_rebuilds);
    }
    av_frame_free(&g->scaled_frame);
    sws_freeContext(g->win_sws);
    g->win_sws = NULL;
    if (g->postfx_frames) {
        // the number the filter overlay is allowed to be judged by: the cost of
        // the grade itself, per frame, as a distribution rather than a mean
        unsigned n = g->postfx_us_count;
        uint32_t sorted[SC_POSTFX_SAMPLES];
        memcpy(sorted, g->postfx_us, (size_t) n * sizeof(*sorted));
        qsort(sorted, n, sizeof(*sorted), cmp_u32);
        LOGI("postfx-cost: frames=%" PRIu64 " samples=%u med=%.3fms "
             "p90=%.3fms p99=%.3fms max=%.3fms avg=%.3fms",
             g->postfx_frames, n,
             (double) percentile_u32(sorted, n, 50) / 1000.0,
             (double) percentile_u32(sorted, n, 90) / 1000.0,
             (double) percentile_u32(sorted, n, 99) / 1000.0,
             (double) sorted[n - 1] / 1000.0,
             (double) g->postfx_total_us / (double) g->postfx_frames / 1000.0);
    }
    if (g->params.telemetry_log && g->window_latency_count) {
        unsigned n = g->window_latency_count;
        qsort(g->window_latency, n, sizeof(*g->window_latency), cmp_u32);
        // the host-side half of glass-to-glass: demuxer receive -> presented
        LOGI("telemetry-summary: seconds=%u lat_med=%ums lat_p90=%ums "
             "lat_p99=%ums lat_max=%ums lat_avg=%ums",
             n,
             percentile_u32(g->window_latency, n, 50),
             percentile_u32(g->window_latency, n, 90),
             percentile_u32(g->window_latency, n, 99),
             g->window_latency[n - 1], g->latency_avg_ms);
    }
}

void
sc_gaming_apply_upscale(struct sc_gaming *g, SDL_Texture *texture) {
    if (!texture || g->params.upscale_filter == SC_UPSCALE_DEFAULT) {
        return;
    }
    SDL_ScaleMode mode;
    const char *name;
    switch (g->params.upscale_filter) {
        case SC_UPSCALE_NEAREST:
            mode = SDL_SCALEMODE_NEAREST;
            name = "nearest";
            break;
        case SC_UPSCALE_LINEAR:
            mode = SDL_SCALEMODE_LINEAR;
            name = "linear";
            break;
        default:
            mode = SDL_SCALEMODE_PIXELART;
            name = "pixelart";
            break;
    }
    if (!SDL_SetTextureScaleMode(texture, mode)) {
        LOGW("upscaling filter: %s not available: %s", name, SDL_GetError());
    }
}

void
sc_gaming_account_packet(struct sc_gaming *g, size_t size, bool video) {
    if (video) {
        g->bytes_video += size;
        // remember when this picture entered the host so the OSD can report a
        // real measured latency even when the video buffer is disabled
        if (g->recv_count < sizeof(g->recv_fifo) / sizeof(g->recv_fifo[0])) {
            unsigned tail = (g->recv_head + g->recv_count)
                          % (sizeof(g->recv_fifo) / sizeof(g->recv_fifo[0]));
            g->recv_fifo[tail] = sc_tick_now();
            ++g->recv_count;
        }
    } else {
        g->bytes_audio += size;
    }
}

void
sc_gaming_push_audio(struct sc_gaming *g, const uint8_t *data, size_t len) {
    if (g->abridge) {
        sc_byte_bridge_push(g->abridge, data, len);
    }
}

#define PCM_TAP_RATE 48000
#define PCM_TAP_CHANNELS 2

/** Downcast frame_sink to sc_pcm_tap */
#define PCM_TAP_DOWNCAST(SINK) container_of(SINK, struct sc_pcm_tap, frame_sink)

static bool
pcm_tap_ensure_swr(struct sc_pcm_tap *tap, const AVFrame *frame) {
    int rate = frame->sample_rate;
    int channels = frame->ch_layout.nb_channels;
    int format = frame->format;
    if (!channels) {
        channels = PCM_TAP_CHANNELS;
    }
    if (tap->swr && tap->in_rate == rate && tap->in_channels == channels
            && tap->in_format == format) {
        return true;
    }
    swr_free(&tap->swr);
    tap->in_rate = 0;
    tap->in_channels = 0;
    tap->in_format = -1;

    AVChannelLayout in;
    if (av_channel_layout_copy(&in, &frame->ch_layout) < 0) {
        return false;
    }
    if (in.nb_channels != channels) {
        av_channel_layout_default(&in, channels);
    }
    AVChannelLayout out = AV_CHANNEL_LAYOUT_STEREO;
    int ret = swr_alloc_set_opts2(&tap->swr, &out, AV_SAMPLE_FMT_S16,
                                  PCM_TAP_RATE, &in, format, rate, 0, NULL);
    av_channel_layout_uninit(&in);
    if (ret < 0 || !tap->swr || swr_init(tap->swr) < 0) {
        swr_free(&tap->swr);
        return false;
    }
    tap->in_rate = rate;
    tap->in_channels = channels;
    tap->in_format = format;
    LOGI("pcm tap: %d Hz / %d ch / %s -> %d Hz s16le stereo", rate, channels,
         av_get_sample_fmt_name(format), PCM_TAP_RATE);
    return true;
}

void
sc_pcm_tap_push(struct sc_pcm_tap *tap, const AVFrame *frame) {
    if (!tap->bridge || tap->broken || !frame || frame->nb_samples <= 0
            || frame->sample_rate <= 0 || !frame->extended_data
            || !frame->extended_data[0]) {
        return;
    }
    if (!pcm_tap_ensure_swr(tap, frame)) {
        tap->broken = true;
        LOGW("pcm tap: resampler unavailable, tap disabled");
        return;
    }
    int out_max = (int) av_rescale_rnd(swr_get_delay(tap->swr,
                                                    frame->sample_rate)
                                       + frame->nb_samples,
                                       PCM_TAP_RATE, frame->sample_rate,
                                       AV_ROUND_UP);
    size_t need = (size_t) out_max * PCM_TAP_CHANNELS * 2;
    if (need > tap->buf_size) {
        free(tap->buf);
        tap->buf = malloc(need);
        if (!tap->buf) {
            tap->buf_size = 0;
            tap->broken = true;
            LOGW("pcm tap: out of memory, tap disabled");
            return;
        }
        tap->buf_size = need;
    }
    uint8_t *dst[1] = { tap->buf };
    int n = swr_convert(tap->swr, dst, out_max,
                        (const uint8_t **) frame->extended_data,
                        frame->nb_samples);
    if (n < 0) {
        tap->broken = true;
        LOGW("pcm tap: conversion failed (%d), tap disabled", n);
        return;
    }
    if (n > 0) {
        size_t bytes = (size_t) n * PCM_TAP_CHANNELS * 2;
        tap->pushed += bytes;
        sc_byte_bridge_push(tap->bridge, tap->buf, bytes);
    }
}

static bool
sc_pcm_tap_frame_sink_open(struct sc_frame_sink *sink,
                           const AVCodecContext *ctx,
                           const struct sc_stream_session *session) {
    (void) session;

    struct sc_pcm_tap *tap = PCM_TAP_DOWNCAST(sink);
    if (!tap->broken) {
        LOGI("pcm tap: source is %d Hz / %d ch / %s", ctx->sample_rate,
             ctx->ch_layout.nb_channels,
             av_get_sample_fmt_name(ctx->sample_fmt));
    }
    // never fail: the mirror must not depend on an optional audio output
    return true;
}

static void
sc_pcm_tap_frame_sink_close(struct sc_frame_sink *sink) {
    (void) sink;
}

static enum sc_sink_result
sc_pcm_tap_frame_sink_push(struct sc_frame_sink *sink, const AVFrame *frame) {
    sc_pcm_tap_push(PCM_TAP_DOWNCAST(sink), frame);
    // a slow or absent consumer only drops chunks inside the bridge, so the
    // decoder is never told to stop
    return SC_SINK_OK;
}

bool
sc_pcm_tap_init(struct sc_pcm_tap *tap, const char *path) {
    static const struct sc_frame_sink_ops ops = {
        .open = sc_pcm_tap_frame_sink_open,
        .close = sc_pcm_tap_frame_sink_close,
        .push = sc_pcm_tap_frame_sink_push,
    };

    memset(tap, 0, sizeof(*tap));
    tap->in_format = -1;
    tap->frame_sink.ops = &ops;

    if (!path || !*path) {
        // not configured: every push is a no-op
        return true;
    }
    tap->bridge = sc_byte_bridge_create(path, "pcm tap");
    if (!tap->bridge) {
        LOGW("pcm tap: bridge unavailable, tap disabled");
        return false;
    }
    return true;
}

void
sc_pcm_tap_destroy(struct sc_pcm_tap *tap) {
    if (tap->bridge) {
        LOGI("pcm tap: %" PRIu64 " bytes of s16le/%d Hz/stereo written",
             tap->pushed, PCM_TAP_RATE);
    }
    sc_byte_bridge_destroy(tap->bridge);
    swr_free(&tap->swr);
    free(tap->buf);
    memset(tap, 0, sizeof(*tap));
}

void
sc_gaming_set_postfx_grade(struct sc_gaming *g, const struct sc_gaming_params *p) {
    g->params.postfx = p->postfx;
    g->params.sharpen = p->sharpen;
    g->params.night_boost = p->night_boost;
    g->params.saturation = p->saturation;
    g->params.contrast = p->contrast;
    g->params.brightness = p->brightness;
    g->params.gamma = p->gamma;
    // the LUT is rebuilt lazily by the next filtered frame: one 256-entry table,
    // inside the pass that already exists. Nothing here touches the decoder, the
    // capture size or the pointer mapping.
    g->lut_valid = false;
}

const struct sc_gaming_params *
sc_gaming_get_params(const struct sc_gaming *g) {
    return &g->params;
}

const uint8_t *
sc_gaming_glyph(char c) {
    return glyph_for(c);
}

static void
record_postfx_cost(struct sc_gaming *g, sc_tick start) {
    uint32_t us = (uint32_t) SC_TICK_TO_US(sc_tick_now() - start);
    g->postfx_total_us += us;
    ++g->postfx_frames;
    if (g->postfx_us_count < SC_POSTFX_SAMPLES) {
        g->postfx_us[g->postfx_us_count++] = us;
        return;
    }
    // keep the recent window: a long session must not be judged by its first
    // frames, and the newest samples are the ones an overlay can still affect
    g->postfx_us[g->postfx_us_head] = us;
    g->postfx_us_head = (g->postfx_us_head + 1) % SC_POSTFX_SAMPLES;
}

struct AVFrame *
sc_gaming_process_frame(struct sc_gaming *g, struct AVFrame *frame) {
    if (!g->params.postfx || !frame
            || frame->format != AV_PIX_FMT_YUV420P) {
        g->postfx_active = false;
        return frame;
    }
    sc_tick t0 = sc_tick_now();
    if (!ensure_work_frame(g, frame)) {
        LOGW("postfx: work buffer unavailable, filters disabled");
        g->params.postfx = 0;
        g->postfx_active = false;
        return frame;
    }

    unsigned w = frame->width;
    unsigned h = frame->height;
    g->postfx_active = true;

    copy_plane(frame->data[0], frame->linesize[0], g->work_frame->data[0],
               g->work_frame->linesize[0], w, h);
    copy_plane(frame->data[1], frame->linesize[1], g->work_frame->data[1],
               g->work_frame->linesize[1], w / 2, h / 2);
    copy_plane(frame->data[2], frame->linesize[2], g->work_frame->data[2],
               g->work_frame->linesize[2], w / 2, h / 2);

    g->work_frame->pts = frame->pts;

    if (!g->lut_valid) {
        g->lut_apply = build_luma_lut(g->luma_lut, &g->params);
        g->lut_valid = true;
    }

    if (g->params.postfx & SC_POSTFX_SHARPEN) {
        copy_plane(g->work_frame->data[0], g->work_frame->linesize[0],
                   g->sharpen_tmp, (int) w, w, h);
        sharpen_luma(g->sharpen_tmp, (int) w, g->work_frame->data[0],
                     g->work_frame->linesize[0], w, h, g->params.sharpen);
    }
    if (g->lut_apply) {
        const uint8_t *lut = g->luma_lut;
        uint8_t *y = g->work_frame->data[0];
        int ls = g->work_frame->linesize[0];
        for (unsigned row = 0; row < h; ++row) {
            uint8_t *p = y + (size_t) row * ls;
            for (unsigned x = 0; x < w; ++x) {
                p[x] = lut[p[x]];
            }
        }
    }
    if ((g->params.postfx & SC_POSTFX_SATURATION)
            && g->params.saturation != 100) {
        scale_chroma(g->work_frame->data[1], g->work_frame->linesize[1],
                     w / 2, h / 2, g->params.saturation);
        scale_chroma(g->work_frame->data[2], g->work_frame->linesize[2],
                     w / 2, h / 2, g->params.saturation);
    }
    record_postfx_cost(g, t0);
    return g->work_frame;
}

void
sc_gaming_set_window_target(struct sc_gaming *g, unsigned w, unsigned h) {
    if (g->params.window_filter == SC_WINDOW_FILTER_OFF) {
        return;
    }
    // YUV420P requires even dimensions. Quantizing to 16px keeps a dragged
    // window from rebuilding the resampler on every mouse move while staying
    // within 8px of the content rect, which the GPU blit then absorbs.
    w = (w + 8u) & ~15u;
    h = (h + 8u) & ~15u;
    if (w < 16 || h < 16 || w > 8192 || h > 8192) {
        // minimized window or an absurd request: keep the GPU path
        g->win_target_w = 0;
        g->win_target_h = 0;
        return;
    }
    g->win_target_w = w;
    g->win_target_h = h;
}

struct AVFrame *
sc_gaming_resample_for_window(struct sc_gaming *g, struct AVFrame *frame) {
    if (g->params.window_filter == SC_WINDOW_FILTER_OFF || !frame
            || g->win_broken) {
        return frame;
    }
    if (frame->format != AV_PIX_FMT_YUV420P) {
        // hardware interop (or another layout): the texture upload expects the
        // decoded format, so resampling here would be rejected by the interop
        if (!g->win_fmt_warned) {
            g->win_fmt_warned = true;
            LOGW("window filter: frames are not YUV420P (software interop "
                 "required), GPU scaling kept");
        }
        return frame;
    }
    unsigned tw = g->win_target_w;
    unsigned th = g->win_target_h;
    if (!tw || !th
            || ((unsigned) frame->width == tw && (unsigned) frame->height == th)) {
        return frame;
    }
    if (!ensure_scaled_frame(g, frame)) {
        g->win_broken = true;
        LOGW("window filter: resampler unavailable, GPU scaling kept");
        return frame;
    }
    const uint8_t *const *src = (const uint8_t *const *) frame->data;
    uint8_t *const *dst = (uint8_t *const *) g->scaled_frame->data;
    sc_tick t0 = sc_tick_now();
    int ret = sws_scale(g->win_sws, src, frame->linesize, 0, frame->height,
                        dst, g->scaled_frame->linesize);
    if (ret < 0) {
        g->win_broken = true;
        LOGW("window filter: scale failed (%d), GPU scaling kept", ret);
        return frame;
    }
    g->win_total += sc_tick_now() - t0;
    ++g->win_frames;
    g->scaled_frame->pts = frame->pts;
    return g->scaled_frame;
}

void
sc_gaming_on_frame_rendered(struct sc_gaming *g, struct AVFrame *decoded,
                            struct AVFrame *output) {
    sc_tick now = sc_tick_now();

    ++g->rendered_frames;
    if (g->stall_thread && !SDL_GetAtomicInt(&g->stall_seen)) {
        SDL_SetAtomicInt(&g->stall_seen, 1);
    }
    if (!g->borderless_frame_checked && g->borderless_fullscreen_active) {
        // did the borderless state survive the window's first real frame?
        g->borderless_frame_checked = true;
        int rw = 0, rh = 0;
        SDL_GetWindowSize(g->window, &rw, &rh);
        LOGI("borderless: after first frame %dx%d flags=0x%x", rw, rh,
             (unsigned) SDL_GetWindowFlags(g->window));
    }
    if (g->fps_window_start && now >= g->fps_window_start) {
        sc_tick elapsed = now - g->fps_window_start;
        if (elapsed >= TELEMETRY_PERIOD) {
            g->fps = (float) g->rendered_frames * SC_TICK_FREQ / (float) elapsed;
            g->rendered_frames = 0;
            g->fps_window_start = now;
        }
    } else {
        g->fps_window_start = now;
    }

    sc_tick elapsed = now - g->telemetry_window_start;
    bool window_rolled = elapsed >= TELEMETRY_PERIOD;
    if (window_rolled) {
        // sc_tick is µs, so the rate factor is SC_TICK_FREQ (1e6), not 1000:
        // with 1000 the OSD showed ~5 KB/s for a 5300 KB/s stream.
        g->kbps_video = (uint32_t) (g->bytes_video * SC_TICK_FREQ
                                    / (uint64_t) elapsed / 1024ULL);
        g->kbps_audio = (uint32_t) (g->bytes_audio * SC_TICK_FREQ
                                    / (uint64_t) elapsed / 1024ULL);
        g->bytes_window_video = g->bytes_video;
        g->bytes_window_audio = g->bytes_audio;
        g->bytes_video = 0;
        g->bytes_audio = 0;
        g->telemetry_window_start = now;
    }

    // pop one receive timestamp per presented picture
    sc_tick recv = 0;
    if (g->recv_count) {
        recv = g->recv_fifo[g->recv_head];
        g->recv_head = (g->recv_head + 1)
                     % (sizeof(g->recv_fifo) / sizeof(g->recv_fifo[0]));
        --g->recv_count;
    }
    if (decoded && decoded->opaque_ref
            && decoded->opaque_ref->size >= sizeof(sc_tick)) {
        // the exact path: the demuxer date is carried on the frame
        recv = *(const sc_tick *) decoded->opaque_ref->data;
    }
    if (recv) {
        int64_t delta = now - recv;
        if (delta >= 0) {
            uint32_t ms = (uint32_t) SC_TICK_TO_MS(delta);
            g->latency_ms = ms;
            g->latency_known = true;
            if (!g->latency_avg_ms) {
                g->latency_avg_ms = ms;
            } else {
                g->latency_avg_ms = (uint32_t) (
                    LATENCY_EMA_ALPHA * ms
                    + (1.0 - LATENCY_EMA_ALPHA) * g->latency_avg_ms);
            }
            if (ms > g->latency_max_ms) {
                g->latency_max_ms = ms;
            }
        }
    }

    if (decoded) {
        g->src_w = decoded->width;
        g->src_h = decoded->height;
    }

    if (g->params.telemetry_log) {
        if (g->latency_ms > g->window_lat_max) {
            g->window_lat_max = g->latency_ms;
        }
        if (window_rolled) {
            unsigned cap = sizeof(g->window_latency)
                         / sizeof(g->window_latency[0]);
            if (g->window_latency_count < cap) {
                g->window_latency[g->window_latency_count++]
                    = g->window_lat_max;
            }
            uint32_t worst = g->window_lat_max;
            g->window_lat_max = 0;
            // the byte totals travel with the rates because a KB/s integer is 0
            // for both "nothing arrived" and "900 B/s arrived", and the second
            // one is a live picture (issue #44, measured in §5.1b9).
            LOGI("telemetry: fps=%u.%u v_kbps=%u a_kbps=%u lat=%ums "
                 "window_max=%ums src=%ux%u v_bytes=%llu a_bytes=%llu",
                 (unsigned) g->fps, ((unsigned) (g->fps * 10.f)) % 10,
                 g->kbps_video, g->kbps_audio,
                 g->latency_known ? g->latency_ms : 0, worst,
                 g->src_w, g->src_h,
                 (unsigned long long) g->bytes_window_video,
                 (unsigned long long) g->bytes_window_audio);
        }
    }
    if (output && g->vbridge) {
        sc_video_bridge_push(g->vbridge, output);
    }

    if (g->params.osd != SC_OSD_OFF && now >= g->osd_next_update) {
        g->osd_next_update = now + OSD_REFRESH_PERIOD;
    }

    if (g->params.cursor_autohide_ms && !g->cursor_hidden) {
        if (now >= g->cursor_last_move
                       + SC_TICK_FROM_MS(g->params.cursor_autohide_ms)) {
            g->cursor_hidden = true;
            SDL_HideCursor();
        }
    }
}

void
sc_gaming_render_overlay(struct sc_gaming *g, const SDL_FRect *content,
                         float pixel_density) {
    g->content_rect = *content;
    g->pixel_density = pixel_density > 0 ? pixel_density : 1.f;

    // the content rect is in logical pixels; multiply by the window pixel
    // density to address the renderer output (physical pixels)
    float scale = g->pixel_density;

    if (g->touch_visualizer_active) {
        sc_tick now = sc_tick_now();
        float radius = content->w * scale * 0.035f;
        if (radius < 10) {
            radius = 10;
        }
        for (unsigned i = 0; i < SC_GAMING_MAX_TOUCH_POINTS; ++i) {
            const struct sc_touch_point *t = &g->touches[i];
            bool fading = !t->active && now < t->since + TOUCH_FADE;
            if (!t->active && !fading) {
                continue;
            }
            uint8_t alpha = 255;
            if (fading) {
                alpha = (uint8_t) (255 * (t->since + TOUCH_FADE - now)
                                   / TOUCH_FADE);
            }
            float cx = (content->x + t->nx * content->w) * scale;
            float cy = (content->y + t->ny * content->h) * scale;
            draw_disc(g->renderer, cx, cy, radius, alpha);
        }
    }

    if (g->params.osd == SC_OSD_OFF) {
        return;
    }
    sc_tick now = sc_tick_now();
    if (!g->osd_texture || now >= g->osd_next_update) {
        if (g->osd_texture && now < g->osd_next_update) {
            // fall through: keep the existing texture
        }
        osd_recompute(g, content);
        osd_render(g);
        g->osd_next_update = now + OSD_REFRESH_PERIOD;
    }
    if (!g->osd_texture) {
        return;
    }
    SDL_FRect dst = {
        .x = content->x * scale + 12,
        .y = content->y * scale + 12,
        .w = g->osd_w,
        .h = g->osd_h,
    };
    SDL_RenderTexture(g->renderer, g->osd_texture, NULL, &dst);
}

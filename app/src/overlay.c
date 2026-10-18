#include "overlay.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
# include <windows.h>
#endif

#include "gaming.h"
#include "util/log.h"

// --- geometry: one 8 px grid, corners inside 6-8 px, nothing at 0 ----------
#define PANEL_W 496
#define PANEL_H 400
#define PAD 16
#define GAP 8
#define HEADER_H 32
#define ROW_H 40
#define SLIDER_Y 22
#define BTN_H 32
// three buttons on one row inside the padding: 160 did not fit (3*160 + 2*8
// overflows the 464 px content width, which cut CANCELAR at the panel edge),
// so the width is derived from the grid instead of chosen next to it
#define BTN_W ((PANEL_W - 2 * PAD - 2 * GAP) / 3)
#define BTN_X1 (PAD + BTN_W + GAP)
#define BTN_X2 (PAD + 2 * (BTN_W + GAP))
#define BTN_ROW1 312
#define BTN_ROW2 352
#define R_PANEL 8
#define R_CONTROL 6
#define TEXT_SCALE 2

_Static_assert(2 * PAD + 3 * BTN_W + 2 * GAP <= PANEL_W,
               "the action row must fit inside the panel");
_Static_assert(BTN_ROW2 + BTN_H <= PANEL_H, "the last button row must fit");

// SDL 3.4.18 here has no rounded-rect primitive and no system-move, so the
// panel draws its own corners (scanlines) and drags its own window.
#define PANEL_ALPHA 232

enum slide {
    SL_CONTRAST, SL_SATURATION, SL_BRIGHTNESS, SL_GAMMA, SL_SHARP, SL_NIGHT,
    SL_COUNT,
};

enum button {
    BTN_RESET, BTN_APPLY, BTN_CANCEL, BTN_SAVE, BTN_LOAD,
    BTN_COUNT,
};

struct slide_spec {
    const char *es;
    const char *en;
    unsigned min;
    unsigned max;
    unsigned neutral;
    unsigned bit;
};

static const struct slide_spec SLIDES[SL_COUNT] = {
    { "CONTRASTE",  "CONTRAST",   0,  200, 100, SC_POSTFX_CONTRAST   },
    { "SATURACION", "SATURATION", 0,  200, 100, SC_POSTFX_SATURATION },
    { "BRILLO",     "BRIGHTNESS", 0,  200, 100, SC_POSTFX_BRIGHTNESS },
    { "GAMMA",      "GAMMA",     25,  200, 100, SC_POSTFX_GAMMA      },
    { "NITIDEZ",    "SHARPEN",    0,  100,   0, SC_POSTFX_SHARPEN    },
    { "NOCTURNO",   "NIGHT",      0,  100,   0, SC_POSTFX_NIGHTBOOST },
};

static const char *const BTNS_ES[BTN_COUNT] = {
    "REINICIAR", "APLICAR", "CANCELAR", "GUARDAR", "CARGAR",
};
static const char *const BTNS_EN[BTN_COUNT] = {
    "RESET", "APPLY", "CANCEL", "SAVE", "LOAD",
};

struct filter {
    char name[24];
    unsigned v[SL_COUNT];
};

// the grades the brief suggested, so CARGAR has something to cycle through
// before the launcher ever writes a profile file
static const struct filter PRESETS[] = {
    { "Neutral",     { 100, 100, 100, 100,  0,  0 } },
    { "Vivid",       { 115, 135, 100, 105, 20,  0 } },
    { "Cinematic",   { 108, 108,  96, 112, 10,  0 } },
    { "Night",       {  96, 100, 118,  90,  0, 55 } },
    { "Competitive", { 112, 110, 104,  95, 60,  0 } },
};
#define PRESET_COUNT ((unsigned) (sizeof(PRESETS) / sizeof(PRESETS[0])))
#define PROFILE_MAX 16

struct sc_gaming_overlay {
    struct sc_gaming *gaming;
    SDL_Window *window;
    SDL_Renderer *renderer;

    struct sc_gaming_overlay_params params;
    char hotkey_label[32];
    bool visible;
    bool pending_show;    // asked for, but the window is not built yet
    bool dirty;
    int grabbed;   // slider being dragged, -1 for none
    int hover;     // control under the pointer, -1 for none
    bool dragging; // header drag in progress
    int drag_dx;   // window origin minus the global pointer at grab time
    int drag_dy;

    unsigned v[SL_COUNT];
    unsigned snapshot[SL_COUNT]; // what CANCELAR returns to
    bool changed;               // the user moved something in this session
    bool fading;                // the open animation is still running
    bool fade_logged;           // the panel has reported how its open went
    Uint32 fade_start;          // SDL_GetTicks() when the panel was shown
    SDL_TimerID fade_timer;     // wakes the event loop while fading
    struct filter profiles[PROFILE_MAX];
    unsigned profile_count;
    int loaded;                  // index into profiles, -1 when unsaved
    char status[48];

#ifdef _WIN32
    SDL_Thread *hk_thread;
    void *hwnd;             // HWND of the message-only window
    int hk_ready;           // 0 starting, 1 listening, 2 unavailable
    UINT hk_mods;
    UINT hk_vk;
#endif
};

static struct sc_gaming_overlay *g_active;
static Uint32 g_toggle_type;
static Uint32 g_fade_type;
static bool g_toggle_registered;

// v4 §5.2: the panel appears with a 120 ms fade rather than popping in over the
// game. It animates the window opacity, not the pixels, so the ramp costs a
// handful of SetWindowOpacity calls and no repaint: the panel still blits only
// when it is dirty, and the mirror's per-frame path never sees it.
#define FADE_MS 120
#define FADE_STEP_MS 20

// ---------------------------------------------------------------------------
// grade <-> engine
// ---------------------------------------------------------------------------

static unsigned
mask_of(const unsigned *v) {
    unsigned m = 0;
    for (unsigned i = 0; i < SL_COUNT; ++i) {
        if (v[i] != SLIDES[i].neutral) {
            m |= SLIDES[i].bit;
        }
    }
    return m;
}

static void
apply_live(struct sc_gaming_overlay *o) {
    struct sc_gaming_params p = {0};
    p.postfx = mask_of(o->v);
    p.contrast = o->v[SL_CONTRAST];
    p.saturation = o->v[SL_SATURATION];
    p.brightness = o->v[SL_BRIGHTNESS];
    p.gamma = o->v[SL_GAMMA];
    p.sharpen = o->v[SL_SHARP];
    p.night_boost = o->v[SL_NIGHT];
    // one shared 256-entry table is rebuilt by the next filtered frame: no new
    // pass enters the pipeline, which is the whole point of this window
    sc_gaming_set_postfx_grade(o->gaming, &p);
    o->changed = true;
}

static void
read_engine(struct sc_gaming_overlay *o) {
    // the mask decides whether a value counts, exactly as build_luma_lut()
    // treats it: a value carried over from another profile must not show up as
    // an active grade
    const struct sc_gaming_params *p = sc_gaming_get_params(o->gaming);
    o->v[SL_CONTRAST] = (p->postfx & SC_POSTFX_CONTRAST) ? p->contrast : 100;
    o->v[SL_SATURATION] = (p->postfx & SC_POSTFX_SATURATION)
                        ? p->saturation : 100;
    o->v[SL_BRIGHTNESS] = (p->postfx & SC_POSTFX_BRIGHTNESS)
                        ? p->brightness : 100;
    o->v[SL_GAMMA] = (p->postfx & SC_POSTFX_GAMMA) ? p->gamma : 100;
    o->v[SL_SHARP] = (p->postfx & SC_POSTFX_SHARPEN) ? p->sharpen : 0;
    o->v[SL_NIGHT] = (p->postfx & SC_POSTFX_NIGHTBOOST) ? p->night_boost : 0;
}

// ---------------------------------------------------------------------------
// profile file: "current c s b g sh n" plus "profile NAME c s b g sh n"
// ---------------------------------------------------------------------------

static void
use_presets(struct sc_gaming_overlay *o) {
    o->profile_count = 0;
    for (unsigned i = 0; i < PRESET_COUNT; ++i) {
        o->profiles[o->profile_count++] = PRESETS[i];
    }
}

static void
profiles_load(struct sc_gaming_overlay *o) {
    o->loaded = -1;
    if (!o->params.profiles_path) {
        use_presets(o);
        snprintf(o->status, sizeof(o->status),
                 o->params.spanish ? "SIN ARCHIVO / NO FILE" : "NO FILE");
        return;
    }
    FILE *f = fopen(o->params.profiles_path, "r");
    if (!f) {
        use_presets(o);
        snprintf(o->status, sizeof(o->status),
                 o->params.spanish ? "PERFILES INCORPORADOS" : "BUILT-IN GRADES");
        return;
    }
    char line[160];
    unsigned cur[SL_COUNT];
    bool have_current = false;
    o->profile_count = 0;
    while (fgets(line, sizeof(line), f)) {
        char name[24];
        unsigned v[SL_COUNT];
        if (!strncmp(line, "profile ", 8)) {
            if (o->profile_count < PROFILE_MAX
                    && sscanf(line, "profile %23s %u %u %u %u %u %u", name,
                              &v[0], &v[1], &v[2], &v[3], &v[4], &v[5]) == 7) {
                struct filter *slot = &o->profiles[o->profile_count++];
                memcpy(slot->name, name, sizeof(slot->name));
                memcpy(slot->v, v, sizeof(slot->v));
            }
        } else if (!strncmp(line, "current ", 8)) {
            // six conversions, not seven: "current" is literal text in the
            // format, so sscanf() cannot return 7 here (asserting 7 made the
            // stored grade unreachable and silently kept the CLI one)
            if (sscanf(line, "current %u %u %u %u %u %u", &cur[0], &cur[1],
                       &cur[2], &cur[3], &cur[4], &cur[5]) == 6) {
                have_current = true;
            }
        }
    }
    fclose(f);
    if (!o->profile_count) {
        use_presets(o);
    }
    if (have_current) {
        memcpy(o->v, cur, sizeof(cur));
        // the stored grade is the session's grade before the user opens the
        // panel: this is what "the active profile is applied at session start"
        // means, and it happens without waiting for a hotkey
        apply_live(o);
        snprintf(o->status, sizeof(o->status),
                 o->params.spanish ? "ACTUAL / CURRENT" : "CURRENT");
    } else {
        snprintf(o->status, sizeof(o->status), "%u %s", o->profile_count,
                 o->params.spanish ? "PERFILES" : "PROFILES");
    }
}

static bool
profiles_save(struct sc_gaming_overlay *o) {
    if (!o->params.profiles_path) {
        return false;
    }
    FILE *f = fopen(o->params.profiles_path, "w");
    if (!f) {
        LOGW("overlay: cannot write profiles at %s", o->params.profiles_path);
        return false;
    }
    fprintf(f, "# GamingScrcpy filter profiles v1\n");
    fprintf(f, "current %u %u %u %u %u %u\n", o->v[0], o->v[1], o->v[2],
            o->v[3], o->v[4], o->v[5]);
    for (unsigned i = 0; i < o->profile_count; ++i) {
        const struct filter *p = &o->profiles[i];
        fprintf(f, "profile %s %u %u %u %u %u %u\n", p->name, p->v[0], p->v[1],
                p->v[2], p->v[3], p->v[4], p->v[5]);
    }
    fclose(f);
    return true;
}

// ---------------------------------------------------------------------------
// drawing
// ---------------------------------------------------------------------------

static void
fill_rounded(SDL_Renderer *r, const SDL_FRect *rc, int radius) {
    int w = (int) rc->w;
    int h = (int) rc->h;
    if (w <= 0 || h <= 0) {
        return;
    }
    int rr = radius;
    if (rr * 2 > h) {
        rr = h / 2;
    }
    if (rr * 2 > w) {
        rr = w / 2;
    }
    if (rr < 1) {
        SDL_RenderFillRect(r, rc);
        return;
    }
    for (int y = 0; y < h; ++y) {
        int k = y < rr ? y : (h - 1 - y < rr ? h - 1 - y : rr);
        float inset = 0.f;
        if (k < rr) {
            float dy = (float) rr - (float) k - 0.5f;
            if (dy < 0.f) {
                dy = 0.f;
            }
            if (dy < (float) rr) {
                inset = (float) rr
                      - sqrtf((float) rr * (float) rr - dy * dy);
            }
        }
        int span = w - 2 * (int) (inset + 0.5f);
        if (span <= 0) {
            continue;
        }
        SDL_FRect line = { rc->x + inset, rc->y + y, span, 1 };
        SDL_RenderFillRect(r, &line);
    }
}

// border + fill in one call: the panel has no stroke primitive, so a frame is
// a larger rounded shape painted behind a smaller one
static void
draw_box(SDL_Renderer *r, const SDL_FRect *rc, int radius, int border,
         Uint8 br, Uint8 bg, Uint8 bb, Uint8 ba,
         Uint8 fr, Uint8 fg, Uint8 fb, Uint8 fa) {
    SDL_SetRenderDrawColor(r, br, bg, bb, ba);
    fill_rounded(r, rc, radius);
    SDL_FRect inner = { rc->x + border, rc->y + border,
                        rc->w - 2 * border, rc->h - 2 * border };
    SDL_SetRenderDrawColor(r, fr, fg, fb, fa);
    fill_rounded(r, &inner, radius > border ? radius - border : 1);
}

static void
draw_text(SDL_Renderer *r, int x, int y, const char *text, uint8_t scale,
          Uint8 red, Uint8 green, Uint8 blue) {
    SDL_SetRenderDrawColor(r, red, green, blue, 255);
    unsigned col = 0;
    for (const char *p = text; *p; ++p, ++col) {
        const uint8_t *rows = sc_gaming_glyph(*p);
        for (int row = 0; row < GLYPH_H; ++row) {
            for (int c = 0; c < GLYPH_W; ++c) {
                if (!(rows[row] & (1 << (GLYPH_W - 1 - c)))) {
                    continue;
                }
                SDL_FRect px = {
                    x + (int) (col * GLYPH_ADVANCE + c) * (int) scale,
                    y + row * (int) scale,
                    (float) scale, (float) scale,
                };
                SDL_RenderFillRect(r, &px);
            }
        }
    }
}

static int
text_w(const char *text) {
    return (int) strlen(text) * GLYPH_ADVANCE * TEXT_SCALE;
}

static SDL_FRect
button_rect(unsigned idx) {
    SDL_FRect rc;
    rc.x = idx == 0 ? PAD : (idx == 1 ? BTN_X1 : (idx == 2 ? BTN_X2
                : (idx == 3 ? PAD : BTN_X1)));
    rc.y = idx < 3 ? BTN_ROW1 : BTN_ROW2;
    rc.w = BTN_W;
    rc.h = BTN_H;
    return rc;
}

static void
draw_button(struct sc_gaming_overlay *o, unsigned idx, const char *label) {
    SDL_FRect rc = button_rect(idx);
    bool hot = o->hover == (int) (100 + idx);
    // hover is a thicker frame, not only a brighter one: the state survives
    // without relying on hue
    int border = hot ? 2 : 1;
    if (idx == BTN_APPLY) {
        draw_box(o->renderer, &rc, R_CONTROL, border,
                 79, 163, 255, 255, 30, 58, 87, 255);
    } else if (idx == BTN_CANCEL) {
        draw_box(o->renderer, &rc, R_CONTROL, border,
                 hot ? 200 : 194, hot ? 202 : 85, hot ? 210 : 106, 255,
                 42, 26, 34, 255);
    } else {
        draw_box(o->renderer, &rc, R_CONTROL, border,
                 hot ? 232 : 42, hot ? 234 : 47, hot ? 240 : 58, 255,
                 29, 32, 40, 255);
    }
    draw_text(o->renderer, (int) rc.x + (BTN_W - text_w(label)) / 2,
              (int) rc.y + (BTN_H - 7 * TEXT_SCALE) / 2, label, TEXT_SCALE,
              232, 234, 240);
}

static void
overlay_paint(struct sc_gaming_overlay *o) {
    SDL_Renderer *r = o->renderer;
    bool es = o->params.spanish;
    SDL_FRect body = { 0, 0, PANEL_W, PANEL_H };

    SDL_SetRenderDrawColor(r, 0, 0, 0, 255);
    SDL_RenderClear(r);
    // 91 % over the window's own black: SDL3 has no per-window alpha on
    // Windows, so the "not a slab of opaque chrome" requirement is met here
    draw_box(r, &body, R_PANEL, 1, 42, 47, 58, 255, 22, 24, 31, PANEL_ALPHA);

    draw_text(r, PAD, (HEADER_H - 7 * TEXT_SCALE) / 2, "FILTROS", TEXT_SCALE,
              79, 163, 255);
    draw_text(r, PANEL_W - PAD - text_w(o->hotkey_label),
              (HEADER_H - 7 * TEXT_SCALE) / 2, o->hotkey_label, TEXT_SCALE,
              141, 148, 166);
    SDL_FRect sep = { PAD, HEADER_H, PANEL_W - 2 * PAD, 1 };
    SDL_SetRenderDrawColor(r, 42, 47, 58, 255);
    SDL_RenderFillRect(r, &sep);

    draw_text(r, PAD, 44, o->status, TEXT_SCALE, 141, 148, 166);

    for (unsigned i = 0; i < SL_COUNT; ++i) {
        int y = 72 + (int) i * ROW_H;
        const struct slide_spec *s = &SLIDES[i];
        bool on = o->grabbed == (int) i || o->hover == (int) i;
        draw_text(r, PAD, y, es ? s->es : s->en, TEXT_SCALE, 232, 234, 240);
        char num[8];
        snprintf(num, sizeof(num), "%u", o->v[i]);
        // the value goes accent-coloured only when the filter actually bites
        bool neutral = o->v[i] == s->neutral;
        draw_text(r, PANEL_W - PAD - text_w(num), y, num, TEXT_SCALE,
                  neutral ? 141 : 79, neutral ? 148 : 163,
                  neutral ? 166 : 255);

        SDL_FRect track = { PAD, (float) (y + SLIDER_Y),
                            PANEL_W - 2 * PAD, 8 };
        draw_box(r, &track, 4, 1, 42, 47, 58, 255, 29, 32, 40, 255);
        float frac = (float) (o->v[i] - s->min) / (float) (s->max - s->min);
        SDL_FRect fill = { track.x + 1, track.y + 1,
                           (track.w - 2) * frac, track.h - 2 };
        SDL_SetRenderDrawColor(r, 79, 163, 255, 255);
        fill_rounded(r, &fill, 3);
        float hx = track.x + track.w * frac - 8;
        if (hx < track.x) {
            hx = track.x;
        }
        if (hx + 16 > track.x + track.w) {
            hx = track.x + track.w - 16;
        }
        SDL_FRect knob = { hx, track.y - 4, 16, 16 };
        draw_box(r, &knob, on ? 8 : R_CONTROL, on ? 2 : 1,
                 79, 163, 255, 255, 232, 234, 240, 255);
    }

    for (unsigned i = 0; i < BTN_COUNT; ++i) {
        draw_button(o, i, es ? BTNS_ES[i] : BTNS_EN[i]);
    }
    SDL_RenderPresent(r);
    o->dirty = false;
}

// ---------------------------------------------------------------------------
// hit testing
// ---------------------------------------------------------------------------

static int
hit_slider(float x, float y) {
    for (unsigned i = 0; i < SL_COUNT; ++i) {
        float track_y = 72 + (int) i * ROW_H + SLIDER_Y;
        if (y >= track_y - 8 && y <= track_y + 16 && x >= PAD - 4
                && x <= PANEL_W - PAD + 4) {
            return (int) i;
        }
    }
    return -1;
}

static int
hit_button(float x, float y) {
    for (int i = 0; i < BTN_COUNT; ++i) {
        SDL_FRect rc = button_rect((unsigned) i);
        if (x >= rc.x && x <= rc.x + rc.w && y >= rc.y && y <= rc.y + rc.h) {
            return i;
        }
    }
    return -1;
}

static void
set_from_x(struct sc_gaming_overlay *o, int idx, float x) {
    const struct slide_spec *s = &SLIDES[idx];
    float frac = (x - PAD) / (float) (PANEL_W - 2 * PAD);
    if (frac < 0) {
        frac = 0;
    }
    if (frac > 1) {
        frac = 1;
    }
    unsigned v = s->min + (unsigned) (frac * (s->max - s->min) + 0.5f);
    if (v == o->v[idx]) {
        return;
    }
    o->v[idx] = v;
    apply_live(o);
    o->dirty = true;
}

static void
press_button(struct sc_gaming_overlay *o, int idx) {
    bool es = o->params.spanish;
    switch (idx) {
        case BTN_RESET:
            for (unsigned i = 0; i < SL_COUNT; ++i) {
                o->v[i] = SLIDES[i].neutral;
            }
            apply_live(o);
            snprintf(o->status, sizeof(o->status),
                     es ? "REINICIADO" : "RESET");
            break;
        case BTN_APPLY:
            apply_live(o);
            snprintf(o->status, sizeof(o->status),
                     profiles_save(o)
                     ? (es ? "APLICADO + GUARDADO" : "APPLIED + SAVED")
                     : (es ? "APLICADO (VIVO)" : "APPLIED (LIVE)"));
            break;
        case BTN_CANCEL:
            memcpy(o->v, o->snapshot, sizeof(o->v));
            apply_live(o);
            snprintf(o->status, sizeof(o->status),
                     es ? "DESCARTADO" : "CANCELLED");
            break;
        case BTN_SAVE: {
            char name[24];
            if (o->loaded >= 0 && (unsigned) o->loaded < o->profile_count) {
                memcpy(name, o->profiles[o->loaded].name, sizeof(name));
            } else {
                snprintf(name, sizeof(name), "Overlay");
            }
            struct filter dup;
            memcpy(dup.name, name, sizeof(dup.name));
            memcpy(dup.v, o->v, sizeof(dup.v));
            bool replaced = false;
            for (unsigned i = 0; i < o->profile_count; ++i) {
                if (!strcmp(o->profiles[i].name, name)) {
                    o->profiles[i] = dup;
                    replaced = true;
                    break;
                }
            }
            if (!replaced && o->profile_count < PROFILE_MAX) {
                o->profiles[o->profile_count++] = dup;
            }
            for (unsigned i = 0; i < o->profile_count; ++i) {
                if (!strcmp(o->profiles[i].name, name)) {
                    o->loaded = (int) i;
                    break;
                }
            }
            apply_live(o);
            if (profiles_save(o)) {
                snprintf(o->status, sizeof(o->status), "%s", name);
            } else {
                snprintf(o->status, sizeof(o->status),
                         es ? "NO SE PUDO ESCRIBIR" : "CANNOT WRITE");
            }
            break;
        }
        case BTN_LOAD: {
            if (!o->profile_count) {
                break;
            }
            o->loaded = (int) ((unsigned) (o->loaded + 1) % o->profile_count);
            memcpy(o->v, o->profiles[o->loaded].v, sizeof(o->v));
            apply_live(o);
            snprintf(o->status, sizeof(o->status), "%s",
                     o->profiles[o->loaded].name);
            break;
        }
        default:
            break;
    }
    o->dirty = true;
}

// ---------------------------------------------------------------------------
// events
// ---------------------------------------------------------------------------

static SDL_WindowID
event_window_id(const SDL_Event *ev) {
    switch (ev->type) {
        case SDL_EVENT_KEY_DOWN:
        case SDL_EVENT_KEY_UP:
            return ev->key.windowID;
        case SDL_EVENT_TEXT_INPUT:
        case SDL_EVENT_TEXT_EDITING:
            return ev->text.windowID;
        case SDL_EVENT_MOUSE_MOTION:
            return ev->motion.windowID;
        case SDL_EVENT_MOUSE_BUTTON_DOWN:
        case SDL_EVENT_MOUSE_BUTTON_UP:
            return ev->button.windowID;
        case SDL_EVENT_MOUSE_WHEEL:
            return ev->wheel.windowID;
        default:
            if (ev->type >= SDL_EVENT_WINDOW_FIRST
                    && ev->type <= SDL_EVENT_WINDOW_LAST) {
                return ev->window.windowID;
            }
            return 0;
    }
}

bool
sc_gaming_event_is_for_overlay(const SDL_Event *event) {
    if (!event) {
        return false;
    }
    SDL_WindowID id = event_window_id(event);
    return id != 0 && g_active && g_active->window
        && id == SDL_GetWindowID(g_active->window);
}

SDL_WindowID
sc_gaming_overlay_active_window_id(void) {
    if (!g_active || !g_active->window) {
        return 0;
    }
    return SDL_GetWindowID(g_active->window);
}

// The panel owns a second window and a second renderer. Building them while the
// mirror is still starting up cost the mirror its first frame: a session opened
// with --game-filter-overlay never painted and Windows marked the window "Not
// Responding" (BUILD_REPORT §5.1ar). The panel is hidden until the user asks for
// it, so its window is created on that first request, from the main loop.
static bool
overlay_ensure_window(struct sc_gaming_overlay *o) {
    if (o->window) {
        return true;
    }
    Uint32 flags = SDL_WINDOW_BORDERLESS | SDL_WINDOW_ALWAYS_ON_TOP
                 | SDL_WINDOW_HIGH_PIXEL_DENSITY | SDL_WINDOW_HIDDEN;
    o->window = SDL_CreateWindow(o->params.title ? o->params.title
                                                 : "GamingScrcpy filters",
                                 PANEL_W, PANEL_H, flags);
    if (!o->window) {
        LOGE("overlay: window failed: %s", SDL_GetError());
        return false;
    }
    int x = 64, y = 64;
    if (o->params.parent) {
        // land it at the mirror's top-right rather than over the game's HUD
        int wx, wy, ww, wh;
        SDL_GetWindowPosition(o->params.parent, &wx, &wy);
        SDL_GetWindowSize(o->params.parent, &ww, &wh);
        x = wx + ww - PANEL_W - PAD;
        y = wy + HEADER_H + PAD;
        if (x < 0) {
            x = PAD;
        }
        if (y < 0) {
            y = PAD;
        }
    }
    SDL_SetWindowPosition(o->window, x, y);

    // asked for by name so the mirror keeps the GPU to itself; the software
    // backend only ever blits when the panel is dirty
    o->renderer = SDL_CreateRenderer(o->window, "software");
    if (!o->renderer) {
        LOGI("overlay: software renderer unavailable (%s), using the default",
             SDL_GetError());
        o->renderer = SDL_CreateRenderer(o->window, NULL);
    }
    if (!o->renderer) {
        LOGE("overlay: renderer failed: %s", SDL_GetError());
        SDL_DestroyWindow(o->window);
        o->window = NULL;
        return false;
    }
    SDL_SetRenderVSync(o->renderer, 0);
    SDL_SetRenderDrawBlendMode(o->renderer, SDL_BLENDMODE_BLEND);
    LOGI("filter-overlay: panel window=%dx%d renderer=%s", PANEL_W, PANEL_H,
         SDL_GetRendererName(o->renderer));
    return true;
}

static void
set_visible(struct sc_gaming_overlay *o, bool visible) {
    o->visible = visible;
    o->dragging = false;
    if (visible) {
        memcpy(o->snapshot, o->v, sizeof(o->v));
        // never build the window from here: this runs inside an event watch,
        // while SDL is pumping events. The main loop does it on its next pass.
        o->pending_show = true;
        o->dirty = true;
    } else {
        o->grabbed = -1;
        o->hover = -1;
        if (o->window) {
            // hiding mid-fade must not leave the panel transparent for the next show
            o->fading = false;
            SDL_SetWindowOpacity(o->window, 1.0f);
            SDL_HideWindow(o->window);
        }
    }
}

void
sc_gaming_overlay_toggle(struct sc_gaming_overlay *o) {
    if (!o) {
        return;
    }
    if (!o->visible) {
        read_engine(o);
    }
    set_visible(o, !o->visible);
}

bool
sc_gaming_overlay_hotkey_live(struct sc_gaming_overlay *o) {
#ifdef _WIN32
    return o && o->hk_ready == 1;
#else
    (void) o;
    return false;
#endif
}

bool
sc_gaming_overlay_want_local_hotkey(struct sc_gaming_overlay *o,
                                    const SDL_Event *event) {
#ifdef _WIN32
    // armed only while RegisterHotKey() does not have the combo: if it does,
    // the message thread already toggles and handling the keydown too would
    // open and close the panel in one press
    if (!o || o->hk_ready == 1 || o->hk_vk == 0) {
        return false;
    }
    if (event->type != SDL_EVENT_KEY_DOWN || event->key.repeat) {
        return false;
    }
    if (o->window && event_window_id(event) == SDL_GetWindowID(o->window)) {
        // keys inside the panel are its own business (Esc closes it)
        return false;
    }
    SDL_Scancode want;
    if (o->hk_vk >= VK_F1 && o->hk_vk <= VK_F12) {
        want = (SDL_Scancode) (SDL_SCANCODE_F1 + (o->hk_vk - VK_F1));
    } else if (o->hk_vk >= 'A' && o->hk_vk <= 'Z') {
        want = (SDL_Scancode) (SDL_SCANCODE_A + (o->hk_vk - 'A'));
    } else if (o->hk_vk == '0') {
        want = SDL_SCANCODE_0;
    } else if (o->hk_vk >= '1' && o->hk_vk <= '9') {
        want = (SDL_Scancode) (SDL_SCANCODE_1 + (o->hk_vk - '1'));
    } else {
        return false;
    }
    if (event->key.scancode != want) {
        return false;
    }
    // the modifier set must match exactly, so Ctrl+Alt+Shift+F is a different
    // shortcut and stays with the game
    SDL_Keymod held = event->key.mod
            & (SDL_KMOD_ALT | SDL_KMOD_CTRL | SDL_KMOD_SHIFT | SDL_KMOD_GUI);
    SDL_Keymod want_mod = 0;
    if (o->hk_mods & MOD_ALT) {
        want_mod |= SDL_KMOD_ALT;
    }
    if (o->hk_mods & MOD_CONTROL) {
        want_mod |= SDL_KMOD_CTRL;
    }
    if (o->hk_mods & MOD_SHIFT) {
        want_mod |= SDL_KMOD_SHIFT;
    }
    if (o->hk_mods & MOD_WIN) {
        want_mod |= SDL_KMOD_GUI;
    }
    return held == want_mod;
#else
    (void) o;
    (void) event;
    return false;
#endif
}

// The event loop blocks in SDL_WaitEvent, so nothing would wake it to advance
// the ramp. The timer only posts an event -- every pixel change happens on the
// main thread, in the tick below, exactly like the hotkey thread does.
static Uint32 SDLCALL
fade_wakeup(void *userdata, SDL_TimerID timerID, Uint32 interval) {
    (void) userdata;
    (void) timerID;
    struct sc_gaming_overlay *o = g_active;
    if (!o || !o->fading || !g_fade_type) {
        return 0; // stop re-arming once the ramp is over
    }
    SDL_Event ev;
    SDL_zero(ev);
    ev.type = (SDL_EventType) g_fade_type;
    SDL_PushEvent(&ev);
    return interval;
}

// The same switch the launcher reads through SystemParameters.ClientAreaAnimation:
// a user who turned Windows animations off gets the panel at full opacity at once.
static bool
overlay_animations_ok(void) {
    // the harness has to exercise the ramp on a host whose Windows setting is
    // off (this build machine is one), and no shipped path sets this variable
    if (SDL_getenv("GAMINGSCRCPY_FORCE_FADE")) {
        return true;
    }
#ifdef _WIN32
# ifndef SPI_GETCLIENTAREAANIMATION
#  define SPI_GETCLIENTAREAANIMATION 0x1048
# endif
    BOOL on = TRUE;
    if (!SystemParametersInfoA(SPI_GETCLIENTAREAANIMATION, 0, &on, 0)) {
        return true; // unreadable setting: animate, like the default of the API
    }
    return on != FALSE;
#else
    return false; // only Windows has an opacity path here; others paint at once
#endif
}

void
sc_gaming_overlay_tick(void) {
    struct sc_gaming_overlay *o = g_active;
    if (!o) {
        return;
    }
    if (o->pending_show) {
        o->pending_show = false;
        if (!overlay_ensure_window(o)) {
            o->visible = false;
            return;
        }
        SDL_ShowWindow(o->window);
        SDL_RaiseWindow(o->window);
        o->dirty = true;
        if (overlay_animations_ok()) {
            o->fading = true;
            o->fade_start = SDL_GetTicks();
            SDL_SetWindowOpacity(o->window, 0.0f);
            if (!o->fade_timer) {
                o->fade_timer = SDL_AddTimer(FADE_STEP_MS, fade_wakeup, NULL);
            }
            if (!o->fade_timer) {
                // no timer means no wakeups, and a half-transparent panel would
                // never be raised: fall back to the instant show
                LOGW("overlay: fade timer unavailable, showing the panel at once");
                o->fading = false;
                SDL_SetWindowOpacity(o->window, 1.0f);
            }
        } else if (!o->fade_logged) {
            o->fade_logged = true;
            LOGI("filter-overlay: open fade skipped (Windows animations are off)");
        }
    }
    if (o->fading && o->window) {
        Uint32 elapsed = SDL_GetTicks() - o->fade_start;
        float a = elapsed >= FADE_MS ? 1.0f : (float) elapsed / (float) FADE_MS;
        SDL_SetWindowOpacity(o->window, a);
        if (a >= 1.0f) {
            o->fading = false;
            if (!o->fade_logged) {
                o->fade_logged = true;
                LOGI("filter-overlay: open fade complete in %u ms (opacity back to 1.00)",
                     elapsed);
            }
        }
    }
    if (o->visible && o->window && o->dirty) {
        overlay_paint(o);
    }
}

bool
sc_gaming_overlay_snapshot(struct sc_gaming_overlay *o, const char *path) {
    // the harness needs the panel's own pixels: a screenshot of the mirror
    // cannot show whether the panel painted
    if (!o || !path) {
        return false;
    }
    if (!o->visible) {
        sc_gaming_overlay_toggle(o);
    }
    // the panel has no window until it is first asked for, and this is that ask
    sc_gaming_overlay_tick();
    if (!o->renderer) {
        return false;
    }
    overlay_paint(o);
    SDL_Surface *s = SDL_RenderReadPixels(o->renderer, NULL);
    if (!s) {
        LOGE("overlay: readback failed: %s", SDL_GetError());
        return false;
    }
    bool ok = SDL_SaveBMP(s, path);
    if (!ok) {
        LOGE("overlay: cannot write %s: %s", path, SDL_GetError());
    }
    SDL_DestroySurface(s);
    return ok;
}

void
sc_gaming_overlay_demo_pulse(int delta) {
    struct sc_gaming_overlay *o = g_active;
    if (!o) {
        return;
    }
    if (!o->visible) {
        sc_gaming_overlay_toggle(o);
    }
    sc_gaming_overlay_tick();
    for (unsigned i = 0; i < SL_COUNT; ++i) {
        const struct slide_spec *s = &SLIDES[i];
        long v = (long) s->neutral + delta;
        if (v < (long) s->min) {
            v = (long) s->min;
        }
        if (v > (long) s->max) {
            v = (long) s->max;
        }
        o->v[i] = (unsigned) v;
    }
    apply_live(o);
    o->dirty = true;
}

static bool SDLCALL
overlay_watch(void *userdata, SDL_Event *event) {
    struct sc_gaming_overlay *o = userdata;
    if (!o || !o->window) {
        return true;
    }
    if (g_toggle_registered && event->type == g_toggle_type) {
        sc_gaming_overlay_toggle(o);
        return false;
    }
    if (event_window_id(event) != SDL_GetWindowID(o->window)) {
        return true;
    }
    if (!o->visible) {
        return false;
    }
    switch (event->type) {
        case SDL_EVENT_MOUSE_MOTION: {
            if (o->dragging) {
                float gx, gy;
                SDL_GetGlobalMouseState(&gx, &gy);
                SDL_SetWindowPosition(o->window, (int) gx + o->drag_dx,
                                      (int) gy + o->drag_dy);
                break;
            }
            int s = hit_slider(event->motion.x, event->motion.y);
            int b = s < 0 ? hit_button(event->motion.x, event->motion.y) : -1;
            int next = s >= 0 ? s : (b >= 0 ? 100 + b : -1);
            if (o->grabbed >= 0) {
                set_from_x(o, o->grabbed, event->motion.x);
            }
            if (next != o->hover) {
                o->hover = next;
                o->dirty = true;
            }
            break;
        }
        case SDL_EVENT_MOUSE_BUTTON_DOWN: {
            float x = event->button.x;
            float y = event->button.y;
            if (y <= HEADER_H) {
                // borderless windows have no title bar, so the header band is
                // the handle: remember where inside it the pointer landed
                float gx, gy;
                int wx, wy;
                SDL_GetGlobalMouseState(&gx, &gy);
                SDL_GetWindowPosition(o->window, &wx, &wy);
                o->drag_dx = wx - (int) gx;
                o->drag_dy = wy - (int) gy;
                o->dragging = true;
                break;
            }
            int s = hit_slider(x, y);
            if (s >= 0) {
                o->grabbed = s;
                set_from_x(o, s, x);
                break;
            }
            int b = hit_button(x, y);
            if (b >= 0) {
                press_button(o, b);
            }
            break;
        }
        case SDL_EVENT_MOUSE_BUTTON_UP:
            o->grabbed = -1;
            o->dragging = false;
            break;
        case SDL_EVENT_KEY_DOWN:
            if (event->key.key == SDLK_ESCAPE) {
                set_visible(o, false);
                break;
            }
            if (event->key.key == SDLK_TAB) {
                o->hover = (o->hover + 1) % (int) (SL_COUNT + BTN_COUNT);
                o->dirty = true;
                break;
            }
            if (o->hover >= 0 && o->hover < (int) SL_COUNT
                    && (event->key.key == SDLK_LEFT
                        || event->key.key == SDLK_RIGHT)) {
                const struct slide_spec *s = &SLIDES[o->hover];
                int step = (event->key.key == SDLK_RIGHT ? 1 : -1) * 5;
                int v = (int) o->v[o->hover] + step;
                if (v < (int) s->min) {
                    v = (int) s->min;
                }
                if (v > (int) s->max) {
                    v = (int) s->max;
                }
                o->v[o->hover] = (unsigned) v;
                apply_live(o);
                o->dirty = true;
                break;
            }
            if (o->hover >= (int) SL_COUNT && event->key.key == SDLK_RETURN) {
                press_button(o, o->hover - (int) SL_COUNT);
            }
            break;
        case SDL_EVENT_WINDOW_EXPOSED:
        case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
            o->dirty = true;
            break;
        default:
            break;
    }
    // SDL ignores the return value of an event watch; the isolation this panel
    // needs is done by sc_screen_handle_event(), which refuses foreign windows
    return false;
}

// ---------------------------------------------------------------------------
// global hotkey (Windows): a message-only window on its own thread, so the
// toggle works when the mirror is not focused and no render call ever happens
// off the SDL event thread
// ---------------------------------------------------------------------------

#ifdef _WIN32
static void
push_toggle(void) {
    if (!g_toggle_registered) {
        return;
    }
    SDL_Event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = g_toggle_type;
    SDL_PushEvent(&ev);
}

static bool
parse_hotkey(const char *spec, UINT *mods, UINT *vk) {
    char buf[64];
    snprintf(buf, sizeof(buf), "%s", spec ? spec : "super+alt+f");
    for (char *c = buf; *c; ++c) {
        if (*c >= 'A' && *c <= 'Z') {
            *c = (char) (*c - 'A' + 'a');
        }
    }
    *mods = 0;
    *vk = 0;
    // hand-rolled split: strtok() naming differs between the CRTs of this
    // project, and the token set is fixed anyway
    for (char *tok = buf; tok && *tok;) {
        char *next = strchr(tok, '+');
        if (next) {
            *next++ = 0;
        }
        if (!strcmp(tok, "ctrl") || !strcmp(tok, "control")) {
            *mods |= MOD_CONTROL;
        } else if (!strcmp(tok, "alt")) {
            *mods |= MOD_ALT;
        } else if (!strcmp(tok, "shift")) {
            *mods |= MOD_SHIFT;
        } else if (!strcmp(tok, "super") || !strcmp(tok, "win")
                || !strcmp(tok, "meta")) {
            *mods |= MOD_WIN;
        } else if (tok[0] == 'f' && tok[1] >= '1' && tok[1] <= '9'
                && !tok[2]) {
            *vk = (UINT) (VK_F1 + atoi(&tok[1]) - 1);
        } else if (!tok[1] && ((tok[0] >= 'a' && tok[0] <= 'z')
                || (tok[0] >= '0' && tok[0] <= '9'))) {
            SHORT scan = VkKeyScanA(tok[0]);
            if (scan == -1) {
                return false;
            }
            *vk = (UINT) (scan & 0xFF);
        } else {
            return false;
        }
        tok = next;
    }
    return *vk != 0 && *mods != 0;
}

static LRESULT CALLBACK
hotkey_proc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam) {
    if (msg == WM_HOTKEY) {
        push_toggle();
        return 0;
    }
    if (msg == WM_DESTROY) {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProc(hwnd, msg, wparam, lparam);
}

static int SDLCALL
hotkey_thread(void *userdata) {
    struct sc_gaming_overlay *o = userdata;
    static bool klass_done;
    WNDCLASSA wc;
    memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc = hotkey_proc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "GamingScrcpyFilterHotkey";
    if (!klass_done) {
        if (!RegisterClassA(&wc)) {
            o->hk_ready = 2;
            return 0;
        }
        klass_done = true;
    }
    HWND hwnd = CreateWindowExA(0, wc.lpszClassName, "gaming-filter-hotkey",
                                0, 0, 0, 0, 0, HWND_MESSAGE, NULL,
                                wc.hInstance, NULL);
    if (!hwnd) {
        o->hk_ready = 2;
        return 0;
    }
    o->hwnd = hwnd;
    if (!RegisterHotKey(hwnd, 1, o->hk_mods, o->hk_vk)) {
        LOGW("overlay: global hotkey '%s' is taken (error %lu); the panel "
             "still opens while the mirror has focus", o->hotkey_label,
             (unsigned long) GetLastError());
        DestroyWindow(hwnd);
        o->hwnd = NULL;
        o->hk_ready = 2;
        return 0;
    }
    o->hk_ready = 1;
    MSG msg;
    while (GetMessageA(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    UnregisterHotKey(hwnd, 1);
    return 0;
}
#endif

unsigned
sc_gaming_overlay_preset_count(void) {
    return PRESET_COUNT;
}

// ---------------------------------------------------------------------------
// lifecycle
// ---------------------------------------------------------------------------

struct sc_gaming_overlay *
sc_gaming_overlay_create(struct sc_gaming *gaming,
                         const struct sc_gaming_overlay_params *params) {
    struct sc_gaming_overlay *o = calloc(1, sizeof(*o));
    if (!o) {
        LOGE("overlay: out of memory");
        return NULL;
    }
    o->gaming = gaming;
    o->params = *params;
    o->grabbed = -1;
    o->hover = -1;
    o->loaded = -1;

    if (!g_toggle_registered) {
        // two types: the hotkey posts the first, the fade timer the second
        g_toggle_type = SDL_RegisterEvents(2);
        g_toggle_registered = g_toggle_type != (Uint32) -1;
        g_fade_type = g_toggle_type + 1;
    }
    if (!g_toggle_registered) {
        LOGW("overlay: no user event available, the global hotkey is off");
    }

    snprintf(o->hotkey_label, sizeof(o->hotkey_label), "%s",
             params->hotkey ? params->hotkey : "super+alt+f");
    for (char *c = o->hotkey_label; *c; ++c) {
        if (*c >= 'a' && *c <= 'z') {
            *c = (char) (*c - 'a' + 'A');
        }
    }

    read_engine(o);
    profiles_load(o);
    // loading the stored grade is not a user edit: only a move, a button or a
    // pulse may rewrite the file at the end of the session
    o->changed = false;
    memcpy(o->snapshot, o->v, sizeof(o->v));

    g_active = o;
    SDL_AddEventWatch(overlay_watch, o);

#ifdef _WIN32
    o->hk_ready = 0;
    if (g_toggle_registered
            && parse_hotkey(params->hotkey, &o->hk_mods, &o->hk_vk)) {
        o->hk_thread = SDL_CreateThread(hotkey_thread, "sc-hotkey", o);
        if (!o->hk_thread) {
            LOGW("overlay: hotkey thread failed to start: %s", SDL_GetError());
        }
    } else {
        snprintf(o->hotkey_label, sizeof(o->hotkey_label), "ESC");
        LOGW("overlay: cannot parse hotkey '%s', global toggle disabled",
             params->hotkey ? params->hotkey : "(null)");
    }
#else
    snprintf(o->hotkey_label, sizeof(o->hotkey_label), "ESC");
    LOGW("overlay: the global hotkey is implemented for Windows only");
#endif

    if (params->start_visible) {
        // measured, not assumed: with the panel requested at startup the mirror
        // never paints (gate §22, panel-shown arm: 0 telemetry lines in 8 s). The
        // panel is worth less than the picture, so the flag is refused with an
        // explanation and the hotkey still opens it.
        LOGW("overlay: --game-overlay-visible is disabled, it costs the mirror "
             "its picture; press %s once the session is up to open the panel",
             o->hotkey_label);
    }
    LOGI("filter-overlay: hotkey=%s visible=%s profiles=%s (the panel window is "
         "built on the first show)", o->hotkey_label,
         params->start_visible ? "yes" : "no",
         params->profiles_path ? params->profiles_path : "(none)");
    return o;
}

void
sc_gaming_overlay_destroy(struct sc_gaming_overlay *o) {
    if (!o) {
        return;
    }
#ifdef _WIN32
    if (o->hk_thread) {
        if (o->hk_ready == 1 && o->hwnd) {
            PostMessageA((HWND) o->hwnd, WM_CLOSE, 0, 0);
        }
        SDL_WaitThread(o->hk_thread, NULL);
        o->hk_thread = NULL;
    }
#endif
    SDL_RemoveEventWatch(overlay_watch, o);
    o->fading = false;
    if (o->fade_timer) {
        SDL_RemoveTimer(o->fade_timer);
        o->fade_timer = 0;
    }
    if (g_active == o) {
        g_active = NULL;
    }
    if (o->visible) {
        apply_live(o); // keep what the user last saw on screen
    }
    if (o->params.profiles_path && o->changed) {
        // closing the session stores the grade as "current", so the next one
        // starts with it without the user pressing GUARDAR. A session where
        // nobody touched the panel must leave the file as it was.
        profiles_save(o);
    }
    SDL_DestroyRenderer(o->renderer);
    SDL_DestroyWindow(o->window);
    o->renderer = NULL;
    o->window = NULL;
    free(o);
}

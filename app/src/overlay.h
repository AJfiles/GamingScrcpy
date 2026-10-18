#ifndef SC_OVERLAY_H
#define SC_OVERLAY_H

#include "common.h"

#include <SDL3/SDL.h>

#include <stdbool.h>

struct sc_gaming;

/**
 * Real-time image-filter panel: a borderless, always-on-top window of its own,
 * floating over the mirror.
 *
 * It is a separate window on purpose. The mirror's pipeline never draws it and
 * never measures it, so opening the panel cannot add cost to a frame; what it
 * does is change the parameters of the postfx engine that already exists, which
 * rebuilds one shared 256-entry luma table on the next frame. Nothing here adds
 * a render pass, a second texture or a per-frame GPU context.
 *
 * Threading: everything runs on the thread that pumps SDL events, which is also
 * the thread that processes frames, so a parameter change and a frame never
 * race. The global hotkey arrives from a Win32 message thread and is handed to
 * that thread as a queued SDL event rather than applied directly.
 */
// Opaque on purpose: the mirror only ever hands events to it and asks whether
// a window id is its own, so the panel's internals stay in one file.
struct sc_gaming_overlay;

struct sc_gaming_overlay_params {
    // window title, and the language of every label the panel paints
    const char *title;
    bool spanish;
    // start visible instead of waiting for the hotkey
    bool start_visible;
    // "super+alt+f" — NULL means the built-in default
    const char *hotkey;
    // profile file, NULL disables saving (the panel says so on screen)
    const char *profiles_path;
    // mirror window, used only to place the panel next to it at first
    SDL_Window *parent;
};

struct sc_gaming_overlay *
sc_gaming_overlay_create(struct sc_gaming *gaming,
                         const struct sc_gaming_overlay_params *params);

void
sc_gaming_overlay_destroy(struct sc_gaming_overlay *overlay);

// Toggle with the global hotkey (called from the SDL event thread).
void
sc_gaming_overlay_toggle(struct sc_gaming_overlay *overlay);

// True when this keydown is the configured combo and RegisterHotKey() did not
// get it (another app owns it, or the hotkey thread is unavailable). The mirror
// then toggles the panel itself and must consume the key, because an unhandled
// Super+Alt+F would otherwise be typed into the game.
bool
sc_gaming_overlay_want_local_hotkey(struct sc_gaming_overlay *overlay,
                                    const SDL_Event *event);

// True when the global hotkey is listening, so the caller knows whether the
// local fallback above is armed.
bool
sc_gaming_overlay_hotkey_live(struct sc_gaming_overlay *overlay);

// Repaint the panel if something changed. Called from the event loop, never
// from the mirror's render path: an idle panel costs one flag test, and the
// frame pipeline never draws or measures it.
void
sc_gaming_overlay_tick(void);

// Write the panel's own pixels to a BMP so the tests can assert that it really
// painted (a screenshot of the mirror window cannot show the panel).
bool
sc_gaming_overlay_snapshot(struct sc_gaming_overlay *overlay, const char *path);

// Drive the panel from a measurement harness: show it and move every slider by
// `delta` through the same path a pointer drag takes. Used by the gate that
// compares a frame's cost with the panel open against the cost without it.
void
sc_gaming_overlay_demo_pulse(int delta);

// The window id of a live panel, 0 when there is none. sc_screen_handle_event()
// uses this to keep the panel's own pointer and window traffic away from the
// input manager: a drag on a slider must never become a touch on the device.
SDL_WindowID
sc_gaming_overlay_active_window_id(void);

// True when this event names the panel's window (so nothing else may act on it).
bool
sc_gaming_event_is_for_overlay(const SDL_Event *event);

// Fill a grade from the built-in preset list, for the tests that assert the
// shipped presets stay inside the engine's ranges.
unsigned
sc_gaming_overlay_preset_count(void);

#endif

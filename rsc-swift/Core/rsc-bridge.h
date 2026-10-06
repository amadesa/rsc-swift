#ifndef _H_RSC_BRIDGE
#define _H_RSC_BRIDGE

/*
 * the C API the swift app uses to drive the rsc-c core. everything here is
 * safe to call from the main thread; the game itself runs on its own thread
 * started by rsc_start().
 */

#include <stdint.h>

typedef enum {
    RSC_TOUCH_DOWN = 0,
    RSC_TOUCH_MOVE = 1,
    RSC_TOUCH_UP = 2
} RscTouchPhase;

/* subset of the K_* codes in mudclient.h */
typedef enum {
    RSC_KEY_BACKSPACE = 8,
    RSC_KEY_TAB = 9,
    RSC_KEY_ENTER = 13,
    RSC_KEY_ESCAPE = 27,
    RSC_KEY_PAGE_UP = 33,
    RSC_KEY_PAGE_DOWN = 34,
    RSC_KEY_HOME = 36,
    RSC_KEY_LEFT = 37,
    RSC_KEY_UP = 38,
    RSC_KEY_RIGHT = 39,
    RSC_KEY_DOWN = 40,
    RSC_KEY_F1 = 112
} RscKey;

/* called on the game thread when a text field is focused in-game */
typedef void (*RscKeyboardCallback)(void *context, const char *text,
                                    int is_password);

/* called on the game thread when the focused text field goes away, e.g.
 * after logging in or switching login screens */
typedef void (*RscHideKeyboardCallback)(void *context);

/* called on the game thread, e.g. for wiki lookups */
typedef void (*RscOpenURLCallback)(void *context, const char *url);

/* called on the game thread when "Add world" is tapped */
typedef void (*RscRequestWorldCallback)(void *context);

/* called on the game thread when "Remove" is tapped on the world list. call
 * rsc_remove_world(index) to confirm */
typedef void (*RscRequestRemoveWorldCallback)(void *context, int index,
                                              const char *name);

/* called on the game thread when "Register" is tapped. url is empty when the
 * selected world has no registration page */
typedef void (*RscRegisterCallback)(void *context, const char *world_name,
                                    const char *url);

/* called on the game thread with signed 16-bit mono PCM */
typedef void (*RscSoundCallback)(void *context, const int16_t *pcm,
                                 int samples, int sample_rate);

typedef struct {
    /* directory containing config85.jag, media59.jag etc. */
    const char *cache_dir;
    /* writable directory for options.ini and worlds.cfg */
    const char *config_dir;
    /* initial game resolution in pixels */
    int width;
    int height;
    int members;

    void *context;
    RscKeyboardCallback on_keyboard;
    RscHideKeyboardCallback on_hide_keyboard;
    RscSoundCallback on_sound;
    RscOpenURLCallback on_open_url;
    RscRequestWorldCallback on_request_world;
    RscRequestRemoveWorldCallback on_request_remove_world;
    RscRegisterCallback on_register;
} RscConfig;

/* start the game thread. may only be called once */
void rsc_start(const RscConfig *config);

/* request a new game resolution (e.g. after rotation) */
void rsc_resize(int width, int height);

/* x and y are normalized to 0..1 across the game view */
void rsc_touch(RscTouchPhase phase, intptr_t finger, float x, float y);

/* press and release a special key */
void rsc_key(RscKey key);

/* hold and release a key, e.g. arrow keys from a hardware keyboard */
void rsc_key_down(int code);
void rsc_key_up(int code);

/*
 * add a world to the login screen's world list and select it. the RSA
 * exponent and modulus are hex, 0-padded to a multiple of 8 characters.
 * register_url may be NULL or empty
 */
void rsc_add_world(const char *name, const char *host, int port,
                   const char *rsa_exponent, const char *rsa_modulus,
                   const char *register_url);

/* remove a world from the world list (the last one is always kept) */
void rsc_remove_world(int index);

/* whether a player is logged in to a world */
int rsc_is_logged_in(void);

/* while in the background the game keeps running (staying connected) but
 * skips drawing */
void rsc_set_background(int background);

/* type printable ASCII text */
void rsc_text(const char *text);

/*
 * borrow the most recently presented frame. pixels are 0x00RRGGBB, which is
 * BGRA byte order on little endian. returns a serial number that increases
 * with every new frame, or 0 if nothing has been drawn yet. must be paired
 * with rsc_frame_unlock().
 */
uint64_t rsc_frame_lock(const uint32_t **pixels, int *width, int *height);
void rsc_frame_unlock(void);

#endif

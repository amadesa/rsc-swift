#ifndef _H_RSC_BRIDGE
#define _H_RSC_BRIDGE

/*
 * the C API the swift app uses to drive the rsc-c core. everything here is
 * safe to call from the main thread; the game itself runs on its own thread
 * started by rsc_start().
 */

#include <stddef.h>
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

/* called on the game thread when the watch layout opens a right click
 * ("Choose option") menu, for the app to show instead. items may contain
 * @col@ colour codes. answer with rsc_choose_menu_item */
typedef void (*RscMenuCallback)(void *context, int count,
                                const char *const *items);

/* called on the game thread for each message the game shows (type is 2
 * chat, 3 game, 4 other chat, 5 quest, 6 private). may contain @col@
 * colour codes */
typedef void (*RscMessageCallback)(void *context, const char *message,
                                   int type);

/* called on the game thread each time the server accepts a login
 * (reconnecting too), with the world it's on, so the app can keep the
 * account. the password is only valid during the call */
typedef void (*RscLoginCallback)(void *context, const char *username,
                                 const char *password, const char *world_name,
                                 const char *host, int port);

/* called on the game thread with signed 16-bit mono PCM */
typedef void (*RscSoundCallback)(void *context, const int16_t *pcm,
                                 int samples, int sample_rate);

/* asks the app to fetch the May 2001 game's data into data_dir */
typedef void (*RscRequestRetroDataCallback)(void *context,
                                            const char *data_dir);

typedef struct {
    /* directory containing config85.jag, media59.jag etc. */
    const char *cache_dir;
    /* writable directory for options.ini and worlds.cfg */
    const char *config_dir;
    /* writable directory for game data fetched later: the May 2001 game's
     * (config17.jag, media12.jag, entity3.jag, textures5.jag, models6.jag,
     * maps14.jag), which 2001Scape's worlds need. may be NULL */
    const char *data_dir;
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
    RscMenuCallback on_menu;
    RscMessageCallback on_message;
    RscLoginCallback on_login;
    /* "Accounts" on the welcome screen, shown when this is set (not on the
     * watch), opens the app's list of saved accounts */
    RscRequestWorldCallback on_request_accounts;
    /* a 2001 game world was chosen and its data isn't in cache_dir or
     * data_dir: fetch the files above into data_dir, then call
     * rsc_retro_data_ready. called on the game thread */
    RscRequestRetroDataCallback on_request_retro_data;
} RscConfig;

/* start the game thread. may only be called once */
void rsc_start(const RscConfig *config);

/* request a new game resolution (e.g. after rotation) */
void rsc_resize(int width, int height);

/* how far in from each edge the game's controls should stay, in game
 * pixels, to clear the Dynamic Island, rounded corners and home indicator.
 * the 3D view still fills the screen. corner_radius is the screen's, in
 * game pixels (0 for square corners): the status bars, which can't be
 * tapped, go below the safe area as far as the corners allow. may be
 * called before rsc_start */
void rsc_set_safe_insets(int top, int left, int bottom, int right,
                         int corner_radius);

/* Stay connected in the background (Settings > RSC), which the game shows
 * as a checkbox in Additional options > Game. the app sets it on start and
 * on return, and reads it back on leaving in case the checkbox changed */
void rsc_set_stay_connected(int enabled);
int rsc_get_stay_connected(void);

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
 * register_url may be NULL or empty. retro is 1 for a world on the May
 * 2001 game (2001Scape), which game.openrsc.com:43593 is anyway
 */
void rsc_add_world(const char *name, const char *host, int port,
                   const char *rsa_exponent, const char *rsa_modulus,
                   const char *register_url, int retro);

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
 * the Apple Watch layout: the chat tabs, status bars and combat style box
 * aren't drawn (the app shows its own), and the ui tab icons on the right
 * only appear while revealed or while a tab is open
 */
void rsc_set_watch_ui(int enabled);
void rsc_set_ui_tabs_revealed(int revealed);

typedef struct {
    int logged_in;
    int hits;
    int max_hits;
    int prayer;
    int max_prayer;
    /* 0 to 750 */
    int fatigue;
    /* 0 controlled, 1 aggressive, 2 accurate, 3 defensive */
    int combat_style;
    /* the open ui tab, 0 for none */
    int ui_tab;
    /* a window covering most of the screen (bank, shop, trade, duel,
     * sleeping) */
    int window_open;
    int inventory_count;
    /* showing "Oh dear you are dead" */
    int dead;
    /* seconds until the client logs out for not being touched, or -1 when
     * it won't (the option is off, or in combat) */
    int idle_logout_seconds;
    /* the account logged in to */
    char username[21];
    /* playing the May 2001 game, which has no prayer points or fatigue */
    int retro;
} RscStatus;

/* the player's current stats, read from any thread */
void rsc_get_status(RscStatus *status);

/* remember this login (as options.ini would) and, if the login screen is
 * showing, fill it in. ignored while logged in. from any thread */
void rsc_set_login(const char *username, const char *password);

/*
 * log in as tapping Ok on the login screen would, on the world at host:port
 * in the world list. ignored while logged in. the outcome shows in
 * rsc_get_login_state. on the watch the password isn't kept in options.ini
 */
void rsc_login(const char *username, const char *password, const char *host,
               int port);

typedef struct {
    /* the game data has loaded, so rsc_login can work */
    int ready;
    /* 0 welcome, 1 new user, 2 existing user, 4 world list */
    int screen;
    /* Options (the additional options) is open over the login screen */
    int options_open;
    /* rsc_login calls that have finished, whatever the outcome */
    int logins_finished;
    /* the login screen's two status lines, e.g. after a failed login */
    char status[96];
    char status_bottom[96];
    /* the selected world */
    char world_name[32];
    char world_host[64];
    int world_port;
    /* the RuneScape logo at the top of the login screen, in frame pixels */
    int logo_y;
    int logo_height;
    /* the frame's size, for placing views over it */
    int frame_width;
    int frame_height;
    /* the world list on the Worlds screen, in frame pixels, for the native
     * scroll view over it (rsc_set_world_list_scroll) */
    int world_list_x;
    int world_list_y;
    int world_list_width;
    int world_list_height;
    int world_list_row_height;
    int world_count;
    /* the selected world's row */
    int world_selected;
    /* the 2001 game's data, for a 2001Scape world: 0 here or not needed, 1
     * downloading, 2 the download failed */
    int retro_data;
} RscLoginState;

/* the login screen's state, from any thread */
void rsc_get_login_state(RscLoginState *state);

typedef enum {
    RSC_LOGIN_SCREEN_WELCOME = 0,
    RSC_LOGIN_SCREEN_WORLDS = 4,
    /* Additional options, over the welcome screen */
    RSC_LOGIN_SCREEN_OPTIONS = 100
} RscLoginScreen;

/* switch the login screen, as its buttons would. ignored while logged in */
void rsc_show_login_screen(RscLoginScreen screen);

/* how far the world list is scrolled, in frame pixels: the native scroll
 * view's offset, which can go past either end while it bounces */
void rsc_set_world_list_scroll(float pixels);

/* select the world in this row of the list, as tapping it would */
void rsc_choose_world(int index);

/* whether the world in this row runs the May 2001 game (2001Scape) */
int rsc_world_is_retro(int index);

/* the 2001 game's data is in data_dir (success 1), or couldn't be fetched
 * (0), after on_request_retro_data */
void rsc_retro_data_ready(int success);

/* change and remember the combat style, like tapping it in the game */
void rsc_set_combat_style(int style);

/* open a ui tab (1 inventory, 2 map, 3 stats, 4 magic, 5 friends, 6
 * options) or close it (0), e.g. for screenshots in the simulator */
void rsc_show_ui_tab(int tab);

/* full screen tab panels on the watch: the crown steps to the next (1) or
 * previous (-1) tab */
void rsc_step_ui_tab(int direction);
int rsc_ui_tabs_full_screen(void);

/* pick an item from the menu given to on_menu, or -1 to close it */
void rsc_choose_menu_item(int index);

/*
 * relay mode: reach the game server through rsc-relay over HTTPS instead of
 * a TCP socket (needed on watchOS). The game asks the app to open, send and
 * close through these callbacks, each tagged with a generation number that
 * identifies the connection; results go back through rsc_relay_*.
 */
typedef struct {
    void *context;
    /* open a relay session to host:port, then call rsc_relay_opened */
    void (*open)(void *context, int generation, const char *host, int port);
    /* bytes are waiting: collect them with rsc_relay_take_pending */
    void (*send)(void *context, int generation);
    /* close the relay session */
    void (*close)(void *context, int generation);
} RelayCallbacks;

/* turn relay mode on or off for new connections */
void rsc_relay_configure(int enabled, RelayCallbacks callbacks);

/* report the result of an open request */
void rsc_relay_opened(int generation, int success);

/* say why opening failed (before rsc_relay_opened(generation, 0)), as two
 * short lines the login screen shows instead of "Unable to connect" */
void rsc_relay_failed(int generation, const char *title, const char *advice);

/* hand over bytes the relay received from the game server */
void rsc_relay_received(int generation, const void *data, size_t length);

/* the relay session ended */
void rsc_relay_closed(int generation);

/* take up to length bytes the game has queued to send; returns how many */
size_t rsc_relay_take_pending(int generation, void *buffer, size_t length);

/*
 * borrow the most recently presented frame. pixels are 0x00RRGGBB, which is
 * BGRA byte order on little endian. returns a serial number that increases
 * with every new frame, or 0 if nothing has been drawn yet. must be paired
 * with rsc_frame_unlock().
 */
uint64_t rsc_frame_lock(const uint32_t **pixels, int *width, int *height);
void rsc_frame_unlock(void);

#endif

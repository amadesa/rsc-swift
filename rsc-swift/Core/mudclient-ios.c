#include "mudclient.h"
#include "rsc-bridge.h"
#include "ui/worldlist.h"

#ifdef IOS

#include <pthread.h>

/*
 * iOS platform layer. the swift app posts input events from the main thread
 * into a queue which the game thread drains in mudclient_poll_events(). the
 * touch handling mirrors the SDL/android implementation in mudclient-sdl.c so
 * the mobile controls behave the same as the android and web clients.
 */

#define EVENT_QUEUE_SIZE 1024

typedef enum {
    EVENT_TOUCH_DOWN,
    EVENT_TOUCH_MOVE,
    EVENT_TOUCH_UP,
    EVENT_KEY,
    EVENT_KEY_DOWN,
    EVENT_KEY_UP,
    EVENT_ADD_WORLD,
    EVENT_REMOVE_WORLD,
    EVENT_COMBAT_STYLE,
    EVENT_UI_TAB,
    EVENT_UI_TAB_STEP,
    EVENT_MENU_CHOICE,
    EVENT_LOGIN,
    EVENT_LOGIN_SCREEN,
    EVENT_CHOOSE_WORLD
} EventType;

typedef struct {
    char name[32];
    char host[64];
    int port;
    char rsa_exponent[512];
    char rsa_modulus[512];
    char register_url[256];
} PendingWorld;

typedef struct {
    char username[USERNAME_LENGTH + 1];
    char password[PASSWORD_LENGTH + 1];
    char host[64];
    int port;
} PendingLogin;

typedef struct {
    EventType type;
    intptr_t finger;
    float x;
    float y;
    int code;
    int char_code;
    PendingWorld *world; /* EVENT_ADD_WORLD, freed by the game thread */
    PendingLogin *login; /* EVENT_LOGIN, wiped and freed by the game thread */
} Event;

static pthread_mutex_t event_lock = PTHREAD_MUTEX_INITIALIZER;
static Event event_queue[EVENT_QUEUE_SIZE];
static int event_head = 0;
static int event_tail = 0;

static int requested_width = MUD_WIDTH;
static int requested_height = MUD_HEIGHT;
static int requested_resize = 0;

/* top, left, bottom, right and the screen's corner radius in game pixels
 * (rsc_set_safe_insets), and the ones in use, which only change with a
 * resize on the game thread */
static int requested_insets[5] = {0};
static int safe_insets[5] = {0};

/* from rsc_set_login, applied on the game thread */
static char requested_username[USERNAME_LENGTH + 1];
static char requested_password[PASSWORD_LENGTH + 1];
static int requested_login = 0;

static pthread_mutex_t frame_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t *frame_pixels = NULL;
static int frame_capacity = 0;
static int frame_width = 0;
static int frame_height = 0;
static uint64_t frame_serial = 0;

static RscConfig config = {0};

/* the screen the on-screen keyboard was last opened (or closed) for */
static int keyboard_logged_in = -1;
static int keyboard_login_screen = -1;

/* only read from other threads, for rsc_is_logged_in */
static mudclient *ios_mud = NULL;
static volatile int is_background = 0;
static volatile int is_watch_ui = 0;
static volatile int ui_tabs_revealed = 0;

/* for rsc_get_login_state, under event_lock */
static int logins_finished = 0;
static char login_status[96];
static char login_status_bottom[96];
static char cache_dir[PATH_MAX] = {0};
static char config_dir[PATH_MAX] = {0};

/* touch state, same as mudclient-sdl.c */
static int mudclient_horizontal_drag = 0;
static int mudclient_vertical_drag = 0;
static double mudclient_pinch_distance = 0;
static int mudclient_has_right_clicked = 0;
static int mudclient_touch_start = 0; // ms
static int mudclient_touch_start_x = 0;
static int mudclient_touch_start_y = 0;
static float mudclient_touch_last_y = 0; // normalized
static intptr_t mudclient_finger_1_id = 0;
static intptr_t mudclient_finger_2_id = 0;

/* wipes the password before freeing */
static void free_login(PendingLogin *login) {
    if (login == NULL) {
        return;
    }

    volatile char *bytes = (volatile char *)login;

    for (size_t i = 0; i < sizeof(*login); i++) {
        bytes[i] = 0;
    }

    free(login);
}

static void push_event(Event event) {
    pthread_mutex_lock(&event_lock);

    int next = (event_head + 1) % EVENT_QUEUE_SIZE;

    /* drop input rather than block the UI if the game thread stalls */
    if (next != event_tail) {
        event_queue[event_head] = event;
        event_head = next;
    } else {
        free(event.world);
        free_login(event.login);
    }

    pthread_mutex_unlock(&event_lock);
}

static int pop_event(Event *event) {
    pthread_mutex_lock(&event_lock);

    int has_event = event_head != event_tail;

    if (has_event) {
        *event = event_queue[event_tail];
        event_tail = (event_tail + 1) % EVENT_QUEUE_SIZE;
    }

    pthread_mutex_unlock(&event_lock);

    return has_event;
}

static void clamp_size(int *width, int *height) {
    if (*width < MUD_MIN_WIDTH) {
        *width = MUD_MIN_WIDTH;
    }

    if (*height < MUD_MIN_HEIGHT) {
        *height = MUD_MIN_HEIGHT;
    }
}

static void *game_thread(void *arg) {
    (void)arg;

    char *argv[] = {"mudclient", config.members ? "members" : "free", NULL};

    mudclient_ios_main(2, argv);

    return NULL;
}

void rsc_start(const RscConfig *new_config) {
    config = *new_config;

    snprintf(cache_dir, sizeof(cache_dir), "%s", new_config->cache_dir);
    snprintf(config_dir, sizeof(config_dir), "%s", new_config->config_dir);

    config.cache_dir = cache_dir;
    config.config_dir = config_dir;

    requested_width = new_config->width;
    requested_height = new_config->height;
    clamp_size(&requested_width, &requested_height);

    /* the client keeps some large buffers on the stack. watches have far
     * less memory, so fall back to smaller stacks if the system refuses */
    static const size_t stack_sizes[] = {16 << 20, 8 << 20, 4 << 20};
    int started = 0;

    for (size_t i = 0; i < sizeof(stack_sizes) / sizeof(stack_sizes[0]); i++) {
        pthread_attr_t attr;
        pthread_attr_init(&attr);
        pthread_attr_setstacksize(&attr, stack_sizes[i]);
        pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);

        pthread_t thread;
        started = pthread_create(&thread, &attr, game_thread, NULL) == 0;
        pthread_attr_destroy(&attr);

        if (started) {
            break;
        }
    }

    if (!started) {
        mud_error("couldn't start the game thread\n");
    }
}

void rsc_resize(int width, int height) {
    clamp_size(&width, &height);

    pthread_mutex_lock(&event_lock);
    requested_width = width;
    requested_height = height;
    requested_resize = 1;
    pthread_mutex_unlock(&event_lock);
}

void rsc_set_safe_insets(int top, int left, int bottom, int right,
                         int corner_radius) {
    int insets[5] = {top, left, bottom, right, corner_radius};

    pthread_mutex_lock(&event_lock);

    for (int i = 0; i < 5; i++) {
        int inset = insets[i] < 0 ? 0 : insets[i];

        if (requested_insets[i] != inset) {
            requested_insets[i] = inset;
            /* the controls' panels are laid out on resize */
            requested_resize = 1;
        }
    }

    pthread_mutex_unlock(&event_lock);
}

int mudclient_ios_safe_inset(int edge) {
    int inset = safe_insets[edge];

    /* the surface is half the game size when the UI is scaled up */
    if (ios_mud != NULL && mudclient_is_ui_scaled(ios_mud)) {
        inset = (inset + 1) / 2;
    }

    return inset;
}

void rsc_touch(RscTouchPhase phase, intptr_t finger, float x, float y) {
    EventType type = EVENT_TOUCH_MOVE;

    if (phase == RSC_TOUCH_DOWN) {
        type = EVENT_TOUCH_DOWN;
    } else if (phase == RSC_TOUCH_UP) {
        type = EVENT_TOUCH_UP;
    }

    push_event((Event){.type = type, .finger = finger, .x = x, .y = y});
}

/* same as get_sdl_keycodes(): special keys only produce a character for
 * enter, backspace and tab */
static int get_char_code(int code) {
    if (code == RSC_KEY_ENTER || code == RSC_KEY_BACKSPACE ||
        code == RSC_KEY_TAB || (code < 127 && isprint(code))) {
        return code;
    }

    return -1;
}

void rsc_key(RscKey key) {
    push_event(
        (Event){.type = EVENT_KEY, .code = key, .char_code = get_char_code(key)});
}

void rsc_key_down(int code) {
    push_event((Event){
        .type = EVENT_KEY_DOWN, .code = code, .char_code = get_char_code(code)});
}

void rsc_key_up(int code) {
    push_event((Event){.type = EVENT_KEY_UP, .code = code});
}

void rsc_add_world(const char *name, const char *host, int port,
                   const char *rsa_exponent, const char *rsa_modulus,
                   const char *register_url) {
    PendingWorld *world = calloc(1, sizeof(PendingWorld));

    snprintf(world->name, sizeof(world->name), "%s", name);
    snprintf(world->host, sizeof(world->host), "%s", host);
    world->port = port;
    snprintf(world->rsa_exponent, sizeof(world->rsa_exponent), "%s",
             rsa_exponent);
    snprintf(world->rsa_modulus, sizeof(world->rsa_modulus), "%s",
             rsa_modulus);
    snprintf(world->register_url, sizeof(world->register_url), "%s",
             register_url != NULL ? register_url : "");

    push_event((Event){.type = EVENT_ADD_WORLD, .world = world});
}

void rsc_remove_world(int index) {
    push_event((Event){.type = EVENT_REMOVE_WORLD, .code = index});
}

void rsc_choose_world(int index) {
    push_event((Event){.type = EVENT_CHOOSE_WORLD, .code = index});
}

/* a float is written whole on the platforms this runs on, and a frame drawn
 * with the previous offset is harmless */
static volatile float world_list_scroll = 0;

/* where the game last drew the world list, for rsc_get_login_state */
typedef struct {
    int x, y, width, height, row_height, count, selected;
} WorldListLayout;

static WorldListLayout world_list = {0};

void rsc_set_world_list_scroll(float pixels) { world_list_scroll = pixels; }

float mudclient_ios_world_list_scroll(void) { return world_list_scroll; }

void rsc_text(const char *text) {
    for (const char *c = text; *c != '\0'; c++) {
        if (isprint((unsigned char)*c)) {
            push_event((Event){.type = EVENT_KEY, .code = *c, .char_code = *c});
        }
    }
}

uint64_t rsc_frame_lock(const uint32_t **pixels, int *width, int *height) {
    pthread_mutex_lock(&frame_lock);

    *pixels = frame_pixels;
    *width = frame_width;
    *height = frame_height;

    return frame_serial;
}

void rsc_frame_unlock(void) { pthread_mutex_unlock(&frame_lock); }

int rsc_is_logged_in(void) {
    return ios_mud != NULL && ios_mud->logged_in;
}

void rsc_set_background(int background) { is_background = background; }

int mudclient_ios_is_background(void) { return is_background; }

void rsc_set_watch_ui(int enabled) { is_watch_ui = enabled; }

void rsc_set_ui_tabs_revealed(int revealed) { ui_tabs_revealed = revealed; }

int mudclient_ios_is_watch_ui(void) { return is_watch_ui; }

/* on the watch the ui tab icons stay out of the way until revealed */
int mudclient_ios_ui_tabs_hidden(mudclient *mud) {
    return is_watch_ui && !ui_tabs_revealed && mud->show_ui_tab == 0;
}

void rsc_get_status(RscStatus *status) {
    mudclient *mud = ios_mud;

    memset(status, 0, sizeof(*status));

    if (mud == NULL || !mud->logged_in) {
        return;
    }

    status->logged_in = 1;
    snprintf(status->username, sizeof(status->username), "%s", mud->username);
    status->hits = mud->player_skill_current[SKILL_HITS];
    status->max_hits = mud->player_skill_base[SKILL_HITS];
    status->prayer = mud->player_skill_current[SKILL_PRAYER];
    status->max_prayer = mud->player_skill_base[SKILL_PRAYER];
    status->fatigue = mud->stat_fatigue;
    status->combat_style = mud->combat_style;
    status->ui_tab = mud->show_ui_tab;

    status->window_open =
        mud->is_sleeping || mud->show_dialog_bank || mud->show_dialog_shop ||
        mud->show_dialog_trade || mud->show_dialog_trade_confirm ||
        mud->show_dialog_duel || mud->show_dialog_duel_confirm ||
        mud->show_additional_options || mud->show_appearance_change;

    status->inventory_count = mud->inventory_items_count;
    status->dead = mud->death_screen_timeout > 0;

    /* mudclient_handle_game_input logs out after 4500 untouched ticks */
    status->idle_logout_seconds = -1;

    if (mud->options->idle_logout && mud->combat_timeout == 0 &&
        mud->target_fps > 0) {
        int ticks = 4500 - mud->mouse_action_timeout;
        status->idle_logout_seconds =
            (ticks > 0 ? ticks : 0) * mud->target_fps / 1000;
    }
}

void rsc_set_login(const char *username, const char *password) {
    pthread_mutex_lock(&event_lock);
    snprintf(requested_username, sizeof(requested_username), "%s", username);
    snprintf(requested_password, sizeof(requested_password), "%s", password);
    requested_login = 1;
    pthread_mutex_unlock(&event_lock);
}

void rsc_login(const char *username, const char *password, const char *host,
               int port) {
    PendingLogin *login = calloc(1, sizeof(PendingLogin));

    if (login == NULL) {
        return;
    }

    snprintf(login->username, sizeof(login->username), "%s", username);
    snprintf(login->password, sizeof(login->password), "%s", password);
    snprintf(login->host, sizeof(login->host), "%s", host);
    login->port = port;

    push_event((Event){.type = EVENT_LOGIN, .login = login});
}

/* on the game thread, from mudclient_show_login_screen_status */
void mudclient_ios_on_login_status(const char *status,
                                   const char *status_bottom) {
    pthread_mutex_lock(&event_lock);
    snprintf(login_status, sizeof(login_status), "%s", status);
    snprintf(login_status_bottom, sizeof(login_status_bottom), "%s",
             status_bottom);
    pthread_mutex_unlock(&event_lock);
}

static void finish_login(void) {
    pthread_mutex_lock(&event_lock);
    logins_finished++;
    pthread_mutex_unlock(&event_lock);
}

static void handle_login(mudclient *mud, PendingLogin *login) {
    if (mud->logged_in || mud->panel_login_existing_user == NULL) {
        finish_login();
        return;
    }

    mud->show_additional_options = 0;
    mud->login_screen = LOGIN_STAGE_EXISTING;

    panel_update_text(mud->panel_login_existing_user,
                      mud->control_login_username, login->username);
    panel_update_text(mud->panel_login_existing_user,
                      mud->control_login_password, "");

    if (!worldlist_select_address(mud, login->host, login->port)) {
        mudclient_show_login_screen_status(
            mud, "This account's world isn't in the world list.",
            "Add it on the iPhone, then try again");
        finish_login();
        return;
    }

    snprintf(mud->login_username, sizeof(mud->login_username), "%s",
             login->username);
    snprintf(mud->login_pass, sizeof(mud->login_pass), "%s", login->password);

    mudclient_login(mud, mud->login_username, mud->login_pass, 0);

    /* mud->password keeps it for reconnecting */
    memset(mud->login_pass, 0, sizeof(mud->login_pass));

    finish_login();
}

void rsc_show_login_screen(RscLoginScreen screen) {
    push_event((Event){.type = EVENT_LOGIN_SCREEN, .code = screen});
}

static void handle_login_screen(mudclient *mud, int screen) {
    if (mud->logged_in || mud->panel_login_existing_user == NULL) {
        return;
    }

    if (screen == RSC_LOGIN_SCREEN_OPTIONS) {
        mud->login_screen = LOGIN_STAGE_WELCOME;
        mud->show_additional_options = 1;
    } else if (screen == RSC_LOGIN_SCREEN_WORLDS) {
        mud->show_additional_options = 0;
        mud->login_screen = LOGIN_STAGE_WORLD;
    } else {
        mud->show_additional_options = 0;
        mud->login_screen = LOGIN_STAGE_WELCOME;
    }
}

void rsc_get_login_state(RscLoginState *state) {
    mudclient *mud = ios_mud;

    memset(state, 0, sizeof(*state));

    pthread_mutex_lock(&event_lock);
    state->logins_finished = logins_finished;
    snprintf(state->status, sizeof(state->status), "%s", login_status);
    snprintf(state->status_bottom, sizeof(state->status_bottom), "%s",
             login_status_bottom);
    pthread_mutex_unlock(&event_lock);

    if (mud == NULL || mud->loading_step != 0 ||
        mud->panel_login_existing_user == NULL) {
        return;
    }

    state->ready = 1;
    state->screen = mud->login_screen;
    state->options_open = mud->show_additional_options;

    snprintf(state->world_host, sizeof(state->world_host), "%s", mud->server);
    state->world_port = mud->port;
    snprintf(state->world_name, sizeof(state->world_name), "%s",
             worldlist_name_at(mud->server, mud->port));

    /* as mudclient_draw_login_screens places it */
    int is_compact = mud->surface->width < MUD_VANILLA_WIDTH ||
                     mud->surface->height < MUD_VANILLA_HEIGHT;
    int height = is_compact ? MUD_MIN_HEIGHT : MUD_VANILLA_HEIGHT;

    state->logo_y = (mud->surface->height / 2) - (height / 2) + 10;
    state->logo_height = is_compact ? 125 : 200;

    state->frame_width = mud->surface->width;
    state->frame_height = mud->surface->height;

    /* the panel is rebuilt on the game thread, so it's read from the copy
     * worldlist_draw_scrolling last published */
    pthread_mutex_lock(&event_lock);
    state->world_list_x = world_list.x;
    state->world_list_y = world_list.y;
    state->world_list_width = world_list.width;
    state->world_list_height = world_list.height;
    state->world_list_row_height = world_list.row_height;
    state->world_count = world_list.count;
    state->world_selected = world_list.selected;
    pthread_mutex_unlock(&event_lock);
}

void mudclient_ios_publish_world_list(int x, int y, int width, int height,
                                      int row_height, int count,
                                      int selected) {
    pthread_mutex_lock(&event_lock);
    world_list = (WorldListLayout){x, y, width, height, row_height, count,
                                   selected};
    pthread_mutex_unlock(&event_lock);
}

void mudclient_ios_on_login(mudclient *mud, const char *username,
                            const char *password) {
    if (config.on_login == NULL) {
        return;
    }

    config.on_login(config.context, username, password,
                    worldlist_name_at(mud->server, mud->port), mud->server,
                    mud->port);
}

static void apply_requested_login(mudclient *mud) {
    char username[USERNAME_LENGTH + 1];
    char password[PASSWORD_LENGTH + 1];

    pthread_mutex_lock(&event_lock);
    int should_apply = requested_login;
    requested_login = 0;
    memcpy(username, requested_username, sizeof(username));
    memcpy(password, requested_password, sizeof(password));
    pthread_mutex_unlock(&event_lock);

    if (!should_apply || mud->logged_in) {
        return;
    }

    snprintf(mud->options->username, sizeof(mud->options->username), "%s",
             username);
    snprintf(mud->options->password, sizeof(mud->options->password), "%s",
             password);

    if (mud->panel_login_existing_user != NULL) {
        panel_update_text(mud->panel_login_existing_user,
                          mud->control_login_username, username);
        panel_update_text(mud->panel_login_existing_user,
                          mud->control_login_password, password);
    }
}

void mudclient_ios_on_message(char *message, int type) {
    if (config.on_message != NULL) {
        config.on_message(config.context, message, type);
    }
}

void rsc_set_combat_style(int style) {
    push_event((Event){.type = EVENT_COMBAT_STYLE, .code = style});
}

void rsc_show_ui_tab(int tab) {
    push_event((Event){.type = EVENT_UI_TAB, .code = tab});
}

void rsc_step_ui_tab(int direction) {
    push_event((Event){.type = EVENT_UI_TAB_STEP, .code = direction});
}

int rsc_ui_tabs_full_screen(void) {
    mudclient *mud = ios_mud;

    return mud != NULL && mud->options != NULL &&
           mudclient_ui_tab_is_watch_full_screen(mud);
}

void rsc_choose_menu_item(int index) {
    push_event((Event){.type = EVENT_MENU_CHOICE, .code = index});
}

/* hands the right click menu that just opened to the watch app */
void mudclient_ios_show_menu(mudclient *mud) {
    /* nothing could close a menu the app isn't shown */
    if (config.on_menu == NULL || mud->menu_items_count <= 0) {
        mud->show_right_click_menu = 0;
        return;
    }

    /* far more than fit in a menu */
    enum { MENU_SHOWN_MAX = 64 };

    static char texts[MENU_SHOWN_MAX][160];
    static const char *items[MENU_SHOWN_MAX];

    int count = mud->menu_items_count;

    if (count > MENU_SHOWN_MAX) {
        count = MENU_SHOWN_MAX;
    }

    for (int i = 0; i < count; i++) {
        struct MenuEntry *item = &mud->menu_items[mud->menu_indices[i]];

        snprintf(texts[i], sizeof(texts[i]), "%s %s", item->action_text,
                 item->target_text);

        items[i] = texts[i];
    }

    config.on_menu(config.context, count, items);
}

const char *mudclient_ios_cache_dir(void) { return cache_dir; }

const char *mudclient_ios_config_dir(void) { return config_dir; }

void mudclient_ios_get_game_size(int *width, int *height) {
    pthread_mutex_lock(&event_lock);
    *width = requested_width;
    *height = requested_height;
    pthread_mutex_unlock(&event_lock);
}

void mudclient_ios_show_keyboard(char *text, int is_password) {
    /* the keyboard belongs to the screen it was opened on. this runs in the
     * same frame as e.g. tapping Login, so the screen change that caused it
     * mustn't close it again */
    if (ios_mud != NULL) {
        keyboard_logged_in = ios_mud->logged_in;
        keyboard_login_screen = ios_mud->login_screen;
    }

    if (config.on_keyboard != NULL) {
        config.on_keyboard(config.context, text, is_password);
    }
}

void mudclient_ios_play_sound(int16_t *pcm, int samples) {
    if (config.on_sound != NULL) {
        config.on_sound(config.context, pcm, samples, SAMPLE_RATE);
    }
}

void mudclient_ios_open_url(char *url) {
    if (config.on_open_url != NULL) {
        config.on_open_url(config.context, url);
    }
}

/* Stay connected in the background, kept by the app (Settings > RSC) and
 * shown in Additional options > Game. read and written from both threads,
 * but only ever 0 or 1 */
static int stay_connected = 1;

int *mudclient_ios_stay_connected(void) {
    return is_watch_ui ? NULL : &stay_connected;
}

void rsc_set_stay_connected(int enabled) { stay_connected = enabled != 0; }

int rsc_get_stay_connected(void) { return stay_connected; }

int mudclient_ios_has_accounts(void) {
    return config.on_request_accounts != NULL && !is_watch_ui;
}

void mudclient_ios_request_accounts(void) {
    if (config.on_request_accounts != NULL) {
        config.on_request_accounts(config.context);
    }
}

void mudclient_ios_request_world(void) {
    if (config.on_request_world != NULL) {
        config.on_request_world(config.context);
    }
}

void mudclient_ios_request_remove_world(int index, char *name) {
    if (config.on_request_remove_world != NULL) {
        config.on_request_remove_world(config.context, index, name);
    }
}

void mudclient_ios_register(char *world_name, char *url) {
    if (config.on_register != NULL) {
        config.on_register(config.context, world_name, url);
    }
}

void mudclient_ios_present(int32_t *pixels, int width, int height) {
    pthread_mutex_lock(&frame_lock);

    int area = width * height;

    if (area > frame_capacity) {
        free(frame_pixels);
        frame_pixels = malloc(area * sizeof(uint32_t));
        frame_capacity = area;
    }

    memcpy(frame_pixels, pixels, area * sizeof(uint32_t));
    frame_width = width;
    frame_height = height;
    frame_serial++;

    pthread_mutex_unlock(&frame_lock);
}

/*
 * combat style is reset to controlled on every login, so remember the last
 * one picked per world and character. combat-styles.cfg has one entry per
 * line: "host port username style", lower case, spaces in names as '_'.
 */
#define COMBAT_STYLES_FILE "combat-styles.cfg"
#define COMBAT_STYLES_MAX 256

typedef struct {
    char host[64];
    int port;
    char username[USERNAME_LENGTH + 1];
    int style;
} CombatStyleEntry;

static CombatStyleEntry saved_combat_styles[COMBAT_STYLES_MAX];

static void combat_style_normalise(char *dest, size_t size, const char *src) {
    size_t i = 0;

    for (; i + 1 < size && src[i] != '\0'; i++) {
        dest[i] = src[i] == ' ' ? '_' : (char)tolower((unsigned char)src[i]);
    }

    dest[i] = '\0';
}

static int combat_styles_read(void) {
    char path[PATH_MAX];
    get_config_path(COMBAT_STYLES_FILE, path);

    FILE *file = fopen(path, "r");

    if (file == NULL) {
        return 0;
    }

    char line[256];
    int count = 0;

    while (count < COMBAT_STYLES_MAX && fgets(line, sizeof(line), file)) {
        CombatStyleEntry *entry = &saved_combat_styles[count];

        if (sscanf(line, "%63s %d %20s %d", entry->host, &entry->port,
                   entry->username, &entry->style) == 4) {
            count++;
        }
    }

    fclose(file);
    return count;
}

static void combat_styles_write(int count) {
    char path[PATH_MAX];
    get_config_path(COMBAT_STYLES_FILE, path);

    FILE *file = fopen(path, "w");

    if (file == NULL) {
        return;
    }

    for (int i = 0; i < count; i++) {
        fprintf(file, "%s %d %s %d\n", saved_combat_styles[i].host,
                saved_combat_styles[i].port, saved_combat_styles[i].username,
                saved_combat_styles[i].style);
    }

    fclose(file);
}

/* index of this world and character in saved_combat_styles, or -1 */
static int combat_styles_find(mudclient *mud, int count, char *host,
                              char *username) {
    combat_style_normalise(host, 64, mud->server);
    combat_style_normalise(username, USERNAME_LENGTH + 1, mud->username);

    for (int i = 0; i < count; i++) {
        if (saved_combat_styles[i].port == mud->port &&
            strcmp(saved_combat_styles[i].host, host) == 0 &&
            strcmp(saved_combat_styles[i].username, username) == 0) {
            return i;
        }
    }

    return -1;
}

void mudclient_ios_save_combat_style(mudclient *mud) {
    if (mud->username[0] == '\0') {
        return;
    }

    char host[64];
    char username[USERNAME_LENGTH + 1];

    int count = combat_styles_read();
    int index = combat_styles_find(mud, count, host, username);

    if (index < 0) {
        if (count >= COMBAT_STYLES_MAX) {
            return;
        }

        index = count++;
        strcpy(saved_combat_styles[index].host, host);
        saved_combat_styles[index].port = mud->port;
        strcpy(saved_combat_styles[index].username, username);
    }

    saved_combat_styles[index].style = mud->combat_style;
    combat_styles_write(count);
}

/* the style saved for this world and character, or 0 (controlled) */
int mudclient_ios_saved_combat_style(mudclient *mud) {
    if (mud->username[0] == '\0') {
        return 0;
    }

    char host[64];
    char username[USERNAME_LENGTH + 1];

    int count = combat_styles_read();
    int index = combat_styles_find(mud, count, host, username);

    if (index < 0) {
        return 0;
    }

    int style = saved_combat_styles[index].style;

    return style >= 0 && style <= 3 ? style : 0;
}

void mudclient_ios_restore_combat_style(mudclient *mud) {
    int style = mudclient_ios_saved_combat_style(mud);

    /* controlled is what the server starts with */
    if (style == 0) {
        return;
    }

    mud->combat_style = style;

    packet_stream_new_packet(mud->packet_stream, CLIENT_COMBAT_STYLE);
    packet_stream_put_byte(mud->packet_stream, mud->combat_style);
    packet_stream_send_packet(mud->packet_stream);
}

void mudclient_start_application(mudclient *mud, char *title) {
    (void)title;

    ios_mud = mud;

    /*
     * the login screen backgrounds are rendered from the 3D scene once while
     * loading and are drawn assuming they're 512 pixels wide, as the desktop
     * client always starts at the vanilla size. do the same and switch to
     * the real size as soon as loading finishes (the backgrounds are scaled
     * or centred from then on).
     */
    mud->game_width = MUD_VANILLA_WIDTH;
    mud->game_height = MUD_VANILLA_HEIGHT;

    /* lay out again once loading finishes, which also applies the offsets
     * that centre the login panels */
    pthread_mutex_lock(&event_lock);
    requested_resize = 1;
    pthread_mutex_unlock(&event_lock);
}

static void handle_touch_down(mudclient *mud, Event *event) {
    int touch_x = event->x * mud->game_width;
    int touch_y = event->y * mud->game_height;

    if (!mudclient_finger_1_down) {
        mudclient_has_right_clicked = 0;

        mudclient_finger_1_id = event->finger;
        mudclient_finger_1_down = 1;

        mudclient_finger_1_x = touch_x;
        mudclient_finger_1_y = touch_y;

        mudclient_touch_start = get_ticks();

        mudclient_touch_start_x = touch_x;
        mudclient_touch_start_y = touch_y;
        mudclient_touch_last_y = event->y;

        mudclient_mouse_moved(mud, touch_x, touch_y);
    } else if (!mudclient_finger_2_down) {
        mudclient_finger_2_id = event->finger;
        mudclient_finger_2_down = 1;

        mudclient_finger_2_x = touch_x;
        mudclient_finger_2_y = touch_y;
    }
}

static void handle_touch_move(mudclient *mud, Event *event) {
    int touch_x = event->x * mud->game_width;
    int touch_y = event->y * mud->game_height;

    if (event->finger == mudclient_finger_1_id) {
        mudclient_finger_1_x = touch_x;
        mudclient_finger_1_y = touch_y;
    } else if (event->finger == mudclient_finger_2_id) {
        mudclient_finger_2_x = touch_x;
        mudclient_finger_2_y = touch_y;
    }

    if (mud->options->touch_pinch != 0 && mudclient_finger_1_down &&
        mudclient_finger_2_down) {
        double pinch_distance =
            distance(mudclient_finger_1_x, mudclient_finger_1_y,
                     mudclient_finger_2_x, mudclient_finger_2_y);

        if (mudclient_pinch_distance > 0) {
            float scale = mud->options->touch_pinch / 100.0f;

            mud->mouse_scroll_delta =
                (mudclient_pinch_distance - pinch_distance) * scale;
        }

        mudclient_pinch_distance = pinch_distance;
        mudclient_has_right_clicked = 1;
    } else if (mudclient_finger_1_down && !mudclient_finger_2_down &&
               event->finger == mudclient_finger_1_id) {
        int delta_x = touch_x - mudclient_touch_start_x;
        int delta_y = touch_y - mudclient_touch_start_y;

        float dy = event->y - mudclient_touch_last_y;
        mudclient_touch_last_y = event->y;

        if (!mudclient_horizontal_drag && abs(delta_x) > 30) {
            mudclient_horizontal_drag = 1;

            mudclient_mouse_pressed(mud, mudclient_touch_start_x,
                                    mudclient_touch_start_y, 2);
        }

        if (mud->options->touch_vertical_drag != 0 && mud->show_ui_tab == 0 &&
            (mudclient_vertical_drag || abs(delta_y) > 30)) {
            mudclient_vertical_drag = 1;

            mud->mouse_scroll_delta =
                (dy * (mud->options->touch_vertical_drag / 100.0f)) *
                mud->game_height;
        }

        mudclient_mouse_moved(mud, touch_x, touch_y);
    }
}

static void handle_touch_up(mudclient *mud, Event *event) {
    int touch_x = event->x * mud->game_width;
    int touch_y = event->y * mud->game_height;

    if (mudclient_finger_1_down && event->finger == mudclient_finger_1_id) {
        mudclient_finger_1_down = 0;
    
        if (!mudclient_has_right_clicked && !mudclient_vertical_drag &&
            !mudclient_horizontal_drag && mudclient_pinch_distance == 0) {
            mudclient_mouse_pressed(mud, touch_x, touch_y, 0);
            mudclient_mouse_released(mud, touch_x, touch_y, 0);
        } else {
            mudclient_vertical_drag = 0;

            if (mudclient_horizontal_drag) {
                mudclient_mouse_released(mud, mud->mouse_x, mud->mouse_y, 2);
                mudclient_horizontal_drag = 0;
            }
        }
    } else if (mudclient_finger_2_down &&
               event->finger == mudclient_finger_2_id) {
        mudclient_finger_2_down = 0;
        mudclient_pinch_distance = 0;
    }
}

/*
 * the keyboard is normally dismissed with its return key, but the login can
 * also be submitted with the in-game Ok button. close it whenever the screen
 * its text field belonged to goes away, so later typing doesn't end up in
 * the chat box
 */
static void hide_keyboard_on_screen_change(mudclient *mud) {
    int changed = mud->logged_in != keyboard_logged_in ||
                  (!mud->logged_in && mud->login_screen != keyboard_login_screen);

    if (changed && keyboard_logged_in != -1 &&
        config.on_hide_keyboard != NULL) {
        config.on_hide_keyboard(config.context);
    }

    keyboard_logged_in = mud->logged_in;
    keyboard_login_screen = mud->login_screen;
}

void mudclient_poll_events(mudclient *mud) {
    hide_keyboard_on_screen_change(mud);

    /* long press for right click */
    if (!mudclient_has_right_clicked && !mudclient_horizontal_drag &&
        !mudclient_vertical_drag && mudclient_finger_1_down &&
        !mudclient_finger_2_down &&
        get_ticks() - mudclient_touch_start >= mud->options->touch_menu_delay) {
        mudclient_mouse_pressed(mud, mud->mouse_x, mud->mouse_y, 3);
        mudclient_mouse_released(mud, mud->mouse_x, mud->mouse_y, 3);
        mudclient_has_right_clicked = 1;
    }

    /* panels only exist once loading finishes */
    if (mud->loading_step == 0) {
        pthread_mutex_lock(&event_lock);
        int should_resize = requested_resize;
        requested_resize = 0;

        if (should_resize) {
            memcpy(safe_insets, requested_insets, sizeof(safe_insets));
        }

        pthread_mutex_unlock(&event_lock);

        if (should_resize) {
            mudclient_on_resize(mud);
        }

        apply_requested_login(mud);
    }

    Event event;

    while (pop_event(&event)) {
        switch (event.type) {
        case EVENT_TOUCH_DOWN:
            handle_touch_down(mud, &event);
            break;
        case EVENT_TOUCH_MOVE:
            handle_touch_move(mud, &event);
            break;
        case EVENT_TOUCH_UP:
            handle_touch_up(mud, &event);
            break;
        case EVENT_KEY:
            mudclient_key_pressed(mud, event.code, event.char_code);
            mudclient_key_released(mud, event.code);
            break;
        case EVENT_KEY_DOWN:
            mudclient_key_pressed(mud, event.code, event.char_code);
            break;
        case EVENT_KEY_UP:
            mudclient_key_released(mud, event.code);
            break;
        case EVENT_ADD_WORLD:
            if (mud->panel_login_worldlist != NULL) {
                worldlist_add(mud, event.world->name, event.world->host,
                              event.world->port, event.world->rsa_exponent,
                              event.world->rsa_modulus,
                              event.world->register_url);
            }

            free(event.world);
            break;
        case EVENT_LOGIN:
            handle_login(mud, event.login);
            free_login(event.login);
            break;
        case EVENT_LOGIN_SCREEN:
            handle_login_screen(mud, event.code);
            break;
        case EVENT_REMOVE_WORLD:
            if (mud->panel_login_worldlist != NULL) {
                worldlist_remove(mud, event.code);
            }
            break;
        case EVENT_CHOOSE_WORLD:
            if (mud->panel_login_worldlist != NULL) {
                worldlist_choose(mud, event.code);
            }
            break;
        case EVENT_MENU_CHOICE:
            if (mud->show_right_click_menu) {
                if (event.code >= 0 && event.code < mud->menu_items_count) {
                    mudclient_menu_item_click(mud,
                                              mud->menu_indices[event.code]);
                }

                mud->show_right_click_menu = 0;
            }
            break;
        case EVENT_UI_TAB:
            if (mud->logged_in && event.code >= 0 && event.code <= 6) {
                mud->show_ui_tab = event.code;

                /* as if its icon was tapped: a tab closes when the pointer
                 * is outside it (ui-tabs.c) */
                if (event.code > 0 &&
                    mudclient_ui_tab_is_watch_full_screen(mud)) {
                    mudclient_ui_tab_point_at_header(mud);
                } else if (event.code > 0 && mudclient_is_touch(mud)) {
                    int size = UI_TABS_TOUCH_BUTTON_SIZE;

                    mud->mouse_x = UI_TABS_TOUCH_X + size / 2;
                    mud->mouse_y = UI_TABS_TOUCH_Y +
                                   (event.code - 1) * (size - 2) + size / 2;
                }
            }
            break;
        case EVENT_UI_TAB_STEP:
            if (mud->logged_in && mud->show_ui_tab != 0 &&
                mudclient_ui_tab_is_watch_full_screen(mud)) {
                mudclient_ui_tab_step(mud, event.code);
                mudclient_ui_tab_point_at_header(mud);
            }
            break;
        case EVENT_COMBAT_STYLE:
            if (mud->logged_in && event.code >= 0 && event.code <= 3) {
                mud->combat_style = event.code;

                packet_stream_new_packet(mud->packet_stream,
                                         CLIENT_COMBAT_STYLE);
                packet_stream_put_byte(mud->packet_stream, mud->combat_style);
                packet_stream_send_packet(mud->packet_stream);

                mudclient_ios_save_combat_style(mud);
            }
            break;
        }
    }
}

#endif

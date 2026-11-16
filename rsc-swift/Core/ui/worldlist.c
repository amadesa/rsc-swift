#include "worldlist.h"
#include <assert.h>
#include <stdio.h>

#ifdef EMSCRIPTEN
#define USE_WEBSOCKS 1
#else
#define USE_WEBSOCKS 0
#endif

#define WORLDLIST_MAX 256

struct server_type {
    char name[32];
    char host[64];
    int port;
    char rsa_exponent[512];
    char rsa_modulus[512];
    /* account creation page, may be empty */
    char register_url[256];
};

static struct server_type list[WORLDLIST_MAX] = {0};

/* which defaults a saved list has been given, kept as a "#defaults N" line
 * in worlds.cfg (older builds skip it). a world added to the defaults later
 * is added to saved lists once, so removing it again sticks */
#define WORLDLIST_DEFAULTS_VERSION 2

static void worldlist_set_defaults(void);
static void worldlist_set_2001scape(struct server_type *world);
static int worldlist_add_new_defaults(int version, int count);
static void worldlist_write(void);
static void worldlist_read_presets(struct mudclient *mud);
static void worldlist_populate(mudclient *mud);
static void worldlist_select(mudclient *, int);
static const char *worldlist_known_register_url(const char *host);

static void worldlist_set_defaults(void) {
    memset(list, 0, sizeof(list));

    strcpy(list[0].name, "RSC_Preservation");
    strcpy(list[0].host, "game.openrsc.com");
    list[0].port = USE_WEBSOCKS ? 43496 : 43596; /* websockets */
    strcpy(list[0].rsa_exponent, "00010001");
    strcpy(list[0].rsa_modulus, "87cef754966ecb19806238d9fecf0f421e816976f74f365c86a584e51049794d41fefbdc5fed3a3ed3b7495ba24262bb7d1dd5d2ff9e306b5bbf5522a2e85b25");
    strcpy(list[0].register_url, worldlist_known_register_url(list[0].host));

    strcpy(list[1].name, "Neat_F2P");
    strcpy(list[1].host, "192.3.118.9");
    list[1].port = USE_WEBSOCKS ? 43494 : 43594;
    strcpy(list[1].rsa_exponent, "00010001");
    strcpy(list[1].rsa_modulus, "86b03ac30518bdb3e508ca9660efc7738a73ee7dbedbcebf8c56d030a2bdae70503c60829b7fb5eceb529442234c21bce6d529c8da4fce870e83ceffc379e281");
    strcpy(list[1].register_url, worldlist_known_register_url(list[1].host));

    worldlist_set_2001scape(&list[2]);
}

/* RSC Preservation's sister world on the 2001 game, on the same server and
 * key (Open-RSC server/2001scape.conf) */
static void worldlist_set_2001scape(struct server_type *world) {
    memset(world, 0, sizeof(*world));
    strcpy(world->name, "2001Scape");
    strcpy(world->host, "game.openrsc.com");
    world->port = USE_WEBSOCKS ? 43493 : 43593;
    strcpy(world->rsa_exponent, "00010001");
    strcpy(world->rsa_modulus, "87cef754966ecb19806238d9fecf0f421e816976f74f365c86a584e51049794d41fefbdc5fed3a3ed3b7495ba24262bb7d1dd5d2ff9e306b5bbf5522a2e85b25");
    strcpy(world->register_url, worldlist_known_register_url(world->host));
}

/* gives a list saved with older defaults the worlds added since, returning
 * the new count */
static int worldlist_add_new_defaults(int version, int count) {
    if (version >= 2 || count >= WORLDLIST_MAX - 1) {
        return count;
    }

    int after = -1;

    for (int i = 0; i < count; i++) {
        if (strcmp(list[i].host, "game.openrsc.com") == 0 &&
            (list[i].port == 43593 || list[i].port == 43493)) {
            return count; /* already there */
        }

        if (strcmp(list[i].host, "192.3.118.9") == 0) {
            after = i; /* Neat F2P */
        }
    }

    /* under Neat F2P, as in the defaults, or last */
    int index = after >= 0 ? after + 1 : count;

    memmove(&list[index + 1], &list[index],
            (count - index) * sizeof(struct server_type));
    worldlist_set_2001scape(&list[index]);

    return count + 1;
}

/* registration pages for servers we know about, so worlds saved without one
 * (or added from an rscplus .ini, which has no such field) still get it */
static const char *worldlist_known_register_url(const char *host) {
    if (strcmp(host, "game.openrsc.com") == 0) {
        return "https://rsc.vet/register";
    }

    if (strcmp(host, "192.3.118.9") == 0) {
        return "https://www.neatf2p.com/account/create";
    }

    return "";
}

/* names are shown with spaces but stored with underscores, since the file is
 * whitespace separated */
static void worldlist_write(void) {
    char path[PATH_MAX];

    get_config_path("worlds.cfg", path);

    FILE *file = fopen(path, "w");

    if (file == NULL) {
        return;
    }

    fprintf(file, "#defaults %d\n", WORLDLIST_DEFAULTS_VERSION);

    for (int i = 0; list[i].name[0] != '\0'; ++i) {
        char name[sizeof(list[i].name)];
        strcpy(name, list[i].name);

        for (int j = 0; name[j] != '\0'; ++j) {
            if (name[j] == ' ') {
                name[j] = '_';
            }
        }

        /* the register url is an optional sixth field, "-" when unset */
        fprintf(file, "%s %s %d %s %s %s\n", name, list[i].host,
                list[i].port, list[i].rsa_exponent, list[i].rsa_modulus,
                list[i].register_url[0] != '\0' ? list[i].register_url : "-");
    }

    fclose(file);
}

static void worldlist_read_presets(struct mudclient *mud) {
    char path[PATH_MAX];
    int num = 0;

    panel_clear_list(mud->panel_login_worldlist, mud->control_list_worlds);

    get_config_path("worlds.cfg", path);

    FILE *file = fopen(path, "r");
    if (file == NULL) {
        worldlist_set_defaults();
        worldlist_write();
        return;
    }

    memset(list, 0, sizeof(list));

    char line[1536];
    int defaults_version = 1;

    while (num < WORLDLIST_MAX - 1 && fgets(line, sizeof(line), file)) {
        struct server_type *world = &list[num];

        if (line[0] == '#') {
            sscanf(line, "#defaults %d", &defaults_version);
            continue;
        }

        int res = sscanf(line, "%30s %60s %d %500s %500s %255s", world->name,
                         world->host, &world->port, world->rsa_exponent,
                         world->rsa_modulus, world->register_url);

        if (res < 5) {
            memset(world, 0, sizeof(*world));
            continue;
        }

        if (res < 6 || strcmp(world->register_url, "-") == 0) {
            strcpy(world->register_url,
                   worldlist_known_register_url(world->host));
        }

        num++;
    }
    fclose(file);

    /* replace the untouched defaults from older builds, which included
     * OpenRSC Uranium, with the current ones */
    if (num == 3 && strcmp(list[0].name, "OpenRSC_Preservation") == 0 &&
        strcmp(list[1].name, "OpenRSC_Uranium") == 0 &&
        strcmp(list[2].name, "Neat_F2P") == 0) {
        worldlist_set_defaults();
        worldlist_write();
        return;
    }

    /* saved before the current defaults: rewritten with the new worlds and
     * the current version, so they're only added once */
    int changed = defaults_version < WORLDLIST_DEFAULTS_VERSION;

    num = worldlist_add_new_defaults(defaults_version, num);

    /* the world is officially called "RSC Preservation" (formerly OpenRSC);
     * rename the entry older builds saved */
    for (int i = 0; i < num; i++) {
        if (strcmp(list[i].name, "OpenRSC_Preservation") == 0 &&
            strcmp(list[i].host, "game.openrsc.com") == 0 &&
            list[i].port == 43596) {
            strcpy(list[i].name, "RSC_Preservation");
            changed = 1;
        }
    }

    if (changed) {
        worldlist_write();
    }
}

static void worldlist_populate(mudclient *mud) {
    panel_clear_list(mud->panel_login_worldlist, mud->control_list_worlds);

    for (int i = 0; list[i].name[0] != '\0'; ++i) {
        for (int j = 0; list[i].name[j] != '\0'; ++j) {
            if (list[i].name[j] == '_') {
                list[i].name[j] = ' ';
            }
        }
        panel_add_list_entry(mud->panel_login_worldlist,
                             mud->control_list_worlds, i,
                             list[i].name);
    }
}

void worldlist_new(mudclient *mud) {
    int is_compact = mud->surface->width < MUD_VANILLA_WIDTH ||
                     mud->surface->height < MUD_VANILLA_HEIGHT;

    int login_background_height = is_compact ? 125 : 200;

    int x = (is_compact ? MUD_MIN_WIDTH : MUD_VANILLA_WIDTH) / 2;
    int y = login_background_height + 18;

    mud->panel_login_worldlist = malloc(sizeof(Panel));
    assert(mud->panel_login_worldlist != NULL);
    panel_new(mud->panel_login_worldlist, mud->surface, 20);

    panel_add_text_centre(
        mud->panel_login_worldlist, x, y, "Select a world:", FONT_BOLD_12, 1);
    y += 12;

    int button_x = (is_compact ? MUD_MIN_WIDTH : MUD_VANILLA_WIDTH) - 36;

    int button_y =
        is_compact ? MUD_MIN_HEIGHT - 24 : MUD_VANILLA_HEIGHT - 32;

#ifdef IOS
    /* the compact layout leaves room for two worlds; grow the list into the
     * empty space below, up to seven rows, and move the buttons down */
    if (worldlist_scrolls_natively()) {
        int box_height = is_compact ? MUD_MIN_HEIGHT : MUD_VANILLA_HEIGHT;
        int room = (mud->surface->height - box_height) / 2 - 32;
        int wanted = 7 * worldlist_row_height() - (button_y - 14 - y);
        int extra = wanted < room ? wanted : room;

        if (extra > 0) {
            button_y += extra;
        }
    }
#endif

    panel_add_button_background(mud->panel_login_worldlist,
        button_x, button_y, 60, 20);
    panel_add_text_centre(mud->panel_login_worldlist, button_x, button_y,
                              "Back", FONT_BOLD_12, 0);

    mud->control_worldlist_button = panel_add_button(
        mud->panel_login_worldlist, button_x, button_y, 60, 20);

#ifdef IOS
    /* opens the native sheet to import or enter a world */
    int add_x = button_x - 70;

    panel_add_button_background(mud->panel_login_worldlist, add_x, button_y,
                                76, 20);
    panel_add_text_centre(mud->panel_login_worldlist, add_x, button_y,
                          "Add world", FONT_BOLD_12, 0);

    mud->control_worldlist_add = panel_add_button(
        mud->panel_login_worldlist, add_x, button_y, 76, 20);

    /* removes the selected world after a native confirmation */
    int remove_x = add_x - 72;

    panel_add_button_background(mud->panel_login_worldlist, remove_x,
                                button_y, 64, 20);
    panel_add_text_centre(mud->panel_login_worldlist, remove_x, button_y,
                          "Remove", FONT_BOLD_12, 0);

    mud->control_worldlist_remove = panel_add_button(
        mud->panel_login_worldlist, remove_x, button_y, 64, 20);
#endif

#ifdef IOS
    /* stop above the buttons so tapping one can't also select a world */
    int list_height = button_y - 14 - y;
#else
    int list_height = 170;
#endif

    mud->control_list_worlds = panel_add_text_list_interactive(
        mud->panel_login_worldlist, x - 150, y, 250, list_height,
        FONT_REGULAR_11, 256, 1);

#ifdef IOS
    /* keeps the entries and selection, but worldlist_draw_scrolling draws
     * it and the native scroll view takes its touches */
    if (worldlist_scrolls_natively()) {
        panel_hide(mud->panel_login_worldlist, mud->control_list_worlds);
    }
#endif
    worldlist_read_presets(mud);
    worldlist_populate(mud);

    int world_count = 0;

    while (list[world_count].name[0] != '\0') {
        world_count++;
    }

    if (mud->server[0] == '\0') {
        int world_id = mud->options->last_world;

        if (world_id >= 0 && world_id < world_count) {
            worldlist_select(mud, world_id);
        } else {
            printf("would have been %d\n", mud->options->last_world);
            worldlist_select(mud, 0);
        }
    } else {
        /* keep the highlight on the selected world after a resize */
        for (int i = 0; i < world_count; i++) {
            if (strcmp(list[i].host, mud->server) == 0 &&
                list[i].port == mud->port) {
                mud->panel_login_worldlist
                    ->control_activated[mud->control_list_worlds] = i;
                break;
            }
        }
    }
}

static void worldlist_select(mudclient *mud, int index) {
    strcpy(mud->server, list[index].host);
    strcpy(mud->rsa_exponent, list[index].rsa_exponent);
    strcpy(mud->rsa_modulus, list[index].rsa_modulus);
    printf("INFO: Changed world to %s\n", list[index].name);
    mud->port = list[index].port;
    mud->options->last_world = index;
    mud->panel_login_worldlist->control_activated[mud->control_list_worlds] = index;
}

void worldlist_add(mudclient *mud, const char *name, const char *host,
                   int port, const char *rsa_exponent,
                   const char *rsa_modulus, const char *register_url) {
    int index = 0;

    while (index < WORLDLIST_MAX - 1 && list[index].name[0] != '\0') {
        index++;
    }

    if (index >= WORLDLIST_MAX - 1) {
        return;
    }

    snprintf(list[index].name, sizeof(list[index].name), "%s", name);
    snprintf(list[index].host, sizeof(list[index].host), "%s", host);
    list[index].port = port;
    snprintf(list[index].rsa_exponent, sizeof(list[index].rsa_exponent), "%s",
             rsa_exponent);
    snprintf(list[index].rsa_modulus, sizeof(list[index].rsa_modulus), "%s",
             rsa_modulus);

    if (register_url != NULL && register_url[0] != '\0') {
        snprintf(list[index].register_url, sizeof(list[index].register_url),
                 "%s", register_url);
    } else {
        strcpy(list[index].register_url,
               worldlist_known_register_url(list[index].host));
    }

    worldlist_write();
    worldlist_populate(mud);
    worldlist_select(mud, index);
}

static int worldlist_count(void) {
    int count = 0;

    while (count < WORLDLIST_MAX && list[count].name[0] != '\0') {
        count++;
    }

    return count;
}

void worldlist_remove(mudclient *mud, int index) {
    int count = worldlist_count();

    /* always keep one world to connect to */
    if (index < 0 || index >= count || count <= 1) {
        return;
    }

    int selected = mud->options->last_world;

    memmove(&list[index], &list[index + 1],
            (count - index - 1) * sizeof(struct server_type));
    memset(&list[count - 1], 0, sizeof(struct server_type));

    worldlist_write();
    worldlist_populate(mud);

    if (selected > index) {
        selected--;
    } else if (selected == index) {
        selected = 0;
    }

    worldlist_select(mud, selected);
}

#ifdef IOS
void worldlist_register(mudclient *mud) {
    int index = mud->options->last_world;

    if (index < 0 || index >= worldlist_count()) {
        index = 0;
    }

    mudclient_ios_register(list[index].name, list[index].register_url);
}

int worldlist_select_address(mudclient *mud, const char *host, int port) {
    for (int i = 0; i < worldlist_count(); i++) {
        if (strcmp(list[i].host, host) == 0 && list[i].port == port) {
            worldlist_select(mud, i);
            return 1;
        }
    }

    return 0;
}

const char *worldlist_name_at(const char *host, int port) {
    for (int i = 0; i < worldlist_count(); i++) {
        if (strcmp(list[i].host, host) == 0 && list[i].port == port) {
            return list[i].name;
        }
    }

    return "";
}

/* the watch has its own native world list instead */
int worldlist_scrolls_natively(void) { return !mudclient_ios_is_watch_ui(); }

/* as panel_draw_text_list spaces rows for touch */
int worldlist_row_height(void) {
    return surface_text_height(FONT_REGULAR_11) + 6;
}

int worldlist_get_count(void) { return worldlist_count(); }

void worldlist_choose(mudclient *mud, int index) {
    if (index >= 0 && index < worldlist_count()) {
        worldlist_select(mud, index);
    }
}

/* the world list scrolled by pixels rather than whole rows, clipped to the
 * list, with the classic scrollbar showing where it is */
void worldlist_draw_scrolling(mudclient *mud) {
    Panel *panel = mud->panel_login_worldlist;
    int control = mud->control_list_worlds;

    if (panel == NULL || !worldlist_scrolls_natively()) {
        return;
    }

    int x = panel->control_x[control] + panel->offset_x;
    int y = panel->control_y[control] + panel->offset_y;
    int width = panel->control_width[control];
    int height = panel->control_height[control];

    int count = worldlist_count();
    int row_height = worldlist_row_height();
    int content_height = count * row_height;
    int max_scroll = content_height > height ? content_height - height : 0;
    int scroll = (int)mudclient_ios_world_list_scroll();
    int has_scrollbar = content_height > height;

    mudclient_ios_publish_world_list(x, y, width, height, row_height, count,
                                     panel->control_activated[control]);

    surface_set_bounds(mud->surface, x, y,
                       x + width - (has_scrollbar ? 14 : 0), y + height);

    for (int i = 0; i < count; i++) {
        int row_y = y + i * row_height - scroll;

        if (row_y + row_height <= y || row_y >= y + height) {
            continue;
        }

        int colour =
            panel->control_activated[control] == i ? RED : WHITE;

        /* the baseline where panel_draw_text_list puts it */
        surface_draw_string(
            mud->surface, panel->control_list_entries[control][i], x + 2,
            row_y + (surface_text_height(FONT_REGULAR_11) * 5) / 6 + 3,
            FONT_REGULAR_11, colour);
    }

    surface_reset_bounds(mud->surface);

    if (has_scrollbar) {
        int track = height - 27;
        int scrub_height = (track * height) / content_height;

        if (scrub_height < 6) {
            scrub_height = 6;
        }

        int position = scroll < 0 ? 0 : scroll > max_scroll ? max_scroll : scroll;
        int scrub_y = ((track - scrub_height) * position) / max_scroll;

        surface_draw_scrollbar(mud->surface, x, y, width, height, scrub_y,
                               scrub_height);
    }
}
#endif

void worldlist_handle_mouse(mudclient *mud) {
    panel_handle_mouse(mud->panel_login_worldlist, mud->mouse_x,
                           mud->mouse_y, mud->last_mouse_button_down,
                           mud->mouse_button_down, mud->mouse_scroll_delta);
    if (panel_is_clicked(mud->panel_login_worldlist,
                         mud->control_list_worlds)) {
        int world_index =
            mud->panel_login_worldlist
                ->control_list_entry_mouse_over[mud->control_list_worlds];
        if (world_index >= 0) {
            worldlist_select(mud, world_index);
        }
    } else if (panel_is_clicked(mud->panel_login_worldlist,
                               mud->control_worldlist_button)) {
        mud->login_screen = 0;
#ifdef IOS
    } else if (panel_is_clicked(mud->panel_login_worldlist,
                               mud->control_worldlist_add)) {
        mudclient_ios_request_world();
    } else if (panel_is_clicked(mud->panel_login_worldlist,
                               mud->control_worldlist_remove)) {
        int index = mud->options->last_world;

        if (worldlist_count() <= 1) {
            /* nothing to fall back to */
        } else if (index >= 0 && index < worldlist_count()) {
            mudclient_ios_request_remove_world(index, list[index].name);
        }
#endif
    }
}

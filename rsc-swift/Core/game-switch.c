#include "game-switch.h"

#include <unistd.h>

static const char *retro_files[] = {"config17.jag", "media12.jag",
                                    "entity3.jag",  "textures5.jag",
                                    "models6.jag",  "maps14.jag"};

/* the later game's versions, from options.ini or the defaults. options.ini
 * keeps whichever were loaded last, which may be the 2001 game's */
static struct {
    int config;
    int maps;
    int entity;
    int media;
    int models;
    int textures;
} later_versions;

static void set_versions(Options *options, int retro);

/* options.ini keeps the later game's versions even while the 2001 game is
 * loaded, since the world picks the game; so older builds, and the watch
 * that gets a copy, read a file they understand */
void options_saved_versions(Options *options) {
    if (!CONFIG_IS_TEXT(options->version_config)) {
        return;
    }

    if (later_versions.config == 0) {
        later_versions.config = VERSION_CONFIG;
        later_versions.maps = VERSION_MAPS;
        later_versions.entity = VERSION_ENTITY;
        later_versions.media = VERSION_MEDIA;
        later_versions.models = VERSION_MODELS;
        later_versions.textures = VERSION_TEXTURES;
    }

    set_versions(options, 0);
}

static void set_versions(Options *options, int retro) {
    if (retro) {
        options->version_config = RETRO_VERSION_CONFIG;
        options->version_maps = RETRO_VERSION_MAPS;
        options->version_entity = RETRO_VERSION_ENTITY;
        options->version_media = RETRO_VERSION_MEDIA;
        options->version_models = RETRO_VERSION_MODELS;
        options->version_textures = RETRO_VERSION_TEXTURES;
    } else {
        options->version_config = later_versions.config;
        options->version_maps = later_versions.maps;
        options->version_entity = later_versions.entity;
        options->version_media = later_versions.media;
        options->version_models = later_versions.models;
        options->version_textures = later_versions.textures;
    }
}

static int data_file_exists(const char *file) {
    char path[PATH_MAX];

#ifdef IOS
    snprintf(path, sizeof(path), "%s/%s", mudclient_ios_cache_dir(), file);

    if (access(path, R_OK) == 0) {
        return 1;
    }

    const char *data_dir = mudclient_ios_data_dir();

    if (data_dir[0] == '\0') {
        return 0;
    }

    snprintf(path, sizeof(path), "%s/%s", data_dir, file);
#else
    snprintf(path, sizeof(path), "./cache/%s", file);
#endif

    return access(path, R_OK) == 0;
}

int mudclient_has_retro_data(mudclient *mud) {
    (void)mud;

    for (size_t i = 0; i < sizeof(retro_files) / sizeof(retro_files[0]);
         i++) {
        if (!data_file_exists(retro_files[i])) {
            return 0;
        }
    }

    return 1;
}

void mudclient_choose_startup_game(mudclient *mud) {
    Options *options = mud->options;

    if (CONFIG_IS_TEXT(options->version_config)) {
        /* saved while playing the 2001 game */
        later_versions.config = VERSION_CONFIG;
        later_versions.maps = VERSION_MAPS;
        later_versions.entity = VERSION_ENTITY;
        later_versions.media = VERSION_MEDIA;
        later_versions.models = VERSION_MODELS;
        later_versions.textures = VERSION_TEXTURES;
    } else {
        later_versions.config = options->version_config;
        later_versions.maps = options->version_maps;
        later_versions.entity = options->version_entity;
        later_versions.media = options->version_media;
        later_versions.models = options->version_models;
        later_versions.textures = options->version_textures;
    }

    mud->world_is_retro = worldlist_last_world_is_retro(mud);

    /* without the 2001 data, start on the later game; selecting the world
     * fetches it (mudclient_update_game) */
    set_versions(options, mud->world_is_retro && mudclient_has_retro_data(mud));
}

#ifdef RENDER_SW
/* the length of mud->item_models, as mudclient_load_models made it */
static int item_models_length(void) {
    int max_sprite_id = 0;

    for (int i = 0; i < game_data.item_count; i++) {
        if (game_data.items[i].sprite > max_sprite_id) {
            max_sprite_id = game_data.items[i].sprite;
        }
    }

    return max_sprite_id;
}

static void free_model(GameModel **model) {
    if (*model != NULL) {
        game_model_destroy(*model);
        free(*model);
        *model = NULL;
    }
}

/* frees the loaded game's data, keeping the fonts, the jagex logo, the
 * sounds and everything not from the game data */
static void unload_game(mudclient *mud) {
    /* the last session's objects and region, which logging in again would
     * have freed (mudclient_reset_game) */
    for (int i = 0; i < mud->object_count; i++) {
        scene_remove_model(mud->scene, mud->objects[i].model);
        free_model(&mud->objects[i].model);
    }

    for (int i = 0; i < mud->wall_object_count; i++) {
        scene_remove_model(mud->scene, mud->wall_objects[i].model);
        free_model(&mud->wall_objects[i].model);
    }

    mud->object_count = 0;
    mud->wall_object_count = 0;
    mud->ground_item_count = 0;

    world_reset(mud->world, 1);

    /* the next login loads its region even where the last one was
     * (mudclient_load_next_region) */
    mud->last_plane_index = -1;

    for (int i = 0; i < game_data.model_count && i < GAME_OBJECTS_MAX; i++) {
        free_model(&mud->game_models[i]);
    }

    if (mud->item_models != NULL) {
        int length = item_models_length();

        for (int i = 0; i < length; i++) {
            free_model(&mud->item_models[i]);
        }

        free(mud->item_models);
        mud->item_models = NULL;
    }

    free(mud->world->map_pack);
    free(mud->world->member_map_pack);
    free(mud->world->landscape_pack);
    free(mud->world->member_landscape_pack);

    mud->world->map_pack = NULL;
    mud->world->member_map_pack = NULL;
    mud->world->landscape_pack = NULL;
    mud->world->member_landscape_pack = NULL;

    scene_free_textures(mud->scene);

    /* all but the jagex logo (mudclient_load_jagex) */
    surface_free_sprites(mud->surface, 0, SPRITE_LIMIT - 1);

    /* the tables; their strings are small and left */
    free(game_data.textures);
    free(game_data.wall_objects);
    free(game_data.objects);
    free(game_data.npcs);
    free(game_data.spells);
    free(game_data.items);
    free(game_data.tiles);
    free(game_data.animations);
    free(game_data.prayers);
    free(game_data.roofs);

    memset(&game_data, 0, sizeof(game_data));
}

/* as mudclient_start_game loads it */
static void load_game(mudclient *mud) {
    mud->error_loading_data = 0;

    /* mudclient_start_game frees it once loaded */
    surface_texture_pixels = calloc(32 * 1024, sizeof(int32_t));

    mudclient_load_game_config(mud);

    if (!mud->error_loading_data) {
        mudclient_load_media(mud);
    }

    if (!mud->error_loading_data) {
        mudclient_load_entities(mud);
    }

    if (!mud->error_loading_data) {
        world_new(mud->world, mud->scene, mud->surface,
                  mud->options->version_maps);

        mud->world->base_media_sprite = mud->sprite_media;
        mud->world->thick_walls = mud->options->thick_walls;

        mudclient_load_textures(mud);
    }

    if (!mud->error_loading_data) {
        mudclient_load_models(mud);
    }

    if (!mud->error_loading_data) {
        mudclient_load_maps(mud);
    }

    if (!mud->error_loading_data && !mud->options->lowmem) {
        mudclient_render_login_scene_sprites(mud);
    }

    free(surface_texture_pixels);
    surface_texture_pixels = NULL;
}
#endif

/* removes the downloaded 2001 files, so the next try fetches them again */
static void remove_retro_data(void) {
#ifdef IOS
    const char *data_dir = mudclient_ios_data_dir();

    if (data_dir[0] == '\0') {
        return;
    }

    for (size_t i = 0; i < sizeof(retro_files) / sizeof(retro_files[0]);
         i++) {
        char path[PATH_MAX];
        snprintf(path, sizeof(path), "%s/%s", data_dir, retro_files[i]);
        unlink(path);
    }
#endif
}

static void switch_game(mudclient *mud, int retro) {
#ifdef RENDER_SW
    printf("INFO: Switching to the %s game\n", retro ? "2001" : "later");

    unload_game(mud);
    set_versions(mud->options, retro);
    load_game(mud);

    if (mud->error_loading_data && retro) {
        /* back to the later game rather than a frozen screen
         * (mudclient_handle_inputs stops on error_loading_data) */
        mud_error("couldn't load the 2001 game's data\n");

        remove_retro_data();
        mud->retro_data_state = RETRO_DATA_FAILED;

        unload_game(mud);
        set_versions(mud->options, 0);
        load_game(mud);

        if (!mud->error_loading_data) {
            mudclient_show_login_screen_status(
                mud, "Couldn't load the 2001 game",
                "Choose the world again to download it again");
        }

        return;
    }

    if (!mud->error_loading_data) {
        mudclient_show_login_screen_status(mud, "", "");
    }
#else
    (void)mud;
    (void)retro;
#endif
}

static void request_retro_data(mudclient *mud) {
    if (mud->retro_data_state != RETRO_DATA_IDLE) {
        return;
    }

#ifdef IOS
    mud->retro_data_state = RETRO_DATA_DOWNLOADING;

    mudclient_show_login_screen_status(mud, "Downloading the 2001 game...",
                                       "About 600 KB, just this once");

    mudclient_ios_request_retro_data();
#else
    mud->retro_data_state = RETRO_DATA_FAILED;

    mudclient_show_login_screen_status(
        mud, "This world needs the 2001 game's data",
        "Put config17.jag, media12.jag etc. in ./cache");
#endif
}

void mudclient_update_game(mudclient *mud) {
    if (mud->logged_in || mud->world_is_retro == mudclient_is_retro(mud)) {
        return;
    }

    if (!mud->world_is_retro) {
        switch_game(mud, 0);
    } else if (mud->retro_data_state == RETRO_DATA_FAILED) {
        /* until the world is chosen again or a login retries it */
        return;
    } else if (mudclient_has_retro_data(mud)) {
        switch_game(mud, 1);
    } else {
        request_retro_data(mud);
    }
}

int mudclient_prepare_game(mudclient *mud) {
    if (mud->world_is_retro == mudclient_is_retro(mud)) {
        return 1;
    }

    if (!mud->world_is_retro || mudclient_has_retro_data(mud)) {
        switch_game(mud, mud->world_is_retro);

        return !mud->error_loading_data &&
               mud->world_is_retro == mudclient_is_retro(mud);
    }

    /* try again after a failed download */
    if (mud->retro_data_state == RETRO_DATA_FAILED) {
        mud->retro_data_state = RETRO_DATA_IDLE;
    }

    mud->login_after_retro_data = 1;
    request_retro_data(mud);

    return 0;
}

void mudclient_retro_data_ready(mudclient *mud, int success) {
    int login = mud->login_after_retro_data;

    mud->login_after_retro_data = 0;

    if (!success || !mudclient_has_retro_data(mud)) {
        mud->retro_data_state = RETRO_DATA_FAILED;

        if (!mud->logged_in && mud->world_is_retro) {
            mudclient_show_login_screen_status(
                mud, "Couldn't download the 2001 game",
                "Check the connection, then try again");
        }

        return;
    }

    mud->retro_data_state = RETRO_DATA_IDLE;

    if (mud->logged_in) {
        return;
    }

    if (!mud->world_is_retro) {
        /* another world was chosen meanwhile */
        mudclient_show_login_screen_status(mud, "", "");
        return;
    }

    if (!mudclient_is_retro(mud)) {
        switch_game(mud, 1);
    }

    /* not if it fell back to the later game (switch_game) */
    if (login && !mud->error_loading_data && mudclient_is_retro(mud) &&
        mud->username[0] != '\0' &&
        mud->password[0] != '\0') {
        mudclient_login(mud, mud->username, mud->password, 0);
    }
}

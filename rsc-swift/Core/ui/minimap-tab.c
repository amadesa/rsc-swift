#include "./minimap-tab.h"

void mudclient_draw_minimap_entity(mudclient *mud, int x, int y, int colour) {
    if (x + 2 < mud->surface->bounds_min_x ||
        x - 2 > mud->surface->bounds_max_x ||
        y + 2 < mud->surface->bounds_min_y ||
        y - 2 > mud->surface->bounds_max_y) {
        return;
    }

    surface_draw_line_vertical(mud->surface, x, y - 1, 3, colour);
    surface_draw_line_horizontal(mud->surface, x - 1, y, 3, colour);
}

void mudclient_draw_ui_tab_minimap(mudclient *mud, int no_menus) {
    /* bigger on the watch, filling the space (showing more of the map) */
    int map_width = MINIMAP_WIDTH;
    int map_height = MINIMAP_HEIGHT;

    int ui_x = mud->surface->width - map_width - 3;
    int ui_y = UI_BUTTON_SIZE + 1;

    int is_touch = mudclient_is_touch(mud);

    if (is_touch) {
        ui_x = UI_TABS_TOUCH_X - map_width - 1;

        ui_y =
            UI_TABS_TOUCH_Y + (UI_TABS_TOUCH_HEIGHT - map_height + 10) / 2;
    }

    if (mudclient_ui_tab_is_watch_area(mud)) {
        mudclient_ui_tab_watch_area(mud, &ui_x, &ui_y, &map_width,
                                    &map_height);
    }

    mud->ui_tab_min_x = mud->surface->width - 199;
    mud->ui_tab_max_x = mud->surface->width;
    mud->ui_tab_min_y = 0;
    mud->ui_tab_max_y = 240;

    if (is_touch) {
        mud->ui_tab_min_x = ui_x;
        mud->ui_tab_max_x = ui_x + map_width;
        mud->ui_tab_min_y = ui_y - UI_TABS_LABEL_HEIGHT;
        mud->ui_tab_max_y = ui_y + map_height;
    }

    if (mudclient_ui_tabs_have_icons(mud)) {
        mudclient_draw_ui_tab_label(mud, MAP_TAB, map_width, ui_x,
                                    ui_y - UI_TABS_LABEL_HEIGHT);
    }

    surface_draw_box(mud->surface, ui_x, ui_y, map_width, map_height,
                     BLACK);

    surface_set_bounds(mud->surface, ui_x, ui_y, ui_x + map_width,
                       ui_y + map_height);

    int scale = 192 + mud->minimap_random_scale;
    int rotation = (mud->camera_rotation + mud->minimap_random_rotation) & 0xff;

    int player_x = ((mud->local_player->current_x - 6040) * 3 * scale) / 2048;
    int player_y = ((mud->local_player->current_y - 6040) * 3 * scale) / 2048;

    int sin = sin_cos_2048[(1024 - rotation * 4) & 1023];
    int cos = sin_cos_2048[((1024 - rotation * 4) & 1023) + 1024];
    int temp_x = (player_y * sin + player_x * cos) >> 18;

    player_y = (player_y * cos - player_x * sin) >> 18;
    player_x = temp_x;

    surface_draw_minimap_sprite(
        mud->surface, ui_x + (map_width / 2) - player_x,
        ui_y + (map_height / 2) + player_y, mud->sprite_media - 1,
        (rotation + 64) & 255, scale);

    for (int i = 0; i < mud->object_count; i++) {
        int object_x = ((mud->objects[i].x * MAGIC_LOC + 64 -
                         mud->local_player->current_x) *
                        3 * scale) /
                       2048;

        int object_y = ((mud->objects[i].y * MAGIC_LOC + 64 -
                         mud->local_player->current_y) *
                        3 * scale) /
                       2048;

        int temp_x = (object_y * sin + object_x * cos) >> 18;

        object_y = (object_y * cos - object_x * sin) >> 18;
        object_x = temp_x;

        mudclient_draw_minimap_entity(
            mud, ui_x + (map_width / 2) + object_x,
            ui_y + (map_height / 2) - object_y, CYAN);
    }

    for (int i = 0; i < mud->ground_item_count; i++) {
        int item_x = ((mud->ground_items[i].x * MAGIC_LOC + 64 -
                       mud->local_player->current_x) *
                      3 * scale) /
                     2048;

        int item_y = ((mud->ground_items[i].y * MAGIC_LOC + 64 -
                       mud->local_player->current_y) *
                      3 * scale) /
                     2048;

        int temp_x = (item_y * sin + item_x * cos) >> 18;

        item_y = (item_y * cos - item_x * sin) >> 18;
        item_x = temp_x;

        mudclient_draw_minimap_entity(mud, ui_x + (map_width / 2) + item_x,
                                      ui_y + (map_height / 2) - item_y,
                                      RED);
    }

    for (int i = 0; i < mud->npc_count; i++) {
        GameCharacter *npc = mud->npcs[i];

        int npc_x =
            ((npc->current_x - mud->local_player->current_x) * 3 * scale) /
            2048;

        int npc_y =
            ((npc->current_y - mud->local_player->current_y) * 3 * scale) /
            2048;

        int temp_x = (npc_y * sin + npc_x * cos) >> 18;

        npc_y = (npc_y * cos - npc_x * sin) >> 18;
        npc_x = temp_x;

        mudclient_draw_minimap_entity(mud, ui_x + (map_width / 2) + npc_x,
                                      ui_y + (map_height / 2) - npc_y,
                                      YELLOW);
    }

    for (int i = 0; i < mud->player_count; i++) {
        GameCharacter *player = mud->players[i];

        int other_player_x =
            ((player->current_x - mud->local_player->current_x) * 3 * scale) /
            2048;

        int other_player_y =
            ((player->current_y - mud->local_player->current_y) * 3 * scale) /
            2048;

        int temp_x = (other_player_y * sin + other_player_x * cos) >> 18;

        other_player_y = (other_player_y * cos - other_player_x * sin) >> 18;
        other_player_x = temp_x;

        int player_colour = WHITE;

        for (int j = 0; j < mud->friend_list_count; j++) {
            if (player->encoded_username == mud->friend_list[j] &&
                mud->friend_list_online[j] == FRIEND_ONLINE) {
                player_colour = GREEN;
                break;
            }
        }

        mudclient_draw_minimap_entity(
            mud, ui_x + (map_width / 2) + other_player_x,
            ui_y + (map_height / 2) - other_player_y, player_colour);
    }

    /* player */
    surface_draw_circle(mud->surface, ui_x + (map_width / 2),
                        ui_y + (map_height / 2), 2, WHITE, 255, 0);

    /* compass */
    surface_draw_minimap_sprite(mud->surface, ui_x + 19, ui_y + 19,
                                mud->sprite_media + 24,
                                (mud->camera_rotation + 128) & 255, 128);

    surface_set_bounds(mud->surface, 0, 0, mud->surface->width,
                       mud->surface->height);

    if (!no_menus) {
        return;
    }

    int mouse_x = mud->mouse_x - ui_x;
    int mouse_y = mud->mouse_y - ui_y;

    if (mud->options->compass_menu && mouse_x > 0 && mouse_x <= 32 &&
        mouse_y > 0 && mouse_y <= 32) {
        strcpy(mud->menu_items[mud->menu_items_count].action_text, "Look");
        strcpy(mud->menu_items[mud->menu_items_count].target_text, "North");
        mud->menu_items[mud->menu_items_count].type = MENU_MAP_LOOK;
        mud->menu_items[mud->menu_items_count].index = 128;
        mud->menu_items_count++;

        strcpy(mud->menu_items[mud->menu_items_count].action_text, "Look");
        strcpy(mud->menu_items[mud->menu_items_count].target_text, "East");
        mud->menu_items[mud->menu_items_count].type = MENU_MAP_LOOK;
        mud->menu_items[mud->menu_items_count].index = 192;
        mud->menu_items_count++;

        strcpy(mud->menu_items[mud->menu_items_count].action_text, "Look");
        strcpy(mud->menu_items[mud->menu_items_count].target_text, "South");
        mud->menu_items[mud->menu_items_count].type = MENU_MAP_LOOK;
        mud->menu_items[mud->menu_items_count].index = 0;
        mud->menu_items_count++;

        strcpy(mud->menu_items[mud->menu_items_count].action_text, "Look");
        strcpy(mud->menu_items[mud->menu_items_count].target_text, "West");
        mud->menu_items[mud->menu_items_count].type = MENU_MAP_LOOK;
        mud->menu_items[mud->menu_items_count].index = 64;
        mud->menu_items_count++;
        return;
    }

    if (mouse_x >= 0 && mouse_y >= 0 && mouse_x < map_width + 40 &&
        mouse_y < map_height) {
        int delta_y = ((mud->mouse_x - (ui_x + (map_width / 2))) * 16384) /
                      (3 * scale);

        int delta_x = ((mud->mouse_y - (ui_y + (map_height / 2))) * 16384) /
                      (3 * scale);

        int temp_x = (delta_x * sin + delta_y * cos) >> 15;

        delta_x = (delta_x * cos - delta_y * sin) >> 15;
        delta_y = temp_x;
        delta_y += mud->local_player->current_x;
        delta_x = mud->local_player->current_y - delta_x;

        if (mud->mouse_button_click == 1) {
            mudclient_walk_to_action_source(mud, mud->local_region_x,
                                            mud->local_region_y, delta_y / 128,
                                            delta_x / 128, 0);

            mud->mouse_button_click = 0;
        }
    }
}

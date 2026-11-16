#include <math.h>

#include "ui-tabs.h"

char *mudclient_ui_tab_names[] = {"Inventory", "Map",     "Stats",
                                  "Spellbook", "Friends", "Options"};

static void mudclient_toggle_ui_tab(mudclient *mud, int tab);

/* keeps the watch's icons clear of its rounded corners */
#define WATCH_TABS_INSET_Y 34
#define WATCH_TABS_INSET_X 6

static int is_watch_tabs(void) {
#ifdef IOS
    return mudclient_ios_is_watch_ui();
#else
    return 0;
#endif
}

int mudclient_ui_tabs_touch_button_size(mudclient *mud) {
    if (is_watch_tabs()) {
        /* six icons (overlapping by 2) from the top inset to the bottom */
        return (mud->surface->height - WATCH_TABS_INSET_Y * 2 - 1) / 6 + 2;
    }

    return UI_BUTTON_SIZE;
}

int mudclient_ui_tabs_touch_x(mudclient *mud) {
    return mud->surface->width - MUD_SAFE_RIGHT - UI_TABS_TOUCH_BUTTON_SIZE -
           (is_watch_tabs() ? WATCH_TABS_INSET_X : 11);
}

int mudclient_ui_tabs_touch_y(mudclient *mud) {
    if (is_watch_tabs()) {
        return WATCH_TABS_INSET_Y;
    }

    return (mud->surface->height - MUD_SAFE_BOTTOM - UI_TABS_TOUCH_HEIGHT) -
           30;
}

/*
 * on the watch an open tab's panel fills the space left of the tab icons
 * (which run down the whole right edge).
 * the iPhone's places hang from the bottom of its short column of icons,
 * which on the watch left them low. off with watch_tab_panels = 0
 */
int mudclient_ui_tab_is_watch_area(mudclient *mud) {
    return is_watch_tabs() && mud->options->watch_tab_panels;
}

/* an open panel covers the whole screen, under a header with the tab's
 * name and arrows to the next and previous tabs */
int mudclient_ui_tab_is_watch_full_screen(mudclient *mud) {
    return mudclient_ui_tab_is_watch_area(mud) &&
           mud->options->watch_tab_full_screen;
}

/* the screen's rounded corners, about a fifth of its width */
static int watch_corner_radius(mudclient *mud) {
    return mud->surface->width * 19 / 100;
}

/* how far from the top or bottom edge the corner's curve comes in by
 * `inset` from the side */
static int watch_corner_depth(mudclient *mud, int inset) {
    int radius = watch_corner_radius(mud);

    if (inset >= radius) {
        return 0;
    }

    int rest = radius - inset;

    return radius - (int)floor(sqrt((double)(radius * radius - rest * rest)));
}

/* full screen: the panels are this far in from the sides, and as far from
 * the top and bottom as the corners need */
#define WATCH_FULL_INSET_X 8
#define WATCH_FULL_HEADER_HEIGHT 20

static void watch_full_header(mudclient *mud, int *x, int *y, int *width,
                              int *height) {
    int body_y = watch_corner_depth(mud, WATCH_FULL_INSET_X) + 1;

    *height = WATCH_FULL_HEADER_HEIGHT;
    *y = body_y - 2 - *height;
    *x = watch_corner_depth(mud, *y) + 2;
    *width = mud->surface->width - *x * 2;
}

/* the whole space a panel can fill: from the left edge (clear of the
 * rounded corners, as the icons are on the right) to the icons, and from
 * under the label to the bottom of the icons. full screen, all of it but
 * the corners and the header */
void mudclient_ui_tab_watch_area(mudclient *mud, int *x, int *y, int *width,
                                 int *height) {
    if (mudclient_ui_tab_is_watch_full_screen(mud)) {
        int depth = watch_corner_depth(mud, WATCH_FULL_INSET_X) + 1;

        *x = WATCH_FULL_INSET_X;
        *y = depth;
        *width = mud->surface->width - WATCH_FULL_INSET_X * 2;
        *height = mud->surface->height - depth * 2;
        return;
    }

    *x = WATCH_TABS_INSET_X;
    *y = UI_TABS_TOUCH_Y + UI_TABS_LABEL_HEIGHT;
    *width = UI_TABS_TOUCH_X - 1 - *x;
    *height = UI_TABS_TOUCH_Y + UI_TABS_TOUCH_HEIGHT - *y;
}

/* moves a panel so its list control is at x, y. the lists are made once,
 * while loading, at the iPhone's places */
void mudclient_ui_tab_move_list(Panel *panel, int control, int x, int y) {
    panel->offset_x = x - panel->control_x[control];
    panel->offset_y = y - panel->control_y[control];
}

/* a tab icon sprite, scaled up when the icons are bigger than usual */
static void draw_tab_sprite(mudclient *mud, int x, int y, int sprite_id,
                            int alpha) {
    int size = UI_TABS_TOUCH_BUTTON_SIZE;

    if (!mudclient_is_touch(mud) || size == UI_BUTTON_SIZE) {
        if (alpha < 256) {
            surface_draw_sprite_alpha(mud->surface, x, y, sprite_id, alpha);
        } else {
            surface_draw_sprite(mud->surface, x, y, sprite_id);
        }

        return;
    }

    Surface *surface = mud->surface;

#ifdef RENDER_SW
    /* scaling only works on full colour sprites, and only some of the
     * palette ones are converted while loading (e.g. not the selected tab
     * icons, which crashed) */
    if (surface->surface_pixels[sprite_id] == NULL) {
        if (surface->sprite_colours[sprite_id] == NULL) {
            return;
        }

        surface_load_sprite(surface, sprite_id);
    }
#endif

    int width = surface->sprite_translate[sprite_id]
                    ? surface->sprite_width_full[sprite_id]
                    : surface->sprite_width[sprite_id];

    int height = surface->sprite_translate[sprite_id]
                     ? surface->sprite_height_full[sprite_id]
                     : surface->sprite_height[sprite_id];

    width = width * size / UI_BUTTON_SIZE;
    height = height * size / UI_BUTTON_SIZE;

    if (alpha < 256) {
        surface_draw_sprite_scale_alpha(surface, x, y, width, height, sprite_id,
                                        alpha);
    } else {
        surface_draw_sprite_scale(surface, x, y, width, height, sprite_id, 0);
    }
}

void mudclient_draw_inventory_count(mudclient *mud) {
    int is_touch = mudclient_is_touch(mud);

    if (!mud->options->inventory_count ||
        (is_touch && mud->selected_item_inventory_index >= 0)) {
        return;
    }

#ifdef IOS
    if (mudclient_ios_ui_tabs_hidden(mud)) {
        return;
    }
#endif

    int size = UI_TABS_TOUCH_BUTTON_SIZE;
    int x = is_touch ? UI_TABS_TOUCH_X + (18 * size / UI_BUTTON_SIZE)
                     : mud->surface->width - 17;
    int y = is_touch ? UI_TABS_TOUCH_Y + (21 * size / UI_BUTTON_SIZE) : 24;

    int count = mud->inventory_items_count;

    char colour[6] = {0};

    if (count == 30) {
        strcpy(colour, "@red@");
    } else if (count > 25) {
        strcpy(colour, "@or3@");
    } else if (count > 20) {
        strcpy(colour, "@or2@");
    } else if (count > 15) {
        strcpy(colour, "@or1@");
    } else if (count > 10) {
        strcpy(colour, "@gr1@");
    } else if (count > 5) {
        strcpy(colour, "@gr2@");
    } else {
        strcpy(colour, "@gre@");
    }

    char formatted_count[17] = {0};
    sprintf(formatted_count, "%s%d", colour, count);

    surface_draw_string_centre(mud->surface, formatted_count, x, y,
                               FONT_BOLD_13, WHITE);
}

void mudclient_draw_inventory_icon(mudclient *mud, int x, int y,
                                   int is_selected) {
    int size = UI_TABS_TOUCH_BUTTON_SIZE - 3;

    if (is_selected) {
        surface_draw_box(mud->surface, x, y, size, size, 0x000084);
    } else {
        surface_draw_box_alpha(mud->surface, x, y, size, size, GREY_B5, 128);
    }

    mudclient_draw_item(
        mud, x, y + (5 * size / 32), size, 22 * size / 32,
        mud->inventory_item_id[mud->selected_item_inventory_index]);
}

void mudclient_draw_magic_icon(mudclient *mud, int x, int y, int is_selected) {
    int size = UI_TABS_TOUCH_BUTTON_SIZE - 3;

    if (is_selected) {
        surface_draw_box(mud->surface, x, y, size, size, 0x000084);
    } else {
        surface_draw_box_alpha(mud->surface, x, y, size, size, GREY_B5, 128);
    }

    draw_tab_sprite(mud, x, y, mud->sprite_projectile + 1, 256);
}

void mudclient_draw_ui_tabs(mudclient *mud) {
    int is_touch = mudclient_is_touch(mud);

    if (mud->show_dialog_bank && mud->surface->width >= 680 && is_touch) {
        return;
    }

#ifdef IOS
    if (mudclient_ios_ui_tabs_hidden(mud)) {
        return;
    }
#endif

    if (mud->show_ui_tab != 0 && mudclient_ui_tab_is_watch_full_screen(mud)) {
        return;
    }

    int button_y = 3;

    if (mud->options->version_media >= 59) {
        int button_x = mud->surface->width - UI_BUTTON_SIZE;

        if (is_touch) {
            button_x = UI_TABS_TOUCH_X;
            button_y = UI_TABS_TOUCH_Y;
        }

        for (int i = 0; i < 6; i++) {
            int selected_tab = i + 1;

            if (is_touch && selected_tab == INVENTORY_TAB &&
                mud->selected_item_inventory_index >= 0) {
                mudclient_draw_inventory_icon(mud, button_x, button_y, 0);
            } else if (is_touch && selected_tab == MAGIC_TAB &&
                       mud->selected_spell >= 0) {
                mudclient_draw_magic_icon(mud, button_x, button_y, 0);
            } else {
                draw_tab_sprite(mud, button_x, button_y,
                                mud->sprite_media + 33 + i, 128);
            }

            if (is_touch) {
                button_y += UI_TABS_TOUCH_BUTTON_SIZE - 2;
            } else {
                button_x -= UI_BUTTON_SIZE - 2;
            }
        }
    } else {
        int button_x =
            mud->surface->width - mud->surface->sprite_width[mud->sprite_media] - 3;

        surface_draw_sprite_alpha(mud->surface, button_x, button_y,
                                  mud->sprite_media, 128);
    }

    mudclient_draw_inventory_count(mud);
}

/* the next or previous tab, round from Options to Inventory */
void mudclient_ui_tab_step(mudclient *mud, int direction) {
    if (mud->show_ui_tab == 0) {
        return;
    }

    mud->show_ui_tab = (mud->show_ui_tab - 1 + (direction < 0 ? 5 : 1)) % 6 + 1;
}

/* the pointer on the full screen header, which keeps the panel open */
void mudclient_ui_tab_point_at_header(mudclient *mud) {
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;

    watch_full_header(mud, &x, &y, &width, &height);

    mud->mouse_x = x + width / 2;
    mud->mouse_y = y + height / 2;
}

static int is_on_full_header(mudclient *mud) {
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;

    watch_full_header(mud, &x, &y, &width, &height);

    /* a little taller to tap, down to the panel */
    return mud->mouse_x >= x && mud->mouse_x < x + width &&
           mud->mouse_y >= 0 && mud->mouse_y < y + height + 2;
}

/* the header's ends go to the previous and next tabs, its name closes */
static int handle_full_header(mudclient *mud) {
    if (!is_on_full_header(mud)) {
        return 0;
    }

    if (mud->mouse_button_click != 0) {
        int x = 0;
        int y = 0;
        int width = 0;
        int height = 0;

        watch_full_header(mud, &x, &y, &width, &height);

        int arrow_width = width / 4;

        if (mud->mouse_x < x + arrow_width) {
            mudclient_ui_tab_step(mud, -1);
        } else if (mud->mouse_x >= x + width - arrow_width) {
            mudclient_ui_tab_step(mud, 1);
        } else {
            mud->show_ui_tab = 0;
        }

        mud->mouse_button_click = 0;
    }

    return 1;
}

static void draw_full_header(mudclient *mud) {
    int x = 0;
    int y = 0;
    int width = 0;
    int height = 0;

    watch_full_header(mud, &x, &y, &width, &height);

    surface_draw_box_alpha(mud->surface, x, y, width, height, GREY_B5, 160);
    surface_draw_border(mud->surface, x, y, width, height, BLACK);

    int arrow_width = width / 4;

    surface_draw_line_vertical(mud->surface, x + arrow_width, y, height,
                               BLACK);

    surface_draw_line_vertical(mud->surface, x + width - arrow_width, y,
                               height, BLACK);

    int text_y = y + height / 2 + 5;

    surface_draw_string_centre(mud->surface, "<", x + arrow_width / 2, text_y,
                               FONT_BOLD_14, YELLOW);

    surface_draw_string_centre(mud->surface, ">",
                               x + width - arrow_width / 2, text_y,
                               FONT_BOLD_14, YELLOW);

    char title[32] = {0};

    snprintf(title, sizeof(title), "%s @lre@x",
             mudclient_ui_tab_names[mud->show_ui_tab - 1]);

    surface_draw_string_centre(mud->surface, title, x + width / 2, text_y,
                               FONT_BOLD_12, WHITE);
}

static void mudclient_toggle_ui_tab(mudclient *mud, int tab) {
    if (mud->mouse_button_click != 0) {
        mud->show_ui_tab = mud->show_ui_tab == tab ? 0 : tab;
        mud->mouse_button_click = 0;
    }
}

void mudclient_set_active_ui_tab(mudclient *mud, int no_menus) {
    int is_toggle = mudclient_is_touch(mud);

#if defined(_3DS) || defined(__SWITCH__)
    is_toggle = 1;
#endif

    int offset_min_x = mud->surface->width - UI_BUTTON_SIZE;
    int offset_max_x = mud->surface->width - 3;

    int offset_min_y = 3;
    int offset_max_y = UI_BUTTON_SIZE;

    if (mudclient_is_touch(mud)) {
        offset_min_x = UI_TABS_TOUCH_X;
        offset_max_x = mud->surface->width;

        offset_min_y = UI_TABS_TOUCH_Y;
        offset_max_y = offset_min_y + (UI_TABS_TOUCH_BUTTON_SIZE - 2);
    }

    int is_dragging_scrollbar = 0;

    if (mud->options->off_handle_scroll_drag) {
        is_dragging_scrollbar =
            mud->panel_quests->control_list_scrollbar_handle_dragged
                [mud->control_list_quest] ||
            mud->panel_magic->control_list_scrollbar_handle_dragged
                [mud->control_list_magic] ||
            mud->panel_social_list->control_list_scrollbar_handle_dragged
                [mud->control_list_social];

        if (is_dragging_scrollbar) {
            return;
        }
    }

    int has_changed_tab = 0;

    int is_full_screen =
        mud->show_ui_tab != 0 && mudclient_ui_tab_is_watch_full_screen(mud);

    if (is_full_screen && handle_full_header(mud)) {
        return;
    }

#ifdef IOS
    /* hidden icons can't be tapped */
    int tab_count = mudclient_ios_ui_tabs_hidden(mud) ? 0 : 6;
#else
    int tab_count = 6;
#endif

    /* nor those under a full screen panel */
    if (is_full_screen) {
        tab_count = 0;
    }

    for (int i = 0; i < tab_count; i++) {
        int tab = i + 1;

        if (mud->mouse_x >= offset_min_x && mud->mouse_x < offset_max_x &&
            mud->mouse_y >= offset_min_y && mud->mouse_y < offset_max_y) {
            char *tab_name = mudclient_ui_tab_names[i];
            char *page = tab == MAP_TAB ? "RuneScape_Classic_Map" : tab_name;

            if (is_toggle) {
                if (mud->show_ui_tab == tab && mud->selected_wiki && no_menus) {
                    mudclient_menu_add_wiki(mud, tab_name, page);
                } else {
                    mudclient_toggle_ui_tab(mud, tab);
                }

                return;
            }

            if (mud->show_ui_tab == 0 || mud->mouse_y < UI_BUTTON_SIZE - 9) {
                mud->show_ui_tab = tab;

                if (tab == MAP_TAB && mud->options->anti_macro) {
                    mud->minimap_random_rotation =
                        (int)((((float)rand() / (float)RAND_MAX)) * 13) - 6;

                    mud->minimap_random_scale =
                        (int)((((float)rand() / (float)RAND_MAX)) * 23) - 11;
                }

                has_changed_tab = 1;
            }

            if (mud->selected_wiki && no_menus) {
                mudclient_menu_add_wiki(mud, tab_name, page);
            }
        }

        if (mudclient_is_touch(mud)) {
            offset_min_y += UI_TABS_TOUCH_BUTTON_SIZE - 2;
            offset_max_y += UI_TABS_TOUCH_BUTTON_SIZE - 2;
        } else {
            offset_min_x -= UI_BUTTON_SIZE - 2;
            offset_max_x -= UI_BUTTON_SIZE - 2;
        }
    }

    /* full screen, taps anywhere on the panel's area keep it open, even
     * below a short panel */
    if (is_full_screen) {
        int x = 0;
        int y = 0;
        int width = 0;
        int height = 0;

        mudclient_ui_tab_watch_area(mud, &x, &y, &width, &height);

        if (mud->mouse_x < x || mud->mouse_x > x + width || mud->mouse_y < y ||
            mud->mouse_y > y + height) {
            mud->show_ui_tab = 0;
        }

        return;
    }

    /* ui_tab_ boundary values will change next frame after the change */
    if (!has_changed_tab && !is_dragging_scrollbar && mud->show_ui_tab != 0 &&
        (mud->mouse_x < mud->ui_tab_min_x || mud->mouse_x > mud->ui_tab_max_x ||
         mud->mouse_y < mud->ui_tab_min_y ||
         mud->mouse_y > mud->ui_tab_max_y)) {
        mud->show_ui_tab = 0;
    }
}

void mudclient_draw_ui_tab_label(mudclient *mud, int selected_tab, int width,
                                 int x, int y) {
    /* the header has the name */
    if (mudclient_ui_tab_is_watch_full_screen(mud)) {
        return;
    }

    surface_draw_box(mud->surface, x, y, width, 9, UI_LABEL_COLOUR);

    int sprite_id = mud->sprite_media + 26 + selected_tab;

    /* the 2001 game's media has no labels sprite */
    if (mud->surface->sprite_width[sprite_id] == 0) {
        surface_draw_string(mud->surface,
                            mudclient_ui_tab_names[selected_tab - 1], x + 2,
                            y + 8, FONT_REGULAR_11, WHITE);

        surface_draw_line_horizontal(mud->surface, x, y + 9, width, BLACK);
        return;
    }

    int label_offset = !mudclient_is_touch(mud) && mud->show_ui_tab > 4
                           ? width - mud->surface->sprite_width[sprite_id] - 3
                           : 1;

    surface_draw_sprite(mud->surface, x + label_offset, y + 1, sprite_id);
    surface_draw_line_horizontal(mud->surface, x, y + 9, width, BLACK);
}

void mudclient_draw_active_ui_tab(mudclient *mud, int no_menus) {
    if (mud->show_ui_tab == INVENTORY_TAB) {
        mudclient_draw_ui_tab_inventory(mud, no_menus);
    } else if (mud->show_ui_tab == MAP_TAB) {
        mudclient_draw_ui_tab_minimap(mud, no_menus);
    } else if (mud->show_ui_tab == STATS_TAB) {
        mudclient_draw_ui_tab_stats(mud, no_menus);
    } else if (mud->show_ui_tab == MAGIC_TAB) {
        mudclient_draw_ui_tab_magic(mud, no_menus);
    } else if (mud->show_ui_tab == SOCIAL_TAB) {
        mudclient_draw_ui_tab_social(mud, no_menus);
    } else if (mud->show_ui_tab == OPTIONS_TAB) {
        mudclient_draw_ui_tab_options(mud, no_menus);
    }

    /* the header instead of the (hidden) icons */
    if (mud->show_ui_tab != 0 && mudclient_ui_tab_is_watch_full_screen(mud)) {
        draw_full_header(mud);
        return;
    }

    if (mud->show_ui_tab != 0) {
        int selected_y = 3;
        int selected_x;

        if (mud->options->version_media >= 59) {
            selected_x = mud->surface->width -
                         UI_BUTTON_SIZE * mud->show_ui_tab +
                         (mud->show_ui_tab - 1) * 2;

            if (mudclient_is_touch(mud)) {
                selected_x = UI_TABS_TOUCH_X;

                selected_y = UI_TABS_TOUCH_Y +
                    (mud->show_ui_tab - 1) * (UI_TABS_TOUCH_BUTTON_SIZE - 2);

                if (mud->show_ui_tab == INVENTORY_TAB &&
                    mud->selected_item_inventory_index >= 0) {
                    mudclient_draw_inventory_icon(mud,
                        selected_x, selected_y, 1);
                    return;
                } else if (mud->show_ui_tab == MAGIC_TAB &&
                           mud->selected_spell >= 0) {
                    mudclient_draw_magic_icon(mud, selected_x, selected_y, 1);
                    return;
                }
            }
        } else {
            selected_x = mud->surface->width - UI_TABS_WIDTH - 3;
        }

        draw_tab_sprite(mud, selected_x, selected_y,
                        mud->sprite_media + mud->show_ui_tab, 256);
    }

    mudclient_draw_inventory_count(mud);
}

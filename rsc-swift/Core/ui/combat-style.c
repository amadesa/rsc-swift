#include "combat-style.h"

const char *combat_styles[] = {
    "Controlled (+1 of each)", "Aggressive (+3 strength)",
    "Accurate (+3 attack)", "Defensive (+3 defense)"};

const char *combat_styles_compact[] = {
    "Controlled (+1 each)", "Aggressive (+3 str.)", "Accurate (+3 att.)",
    "Defensive (+3 def.)"};

int mudclient_is_combat_style_shown(mudclient *mud) {
#ifdef IOS
    /* the watch app shows these itself */
    if (mudclient_ios_is_watch_ui()) {
        return 0;
    }
#endif

    return mudclient_is_in_combat(mud) || mud->options->combat_style_always;
}

int mudclient_combat_style_bottom(mudclient *mud) {
    int is_compact = mud->surface->width < 390;
    int combat_button_height = is_compact ? 22 : 20;
    int ui_y = mudclient_is_touch(mud) ? 140 + MUD_SAFE_TOP : 15;

    /* the title and the four styles */
    return ui_y + combat_button_height * 5;
}

void mudclient_draw_combat_style(mudclient *mud) {
    int is_compact = mud->surface->width < 390;
    int is_touch = mudclient_is_touch(mud);

    int combat_button_height = is_compact ? 22 : 20;
    int combat_style_width = is_compact ? 106 : 175;

    int ui_x = is_touch ? 13 + MUD_SAFE_LEFT : 7;
    int ui_y = is_touch ? 140 + MUD_SAFE_TOP : 15;

    int combat_styles_length = sizeof(combat_styles) / sizeof(combat_styles[0]);

    if (mud->mouse_button_click != 0 &&
        (is_compact ? mud->show_ui_tab != INVENTORY_TAB : 1)) {
        for (int i = 0; i < combat_styles_length + 1; i++) {
            if (i <= 0 || mud->mouse_x <= ui_x ||
                mud->mouse_x >= ui_x + combat_style_width ||
                mud->mouse_y < ui_y + i * combat_button_height ||
                mud->mouse_y >
                    ui_y + i * combat_button_height + combat_button_height) {
                continue;
            }

            mud->combat_style = i - 1;
            mud->mouse_button_click = 0;

            packet_stream_new_packet(mud->packet_stream, CLIENT_COMBAT_STYLE);
            packet_stream_put_byte(mud->packet_stream, mud->combat_style);
            packet_stream_send_packet(mud->packet_stream);

#ifdef IOS
            /* remembered per world and character for the next login */
            mudclient_ios_save_combat_style(mud);
#endif
            break;
        }
    }

    for (int i = 0; i < combat_styles_length + 1; i++) {
        int box_colour = i == mud->combat_style + 1 ? RED : GREY_BE;

        surface_draw_box_alpha(
            mud->surface, ui_x, ui_y + i * combat_button_height,
            combat_style_width, combat_button_height, box_colour, 128);

        surface_draw_line_horizontal(mud->surface, ui_x,
                                     ui_y + i * combat_button_height,
                                     combat_style_width, BLACK);

        surface_draw_line_horizontal(mud->surface, ui_x,
                                     ui_y + i * combat_button_height +
                                         combat_button_height,
                                     combat_style_width, BLACK);
    }

    int y = 16;

    if (is_compact) {
        surface_draw_string_centre(mud->surface, "Combat style",
                                   ui_x + (combat_style_width / 2), ui_y + y,
                                   FONT_BOLD_12, WHITE);
    } else {
        surface_draw_string_centre(mud->surface, "Select combat style",
                                   ui_x + (combat_style_width / 2), ui_y + y,
                                   FONT_BOLD_13, WHITE);
    }

    y += combat_button_height;

    for (int i = 0; i < combat_styles_length; i++) {
        if (is_compact) {
            surface_draw_string_centre(mud->surface, combat_styles_compact[i],
                                       ui_x + (combat_style_width / 2),
                                       ui_y + y - 1, FONT_REGULAR_11, BLACK);
        } else {
            surface_draw_string_centre(mud->surface, combat_styles[i],
                                       ui_x + (combat_style_width / 2),
                                       ui_y + y, FONT_BOLD_13, BLACK);
        }

        y += combat_button_height;
    }
}

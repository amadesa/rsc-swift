#include "status-bars.h"
#include "combat-style.h"

static void draw_skill_effects(mudclient *mud, int x, int y);

/* the frame RSCPlus draws around its bars (assets/hbar/bar.png), which
 * blends into the blue bar along the bottom. each row is its left edge
 * (mirrored for the right) and the colour across the middle; '.' is see
 * through, showing the bar's fill */
#define BAR_FRAME_HEIGHT 16
#define BAR_FRAME_EDGE 5

static const char *bar_frame_edges[BAR_FRAME_HEIGHT] = {
    ".KKKKK", "KKKKKK", "KK1111", "KK122.", "KK12..", "KK12..",
    "1112..", "2222..", "3222..", "3322..", "3222..", "2222..",
    "1111..", "KKKK2.", "KKKKKK", "KKKKKK"};

static int bar_frame_colour(char c) {
    switch (c) {
    case 'K':
        return 0x0a0a09;
    case '1':
        return 0x002831;
    case '2':
        return 0x00394a;
    case '3':
        return 0x005d7b;
    default:
        return -1;
    }
}

static void draw_bar_frame(mudclient *mud, int x, int y, int width) {
    for (int row = 0; row < BAR_FRAME_HEIGHT; row++) {
        const char *edge = bar_frame_edges[row];

        for (int i = 0; i < BAR_FRAME_EDGE; i++) {
            int colour = bar_frame_colour(edge[i]);

            if (colour != -1) {
                surface_draw_box(mud->surface, x + i, y + row, 1, 1, colour);
                surface_draw_box(mud->surface, x + width - 1 - i, y + row, 1,
                                 1, colour);
            }
        }

        int middle = bar_frame_colour(edge[BAR_FRAME_EDGE]);

        if (middle != -1) {
            surface_draw_line_horizontal(mud->surface, x + BAR_FRAME_EDGE,
                                         y + row, width - BAR_FRAME_EDGE * 2,
                                         middle);
        }
    }
}

/* one of RSCPlus's bars: a dark fill, the value's share in colour (flashing
 * when low), the frame, then the value as text */
static void draw_docked_bar(mudclient *mud, int x, int y, int width,
                            int colour, int is_low, int current, int max) {
    if (max <= 0) {
        return;
    }

    int fill_width = width - 2;
    int filled = current >= max ? fill_width : current * fill_width / max;

    if (filled < 0) {
        filled = 0;
    }

    surface_draw_box(mud->surface, x + 1, y, fill_width, BAR_FRAME_HEIGHT,
                     0x0f0f0f);

    int alpha = 256;

    if (is_low) {
        /* RSCPlus's pulse: between a quarter and fully opaque */
        float wave = (sinf(get_ticks() / 100.0f) + 1.0f) / 2.0f;
        alpha = (int)((0.25f + wave * 0.75f) * 256);
        colour = 0xff0000;
    }

    if (filled > 0) {
        surface_draw_box_alpha(mud->surface, x + 1, y, filled,
                               BAR_FRAME_HEIGHT, colour, alpha);
    }

    draw_bar_frame(mud, x, y, width);

    char value[24] = {0};
    snprintf(value, sizeof(value), "%d/%d", current, max);

    surface_draw_string_centre(mud->surface, value, x + width / 2, y + 12,
                               FONT_REGULAR_11, 0xf0f0f0);
}

/* RSCPlus's long and short bars; ours are squeezed anywhere between them to
 * fit the room along the bottom */
#define BAR_WIDTH_MAX 90
#define BAR_WIDTH_MIN 60
#define BAR_PADDING 4

/* the lowest the bars go, clear of the very edge */
#define BAR_INSET_MIN 2

/* how far a screen corner of the given radius cuts in, d pixels above the
 * bottom */
static int corner_cut(int radius, int d) {
    if (d >= radius) {
        return 0;
    }

    float r = (float)radius;
    float rest = r - (float)d;

    return (int)ceilf(r - sqrtf(r * r - rest * rest));
}

/* the room for the bars along the bottom, d pixels up, inside the rounded
 * corners and the safe insets on the sides */
static void docked_bar_span(mudclient *mud, int d, int *start, int *end) {
    int cut = corner_cut(MUD_SCREEN_CORNER_RADIUS, d) + 1;
    int margin = cut > 4 ? cut : 4;

    *start = MUD_SAFE_LEFT > margin ? MUD_SAFE_LEFT : margin;
    *end = mud->surface->width -
           (MUD_SAFE_RIGHT > margin ? MUD_SAFE_RIGHT : margin);
}

/* the widest bars that fit count of them in the room, squeezed as far as
 * the short ones */
static int docked_bar_width(int count, int room) {
    int width = (room - (count - 1) * BAR_PADDING) / count;

    if (width > BAR_WIDTH_MAX) {
        return BAR_WIDTH_MAX;
    }

    return width < BAR_WIDTH_MIN ? BAR_WIDTH_MIN : width;
}

/*
 * how far above the bottom of the screen the blue bar and status bars go.
 * they can't be tapped, so they needn't keep out of the home indicator's
 * area like the controls: they go as low as the most squeezed row (three
 * short bars) fits inside the screen's rounded corners
 */
int mudclient_bottom_bar_inset(mudclient *mud) {
    int inset = MUD_SAFE_BOTTOM;

    if (inset == 0 || MUD_SCREEN_CORNER_RADIUS == 0) {
        return inset;
    }

    int narrowest = 3 * BAR_WIDTH_MIN + 2 * BAR_PADDING;

    for (int d = BAR_INSET_MIN; d < inset; d++) {
        int start = 0;
        int end = 0;
        docked_bar_span(mud, d, &start, &end);

        if (end - start >= narrowest) {
            return d;
        }
    }

    return inset;
}

/* hits, prayer and fatigue like RSCPlus shows them: framed bars of just the
 * numbers, here centred on the blue bar along the bottom. the opponent's
 * hits aren't shown, so the row doesn't change when a fight starts */
static void draw_docked_status_bars(mudclient *mud) {
    /* the 2001 game has no prayer points or fatigue */
    int is_retro = mudclient_is_retro(mud);

    int show_fatigue =
        !mud->is_sleeping && mud->options->fatigue && !is_retro;

    int show_prayer = !is_retro;

    int count = 1 + show_prayer + show_fatigue;

    /* level with the bottom of the blue bar (message-tabs.c) */
    int inset = mudclient_bottom_bar_inset(mud);
    int y = mud->surface->height - inset - BAR_FRAME_HEIGHT;

    int start = 0;
    int end = 0;
    docked_bar_span(mud, inset, &start, &end);

    int bar_width = docked_bar_width(count, end - start);
    int padding = BAR_PADDING;

    int total = count * bar_width + (count - 1) * padding;
    int x = start + (end - start - total) / 2;

    int hits = mud->player_skill_current[SKILL_HITS];
    int max_hits = mud->player_skill_base[SKILL_HITS];
    int prayer = mud->player_skill_current[SKILL_PRAYER];
    int max_prayer = mud->player_skill_base[SKILL_PRAYER];

    /* RSCPlus flashes under 30% hits or prayer, and from 80% fatigue */
    draw_docked_bar(mud, x, y, bar_width, 0x00d200,
                    max_hits > 0 && hits * 100 / max_hits < 30, hits,
                    max_hits);

    x += bar_width + padding;

    if (show_prayer) {
        draw_docked_bar(mud, x, y, bar_width, 0xa0a0d2,
                        max_prayer > 0 && prayer * 100 / max_prayer < 30,
                        prayer, max_prayer);

        x += bar_width + padding;
    }

    if (show_fatigue) {
        int fatigue = mud->stat_fatigue * 100 / 750;

        draw_docked_bar(mud, x, y, bar_width, 0xd2d200, fatigue >= 80,
                        fatigue, 100);
    }
}

void mudclient_draw_status_bars(mudclient *mud) {
    if (mudclient_is_touch(mud)) {
        draw_docked_status_bars(mud);

        /* drained and boosted skills go under the combat style box (where
         * it's drawn, whether or not it is now), and the options when
         * talking to someone */
        int y = mudclient_combat_style_bottom(mud) + 14;

        if (mud->show_option_menu) {
            /* where mudclient_draw_option_menu puts it */
            int menu_y = mudclient_is_combat_style_shown(mud)
                             ? mudclient_combat_style_bottom(mud) + 4
                             : 136 + MUD_SAFE_TOP;
            int menu_bottom = menu_y + mud->option_menu_count * 24 + 16;

            if (menu_bottom > y) {
                y = menu_bottom;
            }
        }

        /* and under the bank */
        if (mud->dialog_bottom + 16 > y) {
            y = mud->dialog_bottom + 16;
        }

        draw_skill_effects(mud, 86 + MUD_SAFE_LEFT, y);
        return;
    }

    // TODO make that 390 a constant since we're using it more than once
    // (surface_draw_status_bar, combat style somewhere)
    int is_compact = mud->surface->width < 390;

    int is_touch = mudclient_is_touch(mud);

    // TODO maybe make COMBAT_BUTTON_HEIGHT_COMPACT etc.
    int combat_button_height = is_compact ? 22 : 20;

    int status_bar_width = 175 / 2 - 1;

    if (is_touch) {
        status_bar_width = (mud->surface->width * 0.353f) / 2 - 6;
    } else if (is_compact) {
        status_bar_width = 106 / 2 - 1;
    }

    int status_bar_height = is_touch ? 13 : 16;

    int ui_x = is_touch ? 4 : 7;

    int ui_y = is_touch ? mud->surface->height - status_bar_height
                        : 15 + (combat_button_height * 5) + 6;

    int x = ui_x;
    int y = ui_y;

    int max_hits = mud->player_skill_base[SKILL_HITS];
    int current_hits = mud->player_skill_current[SKILL_HITS];

    surface_draw_status_bar(mud->surface, max_hits, current_hits, "Hits", x, y,
                            status_bar_width, status_bar_height, RED, GREEN, 0);

    GameCharacter *opponent = mudclient_get_opponent(mud);

    int show_opponent_health = opponent != NULL && opponent->max_hits != 0;

    if (!is_touch && status_bar_width >= (mud->surface->width / 6) &&
        !show_opponent_health) {
        y += status_bar_height + 5;
    } else {
        x += status_bar_width + (is_touch ? 4 : 3);
    }

    int is_retro = mudclient_is_retro(mud);

    /* the 2001 game has no prayer points */
    if (!is_retro) {
        int max_prayer = mud->player_skill_base[SKILL_PRAYER];
        int current_prayer = mud->player_skill_current[SKILL_PRAYER];

        surface_draw_status_bar(mud->surface, max_prayer, current_prayer,
                                "Prayer", x, y, status_bar_width,
                                status_bar_height, BLACK, CYAN, 0);
    }

    if (is_touch) {
        x += status_bar_width + mud->surface->width * 0.293f + 9;
    }

    if (show_opponent_health) {
        if (is_touch) {
            y = ui_y;
        } else {
            x = ui_x;
            y += status_bar_height + 5;
        }

        char *opponent_name = "";

        if (opponent->npc_id != -1) {
            opponent_name = game_data.npcs[opponent->npc_id].name;
        } else {
            opponent_name = opponent->name;
        }

        char formatted_opponent[strlen(opponent_name) + 2];
        sprintf(formatted_opponent, "%s:", opponent_name);

        surface_draw_status_bar(mud->surface, opponent->max_hits,
                                opponent->current_hits, opponent_name, x, y,
                                is_touch ? status_bar_width
                                         : (status_bar_width * 2) + 3,
                                status_bar_height, RED, GREEN, 0);

        if (is_touch) {
            x += status_bar_width + 4;
        }
    }

    if (!mud->is_sleeping && mud->options->fatigue && !is_retro) {
        if (is_touch) {
            y = ui_y;
        } else {
            x = ui_x;
            y += status_bar_height + 5;
        }

        int width;

        if (status_bar_width >= (mud->surface->width / 6) &&
            !show_opponent_health) {
            width = status_bar_width;
        } else {
            width = status_bar_width * 2 + 3;
        }

        if (is_touch) {
            if (show_opponent_health) {
                width = status_bar_width;
            } else {
                width = status_bar_width * 1.75f;
                x += (mud->surface->width * 0.353f / 2) - (width / 2) - 3;
            }
        }

        surface_draw_status_bar(mud->surface, 750, mud->stat_fatigue, "Fatigue",
                                x, y, width, status_bar_height, BLACK, 0xe2e2e2,
                                1);
    }

    draw_skill_effects(mud, mud->surface->width - 2, 48);
}

static void draw_skill_effects(mudclient *mud, int x, int y) {
    /* Display drained / boosted skills */
    int is_retro = mudclient_is_retro(mud);

    for (int i = 0; i < mudclient_skill_count(mud); ++i) {
        if ((i == SKILL_PRAYER && !is_retro) || i == SKILL_HITS) {
            continue;
        }

        if (mud->player_skill_base[i] == 0) {
            continue;
        }

        if (mud->player_skill_current[i] == mud->player_skill_base[i]) {
            continue;
        }

        const char *colour = "";

        float p =
            mud->player_skill_current[i] / (float)mud->player_skill_base[i];

        if (p >= 1.15f) { /* super potion */
            colour = "@gre@";
        } else if (p >= 1.1f) { /* normal potion */
            colour = "@gr3@";
        } else if (p >= 1.05f) { /* cocktails */
            colour = "@gr2@";
        } else if (p >= 1.0f) {
            colour = "@gr1@";
        } else if (p <= 0.9f) { /* enfeeble */
            colour = "@red@";
        } else if (p <= 0.95f) {
            colour = "@or3@";
        } else if (p <= 0.975f) {
            colour = "@or2@";
        } else {
            colour = "@or1@";
        }

        char formatted_effect[32] = {0};

        snprintf(formatted_effect, sizeof(formatted_effect), "%s%s: %d/%d",
                 colour, mudclient_skill_name(mud, i),
                 mud->player_skill_current[i],
                 mud->player_skill_base[i]);

        surface_draw_string_right(mud->surface, formatted_effect, x, y,
                                  FONT_REGULAR_11, WHITE);

        y += 14;
    }
}

#include "stats-tab.h"

const char *short_skill_names[] = {
    "Attack",   "Defense",  "Strength", "Hits",      "Ranged",  "Prayer",
    "Magic",    "Cooking",  "Woodcut",  "Fletching", "Fishing", "Firemaking",
    "Crafting", "Smithing", "Mining",   "Herblaw",   "Agility", "Thieving"};

const char *skill_names[] = {
    "Attack",   "Defense",  "Strength",    "Hits",      "Ranged",  "Prayer",
    "Magic",    "Cooking",  "Woodcutting", "Fletching", "Fishing", "Firemaking",
    "Crafting", "Smithing", "Mining",      "Herblaw",   "Agility", "Thieving"};

int skills_length;

/* the May 2001 game's skills, in the order its server sends them */
static const char *retro_skill_names[] = {
    "Attack",      "Defense",    "Strength",  "Hits",      "Ranged",
    "Thieving",    "Influence",  "PrayGood",  "PrayEvil",  "GoodMagic",
    "EvilMagic",   "Cooking",    "Tailoring", "Woodcutting",
    "Firemaking",  "Crafting",   "Smithing",  "Mining",    "Herblaw"};

/* hiding is only in the 2001 game */
static const char *equipment_stat_names[] = {
    "Armour", "WeaponAim", "WeaponPower", "Magic", "Prayer", "Hiding"};

const char *mudclient_skill_name(mudclient *mud, int skill) {
    if (mudclient_is_retro(mud)) {
        return skill >= 0 && skill < RETRO_SKILL_COUNT
                   ? retro_skill_names[skill]
                   : "";
    }

    return skill >= 0 && skill < skills_length ? skill_names[skill] : "";
}

int mudclient_skill_count(mudclient *mud) {
    return mudclient_is_retro(mud) ? RETRO_SKILL_COUNT : skills_length;
}

static int experience_array[100];

static const char *free_quests[] = {
    "Black knight's fortress", "Cook's assistant",   "Demon slayer",
    "Doric's quest",           "The restless ghost", "Goblin diplomacy",
    "Ernest the chicken",      "Imp catcher",        "Pirate's treasure",
    "Prince Ali rescue",       "Romeo & Juliet",     "Sheep shearer",
    "Shield of Arrav",         "The knight's sword", "Vampire slayer",
    "Witch's potion",          "Dragon slayer"};

static const char *members_quests[] = {
    "Witch's house",    "Lost city",         "Hero's quest",
    "Druidic ritual",   "Merlin's crystal",  "Scorpion catcher",
    "Family crest",     "Tribal totem",      "Fishing contest",
    "Monk's friend",    "Temple of Ikov",    "Clock tower",
    "The Holy Grail",   "Fight Arena",       "Tree Gnome Village",
    "The Hazeel Cult",  "Sheep Herder",      "Plague City",
    "Sea Slug",         "Waterfall quest",   "Biohazard",
    "Jungle potion",    "Grand tree",        "Shilo village",
    "Underground pass", "Observatory quest", "Tourist trap",
    "Watchtower",       "Dwarf Cannon",      "Murder Mystery",
    "Digsite",          "Gertrude's Cat",    "Legend's Quest"};

char **quest_names;
int quests_length = 0;

void init_stats_tab_global(void) {
    skills_length = sizeof(skill_names) / sizeof(skill_names[0]);

    int total_exp = 0;

    for (int i = 0; i < 99; i++) {
        int level = i + 1;
        int exp = level + 300 * pow(2, (float)level / 7);
        total_exp += exp;
        experience_array[i] = total_exp & 0xffffffc;
    }

    int free_quests_length = sizeof(free_quests) / sizeof(free_quests[0]);

    int members_quests_length =
        sizeof(members_quests) / sizeof(members_quests[0]);

    quests_length = free_quests_length + members_quests_length;
    quest_names = malloc(sizeof(char *) * quests_length);

    for (int i = 0; i < free_quests_length; i++) {
        quest_names[i] = malloc(strlen(free_quests[i]) + 1);
        strcpy(quest_names[i], free_quests[i]);
    }

    for (int i = 0; i < members_quests_length; i++) {
        quest_names[free_quests_length + i] =
            malloc(strlen(members_quests[i]) + 11);

        sprintf(quest_names[free_quests_length + i], "%s (members)",
                members_quests[i]);
    }
}

void mudclient_draw_equipment_status(mudclient *mud, int x, int y,
                                     int line_break, int no_menus) {
    if (no_menus && mud->selected_wiki && mud->mouse_x > x + 5 &&
        mud->mouse_y > y - line_break &&
        mud->mouse_y < y + (line_break / 2) - 4) {
        mudclient_menu_add_wiki(mud, "Equipment Status", "Equipment");
    }

    surface_draw_string(mud->surface, "Equipment Status", x + 5, y,
                        FONT_BOLD_13, YELLOW);

    y += line_break;

    int is_retro = mudclient_is_retro(mud);

    for (int i = 0; i < 3; i++) {
        if (no_menus && mud->selected_wiki && mud->mouse_x > x + 5 &&
            mud->mouse_x < x + (STATS_WIDTH / 2) + 25 &&
            mud->mouse_y > y - line_break && mud->mouse_y < y + 3) {
            mudclient_menu_add_wiki(mud, equipment_stat_names[i],
                                    equipment_stat_names[i]);
        }

        /* longest stat name (11) + 5 + 11 */
        char formatted_stat[28] = {0};

        sprintf(formatted_stat, "%s:@yel@%d", equipment_stat_names[i],
                mud->player_stat_equipment[i]);

        surface_draw_string(mud->surface, formatted_stat, x + 5, y,
                            FONT_BOLD_12, WHITE);

        if (i < 2 || is_retro) {
            if (no_menus && mud->selected_wiki &&
                mud->mouse_x > x + (STATS_WIDTH / 2) + 25 &&
                mud->mouse_y > y - line_break && mud->mouse_y < y + 3) {
                mudclient_menu_add_wiki(mud, equipment_stat_names[i + 3],
                                        equipment_stat_names[i + 3]);
            }

            sprintf(formatted_stat, "%s:@yel@%d", equipment_stat_names[i + 3],
                    mud->player_stat_equipment[i + 3]);

            surface_draw_string(mud->surface, formatted_stat,
                                x + (STATS_WIDTH / 2) + 25, y, FONT_BOLD_12,
                                WHITE);
        }

        y += line_break + 1;
    }
}

void mudclient_draw_ui_tab_stats(mudclient *mud, int no_menus) {
    /* wider on the watch, filling the space (ui-tabs.c) */
    int panel_width = STATS_WIDTH;

    int ui_x = mud->surface->width - panel_width - 3;
    int ui_y = UI_BUTTON_SIZE + 1;

    int height = STATS_HEIGHT;

    int is_touch = mudclient_is_touch(mud);

    /* the watch has room for the full list, as on desktop (ui-tabs.c) */
    int is_watch_area = mudclient_ui_tab_is_watch_area(mud);

    int is_compact =
        !is_watch_area &&
        (is_touch || mud->surface->height < (height + 12) + ui_y);

    /* the 2001 game has no quest list (influence instead of quest points),
     * fatigue or experience */
    int is_retro = mudclient_is_retro(mud);
    int shows_fatigue = mud->options->fatigue && !is_retro;

    const char *stats_tabs[3];

    if (is_compact) {
        height = STATS_COMPACT_HEIGHT;

        stats_tabs[0] = "Skills";
        stats_tabs[1] = "Gear";
        stats_tabs[2] = "Quests";
    } else {
        stats_tabs[0] = "Skills";
        stats_tabs[1] = "Quests";
    }

    int tab_count = (is_compact ? 3 : 2) - is_retro;

    int line_break = (is_compact && !is_touch ? 11 : 12);

    if (!is_compact && !shows_fatigue) {
        height -= line_break;
    }

    if (mud->options->max_skills < 18 && !is_retro) {
        height -= line_break;
    }

    if (!is_retro && (mud->options->total_experience ||
                      mud->options->remaining_experience)) {
        height += line_break;
    }

    /* equipment screen */
    if (is_compact && mud->ui_tab_stats_sub_tab == 1) {
        height = 78;
    }

    if (is_touch) {
        height = 198;
        ui_x = UI_TABS_TOUCH_X - panel_width - 1;
        ui_y = (UI_TABS_TOUCH_Y + UI_TABS_TOUCH_HEIGHT) - height - 2;
    }

    if (is_watch_area) {
        mudclient_ui_tab_watch_area(mud, &ui_x, &ui_y, &panel_width, &height);

        mud->panel_quests->control_width[mud->control_list_quest] =
            panel_width;

        mudclient_ui_tab_move_list(mud->panel_quests, mud->control_list_quest,
                                   ui_x, ui_y + STATS_TAB_HEIGHT);
    } else if (is_touch) {
        /* as made, in case the watch's panels were on before */
        mud->panel_quests->control_width[mud->control_list_quest] =
            STATS_WIDTH;

        mudclient_ui_tab_move_list(mud->panel_quests, mud->control_list_quest,
                                   ui_x, ui_y + STATS_TAB_HEIGHT);
    }

    mud->panel_quests->control_height[mud->control_list_quest] =
        height - STATS_TAB_HEIGHT;

    if (mud->options->version_media >= 59) {
            mudclient_draw_ui_tab_label(mud, STATS_TAB, panel_width + !is_touch,
                                        ui_x - !is_touch,
                                        ui_y - UI_TABS_LABEL_HEIGHT);
    }

    mud->ui_tab_min_x = ui_x;
    mud->ui_tab_max_x = mud->surface->width;
    mud->ui_tab_min_y = 0;
    mud->ui_tab_max_y = ui_y + height + 5;

    if (is_touch) {
        mud->ui_tab_max_x = ui_x + panel_width;
        mud->ui_tab_min_y = ui_y - UI_TABS_LABEL_HEIGHT;
        mud->ui_tab_max_y = ui_y + height;
    }

    surface_draw_box_alpha(mud->surface, ui_x, ui_y + STATS_TAB_HEIGHT,
                           panel_width, height - STATS_TAB_HEIGHT, GREY_DC,
                           128);

    surface_draw_line_horizontal(mud->surface, ui_x, ui_y + STATS_TAB_HEIGHT,
                                 panel_width, BLACK);

    surface_draw_tabs(mud->surface, ui_x, ui_y, panel_width, STATS_TAB_HEIGHT,
                      stats_tabs, tab_count, mud->ui_tab_stats_sub_tab);

    if (mud->ui_tab_stats_sub_tab >= tab_count) {
        mud->ui_tab_stats_sub_tab = tab_count - 1;
    }

    /* the handler for the skills/equipment tab */
    if (mud->ui_tab_stats_sub_tab == 0) {
        int y = ui_y + 36;
        int selected_skill = -1;
        int total_experience = 0;

        if (!is_compact) {
            surface_draw_string(mud->surface, "Skills", ui_x + 5, y,
                                FONT_BOLD_13, YELLOW);

            if (no_menus && mud->selected_wiki && mud->mouse_x > ui_x + 5 &&
                mud->mouse_x < ui_x + (panel_width / 2) - 8 &&
                mud->mouse_y > y - (line_break - 1) && mud->mouse_y < y + 2) {
                mudclient_menu_add_wiki(mud, "Skills", "Skills");
            }

            y += line_break + 1;
        }

        int skills_per_column;
        int second_column_indent;
        const char **display_skills;

        if (is_retro) {
            skills_per_column = 10;
            display_skills = retro_skill_names;
            second_column_indent = ui_x + (panel_width / 2) - 8;
        } else if (mud->options->max_skills < 18) {
            skills_per_column = 8;
            display_skills = skill_names;
            second_column_indent = ui_x + (panel_width / 2) - 7;
        } else {
            skills_per_column = 9;
            display_skills = short_skill_names;
            second_column_indent = ui_x + (panel_width / 2) - 5;
        }

        /* the 2001 game's 19 split 10 and 9: on the desktop the right column
         * starts a line up, so it gets the 10 (as the 2001 client had it) */
        int left_count = skills_per_column;
        int right_count = skills_per_column;

        if (is_retro) {
            left_count = is_compact ? 10 : 9;
            right_count = RETRO_SKILL_COUNT - left_count;
        }

        int rows = left_count > right_count ? left_count : right_count;

        /* draw two columns with each skill name and current/base levels */
        for (int i = 0; i < rows; i++) {
            /* longest skill name (11), @yel@ (5), two levels 3 each (6),
             * colon (1), slash (1) */
            char formatted_skill[25] = {0};

            /* left column */
            if (i < left_count) {
                int text_colour = WHITE;

                total_experience += mud->player_experience[i];

                if (no_menus && mud->mouse_x > ui_x + 3 &&
                    mud->mouse_y >= y - (line_break - 1) &&
                    mud->mouse_y < y + 2 &&
                    mud->mouse_x < ui_x + (panel_width / 2) - 8) {
                    text_colour = RED;
                    selected_skill = i;
                }

                sprintf(formatted_skill, "%s:@yel@%d/%d", display_skills[i],
                        mud->player_skill_current[i],
                        mud->player_skill_base[i]);

                surface_draw_string(mud->surface, formatted_skill, ui_x + 5,
                                    y, FONT_BOLD_12, text_colour);
            }

            /* right column */
            if (i < right_count) {
                int skill = i + left_count;
                int text_colour = WHITE;

                total_experience += mud->player_experience[skill];

                /* where the right column starts, moved over on the wider
                 * watch */
                if (no_menus &&
                    mud->mouse_x >=
                        ui_x + 90 + (panel_width - STATS_WIDTH) / 2 &&
                    mud->mouse_y >= y - (line_break * (is_compact ? 1 : 2)) &&
                    mud->mouse_y < y - (is_compact ? 0 : (line_break - 1)) &&
                    mud->mouse_x < ui_x + panel_width) {
                    text_colour = RED;
                    selected_skill = skill;
                }

                sprintf(formatted_skill, "%s:@yel@%d/%d",
                        display_skills[skill],
                        mud->player_skill_current[skill],
                        mud->player_skill_base[skill]);

                surface_draw_string(mud->surface, formatted_skill,
                                    second_column_indent,
                                    y - (is_compact ? 0 : line_break + 1),
                                    FONT_BOLD_12, text_colour);
            }

            /* the desktop's right column is a line up, so its extra row (the
             * 2001 game's tenth) sits beside the last on the left */
            if (i < left_count) {
                y += line_break + 1;
            }
        }

        /* the quest points and fatigue line, which the 2001 game's tenth
         * row of skills takes */
        if (is_compact && !is_retro) {
            y += line_break + 1;
        }

        if (!is_retro && no_menus && mud->selected_wiki &&
            mud->mouse_x > second_column_indent &&
            mud->mouse_y > y - (line_break * 2) &&
            mud->mouse_y < y - (line_break - 1)) {
            mudclient_menu_add_wiki(mud, "Quest Points", "Quest Points");
        }

        if (!is_retro) {
            char formatted_quest_points[30] = {0};

            sprintf(formatted_quest_points, "Quest Points:@yel@%d",
                    mud->player_quest_points);

            surface_draw_string(mud->surface, formatted_quest_points,
                                second_column_indent, y - 13, FONT_BOLD_12,
                                WHITE);
        }

        if (!is_compact) {
            y += line_break;
        }

        if (shows_fatigue) {
            char formatted_fatigue[27] = {0};

            if (no_menus && mud->selected_wiki && mud->mouse_x > ui_x + 5 &&
                mud->mouse_x < ui_x + (panel_width / 2) - 5 &&
                mud->mouse_y > y - (line_break * 2) &&
                mud->mouse_y < y - (line_break - 1)) {
                mudclient_menu_add_wiki(mud, "Fatigue", "Fatigue");
            }

            sprintf(formatted_fatigue, "Fatigue: @yel@%d%%",
                    (mud->stat_fatigue * 100) / 750);

            surface_draw_string(mud->surface, formatted_fatigue, ui_x + 5, y - 13,
                                FONT_BOLD_12, WHITE);

            y += is_compact ? 2 : 8;
        }

        if (!is_compact) {
            mudclient_draw_equipment_status(mud, ui_x, y, line_break, no_menus);

            y += 51;
            y += line_break / 2;
        }

        if (is_touch) {
            y += 2;
        }

        surface_draw_line_horizontal(
            mud->surface, ui_x, y - (is_compact ? 12 : 15), panel_width, BLACK);

        char formatted_number[15] = {0};

        int wiki_height = line_break * 2;

        if (mud->options->total_experience) {
            wiki_height += line_break;
        }

        if (selected_skill != -1 && is_retro) {
            /* the 2001 server sends no experience */
            if (no_menus && mud->selected_wiki) {
                mudclient_menu_add_wiki(mud, retro_skill_names[selected_skill],
                                        retro_skill_names[selected_skill]);
            }

            selected_skill = -1;
        }

        if (selected_skill != -1) {
            if (!is_compact) {
                /* longest skill (11) + 6 + 1 */
                char formatted_skill[18] = {0};
                sprintf(formatted_skill, "%s skill",
                        skill_names[selected_skill]);

                surface_draw_string(mud->surface, formatted_skill, ui_x + 5, y,
                                    FONT_BOLD_12, YELLOW);

                y += line_break;
            }

            int next_level_at = experience_array[0];

            for (int j = 0; j < 98; j++) {
                if (mud->player_experience[selected_skill] >=
                    experience_array[j]) {
                    next_level_at = experience_array[j + 1];
                }
            }

            int total_xp = mud->player_experience[selected_skill];

            mudclient_format_number_commas(mud, total_xp / 4, formatted_number);

            char formatted_xp[25] = {0};
            sprintf(formatted_xp, "Total xp: %s", formatted_number);

            surface_draw_string(mud->surface, formatted_xp, ui_x + 5, y,
                                FONT_BOLD_12, WHITE);

            y += line_break;

            mudclient_format_number_commas(mud, next_level_at / 4,
                                           formatted_number);

            char formatted_next[30] = {0};
            sprintf(formatted_next, "Next level at: %s", formatted_number);

            surface_draw_string(mud->surface, formatted_next, ui_x + 5, y,
                                FONT_BOLD_12, WHITE);

            if (mud->options->remaining_experience) {
                y += line_break;

                int remaining_xp = (next_level_at - total_xp);

                mudclient_format_number_commas(mud, remaining_xp / 4,
                                               formatted_number);

                char formatted_remainder[5] = {0};
                sprintf(formatted_remainder, "%.2f", (remaining_xp % 4) / 4.0f);

                sprintf(formatted_next, "Remaining xp: %s%s", formatted_number,
                        formatted_remainder + 1);

                surface_draw_string(mud->surface, formatted_next, ui_x + 5, y,
                                    FONT_BOLD_12, WHITE);
            }

            if (no_menus && mud->selected_wiki) {
                const char *skill_name = skill_names[selected_skill];
                mudclient_menu_add_wiki(mud, skill_name, skill_name);
            }
        } else {
            if (no_menus && mud->selected_wiki && mud->mouse_x > ui_x + 5 &&
                mud->mouse_y > y - line_break &&
                mud->mouse_y < y - line_break + wiki_height + 3) {
                mudclient_menu_add_wiki(mud, "Experience", "Experience");
            }

            if (!is_compact) {
                surface_draw_string(mud->surface, "Overall levels", ui_x + 5, y,
                                    FONT_BOLD_12, YELLOW);

                y += line_break;
            }

            int total_level = 0;

            for (int i = 0; i < mudclient_skill_count(mud); i++) {
                total_level += mud->player_skill_base[i];
            }

            mudclient_format_number_commas(mud, total_level, formatted_number);

            char formatted_total[28] = {0};
            sprintf(formatted_total, "Skill total: %s", formatted_number);

            surface_draw_string(mud->surface, formatted_total, ui_x + 5, y,
                                FONT_BOLD_12, WHITE);

            y += line_break;

            if (mud->options->total_experience && !is_retro) {
                mudclient_format_number_commas(mud, total_experience / 4,
                                               formatted_number);

                sprintf(formatted_total, "Total xp: %s", formatted_number);

                surface_draw_string(mud->surface, formatted_total, ui_x + 5, y,
                                    FONT_BOLD_12, WHITE);

                y += line_break;
            }

            if (no_menus && mud->selected_wiki && mud->mouse_x > ui_x &&
                mud->mouse_y > y - line_break && mud->mouse_y < y + 5) {
                mudclient_menu_add_wiki(mud, "Combat level", "Combat level");
            }

            char formatted_combat[25] = {0};

            sprintf(formatted_combat, "Combat level: %d",
                    mud->local_player->level);

            surface_draw_string(mud->surface, formatted_combat, ui_x + 5, y,
                                FONT_BOLD_12, WHITE);

            y += line_break;
        }
    } else if (!is_retro &&
               ((!is_compact && mud->ui_tab_stats_sub_tab == 1) ||
                (is_compact && mud->ui_tab_stats_sub_tab == 2))) {
        int stats_height = 36 + STATS_HEIGHT + 5;

        if (no_menus && mud->selected_wiki && mud->mouse_x > ui_x + 5 &&
            mud->mouse_y > ui_y + 24 + line_break &&
            mud->mouse_y < ui_y + stats_height) {
            int quest_index =
                mud->panel_quests
                    ->control_list_entry_mouse_over[mud->control_list_quest];

            if (quest_index > 0) {
                quest_index -= 1;

                char *quest_name = quest_names[quest_index];
                int quest_name_length = (int)strlen(quest_name);

                for (int i = 0; i < quest_name_length; i++) {
                    if (quest_name[i] == '(') {
                        quest_name_length = i - 1;
                        break;
                    }
                }

                char page_name[quest_name_length + 1];
                memset(page_name, '\0', quest_name_length + 1);
                strncpy(page_name, quest_name, quest_name_length);

                mudclient_menu_add_wiki(mud, quest_name, page_name);
            }
        }

        /* the handler for the quests tab */
        panel_clear_list(mud->panel_quests, mud->control_list_quest);

        panel_add_list_entry(mud->panel_quests, mud->control_list_quest, 0,
                             "@whi@Quest-list (green=completed)");

        for (int i = 0; i < mud->options->max_quests; i++) {
            char *quest_name = quest_names[i];
            char coloured_quest[strlen(quest_name) + 6];

            sprintf(coloured_quest, "%s%s",
                    mud->quest_complete[i] ? "@gre@" : "@red@", quest_name);

            panel_add_list_entry(mud->panel_quests, mud->control_list_quest,
                                 i + 1, coloured_quest);
        }

        panel_draw_panel(mud->panel_quests);
    } else if (is_compact && mud->ui_tab_stats_sub_tab == 1) {
        mudclient_draw_equipment_status(mud, ui_x, ui_y + 38, line_break,
                                        no_menus);
    }

    if (!no_menus) {
        return;
    }

    int mouse_x = mud->mouse_x - ui_x;
    int mouse_y = mud->mouse_y - ui_y;

    /* handle clicking of stats and quest tab, and the scroll wheel for the
     * quest list */
    int is_within_x = mud->options->off_handle_scroll_drag
                          ? 1
                          : mouse_x >= 0 && mouse_x < panel_width;

    if (is_within_x && mouse_y >= 0 && mouse_y < height) {
        int quest_tab = is_retro ? -1 : is_compact ? 2 : 1;

        if (mud->ui_tab_stats_sub_tab == quest_tab) {
            if (is_touch) {
                panel_handle_mouse(
                    mud->panel_quests, mudclient_finger_1_x,
                    mudclient_finger_1_y, mud->last_mouse_button_down,
                    mudclient_finger_1_down, mud->mouse_scroll_delta);
            } else {
                panel_handle_mouse(mud->panel_quests, mud->mouse_x,
                                   mud->mouse_y, mud->last_mouse_button_down,
                                   mud->mouse_button_down,
                                   mud->mouse_scroll_delta);
            }
        }

        if (mouse_y <= STATS_TAB_HEIGHT) {
            int total_tabs = tab_count;
            int selected_tab = mouse_x / (panel_width / total_tabs);

            if (selected_tab < 0 || selected_tab >= total_tabs) {
                return;
            }

            if (mud->selected_wiki) {
                const char *wiki_page = stats_tabs[selected_tab];

                if (is_compact && selected_tab == 1) {
                    wiki_page = "Equipment";
                }

                mudclient_menu_add_wiki(mud, stats_tabs[selected_tab],
                                        wiki_page);
            } else if (mud->mouse_button_click == 1) {
                mud->ui_tab_stats_sub_tab = selected_tab;
            }
        }
    }
}

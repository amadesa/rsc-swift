#include "appearance.h"

struct appearance_buttons {
    int left;
    int right;
};

static struct appearance_buttons
mudclient_create_appearance_box(mudclient *mud, char *type, int x, int y);

static struct appearance_buttons
mudclient_create_appearance_box(mudclient *mud, char *type, int x, int y) {
    int is_compact = mud->surface->width < MUD_VANILLA_WIDTH ||
                     mud->surface->height < MUD_VANILLA_HEIGHT;

    /* box around type text */
    int box_padding = (is_compact ? 5 : 8);
    int box_height = (box_padding + (is_compact ? 25 : 33));

    panel_add_box_rounded(mud->panel_appearance, x, y, APPEARANCE_BOX_WIDTH,
                          box_height);

    char type_copy[strlen(type) + 1];
    strcpy(type_copy, type);

    char *type_split = strtok(type_copy, "\n");

    char type_1[strlen(type_split) + 1];
    strcpy(type_1, type_split);

    type_split = strtok(NULL, "\n");

    if (type_split == NULL) {
        panel_add_text_centre(mud->panel_appearance, x, y, type_1, FONT_BOLD_12,
                              1);
    } else {
        panel_add_text_centre(mud->panel_appearance, x, y - box_padding, type_1,
                              FONT_BOLD_12, 1);

        char type_2[strlen(type_split) + 1];
        strcpy(type_2, type_split);

        panel_add_text_centre(mud->panel_appearance, x, y + box_padding, type_2,
                              FONT_BOLD_12, 1);
    }

    struct appearance_buttons buttons = {0};

    buttons.left =
        panel_add_button(mud->panel_appearance, x - 40, y,
                         APPEARANCE_ARROW_SIZE, APPEARANCE_ARROW_SIZE);

    panel_add_sprite(mud->panel_appearance, x - 40, y,
                     panel_base_sprite_start + 7);

    buttons.right =
        panel_add_button(mud->panel_appearance, x + 40, y,
                         APPEARANCE_ARROW_SIZE, APPEARANCE_ARROW_SIZE);

    panel_add_sprite(mud->panel_appearance, x + 40, y,
                     panel_base_sprite_start + 6);

    return buttons;
}

void mudclient_create_appearance_panel(mudclient *mud) {
    mud->panel_appearance = malloc(sizeof(Panel));
    panel_new(mud->panel_appearance, mud->surface, 100);

    int is_compact = mud->surface->width < MUD_VANILLA_WIDTH ||
                     mud->surface->height < MUD_VANILLA_HEIGHT;

    int x = (is_compact ? MUD_MIN_WIDTH : MUD_VANILLA_WIDTH) / 2;
    int y = 10;

    if (!is_compact) {
        panel_add_text_centre(mud->panel_appearance, x, y,
                              "Please design Your Character", FONT_BOLD_14, 1);

        y += 14;

        panel_add_text_centre(mud->panel_appearance, x - 55, y + 110, "Front",
                              FONT_BOLD_13, 1);

        panel_add_text_centre(mud->panel_appearance, x, y + 110, "Side",
                              FONT_BOLD_13, 1);

        panel_add_text_centre(mud->panel_appearance, x + 55, y + 110, "Back",
                              FONT_BOLD_13, 1);

        y += 145;
    } else {
        y += 102;
    }

    /* box around type text */
    int box_padding = (is_compact ? 5 : 8);
    int box_height = (box_padding + (is_compact ? 25 : 33));
    int box_margin = (box_height + (is_compact ? 3 : 9));

    struct appearance_buttons head_buttons = mudclient_create_appearance_box(
        mud, "Head\nType", x - APPEARANCE_COLUMN_WIDTH, y);

    mud->control_appearance_head_left = head_buttons.left;
    mud->control_appearance_head_right = head_buttons.right;

    struct appearance_buttons hair_buttons = mudclient_create_appearance_box(
        mud, "Hair\nColor", x + APPEARANCE_COLUMN_WIDTH, y);

    mud->control_appearance_hair_left = hair_buttons.left;
    mud->control_appearance_hair_right = hair_buttons.right;

    y += box_margin;

    struct appearance_buttons gender_buttons = mudclient_create_appearance_box(
        mud, "Gender", x - APPEARANCE_COLUMN_WIDTH, y);

    mud->control_appearance_gender_left = gender_buttons.left;
    mud->control_appearance_gender_right = gender_buttons.right;

    struct appearance_buttons top_buttons = mudclient_create_appearance_box(
        mud, "Top\nColor", x + APPEARANCE_COLUMN_WIDTH, y);

    mud->control_appearance_top_left = top_buttons.left;
    mud->control_appearance_top_right = top_buttons.right;

    y += box_margin;

    struct appearance_buttons skin_buttons = mudclient_create_appearance_box(
        mud, "Skin\nColor", x - APPEARANCE_COLUMN_WIDTH, y);

    mud->control_appearance_skin_left = skin_buttons.left;
    mud->control_appearance_skin_right = skin_buttons.right;

    struct appearance_buttons bottom_buttons = mudclient_create_appearance_box(
        mud, "Bottom\nColor", x + APPEARANCE_COLUMN_WIDTH, y);

    mud->control_appearance_bottom_left = bottom_buttons.left;
    mud->control_appearance_bottom_right = bottom_buttons.right;

    y += box_margin - (is_compact ? -1 : 3);

    panel_add_button_background(mud->panel_appearance, x, y,
                                APPEARANCE_ACCEPT_WIDTH,
                                APPEARANCE_ACCEPT_HEIGHT);

    panel_add_text_centre(mud->panel_appearance, x, y, "Accept", 4, 0);

    mud->control_appearance_accept =
        panel_add_button(mud->panel_appearance, x, y, APPEARANCE_ACCEPT_WIDTH,
                         APPEARANCE_ACCEPT_HEIGHT);

    mudclient_create_appearance_retro_panel(mud);
}

static const char *retro_classes[] = {"Adventurer", "Warrior", "Wizard",
                                      "Necromancer", "Ranger"};

static const char *retro_pk_modes[] = {"No thanks", "Yes I'll fight"};

#define RETRO_CLASS_COUNT 5

/* a choice between arrows, like the appearance boxes but wider */
static void create_retro_choice(mudclient *mud, int x, int y, int *left,
                                int *text, int *right) {
    Panel *panel = mud->panel_appearance_retro;

    panel_add_box_rounded(panel, x, y, APPEARANCE_RETRO_CHOICE_WIDTH, 26);
    *text = panel_add_text_centre(panel, x, y, "", FONT_BOLD_13, 1);

    int arrow_x = APPEARANCE_RETRO_CHOICE_WIDTH / 2 + 20;

    *left = panel_add_button(panel, x - arrow_x, y, APPEARANCE_ARROW_SIZE,
                             APPEARANCE_ARROW_SIZE);
    panel_add_sprite(panel, x - arrow_x, y, panel_base_sprite_start + 7);

    *right = panel_add_button(panel, x + arrow_x, y, APPEARANCE_ARROW_SIZE,
                              APPEARANCE_ARROW_SIZE);
    panel_add_sprite(panel, x + arrow_x, y, panel_base_sprite_start + 6);
}

/* the words are the 2001 client's */
void mudclient_create_appearance_retro_panel(mudclient *mud) {
    mud->panel_appearance_retro = malloc(sizeof(Panel));
    panel_new(mud->panel_appearance_retro, mud->surface, 40);

    Panel *panel = mud->panel_appearance_retro;

    int is_compact = mud->surface->width < MUD_VANILLA_WIDTH ||
                     mud->surface->height < MUD_VANILLA_HEIGHT;

    int x = (is_compact ? MUD_MIN_WIDTH : MUD_VANILLA_WIDTH) / 2;
    int y = is_compact ? 10 : 24;
    int line = is_compact ? 12 : 13;

    panel_add_text_centre(panel, x, y, "Character Type", FONT_BOLD_14, 1);
    y += is_compact ? 16 : 22;

    panel_add_text_centre(panel, x, y,
                          "Each character type has different starting",
                          FONT_REGULAR_11, 1);
    y += line;
    panel_add_text_centre(panel, x, y, "bonuses. But the choice you make here",
                          FONT_REGULAR_11, 1);
    y += line;
    panel_add_text_centre(panel, x, y,
                          "isn't permanent, and will change depending",
                          FONT_REGULAR_11, 1);
    y += line;
    panel_add_text_centre(panel, x, y, "on how you play the game.",
                          FONT_REGULAR_11, 1);
    y += is_compact ? 22 : 32;

    create_retro_choice(mud, x, y, &mud->control_appearance_class_left,
                        &mud->control_appearance_class_text,
                        &mud->control_appearance_class_right);
    y += is_compact ? 28 : 42;

    panel_add_text_centre(panel, x, y,
                          "Do you wish to be able to fight with other",
                          FONT_REGULAR_11, 1);
    y += line;
    panel_add_text_centre(panel, x, y,
                          "players? Warning! If you choose 'yes' then",
                          FONT_REGULAR_11, 1);
    y += line;
    panel_add_text_centre(panel, x, y,
                          "other players will be able to attack you too!",
                          FONT_REGULAR_11, 1);
    y += is_compact ? 22 : 32;

    create_retro_choice(mud, x, y, &mud->control_appearance_pk_left,
                        &mud->control_appearance_pk_text,
                        &mud->control_appearance_pk_right);
    y += is_compact ? 32 : 50;

    /* back to the looks, and start */
    int back_width = 70;
    int start_width = APPEARANCE_RETRO_CHOICE_WIDTH;
    int gap = 8;
    int total = back_width + gap + start_width;
    int back_x = x - total / 2 + back_width / 2;
    int start_x = x + total / 2 - start_width / 2;
    int button_height = is_compact ? 26 : APPEARANCE_ACCEPT_HEIGHT;

    panel_add_button_background(panel, back_x, y, back_width, button_height);
    panel_add_text_centre(panel, back_x, y, "Back", 4, 0);
    mud->control_appearance_back =
        panel_add_button(panel, back_x, y, back_width, button_height);

    panel_add_button_background(panel, start_x, y, start_width,
                                button_height);
    panel_add_text_centre(panel, start_x, y, "Start Game", 4, 0);
    mud->control_appearance_start =
        panel_add_button(panel, start_x, y, start_width, button_height);

    panel_update_text(panel, mud->control_appearance_class_text,
                      (char *)retro_classes[mud->appearance_class]);
    panel_update_text(panel, mud->control_appearance_pk_text,
                      (char *)retro_pk_modes[mud->appearance_pk_mode]);
}

static void send_appearance(mudclient *mud) {
    packet_stream_new_packet(mud->packet_stream, CLIENT_APPEARANCE);
    packet_stream_put_byte(mud->packet_stream, mud->appearance_head_gender);
    packet_stream_put_byte(mud->packet_stream, mud->appearance_head_type);
    packet_stream_put_byte(mud->packet_stream, mud->appearance_body_type);
    packet_stream_put_byte(mud->packet_stream, 2);
    packet_stream_put_byte(mud->packet_stream, mud->appearance_hair_colour);
    packet_stream_put_byte(mud->packet_stream, mud->appearance_top_colour);
    packet_stream_put_byte(mud->packet_stream, mud->appearance_bottom_colour);
    packet_stream_put_byte(mud->packet_stream, mud->appearance_skin_colour);

    /* the 2001 game's class and pk mode (see retro-packets.c) */
    if (mudclient_is_retro(mud)) {
        packet_stream_put_byte(mud->packet_stream, mud->appearance_class);
        packet_stream_put_byte(mud->packet_stream, mud->appearance_pk_mode);
    }

    packet_stream_send_packet(mud->packet_stream);

    surface_black_screen(mud->surface);
    mud->show_appearance_change = 0;
    mud->appearance_retro_page = 0;
}

static void handle_appearance_retro_input(mudclient *mud) {
    Panel *panel = mud->panel_appearance_retro;

    panel_handle_mouse(panel, mud->mouse_x, mud->mouse_y,
                       mud->last_mouse_button_down, mud->mouse_button_down,
                       mud->mouse_scroll_delta);

    if (panel_is_clicked(panel, mud->control_appearance_class_left)) {
        mud->appearance_class =
            (mud->appearance_class - 1 + RETRO_CLASS_COUNT) % RETRO_CLASS_COUNT;
    }

    if (panel_is_clicked(panel, mud->control_appearance_class_right)) {
        mud->appearance_class = (mud->appearance_class + 1) % RETRO_CLASS_COUNT;
    }

    if (panel_is_clicked(panel, mud->control_appearance_pk_left) ||
        panel_is_clicked(panel, mud->control_appearance_pk_right)) {
        mud->appearance_pk_mode = !mud->appearance_pk_mode;
    }

    panel_update_text(panel, mud->control_appearance_class_text,
                      (char *)retro_classes[mud->appearance_class]);
    panel_update_text(panel, mud->control_appearance_pk_text,
                      (char *)retro_pk_modes[mud->appearance_pk_mode]);

    if (panel_is_clicked(panel, mud->control_appearance_back)) {
        mud->appearance_retro_page = 0;
    }

    if (panel_is_clicked(panel, mud->control_appearance_start)) {
        send_appearance(mud);
    }
}

void mudclient_handle_appearance_panel_input(mudclient *mud) {
    if (mud->appearance_retro_page) {
        handle_appearance_retro_input(mud);
        return;
    }

    panel_handle_mouse(mud->panel_appearance, mud->mouse_x, mud->mouse_y,
                       mud->last_mouse_button_down, mud->mouse_button_down,
                       mud->mouse_scroll_delta);

    if (panel_is_clicked(mud->panel_appearance,
                         mud->control_appearance_head_left)) {
        do {
            mud->appearance_head_type =
                (mud->appearance_head_type - 1 + game_data.animation_count) %
                game_data.animation_count;
        } while ((game_data.animations[mud->appearance_head_type].gender & 3) !=
                     1 ||
                 (game_data.animations[mud->appearance_head_type].gender &
                  (4 * mud->appearance_head_gender)) == 0);
    }

    if (panel_is_clicked(mud->panel_appearance,
                         mud->control_appearance_head_right)) {
        do {
            mud->appearance_head_type =
                (mud->appearance_head_type + 1) % game_data.animation_count;
        } while ((game_data.animations[mud->appearance_head_type].gender & 3) !=
                     1 ||
                 (game_data.animations[mud->appearance_head_type].gender &
                  (4 * mud->appearance_head_gender)) == 0);
    }

    int hair_colours_length =
        sizeof(player_hair_colours) / sizeof(player_hair_colours[0]);

    if (panel_is_clicked(mud->panel_appearance,
                         mud->control_appearance_hair_left)) {
        mud->appearance_hair_colour =
            (mud->appearance_hair_colour - 1 + hair_colours_length) %
            hair_colours_length;
    }

    if (panel_is_clicked(mud->panel_appearance,
                         mud->control_appearance_hair_right)) {
        mud->appearance_hair_colour =
            (mud->appearance_hair_colour + 1) % hair_colours_length;
    }

    if (panel_is_clicked(mud->panel_appearance,
                         mud->control_appearance_gender_left) ||
        panel_is_clicked(mud->panel_appearance,
                         mud->control_appearance_gender_right)) {
        for (mud->appearance_head_gender = 3 - mud->appearance_head_gender;
             (game_data.animations[mud->appearance_head_type].gender & 3) !=
                 1 ||
             (game_data.animations[mud->appearance_head_type].gender &
              (4 * mud->appearance_head_gender)) == 0;
             mud->appearance_head_type =
                 (mud->appearance_head_type + 1) % game_data.animation_count)
            ;

        for (; (game_data.animations[mud->appearance_body_type].gender & 3) !=
                   2 ||
               (game_data.animations[mud->appearance_body_type].gender &
                (4 * mud->appearance_head_gender)) == 0;
             mud->appearance_body_type =
                 (mud->appearance_body_type + 1) % game_data.animation_count)
            ;
    }

    int top_bottom_colours_length = sizeof(player_top_bottom_colours) /
                                    sizeof(player_top_bottom_colours[0]);

    if (panel_is_clicked(mud->panel_appearance,
                         mud->control_appearance_top_left)) {
        mud->appearance_top_colour =
            (mud->appearance_top_colour - 1 + top_bottom_colours_length) %
            top_bottom_colours_length;
    }

    if (panel_is_clicked(mud->panel_appearance,
                         mud->control_appearance_top_right)) {
        mud->appearance_top_colour =
            (mud->appearance_top_colour + 1) % top_bottom_colours_length;
    }

    int skin_colours_length =
        sizeof(player_skin_colours) / sizeof(player_skin_colours[0]);

    if (panel_is_clicked(mud->panel_appearance,
                         mud->control_appearance_skin_left)) {
        mud->appearance_skin_colour =
            (mud->appearance_skin_colour - 1 + skin_colours_length) %
            skin_colours_length;
    }

    if (panel_is_clicked(mud->panel_appearance,
                         mud->control_appearance_skin_right)) {
        mud->appearance_skin_colour =
            (mud->appearance_skin_colour + 1) % skin_colours_length;
    }

    if (panel_is_clicked(mud->panel_appearance,
                         mud->control_appearance_bottom_left)) {
        mud->appearance_bottom_colour =
            (mud->appearance_bottom_colour - 1 + top_bottom_colours_length) %
            top_bottom_colours_length;
    }

    if (panel_is_clicked(mud->panel_appearance,
                         mud->control_appearance_bottom_right)) {
        mud->appearance_bottom_colour =
            (mud->appearance_bottom_colour + 1) % top_bottom_colours_length;
    }

    if (panel_is_clicked(mud->panel_appearance,
                         mud->control_appearance_accept)) {
        /* the 2001 game asks for a character type and pk mode next */
        if (mudclient_is_retro(mud)) {
            mud->appearance_retro_page = 1;
        } else {
            send_appearance(mud);
        }
    }
}

void mudclient_draw_appearance_panel(mudclient *mud) {
    mud->surface->interlace = 0;
    surface_black_screen(mud->surface);

    if (mud->appearance_retro_page) {
        panel_draw_panel(mud->panel_appearance_retro);

        if (!mud->options->lowmem) {
            mudclient_draw_blue_bar(mud);
        }

        surface_draw(mud->surface);
        return;
    }

    panel_draw_panel(mud->panel_appearance);

    int is_compact = mud->surface->width < MUD_VANILLA_WIDTH ||
                     mud->surface->height < MUD_VANILLA_HEIGHT;

    int x = mud->surface->width / 2;

    int y = (is_compact ? -7 : 25) +
            (mud->surface->height / 2 -
             (is_compact ? MUD_MIN_HEIGHT : MUD_VANILLA_HEIGHT) / 2);

    surface_draw_sprite_scale_mask(
        mud->surface, x - 32 - 55, y, APPEARANCE_CHARACTER_WIDTH,
        APPEARANCE_CHARACTER_HEIGHT,
        game_data.animations[ANIMATION_INDEX_LEGS].file_id,
        player_top_bottom_colours[mud->appearance_bottom_colour]);

    surface_draw_sprite_transform_mask(
        mud->surface, x - 32 - 55, y, APPEARANCE_CHARACTER_WIDTH,
        APPEARANCE_CHARACTER_HEIGHT,
        game_data.animations[mud->appearance_body_type].file_id,
        player_top_bottom_colours[mud->appearance_top_colour],
        player_skin_colours[mud->appearance_skin_colour], 0, 0);

    surface_draw_sprite_transform_mask(
        mud->surface, x - 32 - 55, y, APPEARANCE_CHARACTER_WIDTH,
        APPEARANCE_CHARACTER_HEIGHT,
        game_data.animations[mud->appearance_head_type].file_id,
        player_hair_colours[mud->appearance_hair_colour],
        player_skin_colours[mud->appearance_skin_colour], 0, 0);

    surface_draw_sprite_scale_mask(
        mud->surface, x - 32, y, APPEARANCE_CHARACTER_WIDTH,
        APPEARANCE_CHARACTER_HEIGHT, game_data.animations[2].file_id + 6,
        player_top_bottom_colours[mud->appearance_bottom_colour]);

    surface_draw_sprite_transform_mask(
        mud->surface, x - 32, y, APPEARANCE_CHARACTER_WIDTH,
        APPEARANCE_CHARACTER_HEIGHT,
        game_data.animations[mud->appearance_body_type].file_id + 6,
        player_top_bottom_colours[mud->appearance_top_colour],
        player_skin_colours[mud->appearance_skin_colour], 0, 0);

    surface_draw_sprite_transform_mask(
        mud->surface, x - 32, y, APPEARANCE_CHARACTER_WIDTH,
        APPEARANCE_CHARACTER_HEIGHT,
        game_data.animations[mud->appearance_head_type].file_id + 6,
        player_hair_colours[mud->appearance_hair_colour],
        player_skin_colours[mud->appearance_skin_colour], 0, 0);

    surface_draw_sprite_scale_mask(
        mud->surface, x - 32 + 55, y, APPEARANCE_CHARACTER_WIDTH,
        APPEARANCE_CHARACTER_HEIGHT, game_data.animations[2].file_id + 12,
        player_top_bottom_colours[mud->appearance_bottom_colour]);

    surface_draw_sprite_transform_mask(
        mud->surface, x - 32 + 55, y, APPEARANCE_CHARACTER_WIDTH,
        APPEARANCE_CHARACTER_HEIGHT,
        game_data.animations[mud->appearance_body_type].file_id + 12,
        player_top_bottom_colours[mud->appearance_top_colour],
        player_skin_colours[mud->appearance_skin_colour], 0, 0);

    surface_draw_sprite_transform_mask(
        mud->surface, x - 32 + 55, y, APPEARANCE_CHARACTER_WIDTH,
        APPEARANCE_CHARACTER_HEIGHT,
        game_data.animations[mud->appearance_head_type].file_id + 12,
        player_hair_colours[mud->appearance_hair_colour],
        player_skin_colours[mud->appearance_skin_colour], 0, 0);

    if (!mud->options->lowmem) {
        mudclient_draw_blue_bar(mud);
    }

    surface_draw(mud->surface);
}

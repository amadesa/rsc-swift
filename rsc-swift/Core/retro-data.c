#include "retro-data.h"

#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "scene.h"
#include "utility.h"

#define JAGEX_TRANSPARENT (12345678)

/* the .ob2 number for "transparent" and "smooth shading" */
#define OB2_MAGIC (123456)

int retro_good_spell_count = 0;
int retro_evil_spell_count = 0;

/*
 * the config tables are text: "=count;" and then a record per entry, each
 * a few "=a,b,c;" groups. strings may be "quoted"
 */
typedef struct {
    const char *data;
    size_t length;
    size_t offset;
} TextReader;

static int text_next(TextReader *reader) {
    if (reader->offset >= reader->length) {
        return -1;
    }

    return (unsigned char)reader->data[reader->offset++];
}

/* to just after the next '=' */
static void text_next_group(TextReader *reader) {
    int c;

    do {
        c = text_next(reader);
    } while (c != '=' && c != -1);
}

static int text_int(TextReader *reader) {
    int negative = 0;
    int c = text_next(reader);

    while (c != -1 && (c < '0' || c > '9')) {
        if (c == '-') {
            negative = 1;
        }

        c = text_next(reader);
    }

    int value = 0;

    while (c >= '0' && c <= '9') {
        value = value * 10 + (c - '0');
        c = text_next(reader);
    }

    return negative ? -value : value;
}

static int hex_digit(int c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }

    if (c >= 'a' && c <= 'f') {
        return c - 'a' + 10;
    }

    if (c >= 'A' && c <= 'F') {
        return c - 'A' + 10;
    }

    return -1;
}

static int text_hex(TextReader *reader) {
    int c = text_next(reader);

    while (c != -1 && hex_digit(c) < 0) {
        c = text_next(reader);
    }

    int value = 0;

    while (hex_digit(c) >= 0) {
        value = value * 16 + hex_digit(c);
        c = text_next(reader);
    }

    return value;
}

/* a new string, which the caller owns */
static char *text_string(TextReader *reader) {
    int c = text_next(reader);

    while (c != -1 && (c < 32 || c == ',' || c == ';' || c == '=')) {
        c = text_next(reader);
    }

    int quoted = c == '"';

    if (quoted) {
        c = text_next(reader);
    }

    size_t start = reader->offset - 1;
    size_t end = start;

    while (c != -1) {
        if (quoted ? c == '"' : (c == ',' || c == ';' || c == '=')) {
            break;
        }

        end = reader->offset;
        c = text_next(reader);
    }

    if (c == -1 && start >= reader->length) {
        return mud_strdup("");
    }

    size_t length = end > start ? end - start : 0;
    char *string = malloc(length + 1);
    memcpy(string, reader->data + start, length);
    string[length] = '\0';

    return string;
}

/* "_" is an empty command */
static char *text_command(TextReader *reader, const char *empty) {
    char *command = text_string(reader);

    if (strcmp(command, "_") == 0) {
        free(command);
        return mud_strdup(empty);
    }

    return command;
}

static int transparent_fill(int fill) {
    return fill == JAGEX_TRANSPARENT ? COLOUR_TRANSPARENT : fill;
}

/* the table's text, without the NUL padding some entries have */
static int open_table(TextReader *reader, const char *name, int8_t *jag) {
    size_t length = 0;
    int8_t *data = load_data(name, 0, jag, &length);

    if (data == NULL) {
        mud_error("missing %s from config\n", name);
        return 0;
    }

    size_t text_length = strnlen((char *)data, length);

    reader->data = (const char *)data;
    reader->length = text_length;
    reader->offset = 0;

    return 1;
}

static void close_table(TextReader *reader) {
    free((void *)reader->data);
    reader->data = NULL;
}

/* entity names, looked up by NPCs and items; the files are named
 * separately */
static int entity_count = 0;
static char **entity_names = NULL;

static int find_entity(const char *name) {
    if (strcasecmp(name, "na") == 0) {
        return -1;
    }

    for (int i = 0; i < entity_count; i++) {
        if (strcasecmp(entity_names[i], name) == 0) {
            return i;
        }
    }

    return 0;
}

/* items can be called by any of their names */
static int *item_name_counts = NULL;
static char ***item_names = NULL;

static int find_item(const char *name) {
    if (strcasecmp(name, "na") == 0) {
        return 0;
    }

    for (int i = 0; i < game_data.item_count; i++) {
        for (int j = 0; j < item_name_counts[i]; j++) {
            if (strcasecmp(item_names[i][j], name) == 0) {
                return i;
            }
        }
    }

    return 0;
}

/* the first name is the one shown; the rest are other names to find it by */
static char **read_names(TextReader *reader, int *count) {
    *count = text_int(reader);

    if (*count < 1) {
        *count = 1;
        char **names = calloc(1, sizeof(char *));
        names[0] = mud_strdup("");
        return names;
    }

    char **names = calloc(*count, sizeof(char *));

    for (int i = 0; i < *count; i++) {
        names[i] = text_string(reader);
    }

    return names;
}

static void load_entities(TextReader *reader) {
    text_next_group(reader);
    entity_count = text_int(reader);
    entity_names = calloc(entity_count, sizeof(char *));

    game_data.animation_count = entity_count;
    game_data.animations = calloc(entity_count, sizeof(struct AnimConfig));

    for (int i = 0; i < entity_count; i++) {
        text_next_group(reader);
        entity_names[i] = text_string(reader);

        /* the sprites are loaded by file name (mudclient_load_entities) */
        char *file = text_string(reader);
        strtolower(file);

        struct AnimConfig *animation = &game_data.animations[i];
        animation->name = file;
        animation->colour = text_hex(reader);
        animation->gender = text_int(reader);
        animation->has_a = text_int(reader);
        animation->has_f = text_int(reader);
    }
}

static void load_projectiles(TextReader *reader) {
    text_next_group(reader);
    int count = text_int(reader);
    int sprites = 0;

    for (int i = 0; i < count; i++) {
        text_next_group(reader);
        free(text_string(reader)); /* name */

        int sprite = text_int(reader);

        if (sprite + 1 > sprites) {
            sprites = sprite + 1;
        }

        text_int(reader);
        text_int(reader);
        text_int(reader);
        free(text_string(reader)); /* ammunition */
        text_int(reader);
    }

    game_data.projectile_sprite = sprites;
}

static void load_items(TextReader *reader) {
    text_next_group(reader);
    int count = text_int(reader);

    game_data.item_count = count;
    game_data.items = calloc(count, sizeof(struct ItemConfig));
    game_data.item_sprite_count = 0;

    item_name_counts = calloc(count, sizeof(int));
    item_names = calloc(count, sizeof(char **));

    for (int i = 0; i < count; i++) {
        struct ItemConfig *item = &game_data.items[i];

        text_next_group(reader);
        item_names[i] = read_names(reader, &item_name_counts[i]);
        item->name = item_names[i][0];
        item->description = text_string(reader);

        text_next_group(reader);
        item->sprite = text_int(reader);

        if (item->sprite + 1 > game_data.item_sprite_count) {
            game_data.item_sprite_count = item->sprite + 1;
        }

        item->base_price = text_int(reader);
        item->stackable = text_int(reader); /* 0 stacks */
        item->command = text_command(reader, "");

        /* equipment bonuses and ammunition, which the server works out */
        text_next_group(reader);

        for (int j = 0; j < 6; j++) {
            text_int(reader);
        }

        free(text_string(reader));

        text_next_group(reader);
        item->wearable = text_int(reader);
        free(text_string(reader)); /* worn appearance */
        item->mask = text_hex(reader);
        text_int(reader);
        text_int(reader);

        item->special = 0;
        item->members = 0;
    }
}

static void load_npcs(TextReader *reader) {
    text_next_group(reader);
    int count = text_int(reader);

    game_data.npc_count = count;
    game_data.npcs = calloc(count, sizeof(struct NpcConfig));

    for (int i = 0; i < count; i++) {
        struct NpcConfig *npc = &game_data.npcs[i];
        int name_count = 0;

        text_next_group(reader);
        char **names = read_names(reader, &name_count);
        npc->name = names[0];

        for (int j = 1; j < name_count; j++) {
            free(names[j]);
        }

        free(names);

        npc->description = text_string(reader);
        npc->command = "";

        /* fifteen numbers, the first five known */
        text_next_group(reader);
        npc->attack = text_int(reader);
        npc->defense = text_int(reader);
        npc->strength = text_int(reader);
        npc->hits = text_int(reader);
        npc->attackable = text_int(reader);

        for (int j = 5; j < 15; j++) {
            text_int(reader);
        }

        text_next_group(reader);

        for (int j = 0; j < NPC_SPRITE_COUNT; j++) {
            char *sprite = text_string(reader);
            npc->sprites[j] = find_entity(sprite);
            free(sprite);
        }

        npc->hair_colour = text_hex(reader);
        npc->top_colour = text_hex(reader);
        npc->bottom_colour = text_hex(reader);
        npc->skin_colour = text_hex(reader);

        text_next_group(reader);
        npc->width = text_int(reader);
        npc->height = text_int(reader);
        npc->walk_speed = text_int(reader);
        npc->combat_speed = text_int(reader);
        npc->combat_width = text_int(reader);

        /* drops, which the server decides */
        text_next_group(reader);
        int drops = text_int(reader);

        for (int j = 0; j < drops; j++) {
            free(text_string(reader));
            text_int(reader);
        }
    }
}

static void load_locations(TextReader *reader) {
    text_next_group(reader);
    int count = text_int(reader);

    game_data.object_count = count;
    game_data.objects = calloc(count, sizeof(struct ObjectConfig));

    for (int i = 0; i < count; i++) {
        struct ObjectConfig *object = &game_data.objects[i];
        int name_count = 0;

        text_next_group(reader);
        char **names = read_names(reader, &name_count);
        object->name = names[0];

        for (int j = 1; j < name_count; j++) {
            free(names[j]);
        }

        free(names);

        object->description = text_string(reader);

        text_next_group(reader);
        char *model = text_string(reader);
        int old_count = game_data.model_count;
        object->model_index = game_data_get_model_index(model);

        if (game_data.model_count == old_count) {
            free(model);
        }

        object->width = text_int(reader);
        object->height = text_int(reader);
        object->type = text_int(reader);
        text_int(reader);
        object->command1 = text_command(reader, "WalkTo");
        object->command2 = text_command(reader, "Examine");
        object->elevation = text_int(reader);
    }
}

static void load_boundaries(TextReader *reader) {
    text_next_group(reader);
    int count = text_int(reader);

    game_data.wall_object_count = count;
    game_data.wall_objects = calloc(count, sizeof(struct WallConfig));

    for (int i = 0; i < count; i++) {
        struct WallConfig *wall = &game_data.wall_objects[i];
        int name_count = 0;

        text_next_group(reader);
        char **names = read_names(reader, &name_count);
        wall->name = names[0];

        for (int j = 1; j < name_count; j++) {
            free(names[j]);
        }

        free(names);

        wall->description = text_string(reader);

        text_next_group(reader);
        wall->height = text_int(reader);
        wall->texture_front = transparent_fill(text_int(reader));
        wall->texture_back = transparent_fill(text_int(reader));
        wall->blocking = text_int(reader);
        text_int(reader);
        wall->interactive = text_int(reader);
        wall->command1 = text_command(reader, "WalkTo");
        wall->command2 = text_command(reader, "Examine");
    }
}

static void load_roofs(TextReader *reader) {
    text_next_group(reader);
    int count = text_int(reader);

    game_data.roof_count = count;
    game_data.roofs = calloc(count, sizeof(struct RoofConfig));

    for (int i = 0; i < count; i++) {
        text_next_group(reader);
        free(text_string(reader));
        game_data.roofs[i].height = text_int(reader);
        text_int(reader);
        game_data.roofs[i].fill = text_int(reader);
    }
}

static void load_floors(TextReader *reader) {
    text_next_group(reader);
    int count = text_int(reader);

    game_data.tile_count = count;
    game_data.tiles = calloc(count, sizeof(struct TileConfig));

    for (int i = 0; i < count; i++) {
        text_next_group(reader);
        free(text_string(reader));
        game_data.tiles[i].decoration = transparent_fill(text_int(reader));
        game_data.tiles[i].type = text_int(reader);
        game_data.tiles[i].blocking = text_int(reader);
    }
}

/* one spell book, added to game_data.spells */
static int load_spells(TextReader *reader) {
    text_next_group(reader);
    int count = text_int(reader);
    int first = game_data.spell_count;

    game_data.spells = realloc(game_data.spells, (first + count) *
                                                     sizeof(struct SpellConfig));

    for (int i = 0; i < count; i++) {
        struct SpellConfig *spell = &game_data.spells[first + i];
        memset(spell, 0, sizeof(*spell));

        text_next_group(reader);
        spell->name = text_string(reader);
        spell->level = text_int(reader);
        spell->description = text_string(reader);
        spell->type = text_int(reader);
        text_int(reader);

        text_next_group(reader);
        int runes = text_int(reader);

        for (int j = 0; j < runes; j++) {
            char *rune = text_string(reader);
            int amount = text_int(reader);

            if (j < MAX_REQUIRED_RUNES) {
                spell->runes[j].id = find_item(rune);
                spell->runes[j].count = amount;
            }

            free(rune);
        }

        spell->runes_required =
            runes < MAX_REQUIRED_RUNES ? runes : MAX_REQUIRED_RUNES;
    }

    game_data.spell_count = first + count;

    return count;
}

int retro_data_load_config(int8_t *config_jag) {
    memset(game_data.model_name, 0, sizeof(game_data.model_name));
    game_data.model_count = 0;
    game_data.spell_count = 0;
    game_data.spells = NULL;

    TextReader reader = {0};

    /* the entities and items first, which the rest refer to by name */
    static const char *tables[] = {
        "entity.txt",   "projectile.txt", "objects.txt",
        "npc.txt",      "location.txt",   "boundary.txt",
        "roof.txt",     "floor.txt",      "goodspells.txt",
        "evilspells.txt"};

    for (size_t t = 0; t < sizeof(tables) / sizeof(tables[0]); t++) {
        if (!open_table(&reader, tables[t], config_jag)) {
            return 0;
        }

        switch (t) {
        case 0:
            load_entities(&reader);
            break;
        case 1:
            load_projectiles(&reader);
            break;
        case 2:
            load_items(&reader);
            break;
        case 3:
            load_npcs(&reader);
            break;
        case 4:
            load_locations(&reader);
            break;
        case 5:
            load_boundaries(&reader);
            break;
        case 6:
            load_roofs(&reader);
            break;
        case 7:
            load_floors(&reader);
            break;
        case 8:
            retro_good_spell_count = load_spells(&reader);
            break;
        case 9:
            retro_evil_spell_count = load_spells(&reader);
            break;
        }

        close_table(&reader);
    }

    /* the 2001 prayers aren't in the config */
    game_data.prayer_count = 0;
    game_data.prayers = NULL;

    return 1;
}

int retro_data_load_texture_names(int8_t *textures_jag) {
    TextReader reader = {0};

    size_t length = 0;
    int8_t *data = load_data("textures.txt", 0, textures_jag, &length);

    if (data == NULL) {
        return 0;
    }

    reader.data = (const char *)data;
    reader.length = strnlen((char *)data, length);

    text_next_group(&reader);
    int count = text_int(&reader);

    game_data.texture_count = count;
    game_data.textures = calloc(count, sizeof(struct TextureConfig));

    for (int i = 0; i < count; i++) {
        text_next_group(&reader);
        game_data.textures[i].name = text_string(&reader);
        game_data.textures[i].subtype_name = NULL;
        text_hex(&reader);
        text_int(&reader);
    }

    free(data);

    return 1;
}

/*
 * .ob2: numbers written as three characters from a 64 character alphabet,
 * with line breaks anywhere between them
 */
typedef struct {
    const int8_t *data;
    size_t length;
    size_t offset;
} Ob2Reader;

static int ob2_digit(int c) {
    if (c >= '0' && c <= '9') {
        return c - '0';
    }

    if (c >= 'A' && c <= 'Z') {
        return c - 'A' + 10;
    }

    if (c >= 'a' && c <= 'z') {
        return c - 'a' + 36;
    }

    if (c == 0xa3) { /* £ */
        return 62;
    }

    if (c == '$') {
        return 63;
    }

    return 0;
}

static int ob2_number(Ob2Reader *reader) {
    while (reader->offset < reader->length &&
           (reader->data[reader->offset] == '\n' ||
            reader->data[reader->offset] == '\r')) {
        reader->offset++;
    }

    if (reader->offset + 3 > reader->length) {
        return 0;
    }

    int a = ob2_digit((uint8_t)reader->data[reader->offset]);
    int b = ob2_digit((uint8_t)reader->data[reader->offset + 1]);
    int c = ob2_digit((uint8_t)reader->data[reader->offset + 2]);
    reader->offset += 3;

    return a * 4096 + b * 64 + c - 131072;
}

void game_model_new_ob2(GameModel *game_model, int8_t *data, size_t len) {
    Ob2Reader reader = {data, len, 0};

    game_model_new(game_model);

    ob2_number(&reader); /* its length */
    int vertex_count = ob2_number(&reader);
    int face_count = ob2_number(&reader);

    if (vertex_count <= 0 || face_count < 0) {
        return;
    }

    game_model_allocate(game_model, vertex_count, face_count);

    for (int i = 0; i < vertex_count; i++) {
        game_model->vertex_x[i] = ob2_number(&reader);
        game_model->vertex_y[i] = ob2_number(&reader);
        game_model->vertex_z[i] = ob2_number(&reader);
    }

    game_model->vertex_count = vertex_count;

    for (int i = 0; i < face_count; i++) {
        int count = ob2_number(&reader);
        int front = ob2_number(&reader);
        int back = ob2_number(&reader);
        int extra = ob2_number(&reader);

        /* two numbers the 2001 models give each face, apparently unused */
        ob2_number(&reader);
        ob2_number(&reader);

        int smooth = ob2_number(&reader);

        game_model->face_vertex_count[i] = count;
        game_model->face_fill_front[i] =
            front == OB2_MAGIC ? COLOUR_TRANSPARENT : front;
        game_model->face_fill_back[i] =
            back == OB2_MAGIC ? COLOUR_TRANSPARENT : back;
        game_model->face_intensity[i] = smooth == 0 ? 0 : GAME_MODEL_USE_GOURAUD;

        game_model->face_vertices[i] = calloc(count, sizeof(uint16_t));

        for (int j = 0; j < count; j++) {
            game_model->face_vertices[i][j] = ob2_number(&reader);
        }

        for (int j = 0; j < extra; j++) {
            ob2_number(&reader);
        }
    }

    game_model->face_count = face_count;
}

#include "retro-packets.h"

#include <stdlib.h>
#include <string.h>

#include "chat-message.h"
#include "client-opcodes.h"
#include "packet-handler.h"
#include "retro-data.h"
#include "server-opcodes.h"
#include "ui/social-tab.h"
#include "utility.h"

/* server -> client (Payload38Generator) */
#define RETRO_SERVER_MESSAGE 8
#define RETRO_FRIEND_LIST 23
#define RETRO_FRIEND_UPDATE 24
#define RETRO_IGNORE_LIST 26
#define RETRO_PRIVACY_SETTINGS 27
#define RETRO_PRIVATE_MESSAGE 28
#define RETRO_GAME_SETTINGS 228
#define RETRO_TRADE_ACCEPTED 229
#define RETRO_REMOVE_NPCS 231
#define RETRO_REMOVE_PLAYERS 232
#define RETRO_SHOP_CLOSE 233
#define RETRO_SHOP_OPEN 234
#define RETRO_TRADE_OTHER_ACCEPTED 235
#define RETRO_TRADE_OTHER_ITEMS 236
#define RETRO_TRADE_CLOSE 237
#define RETRO_TRADE_WINDOW 238
#define RETRO_APPEARANCE_SCREEN 239
#define RETRO_REMOVE_WORLD_ENTITY 240
#define RETRO_DEATH 241
#define RETRO_EQUIPMENT_STATS 242
#define RETRO_STATS 243
#define RETRO_WORLD_INFO 244
#define RETRO_OPTIONS_MENU_CLOSE 245
#define RETRO_OPTIONS_MENU_OPEN 246
#define RETRO_UPDATE_NPCS 247
#define RETRO_NPC_COORDS 248
#define RETRO_BOUNDARIES 249
#define RETRO_UPDATE_PLAYERS 250
#define RETRO_UPDATE_APPEARANCES 251
#define RETRO_INVENTORY 252
#define RETRO_SCENERY 253
#define RETRO_GROUND_ITEMS 254
#define RETRO_PLAYER_COORDS 255

/* client -> server (Payload38Parser) */
#define RETRO_CLIENT_REGISTER 2
#define RETRO_CLIENT_CONFIRM_LOGOUT 1
#define RETRO_CLIENT_CHAT 3
#define RETRO_CLIENT_HEARTBEAT 5
#define RETRO_CLIENT_FRIEND_ADD 26
#define RETRO_CLIENT_FRIEND_REMOVE 27
#define RETRO_CLIENT_PRIVATE_MESSAGE 28
#define RETRO_CLIENT_IGNORE_ADD 29
#define RETRO_CLIENT_IGNORE_REMOVE 30
#define RETRO_CLIENT_PRIVACY_SETTINGS 31
#define RETRO_CLIENT_GAME_SETTING 213
#define RETRO_CLIENT_PLAYER_FOLLOW 214
#define RETRO_CLIENT_WALK_ACTION 215
#define RETRO_CLIENT_SHOP_SELL 216
#define RETRO_CLIENT_SHOP_BUY 217
#define RETRO_CLIENT_SHOP_CLOSE 218
#define RETRO_CLIENT_USEWITH_PLAYER 219
#define RETRO_CLIENT_CAST_INVITEM 220
#define RETRO_CLIENT_CAST_GROUND 221
#define RETRO_CLIENT_CAST_OBJECT 222
#define RETRO_CLIENT_CAST_WALLOBJECT 223
#define RETRO_CLIENT_CAST_GROUNDITEM 224
#define RETRO_CLIENT_CAST_NPC 225
#define RETRO_CLIENT_CAST_PLAYER 226
#define RETRO_CLIENT_CAST_SELF 227
#define RETRO_CLIENT_PLAYER_ATTACK 228
#define RETRO_CLIENT_WALL_OBJECT_COMMAND2 229
#define RETRO_CLIENT_OBJECT_COMMAND2 230
#define RETRO_CLIENT_COMBAT_STYLE 231
#define RETRO_CLIENT_TRADE_ACCEPT 232
#define RETRO_CLIENT_TRADE_DECLINE 233
#define RETRO_CLIENT_TRADE_ITEMS 234
#define RETRO_CLIENT_PLAYER_TRADE 235
#define RETRO_CLIENT_APPEARANCE 236
#define RETRO_CLIENT_CHOOSE_OPTION 237
#define RETRO_CLIENT_WALL_OBJECT_COMMAND1 238
#define RETRO_CLIENT_USEWITH_WALLOBJECT 239
#define RETRO_CLIENT_USEWITH_INVITEM 240
#define RETRO_CLIENT_USEWITH_OBJECT 241
#define RETRO_CLIENT_OBJECT_COMMAND1 242
#define RETRO_CLIENT_USEWITH_NPC 243
#define RETRO_CLIENT_NPC_ATTACK 244
#define RETRO_CLIENT_NPC_TALK 245
#define RETRO_CLIENT_INVENTORY_COMMAND 246
#define RETRO_CLIENT_INVENTORY_UNEQUIP 248
#define RETRO_CLIENT_INVENTORY_WEAR 249
#define RETRO_CLIENT_USEWITH_GROUNDITEM 250
#define RETRO_CLIENT_INVENTORY_DROP 251
#define RETRO_CLIENT_GROUNDITEM_TAKE 252
#define RETRO_CLIENT_WALK 255

/* a growing packet for mudclient_handle_packet */
typedef struct {
    int8_t *data;
    int length;
    int max;
} OutBuffer;

static void out_byte(OutBuffer *out, int i) {
    if (out->length < out->max) {
        out->data[out->length++] = i & 0xff;
    }
}

static void out_short(OutBuffer *out, int i) {
    out_byte(out, i >> 8);
    out_byte(out, i);
}

static void out_int(OutBuffer *out, int i) {
    out_short(out, i >> 16);
    out_short(out, i);
}

static void out_long(OutBuffer *out, int64_t i) {
    out_int(out, (int)(i >> 32));
    out_int(out, (int)i);
}

static void out_bytes(OutBuffer *out, const void *src, int length) {
    for (int i = 0; i < length; i++) {
        out_byte(out, ((const uint8_t *)src)[i]);
    }
}

/* bytes from a packet, zeros past its end */
static void out_copy(OutBuffer *out, const int8_t *data, int offset,
                     int length, int size) {
    for (int i = 0; i < length; i++) {
        out_byte(out, offset + i < size ? data[offset + i] : 0);
    }
}

/* the later protocol's packed chat text, from plain 2001 text */
static void out_chat(OutBuffer *out, const int8_t *text, int length) {
    char message[CHAT_MESSAGE_MAX_LENGTH + 1];

    if (length > CHAT_MESSAGE_MAX_LENGTH) {
        length = CHAT_MESSAGE_MAX_LENGTH;
    }

    if (length < 0) {
        length = 0;
    }

    memcpy(message, text, length);
    message[length] = '\0';

    int encoded_length = chat_message_encode(message);
    out_byte(out, encoded_length);
    out_bytes(out, chat_message_encoded, encoded_length);
}

static int short_at(const int8_t *data, int offset, int size) {
    if (offset + 2 > size) {
        return 0;
    }

    return ((data[offset] & 0xff) << 8) | (data[offset + 1] & 0xff);
}

static int byte_at(const int8_t *data, int offset, int size) {
    if (offset >= size) {
        return 0;
    }

    return data[offset] & 0xff;
}

/* a 2001 friend status (0 offline, 1 another world, 2 this world) as the
 * later protocol's (ui/social-tab.c shows 10 as world 1) */
static int friend_status(int status) {
    if (status == 2) {
        return FRIEND_ONLINE;
    }

#ifdef REVISION_177
    return status;
#else
    return status == 1 ? 10 : 0;
#endif
}

/* the 5-bit signed tile offsets of the position packets */
static int signed5(int i) { return i > 15 ? i - 32 : i; }

/* 255: the local player's index, tile and direction, then 3 bytes for each
 * other player in view. the whole list comes every tick */
static void retro_player_coords(mudclient *mud, int8_t *data, int size) {
    if (size < 8) {
        return;
    }

    int server_index = short_at(data, 1, size);
    int tile_x = short_at(data, 3, size);
    int tile_y = short_at(data, 5, size);
    int sprite = byte_at(data, 7, size);

    if (server_index >= PLAYERS_SERVER_MAX) {
        return;
    }

    mud->local_player_server_index = server_index;

    mud->known_player_count = mud->player_count;

    memcpy(mud->known_players, mud->players,
           mud->known_player_count * sizeof(GameCharacter *));

    mud->local_region_x = tile_x;
    mud->local_region_y = tile_y;

    int has_loaded_region = mudclient_load_next_region(
        mud, mud->local_region_x, mud->local_region_y);

    mud->local_region_x -= mud->region_x;
    mud->local_region_y -= mud->region_y;

    int player_x = mud->local_region_x * MAGIC_LOC + 64;
    int player_y = mud->local_region_y * MAGIC_LOC + 64;

    if (has_loaded_region && mud->local_player != NULL) {
        mud->local_player->waypoint_current = 0;
        mud->local_player->moving_step = 0;

        mud->local_player->current_x = mud->local_player->waypoints_x[0] =
            player_x;

        mud->local_player->current_y = mud->local_player->waypoints_y[0] =
            player_y;
    }

    mud->player_count = 0;

    GameCharacter *local_player =
        mudclient_add_player(mud, server_index, player_x, player_y, sprite);

    if (local_player != NULL) {
        mud->local_player = local_player;
    }

    for (int offset = 8; offset + 3 <= size; offset += 3) {
        int packed = short_at(data, offset, size);
        int packed2 = byte_at(data, offset + 2, size);

        int index = packed >> 6;
        int area_x = signed5((packed >> 1) & 0x1f);
        int area_y = signed5(((packed & 1) << 4) | (packed2 >> 4));
        int player_sprite = packed2 & 0xf;

        if (index >= PLAYERS_SERVER_MAX || index == server_index) {
            continue;
        }

        int x = (mud->local_region_x + area_x) * MAGIC_LOC + 64;
        int y = (mud->local_region_y + area_y) * MAGIC_LOC + 64;

        mudclient_add_player(mud, index, x, y, player_sprite);
    }
}

/* 248: 4 bytes for each NPC in view, the whole list every tick */
static void retro_npc_coords(mudclient *mud, int8_t *data, int size) {
    mud->known_npc_count = mud->npc_count;
    mud->npc_count = 0;

    memcpy(mud->known_npcs, mud->npcs,
           mud->known_npc_count * sizeof(GameCharacter *));

    for (int offset = 1; offset + 4 <= size; offset += 4) {
        int packed = short_at(data, offset, size);
        int packed2 = byte_at(data, offset + 2, size);
        int npc_id = byte_at(data, offset + 3, size);

        int index = packed >> 6;
        int area_x = signed5((packed >> 1) & 0x1f);
        int area_y = signed5(((packed & 1) << 4) | (packed2 >> 4));
        int sprite = packed2 & 0xf;

        if (index >= NPCS_SERVER_MAX) {
            continue;
        }

        if (npc_id >= game_data.npc_count) {
            npc_id = 0;
        }

        int x = (mud->local_region_x + area_x) * MAGIC_LOC + 64;
        int y = (mud->local_region_y + area_y) * MAGIC_LOC + 64;

        mudclient_add_npc(mud, index, x, y, sprite, npc_id);
    }
}

/* 250 (bubbles, chat, damage, projectiles) and 251 (appearances) as 234 */
static void retro_player_updates(mudclient *mud, int8_t *data, int size,
                                 int appearances, OutBuffer *out) {
    int count = short_at(data, 1, size);
    int offset = 3;

    out_byte(out, SERVER_REGION_PLAYER_UPDATE);
    int count_offset = out->length;
    out_short(out, 0);

    int written = 0;

    for (int i = 0; i < count && offset + 2 <= size; i++) {
        int index = short_at(data, offset, size);
        offset += 2;

        if (appearances) {
            int server_id = short_at(data, offset, size);
            offset += 2;

            out_short(out, index);
            out_byte(out, 5);
            out_short(out, server_id);
            out_copy(out, data, offset, 8, size); /* username hash */
            offset += 8;

            int worn_count = byte_at(data, offset++, size);
            out_byte(out, worn_count);

            for (int j = 0; j < worn_count; j++) {
                out_byte(out, byte_at(data, offset++, size));
            }

            /* hair, top, bottom and skin colours */
            for (int j = 0; j < 4; j++) {
                out_byte(out, byte_at(data, offset++, size));
            }

            offset++; /* pk mode */
            out_byte(out, byte_at(data, offset++, size)); /* level */
            out_byte(out, byte_at(data, offset++, size)); /* skull */
            written++;
            continue;
        }

        int type = byte_at(data, offset++, size);

        switch (type) {
        case 0: /* bubble */
            out_short(out, index);
            out_byte(out, 0);
            out_short(out, short_at(data, offset, size));
            offset += 2;
            written++;
            break;
        case 1: { /* chat; quest chat starts with @que@ */
            int length = byte_at(data, offset++, size);

            if (length > size - offset) {
                length = size - offset;
            }

            int quest = length >= 5 && memcmp(data + offset, "@que@", 5) == 0;

            out_short(out, index);
            out_byte(out, quest ? 6 : 1);

            if (quest) {
                out_chat(out, data + offset + 5, length - 5);
            } else {
                out_chat(out, data + offset, length);
            }

            offset += length;
            written++;
            break;
        }
        case 2: /* damage, current and max hits */
            out_short(out, index);
            out_byte(out, 2);
            out_copy(out, data, offset, 3, size);
            offset += 3;
            written++;
            break;
        case 3:
        case 4: /* projectile */
            out_short(out, index);
            out_byte(out, type);
            out_copy(out, data, offset, 4, size);
            offset += 4;
            written++;
            break;
        default:
            /* unknown: the rest can't be read */
            i = count;
            break;
        }
    }

    out->data[count_offset] = (written >> 8) & 0xff;
    out->data[count_offset + 1] = written & 0xff;
}

/* 247 as 104 */
static void retro_npc_updates(int8_t *data, int size, OutBuffer *out) {
    int count = short_at(data, 1, size);
    int offset = 3;

    out_byte(out, SERVER_REGION_NPC_UPDATE);
    int count_offset = out->length;
    out_short(out, 0);

    int written = 0;

    for (int i = 0; i < count && offset + 3 <= size; i++) {
        int index = short_at(data, offset, size);
        offset += 2;

        int type = byte_at(data, offset++, size);

        if (type == 1) {
            int target = short_at(data, offset, size);
            offset += 2;

            int length = byte_at(data, offset++, size);

            if (length > size - offset) {
                length = size - offset;
            }

            out_short(out, index);
            out_byte(out, 1);
            out_short(out, target);
            out_chat(out, data + offset, length);
            offset += length;
            written++;
        } else if (type == 2) {
            out_short(out, index);
            out_byte(out, 2);
            out_copy(out, data, offset, 3, size);
            offset += 3;
            written++;
        } else {
            break;
        }
    }

    out->data[count_offset] = (written >> 8) & 0xff;
    out->data[count_offset + 1] = written & 0xff;
}

void mudclient_retro_packet(mudclient *mud, int8_t *data, int size) {
    int opcode = data[0] & 0xff;

    /* the translated packets are at most a little bigger than the 2001 ones
     * (trade amounts go from 2 to 4 bytes) */
    int max = size * 2 + 64;
    int8_t *buffer = malloc(max);

    if (buffer == NULL) {
        return;
    }

    OutBuffer out = {buffer, 0, max};
    int translated = 1;

    switch (opcode) {
    case RETRO_PLAYER_COORDS:
        retro_player_coords(mud, data, size);
        translated = 0;
        break;
    case RETRO_NPC_COORDS:
        retro_npc_coords(mud, data, size);
        translated = 0;
        break;
    case RETRO_REMOVE_NPCS:
    case RETRO_REMOVE_PLAYERS:
        /* the next position list leaves them out */
        translated = 0;
        break;
    case RETRO_WORLD_INFO:
        mud->loading_area = 1;
        mud->plane_width = short_at(data, 1, size);
        mud->plane_height = short_at(data, 3, size);
        mud->plane_index = short_at(data, 5, size);
        mud->plane_multiplier = short_at(data, 7, size);
        mud->plane_height -= mud->plane_index * mud->plane_multiplier;
        translated = 0;
        break;
    case RETRO_EQUIPMENT_STATS:
        /* armour, aim, power, magic, prayer and hiding */
        for (int i = 0; i < PLAYER_STAT_EQUIPMENT_MAX; i++) {
            mud->player_stat_equipment[i] = byte_at(data, 1 + i, size);
        }
        translated = 0;
        break;
    case RETRO_STATS:
        for (int i = 0; i < PLAYER_SKILL_MAX; i++) {
            mud->player_skill_current[i] = byte_at(data, 1 + i, size);
            mud->player_skill_base[i] =
                byte_at(data, 1 + PLAYER_SKILL_MAX + i, size);
        }
        translated = 0;
        break;
    case RETRO_INVENTORY: {
        int count = (size - 1) / 4;

        if (count > INVENTORY_ITEMS_MAX) {
            count = INVENTORY_ITEMS_MAX;
        }

        for (int i = 0; i < count; i++) {
            int id_equip = short_at(data, 1 + i * 4, size);
            int id = id_equip & 32767;

            if (id >= game_data.item_count) {
                id = 0;
            }

            mud->inventory_item_id[i] = id;
            mud->inventory_equipped[i] = id_equip >> 15;
            mud->inventory_item_stack_count[i] = short_at(data, 3 + i * 4, size);
        }

        mud->inventory_items_count = count;
        translated = 0;
        break;
    }
    case RETRO_SERVER_MESSAGE:
        /* the logout confirmation, just before the server closes the
         * connection (Open-RSC ActionSender.sendLogoutRequestConfirm) */
        if (size == 7 && memcmp(data + 1, "@sys@k", 6) == 0) {
            out_byte(&out, SERVER_CLOSE_CONNECTION);
            break;
        }

        out_byte(&out, SERVER_MESSAGE);
        out_copy(&out, data, 1, size - 1, size);
        break;
    case RETRO_FRIEND_LIST: {
        int count = byte_at(data, 1, size);

        out_byte(&out, SERVER_FRIEND_LIST);
        out_byte(&out, count);

        for (int i = 0; i < count; i++) {
            out_copy(&out, data, 2 + i * 9, 8, size);
            out_byte(&out, friend_status(byte_at(data, 10 + i * 9, size)));
        }
        break;
    }
    case RETRO_FRIEND_UPDATE: {
        out_byte(&out, SERVER_FRIEND_STATUS_CHANGE);
        out_copy(&out, data, 1, 8, size);
        out_byte(&out, friend_status(byte_at(data, 9, size)));
        break;
    }
    case RETRO_IGNORE_LIST:
        out_byte(&out, SERVER_IGNORE_LIST);
        out_copy(&out, data, 1, size - 1, size);
        break;
    case RETRO_PRIVACY_SETTINGS:
        /* hide status, chat, private, trade, unused */
        out_byte(&out, SERVER_PRIVACY_SETTINGS);
        out_byte(&out, byte_at(data, 2, size));
        out_byte(&out, byte_at(data, 3, size));
        out_byte(&out, byte_at(data, 4, size));
        out_byte(&out, 1);
        break;
    case RETRO_PRIVATE_MESSAGE:
        out_byte(&out, SERVER_FRIEND_MESSAGE);
        out_copy(&out, data, 1, 8, size);
#ifndef REVISION_177
        out_int(&out, 0);
#endif
        if (size > 9) {
            /* the 204 handler reads the packed text to the end */
            char message[CHAT_MESSAGE_MAX_LENGTH + 1];
            int length = size - 9;

            if (length > CHAT_MESSAGE_MAX_LENGTH) {
                length = CHAT_MESSAGE_MAX_LENGTH;
            }

            memcpy(message, data + 9, length);
            message[length] = '\0';

            int encoded_length = chat_message_encode(message);
            out_bytes(&out, chat_message_encoded, encoded_length);
        }
        break;
    case RETRO_GAME_SETTINGS:
        /* pk, camera auto, pk changes left, one mouse button */
        out_byte(&out, SERVER_GAME_SETTINGS);
        out_byte(&out, byte_at(data, 2, size));
        out_byte(&out, byte_at(data, 4, size));
        out_byte(&out, 0);
        break;
    case RETRO_TRADE_ACCEPTED:
        out_byte(&out, SERVER_TRADE_ACCEPTED);
        out_byte(&out, byte_at(data, 1, size));
        break;
    case RETRO_TRADE_OTHER_ACCEPTED:
        out_byte(&out, SERVER_TRADE_RECIPIENT_ACCEPTED);
        out_byte(&out, byte_at(data, 1, size));
        break;
    case RETRO_SHOP_CLOSE:
        out_byte(&out, SERVER_SHOP_CLOSE);
        break;
    case RETRO_SHOP_OPEN:
        out_byte(&out, SERVER_SHOP_OPEN);
        out_copy(&out, data, 1, size - 1, size);
        break;
    case RETRO_TRADE_OTHER_ITEMS: {
        int count = byte_at(data, 1, size);

        out_byte(&out, SERVER_TRADE_ITEMS);
        out_byte(&out, count);

        for (int i = 0; i < count; i++) {
            out_short(&out, short_at(data, 2 + i * 4, size));
            out_int(&out, short_at(data, 4 + i * 4, size));
        }
        break;
    }
    case RETRO_TRADE_CLOSE:
        out_byte(&out, SERVER_TRADE_CLOSE);
        break;
    case RETRO_TRADE_WINDOW:
        out_byte(&out, SERVER_TRADE_OPEN);
        out_copy(&out, data, 1, 2, size);
        break;
    case RETRO_APPEARANCE_SCREEN:
        out_byte(&out, SERVER_APPEARANCE);
        break;
    case RETRO_REMOVE_WORLD_ENTITY:
        out_byte(&out, SERVER_REGION_ENTITY_UPDATE);
        out_copy(&out, data, 1, size - 1, size);
        break;
    case RETRO_DEATH:
        out_byte(&out, SERVER_PLAYER_DIED);
        break;
    case RETRO_OPTIONS_MENU_CLOSE:
        out_byte(&out, SERVER_OPTION_LIST_CLOSE);
        break;
    case RETRO_OPTIONS_MENU_OPEN:
        out_byte(&out, SERVER_OPTION_LIST);
        out_copy(&out, data, 1, size - 1, size);
        break;
    case RETRO_UPDATE_NPCS:
        retro_npc_updates(data, size, &out);
        break;
    case RETRO_UPDATE_PLAYERS:
        retro_player_updates(mud, data, size, 0, &out);
        break;
    case RETRO_UPDATE_APPEARANCES:
        retro_player_updates(mud, data, size, 1, &out);
        break;
    case RETRO_BOUNDARIES:
        out_byte(&out, SERVER_REGION_WALL_OBJECTS);
        out_copy(&out, data, 1, size - 1, size);
        break;
    case RETRO_SCENERY:
        out_byte(&out, SERVER_REGION_OBJECTS);
        out_copy(&out, data, 1, size - 1, size);
        break;
    case RETRO_GROUND_ITEMS:
        out_byte(&out, SERVER_REGION_GROUND_ITEMS);
        out_copy(&out, data, 1, size - 1, size);
        break;
    default:
        mud_log("2001: unhandled packet %d (%d bytes)\n", opcode, size);
        translated = 0;
        break;
    }

    if (translated && out.length > 0) {
        mudclient_handle_packet(mud, buffer[0] & 0xff, buffer, out.length);
    }

    free(buffer);
}

/* the length of text from the later protocol's packed chat, without the
 * space an odd number of 4-bit characters leaves at the end */
static int unpadded_length(const char *message) {
    int length = strlen(message);

    while (length > 0 && message[length - 1] == ' ') {
        length--;
    }

    return length;
}

/* a 204 spell index as the 2001 book (0 good, 1 evil) and the spell in it */
static void put_spell(OutBuffer *out, int spell) {
    if (spell >= retro_good_spell_count) {
        out_byte(out, 1);
        out_byte(out, spell - retro_good_spell_count);
    } else {
        out_byte(out, 0);
        out_byte(out, spell);
    }
}

int retro_translate_client_packet(const int8_t *packet, int length,
                                  int8_t *out_data, int out_max) {
    if (length < 1) {
        return 0;
    }

    int opcode = packet[0] & 0xff;
    const int8_t *data = packet;
    int size = length;
    OutBuffer out = {out_data, 0, out_max};

    switch (opcode) {
    /* the 2001 login and register are built in their own form */
    case CLIENT_RETRO_LOGIN:
    case CLIENT_RETRO_RECONNECT:
    case RETRO_CLIENT_REGISTER:
        out_bytes(&out, packet, length);
        return out.length;
    case CLIENT_PING:
        out_byte(&out, RETRO_CLIENT_HEARTBEAT);
        break;
    case CLIENT_LOGOUT:
    case CLIENT_CLOSE_CONNECTION:
        out_byte(&out, RETRO_CLIENT_CONFIRM_LOGOUT);
        break;
    case CLIENT_WALK:
    case CLIENT_WALK_ACTION:
        out_byte(&out, opcode == CLIENT_WALK ? RETRO_CLIENT_WALK
                                             : RETRO_CLIENT_WALK_ACTION);
        out_copy(&out, data, 1, size - 1, size);
        break;
    case CLIENT_COMBAT_STYLE:
        out_byte(&out, RETRO_CLIENT_COMBAT_STYLE);
        out_byte(&out, byte_at(data, 1, size));
        break;
    case CLIENT_CHOOSE_OPTION:
        out_byte(&out, RETRO_CLIENT_CHOOSE_OPTION);
        out_byte(&out, byte_at(data, 1, size));
        break;
    case CLIENT_SETTINGS_GAME: {
        /* 204: 0 camera, 2 mouse buttons, 3 sound. 2001: 0 camera, 1 pk, 2
         * mouse buttons */
        int setting = byte_at(data, 1, size);

        if (setting != 0 && setting != 2) {
            return 0;
        }

        out_byte(&out, RETRO_CLIENT_GAME_SETTING);
        out_byte(&out, setting);
        out_byte(&out, byte_at(data, 2, size));
        break;
    }
    case CLIENT_SETTINGS_PRIVACY:
        /* hide status, chat, private, trade, unused */
        out_byte(&out, RETRO_CLIENT_PRIVACY_SETTINGS);
        out_byte(&out, 0);
        out_byte(&out, byte_at(data, 1, size));
        out_byte(&out, byte_at(data, 2, size));
        out_byte(&out, byte_at(data, 3, size));
        out_byte(&out, 0);
        break;
    case CLIENT_APPEARANCE:
        /* the 204 appearance, then the class and pk mode, which
         * ui/appearance.c adds in 2001 mode */
        out_byte(&out, RETRO_CLIENT_APPEARANCE);
        out_copy(&out, data, 1, 8, size);
        out_byte(&out, byte_at(data, 9, size));
        out_byte(&out, byte_at(data, 10, size));
        break;
    case CLIENT_CHAT: {
        char *message = chat_message_decode((int8_t *)data, 1, size - 1);
        out_byte(&out, RETRO_CLIENT_CHAT);
        out_bytes(&out, message, unpadded_length(message));
        break;
    }
    case CLIENT_COMMAND:
        out_byte(&out, RETRO_CLIENT_CHAT);
        out_bytes(&out, "::", 2);
        out_copy(&out, data, 1, size - 1, size);
        break;
    case CLIENT_PM: {
        char *message = chat_message_decode((int8_t *)data, 9, size - 9);
        int message_length = unpadded_length(message);

        out_byte(&out, RETRO_CLIENT_PRIVATE_MESSAGE);
        out_copy(&out, data, 1, 8, size);
        out_byte(&out, message_length);
        out_bytes(&out, message, message_length);
        break;
    }
    case CLIENT_FRIEND_ADD:
    case CLIENT_FRIEND_REMOVE:
    case CLIENT_IGNORE_ADD:
    case CLIENT_IGNORE_REMOVE:
        out_byte(&out, opcode == CLIENT_FRIEND_ADD      ? RETRO_CLIENT_FRIEND_ADD
                       : opcode == CLIENT_FRIEND_REMOVE ? RETRO_CLIENT_FRIEND_REMOVE
                       : opcode == CLIENT_IGNORE_ADD    ? RETRO_CLIENT_IGNORE_ADD
                                                        : RETRO_CLIENT_IGNORE_REMOVE);
        out_copy(&out, data, 1, 8, size);
        break;

    /* the same shorts and bytes in both */
    case CLIENT_NPC_TALK:
    case CLIENT_NPC_ATTACK:
    case CLIENT_PLAYER_ATTACK:
    case CLIENT_PLAYER_TRADE:
    case CLIENT_PLAYER_FOLLOW:
    case CLIENT_INVENTORY_COMMAND:
    case CLIENT_INVENTORY_DROP:
    case CLIENT_INVENTORY_WEAR:
    case CLIENT_INVENTORY_UNEQUIP:
    case CLIENT_USEWITH_INVITEM:
    case CLIENT_USEWITH_NPC:
    case CLIENT_USEWITH_PLAYER:
    case CLIENT_OBJECT_COMMAND1:
    case CLIENT_OBJECT_COMMAND2:
    case CLIENT_USEWITH_OBJECT:
    case CLIENT_WALL_OBJECT_COMMAND1:
    case CLIENT_WALL_OBJECT_COMMAND2:
    case CLIENT_USEWITH_WALLOBJECT:
    case CLIENT_USEWITH_GROUNDITEM: {
        int retro_opcode = 0;
        int payload = size - 1;

        switch (opcode) {
        case CLIENT_NPC_TALK: retro_opcode = RETRO_CLIENT_NPC_TALK; break;
        case CLIENT_NPC_ATTACK: retro_opcode = RETRO_CLIENT_NPC_ATTACK; break;
        case CLIENT_PLAYER_ATTACK:
            retro_opcode = RETRO_CLIENT_PLAYER_ATTACK;
            break;
        case CLIENT_PLAYER_TRADE:
            retro_opcode = RETRO_CLIENT_PLAYER_TRADE;
            break;
        case CLIENT_PLAYER_FOLLOW:
            retro_opcode = RETRO_CLIENT_PLAYER_FOLLOW;
            break;
        case CLIENT_INVENTORY_COMMAND:
            retro_opcode = RETRO_CLIENT_INVENTORY_COMMAND;
            break;
        case CLIENT_INVENTORY_DROP:
            retro_opcode = RETRO_CLIENT_INVENTORY_DROP;
            payload = 2;
            break;
        case CLIENT_INVENTORY_WEAR:
            retro_opcode = RETRO_CLIENT_INVENTORY_WEAR;
            break;
        case CLIENT_INVENTORY_UNEQUIP:
            retro_opcode = RETRO_CLIENT_INVENTORY_UNEQUIP;
            break;
        case CLIENT_USEWITH_INVITEM:
            retro_opcode = RETRO_CLIENT_USEWITH_INVITEM;
            break;
        case CLIENT_USEWITH_NPC:
            retro_opcode = RETRO_CLIENT_USEWITH_NPC;
            break;
        case CLIENT_USEWITH_PLAYER:
            retro_opcode = RETRO_CLIENT_USEWITH_PLAYER;
            break;
        case CLIENT_OBJECT_COMMAND1:
            retro_opcode = RETRO_CLIENT_OBJECT_COMMAND1;
            break;
        case CLIENT_OBJECT_COMMAND2:
            retro_opcode = RETRO_CLIENT_OBJECT_COMMAND2;
            break;
        case CLIENT_USEWITH_OBJECT:
            retro_opcode = RETRO_CLIENT_USEWITH_OBJECT;
            break;
        case CLIENT_WALL_OBJECT_COMMAND1:
            retro_opcode = RETRO_CLIENT_WALL_OBJECT_COMMAND1;
            break;
        case CLIENT_WALL_OBJECT_COMMAND2:
            retro_opcode = RETRO_CLIENT_WALL_OBJECT_COMMAND2;
            break;
        case CLIENT_USEWITH_WALLOBJECT:
            retro_opcode = RETRO_CLIENT_USEWITH_WALLOBJECT;
            break;
        case CLIENT_USEWITH_GROUNDITEM:
            retro_opcode = RETRO_CLIENT_USEWITH_GROUNDITEM;
            break;
        }

        out_byte(&out, retro_opcode);
        out_copy(&out, data, 1, payload, size);
        break;
    }
    case CLIENT_GROUNDITEM_TAKE:
        /* x, y and item; 204 adds one more short */
        out_byte(&out, RETRO_CLIENT_GROUNDITEM_TAKE);
        out_copy(&out, data, 1, 6, size);
        break;

    /* spells: the 204 spell index becomes the book and spell */
    case CLIENT_CAST_SELF:
        out_byte(&out, RETRO_CLIENT_CAST_SELF);
        put_spell(&out, short_at(data, 1, size));
        break;
    case CLIENT_CAST_NPC:
    case CLIENT_CAST_PLAYER:
    case CLIENT_CAST_INVITEM:
        out_byte(&out, opcode == CLIENT_CAST_NPC      ? RETRO_CLIENT_CAST_NPC
                       : opcode == CLIENT_CAST_PLAYER ? RETRO_CLIENT_CAST_PLAYER
                                                      : RETRO_CLIENT_CAST_INVITEM);
        out_copy(&out, data, 1, 2, size);
        put_spell(&out, short_at(data, 3, size));
        break;
    case CLIENT_CAST_GROUND:
    case CLIENT_CAST_OBJECT:
        out_byte(&out, opcode == CLIENT_CAST_GROUND ? RETRO_CLIENT_CAST_GROUND
                                                    : RETRO_CLIENT_CAST_OBJECT);
        out_copy(&out, data, 1, 4, size);
        put_spell(&out, short_at(data, 5, size));
        break;
    case CLIENT_CAST_GROUNDITEM:
        out_byte(&out, RETRO_CLIENT_CAST_GROUNDITEM);
        out_copy(&out, data, 1, 6, size);
        put_spell(&out, short_at(data, 7, size));
        break;
    case CLIENT_CAST_WALLOBJECT:
        out_byte(&out, RETRO_CLIENT_CAST_WALLOBJECT);
        out_copy(&out, data, 1, 5, size);
        put_spell(&out, short_at(data, 6, size));
        break;

    /* shop and trade: amounts and prices are shorts in 2001 */
    case CLIENT_SHOP_BUY:
    case CLIENT_SHOP_SELL: {
        int price = (int)get_unsigned_int((void *)data, 3, size);

        out_byte(&out, opcode == CLIENT_SHOP_BUY ? RETRO_CLIENT_SHOP_BUY
                                                 : RETRO_CLIENT_SHOP_SELL);
        out_copy(&out, data, 1, 2, size);
        out_short(&out, price > 65535 ? 65535 : price);
        break;
    }
    case CLIENT_SHOP_CLOSE:
        out_byte(&out, RETRO_CLIENT_SHOP_CLOSE);
        break;
    case CLIENT_TRADE_ITEM_UPDATE: {
        int count = byte_at(data, 1, size);

        out_byte(&out, RETRO_CLIENT_TRADE_ITEMS);
        out_byte(&out, count);

        for (int i = 0; i < count; i++) {
            int amount = (int)get_unsigned_int((void *)data, 4 + i * 6, size);

            out_short(&out, short_at(data, 2 + i * 6, size));
            out_short(&out, amount > 65535 ? 65535 : amount);
        }
        break;
    }
    case CLIENT_TRADE_ACCEPT:
        out_byte(&out, RETRO_CLIENT_TRADE_ACCEPT);
        out_byte(&out, 1);
        break;
    case CLIENT_TRADE_DECLINE:
        out_byte(&out, RETRO_CLIENT_TRADE_DECLINE);
        break;
    default:
        /* banks, duels, prayers, sleep, recovery questions, known players
         * and the rest weren't in the 2001 game */
        return 0;
    }

    return out.length;
}

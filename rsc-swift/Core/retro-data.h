#ifndef _H_RETRO_DATA
#define _H_RETRO_DATA

/*
 * the May 2001 game data (2001Scape): config17's text tables and the .ob2
 * models of models6, read into the same game_data and GameModel structures
 * as the later binary data.
 *
 * written for rsc-swift from the files themselves and Open-RSC's 2001
 * definitions; the meaning of some columns is still unknown and they're
 * skipped.
 */

#include <stddef.h>
#include <stdint.h>

#include "game-data.h"
#include "game-model.h"

/* the 2001 config is text tables (config17) */
#define CONFIG_IS_TEXT(x) ((x) < 20)

/* the 2001 models are .ob2 text (models6) */
#define MODELS_IS_OB2(x) ((x) < 10)

/* the 2001 textures are TGA files listed in textures.txt (textures5) */
#define TEXTURES_IS_TGA(x) ((x) < 10)

/* the May 2001 protocol: its version and login opcodes */
#define RETRO_VERSION 38
#define CLIENT_RETRO_LOGIN 0
#define CLIENT_RETRO_RECONNECT 19

/* the 2001 spell books, also in game_data.spells (good ones first) */
extern int retro_good_spell_count;
extern int retro_evil_spell_count;

/* fills game_data from config17.jag. returns 0 if a table is missing */
int retro_data_load_config(int8_t *config_jag);

/* fills game_data.textures from textures.txt in textures5.jag. returns 0 if
 * it's missing */
int retro_data_load_texture_names(int8_t *textures_jag);

/* reads a .ob2 model */
void game_model_new_ob2(GameModel *game_model, int8_t *data, size_t len);

#endif

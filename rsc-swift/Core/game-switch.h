#ifndef _H_GAME_SWITCH
#define _H_GAME_SWITCH

/*
 * switching between the later game and the May 2001 game (2001Scape) by
 * world: each world in worlds.cfg says which it runs, and the game data is
 * swapped for that world's before its login screen or login. the 2001 data
 * isn't shipped; the app downloads it the first time (rsc-bridge.h).
 *
 * written for rsc-swift.
 */

#include "mudclient.h"

/* the 2001 game's data files */
#define RETRO_VERSION_CONFIG 17
#define RETRO_VERSION_MAPS 14
#define RETRO_VERSION_ENTITY 3
#define RETRO_VERSION_MEDIA 12
#define RETRO_VERSION_MODELS 6
#define RETRO_VERSION_TEXTURES 5

/* the state of the 2001 data while it's fetched */
#define RETRO_DATA_IDLE 0
#define RETRO_DATA_DOWNLOADING 1
#define RETRO_DATA_FAILED 2

/* before loading anything: the data versions for the last world's game.
 * the 2001 game when that world runs it and its data is here */
void mudclient_choose_startup_game(mudclient *mud);

/* whether the 2001 data files are all here */
int mudclient_has_retro_data(mudclient *mud);

/* each frame on the login screens: switch to the selected world's game,
 * asking the app for the 2001 data the first time */
void mudclient_update_game(mudclient *mud);

/* before logging in: switch to the world's game. returns 0 if the login
 * has to wait for the 2001 data (it continues once it arrives) */
int mudclient_prepare_game(mudclient *mud);

/* the app finished fetching the 2001 data */
void mudclient_retro_data_ready(mudclient *mud, int success);

#endif

#ifndef _H_RETRO_PACKETS
#define _H_RETRO_PACKETS

/*
 * the in-game packets of the May 2001 protocol (version 38, 2001Scape).
 *
 * incoming packets are turned into their later (204) form where the two
 * carry the same thing, and handled by mudclient_handle_packet; the player
 * and NPC positions, which the 2001 server sends as a full list every tick,
 * are handled here. outgoing packets are built as 204 packets everywhere
 * else and translated just before they're sent.
 *
 * written for rsc-swift from Open-RSC's Payload38Parser,
 * Payload38Generator and GameStateUpdater (AGPL).
 */

#include <stdint.h>

#include "mudclient.h"

/* data[0] is the opcode, size counts it */
void mudclient_retro_packet(mudclient *mud, int8_t *data, int size);

/* turns the 204 packet in packet (opcode first, length bytes) into its 2001
 * form in out (at most out_max bytes). returns the new length, or 0 if the
 * 2001 game has nothing like it and it should be dropped */
int retro_translate_client_packet(const int8_t *packet, int length,
                                  int8_t *out, int out_max);

#endif

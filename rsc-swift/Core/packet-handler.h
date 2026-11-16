#ifndef _H_PACKET_HANDLER

#include "chat-message.h"
#include "client-opcodes.h"
#include "mudclient.h"
#include "packet-stream.h"
#include "retro-packets.h"
#include "scene.h"
#include "server-opcodes.h"
#include "ui/message-tabs.h"
#include "utility.h"
#include "world.h"

void mudclient_update_ground_item_models(mudclient *mud);
#if defined(RENDER_GL) || defined(RENDER_3DS_GL)
void mudclient_gl_update_wall_models(mudclient *mud);
#endif
void mudclient_packet_tick(mudclient *mud);
void mudclient_handle_packet(mudclient *mud, int opcode, int8_t *data,
                             int size);

#endif

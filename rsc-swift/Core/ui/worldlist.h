#ifndef WORLDLIST_H
#define WORLDLIST_H

#include "../mudclient.h"

void worldlist_new(mudclient *mud);
void worldlist_handle_mouse(mudclient *mud);
void worldlist_add(mudclient *mud, const char *name, const char *host,
                   int port, const char *rsa_exponent,
                   const char *rsa_modulus, const char *register_url,
                   int retro);

/* whether the last selected world (read from worlds.cfg, before the panel
 * exists) runs the May 2001 game */
int worldlist_last_world_is_retro(mudclient *mud);

/* whether the world at this index runs the May 2001 game */
int worldlist_is_retro(int index);
void worldlist_remove(mudclient *mud, int index);
#ifdef IOS
void worldlist_register(mudclient *mud);

/* select the world at this address, returning 0 if the list has none */
int worldlist_select_address(mudclient *mud, const char *host, int port);

/* the name of the world at this address, or "" */
const char *worldlist_name_at(const char *host, int port);

/* on the iPhone the list is drawn by worldlist_draw_scrolling and scrolled
 * and tapped through a native scroll view over it (GameViewController) */
int worldlist_scrolls_natively(void);
void worldlist_draw_scrolling(mudclient *mud);
int worldlist_row_height(void);
int worldlist_get_count(void);
/* select the world at this index, as tapping it would */
void worldlist_choose(mudclient *mud, int index);
#endif
#endif

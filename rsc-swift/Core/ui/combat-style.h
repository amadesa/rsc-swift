#ifndef _H_COMBAT_STYLE
#define _H_COMBAT_STYLE

#include "../mudclient.h"

extern const char *combat_styles[];

/* whether the combat style box is drawn (in combat, or always) */
int mudclient_is_combat_style_shown(mudclient *mud);
/* the y just below the combat style box, for what goes under it */
int mudclient_combat_style_bottom(mudclient *mud);
void mudclient_draw_combat_style(mudclient *mud);

#endif

#ifndef _H_STATS_TAB
#define _H_STATS_TAB

extern const char *short_skill_names[];
extern const char *skill_names[];
extern int skills_length;

extern char **quest_names;
extern int quests_length;

#include "../mudclient.h"

#define STATS_WIDTH 196
#define STATS_HEIGHT 275
#define STATS_COMPACT_HEIGHT 171
#define STATS_TAB_HEIGHT 24

void init_stats_tab_global(void);

/* the skill's name and the number of skills, for the 2001 game's 19 too */
const char *mudclient_skill_name(mudclient *mud, int skill);
int mudclient_skill_count(mudclient *mud);

void mudclient_draw_equipment_status(mudclient *mud, int x, int y,
                                     int line_break, int no_menus);
void mudclient_draw_ui_tab_stats(mudclient *mud, int no_menus);

#endif

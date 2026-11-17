#ifndef _H_UI_TABS
#define _H_UI_TABS

#define UI_TABS_WIDTH 245
#define UI_BUTTON_SIZE 35

/* the column of tab icons on touch screens. on the watch the icons are
 * bigger, filling the right edge */
#define UI_TABS_TOUCH_BUTTON_SIZE mudclient_ui_tabs_touch_button_size(mud)
#define UI_TABS_TOUCH_HEIGHT (((UI_TABS_TOUCH_BUTTON_SIZE - 2) * 6) + 1)
#define UI_TABS_TOUCH_X mudclient_ui_tabs_touch_x(mud)
#define UI_TABS_TOUCH_Y mudclient_ui_tabs_touch_y(mud)

#define UI_TABS_LABEL_HEIGHT 10

#define INVENTORY_TAB 1
#define MAP_TAB 2
#define STATS_TAB 3
#define MAGIC_TAB 4
#define SOCIAL_TAB 5
#define OPTIONS_TAB 6

#include "../mudclient.h"
#include "inventory-tab.h"
#include "magic-tab.h"
#include "minimap-tab.h"
#include "options-tab.h"
#include "social-tab.h"
#include "stats-tab.h"

void mudclient_draw_inventory_count(mudclient *mud);
void mudclient_draw_inventory_icon(mudclient *mud, int x, int y,
                                   int is_selected);
void mudclient_draw_magic_icon(mudclient *mud, int x, int y, int is_selected);
int mudclient_ui_tabs_have_icons(mudclient *mud);
int mudclient_ui_tabs_touch_button_size(mudclient *mud);
int mudclient_ui_tabs_touch_x(mudclient *mud);
int mudclient_ui_tabs_touch_y(mudclient *mud);
int mudclient_ui_tab_is_watch_area(mudclient *mud);
void mudclient_ui_tab_watch_area(mudclient *mud, int *x, int *y, int *width,
                                 int *height);
int mudclient_ui_tab_is_watch_full_screen(mudclient *mud);
void mudclient_ui_tab_step(mudclient *mud, int direction);
void mudclient_ui_tab_point_at_header(mudclient *mud);
void mudclient_ui_tab_move_list(Panel *panel, int control, int x, int y);
void mudclient_draw_ui_tabs(mudclient *mud);
void mudclient_draw_ui_tab_label(mudclient *mud, int selected_tab, int width,
                                 int x, int y);
void mudclient_set_active_ui_tab(mudclient *mud, int no_menus);
void mudclient_draw_active_ui_tab(mudclient *mud, int no_menus);

extern char *mudclient_ui_tab_names[6];

#endif

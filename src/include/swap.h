#ifndef SWAP_H
#define SWAP_H

#include <stdbool.h>
#include <stdint.h>

int swap_init(void);
void swap_deinit(void);

long get_timestamp(void);

int setup_keybind();

void run_keybind_loop(void);

typedef struct {
    const char *name;
    long pid;
    long zindex;
    bool is_running;
    const char *path;
} SwapAppInfo;

typedef struct {
    int length;
    SwapAppInfo *apps;
    int idx;
} AppReturn;

typedef struct {
    unsigned char red;
    unsigned char green;
    unsigned char blue;
} ColorRGB;

AppReturn *get_apps(char *query);
void deinitAppReturn(AppReturn *app);
AppReturn *update_apps(void);

typedef struct {
    uint32_t window_id;
    const char *name;
    const char *owner;
    int pid;
    bool is_minimized;
    bool is_hidden;
} SwapWindowInfo;

typedef struct {
    int length;
    SwapWindowInfo *windows;
    int idx;
} WindowReturn;

WindowReturn *get_windows(void);
void deinitWindowReturn(WindowReturn *window_return);
uint8_t get_current_mode(void);
void set_mode(uint8_t mode);
void set_window_count(size_t count);
void set_window_info(size_t index, uint32_t window_id, int pid, const char *path);
size_t get_selected_index(void);
void set_selected_index(size_t index);

void openConfigFile(void);
ColorRGB getColor(void);
int reloadConfig(void);

int check_for_screen_recording_perms(void);

#endif

// The launcher (launcher.h): the start screen before the game boots. Drawn by the menu (menu.mm calls launcher_draw in
// launcher mode: its ImGui context, fonts and input); the loop below runs on the main thread like the setup page's.
//
//   the game's title logo (from the player's own files: game_logo.c; the name as text without them)
//   [   Play   ] [ Settings ] [ Controls ] [ Files ]     big tiles: the controller moves between them, A / Enter opens
//   (A) Select  (B) Back                         Quit
//
// Settings and Controls open the in-game menu's own pages in a panel over it (B / Esc closes it); Files opens the data
// folder (saves, mods, logs).
#include <SDL3/SDL.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <atomic>

#include "imgui.h"
#include "imgui_internal.h"  // (NavCursorVisible, SetFocusID)
#include "osk.h"
#include "theme.h"

#ifdef __APPLE__
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#endif
#include <sys/stat.h>

#include "launcher.h"
#include "menu.h"

extern "C" {
#include "../game_logo.h"
#include "../gamelib.h"
#include "../input_bind.h"
#include "../paths.h"
#include "../rt.h"
#include "../settings.h"
#include "../update.h"
#include "../version.h"
#ifdef __APPLE__
void *ui_metal_layer(void);
void *ui_metal_device(void);
#else
bool vk_frame_begin(const float clear[4]);
void vk_frame_end(const char *shot_path);
void vk_shader_cache_cleanup(void);  // vulkan/shaders.c
bool vk_prepare_begin(void);          // vulkan/device.c: the shader preparation, in steps
bool vk_prepare_step(float *frac);
void vk_prepare_info(int *done, int *total, int *phase, int *stage);
void vk_prepare_cancel(void);
void *vk_frame_cmd(void);
uint64_t vk_imgui_texture_rgba(const void *rgba, int w, int h);  // nvn/vulkan/imgui_glue.cpp
#endif
void ui_window_init(void);
SDL_Window *ui_window(void);
}
// menu.mm
void menu_tabs_draw(float scale, ImFont *font, ImFont *font_big, bool in_game, void (*prelaunch)(float));
void menu_tabs_focus_tab(int id);
bool menu_tabs_close_requested(void);
extern int g_tab_request_ext;

// ------------------------------------------------------------------ the look
#define RGB(r, g, b) IM_COL32(r, g, b, 255)
// (0.2.7: "Starry Voyage", the player's pick - a night sky over a planet's glowing rim, the menu as stars along it)
static const ImU32 kSkyTop = RGB(7, 10, 28), kSkyBottom = RGB(20, 29, 74);
static const ImU32 kPlanet = RGB(22, 36, 96), kPlanetRim = IM_COL32(120, 170, 255, 70);
static const ImU32 kTile = RGB(30, 44, 104), kTileHot = RGB(44, 62, 140);
static const ImU32 kPlay = RGB(255, 227, 107), kPlayHot = RGB(255, 236, 150);
static const ImU32 kSoft = RGB(207, 224, 255), kFaint = RGB(140, 160, 210);

// ------------------------------------------------------------------ state
enum { ACT_NONE, ACT_PLAY, ACT_FOLDER, ACT_QUIT, ACT_CHANGE, ACT_REBUILD, ACT_UPDATE, ACT_UPDATE_RESTART };
#define PANEL_GAME (-10)  // g_panel: the Game page (game_panel_draw), not the menu's pages
static std::atomic<int> g_action{ACT_NONE};  // (render -> main thread)
static char g_root[1100] = "extracted";
static int g_panel = -2;   // the settings panel's first page (menu.mm tab ids), -2: closed
static int g_frames;       // frames since the launcher opened (the controller's cursor starts on Play)
// Play was pressed and the game is being made ready (the shader preparation, vulkan/device.c vk_prepare_step): the
// launcher goes on drawing itself, its Play tile reads "Starting" over a bar (main -> render thread). Before, the
// window stood still for up to a minute and the player took it for a hang (2026-11-10).
static std::atomic<bool> g_starting{false};
static std::atomic<float> g_start_frac{0};
static bool g_logo_tried;
static bool g_in_loop;  // the launcher's own frames: the only time the logo's texture is made
static ImTextureID g_logo;
static float g_logo_aspect = 1;

ImTextureID launcher_logo(float *aspect) {
#ifndef __APPLE__
    // (made only here, on the launcher's own frames: the game isn't running, so the upload has the queue to itself)
    if (!g_logo_tried && g_in_loop) {
        g_logo_tried = true;
        uint8_t *px = NULL;
        int w = 0, h = 0;
        if (game_logo_load(g_root, &px, &w, &h)) {
            g_logo = (ImTextureID)vk_imgui_texture_rgba(px, w, h);
            g_logo_aspect = (float)w / (float)h;
            // the window's icon too (the taskbar's): the logo centred on a clear square, 256 px
            SDL_Surface *src = SDL_CreateSurfaceFrom(w, h, SDL_PIXELFORMAT_ABGR8888, px, w * 4);
            if (src && getenv("ODYSSEY_LOGO_DUMP")) SDL_SavePNG(src, getenv("ODYSSEY_LOGO_DUMP"));  // (design work: never shipped)
            int side = w > h ? w : h;
            SDL_Surface *sq = SDL_CreateSurface(side, side, SDL_PIXELFORMAT_ABGR8888);
            if (src && sq) {
                SDL_FillSurfaceRect(sq, NULL, 0);
                SDL_SetSurfaceBlendMode(src, SDL_BLENDMODE_NONE);
                SDL_Rect r = {(side - w) / 2, (side - h) / 2, w, h};
                SDL_BlitSurface(src, NULL, sq, &r);
                SDL_Surface *icon = SDL_ScaleSurface(sq, 256, 256, SDL_SCALEMODE_LINEAR);
                if (icon) SDL_SetWindowIcon(ui_window(), icon), SDL_DestroySurface(icon);
            }
            SDL_DestroySurface(sq);
            SDL_DestroySurface(src);
            free(px);
        }
    }
#endif
    if (aspect) *aspect = g_logo_aspect;
    return g_logo;
}

static uint32_t rnd(uint32_t *s) { return *s = *s * 1664525u + 1013904223u, *s >> 8; }

void launcher_backdrop(ImDrawList *dl, ImVec2 sz, float s) {
    dl->AddRectFilledMultiColor(ImVec2(0, 0), sz, kSkyTop, kSkyTop, kSkyBottom, kSkyBottom);
    // stars, twinkling (the same sky every time), a few bright ones
    double t = SDL_GetTicks() / 1000.0;
    uint32_t seed = 0x0D155E7;
    for (int i = 0; i < 160; i++) {
        float x = (rnd(&seed) & 0xffff) / 65535.0f * sz.x, y = (rnd(&seed) & 0xffff) / 65535.0f * sz.y * 0.72f;
        float ph = (rnd(&seed) & 0xffff) / 65535.0f * 6.283f, sp = 0.6f + (rnd(&seed) & 0xff) / 160.0f;
        float a = 0.15f + 0.85f * (0.5f + 0.5f * sinf((float)t * sp + ph));
        float r = (i % 11 == 0 ? 2.4f : i % 3 == 0 ? 1.6f : 1.1f) * s;
        if (i % 11 == 0) dl->AddCircleFilled(ImVec2(x, y), r * 3.2f, IM_COL32(170, 200, 255, (int)(a * 40)), 16);
        dl->AddCircleFilled(ImVec2(x, y), r, IM_COL32(255, 255, 255, (int)(a * 255)), 8);
    }
    // a shooting star now and then (every 7 s, 0.9 s long)
    float ph = fmodf((float)t, 7.0f);
    if (ph < 0.9f) {
        float k = ph / 0.9f, x0 = sz.x * 0.78f - k * sz.x * 0.32f, y0 = sz.y * 0.1f + k * sz.y * 0.16f;
        for (int i = 0; i < 18; i++) {
            float q = i / 18.0f;
            dl->AddCircleFilled(ImVec2(x0 + q * 120 * s, y0 - q * 60 * s), (2.2f - q * 1.8f) * s,
                                IM_COL32(255, 255, 255, (int)((1 - q) * 230 * (k < 0.85f ? 1 : (1 - k) / 0.15f))), 8);
        }
    }
    // the planet below, its rim glowing
    float r = sz.x * 0.75f;
    ImVec2 c(sz.x * 0.5f, sz.y * 0.88f + r);
    for (int i = 14; i > 0; i--) dl->AddCircleFilled(c, r + i * 7 * s, IM_COL32(110, 160, 255, 6), 256);
    dl->AddCircleFilled(c, r, kPlanet, 256);
    dl->AddCircleFilled(ImVec2(c.x, c.y + r * 0.08f), r * 0.97f, RGB(14, 22, 58), 256);
    dl->AddCircle(c, r, kPlanetRim, 256, 3 * s);
}

// ------------------------------------------------------------------ drawing helpers
static ImU32 mix(ImU32 a, ImU32 b, float t) {
    ImVec4 x = ImGui::ColorConvertU32ToFloat4(a), y = ImGui::ColorConvertU32ToFloat4(b);
    return ImGui::ColorConvertFloat4ToU32(ImVec4(x.x + (y.x - x.x) * t, x.y + (y.y - x.y) * t, x.z + (y.z - x.z) * t,
                                                 x.w + (y.w - x.w) * t));
}

// text with extra space between the letters (the small caps line at the top)
static void spaced_text(ImDrawList *dl, ImFont *f, float size, ImVec2 p, ImU32 col, const char *t, float space) {
    for (const char *c = t; *c; c++) {
        char one[2] = {*c, 0};
        dl->AddText(f, size, p, col, one);
        p.x += f->CalcTextSizeA(size, FLT_MAX, 0, one).x + space;
    }
}
static float spaced_width(ImFont *f, float size, const char *t, float space) {
    float w = 0;
    for (const char *c = t; *c; c++) {
        char one[2] = {*c, 0};
        w += f->CalcTextSizeA(size, FLT_MAX, 0, one).x + (c[1] ? space : 0);
    }
    return w;
}

// The tiles' pictures, centred at c, about 2r across: 0 play, 1 gear, 2 controller, 3 folder (bg: the tile's colour,
// for the holes)
static void icon(ImDrawList *dl, int k, ImVec2 c, float r, ImU32 col, ImU32 bg) {
    switch (k) {
    case 0:
        dl->AddTriangleFilled(ImVec2(c.x - r * 0.55f, c.y - r * 0.8f), ImVec2(c.x + r * 0.85f, c.y),
                              ImVec2(c.x - r * 0.55f, c.y + r * 0.8f), col);
        break;
    case 1:
        for (int i = 0; i < 8; i++) {
            float a = i * 3.14159f / 4, ca = cosf(a), sa = sinf(a), w = r * 0.17f, r0 = r * 0.6f, r1 = r * 0.98f;
            ImVec2 p[4] = {{c.x + ca * r0 - sa * w, c.y + sa * r0 + ca * w}, {c.x + ca * r1 - sa * w, c.y + sa * r1 + ca * w},
                           {c.x + ca * r1 + sa * w, c.y + sa * r1 - ca * w}, {c.x + ca * r0 + sa * w, c.y + sa * r0 - ca * w}};
            dl->AddQuadFilled(p[0], p[1], p[2], p[3], col);
        }
        dl->AddCircleFilled(c, r * 0.72f, col, 32);
        dl->AddCircleFilled(c, r * 0.3f, bg, 24);
        break;
    case 2:
        dl->AddRectFilled(ImVec2(c.x - r, c.y - r * 0.48f), ImVec2(c.x + r, c.y + r * 0.42f), col, r * 0.42f);
        dl->AddCircleFilled(ImVec2(c.x - r * 0.62f, c.y + r * 0.38f), r * 0.36f, col, 24);
        dl->AddCircleFilled(ImVec2(c.x + r * 0.62f, c.y + r * 0.38f), r * 0.36f, col, 24);
        dl->AddRectFilled(ImVec2(c.x - r * 0.78f, c.y - r * 0.07f), ImVec2(c.x - r * 0.3f, c.y + r * 0.09f), bg);
        dl->AddRectFilled(ImVec2(c.x - r * 0.62f, c.y - r * 0.23f), ImVec2(c.x - r * 0.46f, c.y + r * 0.25f), bg);
        dl->AddCircleFilled(ImVec2(c.x + r * 0.42f, c.y - r * 0.12f), r * 0.11f, bg, 12);
        dl->AddCircleFilled(ImVec2(c.x + r * 0.64f, c.y + r * 0.1f), r * 0.11f, bg, 12);
        break;
    case 3:
        dl->AddRectFilled(ImVec2(c.x - r, c.y - r * 0.72f), ImVec2(c.x - r * 0.12f, c.y - r * 0.3f), col, r * 0.14f);
        dl->AddRectFilled(ImVec2(c.x - r, c.y - r * 0.5f), ImVec2(c.x + r, c.y + r * 0.72f), col, r * 0.16f);
        break;
    }
}

// A controller button's face (the hints line): a disc with its letter, or PlayStation's symbol (bind_pad_label's
// "Cross" / "Circle")
static float button_hint(ImDrawList *dl, ImFont *f, float size, ImVec2 p, const char *letter, const char *what) {
    float r = size * 0.62f;
    ImVec2 c(p.x + r, p.y + size * 0.5f);
    dl->AddCircleFilled(c, r, kSoft, 24);
    if (!strcmp(letter, "Cross")) {
        float a = r * 0.42f;
        dl->AddLine(ImVec2(c.x - a, c.y - a), ImVec2(c.x + a, c.y + a), kSkyBottom, r * 0.22f);
        dl->AddLine(ImVec2(c.x - a, c.y + a), ImVec2(c.x + a, c.y - a), kSkyBottom, r * 0.22f);
    } else if (!strcmp(letter, "Circle")) {
        dl->AddCircle(c, r * 0.45f, kSkyBottom, 24, r * 0.2f);
    } else {
        ImVec2 ls = f->CalcTextSizeA(size * 0.8f, FLT_MAX, 0, letter);
        dl->AddText(f, size * 0.8f, ImVec2(c.x - ls.x * 0.5f, c.y - ls.y * 0.5f), kSkyBottom, letter);
    }
    float x = p.x + 2 * r + size * 0.4f;
    dl->AddText(f, size, ImVec2(x, p.y), kSoft, what);
    return x + f->CalcTextSizeA(size, FLT_MAX, 0, what).x + size * 1.4f;
}

// One tile: true when chosen. Lights up under the mouse or the controller's cursor (eased), a white ring for the
// cursor.
static bool tile(const char *id, ImVec2 p, ImVec2 sz, bool play, int ic, const char *label, const char *sub, ImFont *f,
                 ImFont *fb, float s) {
    ImGui::SetCursorScreenPos(p);
    ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
    bool pressed = ImGui::InvisibleButton(id, sz, ImGuiButtonFlags_EnableNav);
    ImGui::PopStyleColor();
    ImGuiID gid = ImGui::GetItemID();
    bool cursor = ImGui::IsItemFocused() && ImGui::GetCurrentContext()->NavCursorVisible;
    bool lit = ImGui::IsItemHovered() || cursor;
    float *hv = ImGui::GetStateStorage()->GetFloatRef(gid, 0);
    *hv += ((lit ? 1.0f : 0.0f) - *hv) * fminf(1, ImGui::GetIO().DeltaTime * 14);
    float grow = 6 * s * *hv;
    ImVec2 a(p.x - grow, p.y - grow), b(p.x + sz.x + grow, p.y + sz.y + grow);
    ImDrawList *dl = ImGui::GetWindowDrawList();
    float round = 20 * s;
    ImU32 bg = play ? mix(kPlay, kPlayHot, *hv) : mix(kTile, kTileHot, *hv);
    if (cursor) dl->AddRect(ImVec2(a.x - 6 * s, a.y - 6 * s), ImVec2(b.x + 6 * s, b.y + 6 * s), IM_COL32(255, 255, 255, 235),
                            round + 6 * s, 0, 4 * s);
    dl->AddRectFilled(a, b, bg, round);
    // the picture top left, the name and what it holds bottom left
    float pad = 26 * s + grow, ir = fminf(sz.y * 0.13f, 34 * s) * (play ? 1.25f : 1.0f);
    icon(dl, ic, ImVec2(a.x + pad + ir, a.y + pad + ir), ir, IM_COL32(255, 255, 255, 245), bg);
    float ls = (play ? fb->FontSize * 0.95f : f->FontSize * 1.05f) * s, ss = f->FontSize * 0.7f * s;
    float y = b.y - pad - ss - 4 * s - ls;
    dl->AddText(play ? fb : f, ls, ImVec2(a.x + pad, y), IM_COL32(255, 255, 255, 255), label);
    dl->AddText(f, ss, ImVec2(a.x + pad, y + ls + 4 * s), play ? IM_COL32(255, 222, 222, 230) : kSoft, sub);
    return pressed;
}

// One star of the menu along the planet's rim: a glowing dot over its name; Play a glowing yellow pill. True when
// chosen; lights up under the mouse or the controller's cursor (eased).
static bool star_item(const char *id, ImVec2 c, const char *label, bool play, ImFont *f, ImFont *fb, float s) {
    ImFont *ft = play ? fb : f;
    float ls = (play ? fb->FontSize * 1.05f : f->FontSize * 1.0f) * s;
    ImVec2 ts = ft->CalcTextSizeA(ls, FLT_MAX, 0, label);
    ImVec2 sz = play ? ImVec2(ts.x + 110 * s, ts.y + 34 * s) : ImVec2(ts.x + 40 * s, ts.y + 40 * s);
    ImVec2 p(c.x - sz.x * 0.5f, c.y - sz.y * 0.5f);
    ImGui::SetCursorScreenPos(p);
    ImGui::PushStyleColor(ImGuiCol_NavCursor, ImVec4(0, 0, 0, 0));
    bool pressed = ImGui::InvisibleButton(id, sz, ImGuiButtonFlags_EnableNav);
    ImGui::PopStyleColor();
    bool cursor = ImGui::IsItemFocused() && ImGui::GetCurrentContext()->NavCursorVisible;
    bool lit = ImGui::IsItemHovered() || cursor;
    float *hv = ImGui::GetStateStorage()->GetFloatRef(ImGui::GetItemID(), 0);
    *hv += ((lit ? 1.0f : 0.0f) - *hv) * fminf(1, ImGui::GetIO().DeltaTime * 12);
    ImDrawList *dl = ImGui::GetWindowDrawList();
    float t = SDL_GetTicks() / 1000.0f;
    if (play) {
        float pulse = 1 + 0.035f * sinf(t * 3.4f) + 0.05f * *hv, w = sz.x * pulse, h = sz.y * pulse;
        ImVec2 a(c.x - w * 0.5f, c.y - h * 0.5f), b(c.x + w * 0.5f, c.y + h * 0.5f);
        for (int i = 10; i > 0; i--)  // (the glow)
            dl->AddRectFilled(ImVec2(a.x - i * 3 * s, a.y - i * 3 * s), ImVec2(b.x + i * 3 * s, b.y + i * 3 * s),
                              IM_COL32(255, 220, 90, 10 + (int)(8 * *hv)), h * 0.5f + i * 3 * s);
        dl->AddRectFilled(a, b, mix(kPlay, kPlayHot, *hv), h * 0.5f);
        if (cursor) dl->AddRect(ImVec2(a.x - 6 * s, a.y - 6 * s), ImVec2(b.x + 6 * s, b.y + 6 * s), IM_COL32(255, 255, 255, 235),
                                h * 0.5f + 6 * s, 0, 3 * s);
        ImVec2 tp(c.x - ts.x * 0.5f * pulse, c.y - ts.y * 0.5f * pulse);
        dl->AddText(ft, ls * pulse, tp, RGB(26, 31, 61), label);
    } else {
        float dot = (5 + 2.5f * *hv) * s;
        ImVec2 dc(c.x, c.y - ts.y * 0.5f - 12 * s);
        for (int i = 6; i > 0; i--) dl->AddCircleFilled(dc, dot + i * 3 * s, IM_COL32(150, 190, 255, 14 + (int)(14 * *hv)), 24);
        dl->AddCircleFilled(dc, dot, mix(RGB(159, 193, 255), RGB(255, 255, 255), *hv), 24);
        dl->AddText(ft, ls, ImVec2(c.x - ts.x * 0.5f, c.y - ts.y * 0.5f + 6 * s), mix(kSoft, RGB(255, 255, 255), *hv), label);
        if (cursor) dl->AddLine(ImVec2(c.x - ts.x * 0.5f, c.y + ts.y * 0.5f + 12 * s), ImVec2(c.x + ts.x * 0.5f, c.y + ts.y * 0.5f + 12 * s),
                                IM_COL32(255, 255, 255, 220), 2.5f * s);
    }
    return pressed;
}

// ------------------------------------------------------------------ the page (menu.mm, render thread)
static void open_panel(int tab) {
    g_panel = tab;
    g_tab_request_ext = tab;
    menu_tabs_focus_tab(tab);
}

// The Game page: the player's own copy of the game - what is set up, and to change it. Odyssey Recomp ships no game
// files: each player brings Super Mario Odyssey 1.0.0 from their own console (setup copies it in, setup.mm).
static void game_panel_draw(ImFont *f, ImFont *fb, float s) {
    ImGuiIO &io = ImGui::GetIO();
    float w = fminf(io.DisplaySize.x * 0.82f, 1200 * s), h = io.DisplaySize.y - 2 * 30 * s;
    ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(w, h), ImGuiCond_Always);
    static bool opened;
    if (g_frames == 0) ImGui::SetNextWindowFocus(), opened = false;
    ImGui::Begin("##launcher_game", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings);
    ImGui::PushFont(f);
    ImGui::PushTextWrapPos(0);
    ImGui::PushFont(fb);
    ImGui::TextUnformatted("Your game");
    ImGui::PopFont();
    ImGui::Separator();
    ImGui::Spacing();
    // what is set up (looked at once a second at most)
    static uint64_t at;
    static char rom[200], code[200], where[1200];
    uint64_t now = SDL_GetTicks();
    if (!at || now - at > 1000) {
        at = now;
        char p[1200];
        snprintf(p, sizeof p, "%s/romfs.bin", g_root);
        struct stat rst;
        if (stat(p, &rst) == 0) snprintf(rom, sizeof rom, "Super Mario Odyssey 1.0.0 - game data %.1f GB", (double)rst.st_size / 1e9);
        else snprintf(rom, sizeof rom, "Super Mario Odyssey 1.0.0 - game data from its folder (romfs)");
        snprintf(code, sizeof code, "%s", gamelib_present(g_root) ? "Game code built for this version" : "Game code not built for this version");
        snprintf(where, sizeof where, "%s/%s", rt_data_root(), g_root);
    }
    ImGui::TextColored(kAccentSoftV, "%s", rom);
    ImGui::TextColored(kAccentSoftV, "%s", code);
    ImGui::PushStyleColor(ImGuiCol_Text, kTextDimV);
    ImGui::Text("Set up in %s", where);
    ImGui::Spacing();
    ImGui::TextUnformatted("Odyssey Recomp includes no game files: you use your own copy of Super Mario Odyssey 1.0.0, "
                           "dumped from your own Switch. Nothing is uploaded anywhere.");
    ImGui::PopStyleColor();
    ImGui::Dummy(ImVec2(0, 8 * s));
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(26 * s, 10 * s));
    float bw = ImGui::GetContentRegionAvail().x;
    if (ImGui::Button("Choose another game folder", ImVec2(bw, 0))) g_action = ACT_CHANGE;
    if (!opened) { ImGui::SetKeyboardFocusHere(-1); ImGui::SetNavCursorVisible(true); opened = true; }
    ImGui::PushStyleColor(ImGuiCol_Text, kTextDimV);
    ImGui::TextUnformatted("Another dump of the game. The current one stays until the new folder checks out; saves are kept.");
    ImGui::PopStyleColor();
    ImGui::Spacing();
    if (ImGui::Button("Rebuild game code", ImVec2(bw, 0))) g_action = ACT_REBUILD;
    ImGui::PushStyleColor(ImGuiCol_Text, kTextDimV);
    ImGui::TextUnformatted("Builds it again from the files set up (a few minutes).");
    ImGui::PopStyleColor();
    ImGui::Spacing();
    if (ImGui::Button("Open data folder", ImVec2(bw, 0))) g_action = ACT_FOLDER;
    ImGui::PushStyleColor(ImGuiCol_Text, kTextDimV);
    ImGui::TextUnformatted("Saves, mods, settings and the log.");
    ImGui::PopStyleColor();
    ImGui::Spacing();
    bool back = ImGui::Button("Back", ImVec2(bw, 0));
    ImGui::PopStyleVar();
    if (ImGui::IsWindowFocused(ImGuiFocusedFlags_RootAndChildWindows) &&
        (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) || ImGui::IsKeyPressed(ImGuiKey_Escape, false)))
        back = true;
    ImGui::PopTextWrapPos();
    ImGui::PopFont();
    ImGui::End();
    if (back) { g_panel = -2; g_frames = 0; }
}

#ifndef __APPLE__
// The shader loading screen (0.2.6): Play makes the game's shaders ready first (vulkan/device.c: the preparation's own
// process). Over the dimmed launcher: what it's doing, how many, a bar with the percent and the time left. Once after
// an install, an update or a new graphics driver; a few seconds otherwise.
static void loading_draw(ImDrawList *dl, ImVec2 D, ImFont *f, ImFont *fb, float s) {
    int done = 0, total = 0, phase = 0, stage = 0;
    vk_prepare_info(&done, &total, &phase, &stage);
    float fr = fminf(1, fmaxf(0, g_start_frac.load()));
    static Uint64 t0;
    static float fr0;
    if (!t0 || fr < fr0) t0 = SDL_GetTicks(), fr0 = fr;
    dl->AddRectFilled(ImVec2(0, 0), D, IM_COL32(4, 10, 20, 205));
    float w = fminf(D.x - 64 * s, 820 * s), h = 300 * s, x = (D.x - w) * 0.5f, y = (D.y - h) * 0.5f;
    dl->AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), IM_COL32(16, 38, 58, 250), 22 * s);
    dl->AddRect(ImVec2(x, y), ImVec2(x + w, y + h), IM_COL32(120, 200, 230, 70), 22 * s, 0, 2 * s);
    float pad = 40 * s, big = fb->FontSize * 1.05f * s, mid = f->FontSize * 0.8f * s, small = f->FontSize * 0.62f * s;
    // a ring of dots going round
    ImVec2 c(x + pad + 18 * s, y + pad + big * 0.55f);
    float t = SDL_GetTicks() / 1000.0f;
    for (int i = 0; i < 12; i++) {
        float a = t * 5.0f - i * 0.5236f, k = 1.0f - i / 12.0f;
        dl->AddCircleFilled(ImVec2(c.x + cosf(a) * 15 * s, c.y + sinf(a) * 15 * s), (2.0f + 2.2f * k) * s,
                            IM_COL32(150, 220, 245, (int)(60 + 195 * k)));
    }
    dl->AddText(fb, big, ImVec2(x + pad + 52 * s, y + pad), IM_COL32(255, 255, 255, 255), "Getting the shaders ready");
    char what[160], a[24], b[24];
    auto num = [](char *o, int v) {  // 20069 -> "20,069"
        if (v >= 1000) snprintf(o, 24, "%d,%03d", v / 1000, v % 1000);
        else snprintf(o, 24, "%d", v);
    };
    num(a, done), num(b, total);
    if (stage == 1 && phase == 0 && fr < 0.199f)
        snprintf(what, sizeof what, total ? "Reading the game's shaders: %s of %s" : "Reading the game's shaders", a, b);
    else if (stage == 1)
        snprintf(what, sizeof what, total && phase ? "Building them for your graphics card: %s of %s" : "Building them for your graphics card", a, b);
    else if (stage == 2)
        snprintf(what, sizeof what, total ? "Shaders from your last play: %s of %s" : "Shaders from your last play", a, b);
    else snprintf(what, sizeof what, "Starting the game");
    dl->AddText(f, mid, ImVec2(x + pad, y + pad + big + 26 * s), IM_COL32(205, 228, 240, 255), what);
    // the bar
    float by = y + pad + big + 26 * s + mid + 26 * s, bh = 14 * s, bw = w - 2 * pad;
    dl->AddRectFilled(ImVec2(x + pad, by), ImVec2(x + pad + bw, by + bh), IM_COL32(255, 255, 255, 40), bh * 0.5f);
    dl->AddRectFilled(ImVec2(x + pad, by), ImVec2(x + pad + bw * fmaxf(fr, 0.015f), by + bh), IM_COL32(110, 215, 245, 255), bh * 0.5f);
    char pct[64], left[64] = "";
    snprintf(pct, sizeof pct, "%d%%", (int)(fr * 100 + 0.5f));
    float el = (SDL_GetTicks() - t0) / 1000.0f;
    if (fr - fr0 > 0.04f && el > 3) {
        int rem = (int)(el * (1 - fr) / (fr - fr0) + 0.5f);
        if (rem >= 90) snprintf(left, sizeof left, "about %d min left", (rem + 30) / 60);
        else if (rem > 3) snprintf(left, sizeof left, "about %d s left", rem);
    }
    dl->AddText(f, mid, ImVec2(x + pad, by + bh + 14 * s), IM_COL32(255, 255, 255, 255), pct);
    if (left[0]) {
        float lw = f->CalcTextSizeA(small, FLT_MAX, 0, left).x;
        dl->AddText(f, small, ImVec2(x + w - pad - lw, by + bh + 14 * s + (mid - small) * 0.5f), IM_COL32(205, 228, 240, 255), left);
    }
    const char *note = "Only after installing, an update or a new graphics driver. Then the game starts in seconds.";
    float nw = f->CalcTextSizeA(small, FLT_MAX, 0, note).x;
    dl->AddText(f, small, ImVec2(x + (w - nw) * 0.5f, y + h - pad * 0.6f - small), IM_COL32(150, 180, 200, 255), note);
}
#endif

static void panel_draw(ImFont *f, ImFont *fb, float s) {
    ImGuiIO &io = ImGui::GetIO();
    float w = fminf(io.DisplaySize.x - 2 * 28 * s, 1760 * s), h = io.DisplaySize.y - 2 * 28 * s;
    ImGui::SetNextWindowPos(ImVec2(io.DisplaySize.x * 0.5f, io.DisplaySize.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(ImVec2(w, h), ImGuiCond_Always);
    static int opened_for = -3;
    if (opened_for != g_panel) ImGui::SetNextWindowFocus(), opened_for = g_panel;
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(24 * s, 24 * s));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowRounding, 22 * s);
    ImGui::Begin("##launcher_panel", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings);
    ImGui::PopStyleVar(2);
    ImGui::PushFont(f);
    menu_tabs_draw(s, f, fb, false, NULL);  // (menu.mm: the list and the pages, "Back" on top of the list)
    ImGui::PopFont();
    ImGui::End();
    osk_draw(fb, s);
    if (menu_tabs_close_requested()) {
        settings_save();
        g_panel = -2;
        opened_for = -3;
        g_frames = 0;  // (the cursor back on Play)
    }
}

void launcher_draw(float scale, void *font_v, void *font_big_v) {
    ImFont *f = (ImFont *)font_v, *fb = (ImFont *)font_big_v;
    ImGuiIO &io = ImGui::GetIO();
    ImVec2 D = io.DisplaySize;
    float s = scale;
    launcher_backdrop(ImGui::GetBackgroundDrawList(), D, s);
    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(D);
    ImGui::Begin("##launcher", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings |
                                         ImGuiWindowFlags_NoBackground | ImGuiWindowFlags_NoBringToFrontOnFocus);
    ImGui::PushFont(f);
    ImDrawList *dl = ImGui::GetWindowDrawList();
    float m = fmaxf(48 * s, D.x * 0.045f), small = f->FontSize * 0.62f * s;

    // top line: the name (small, spaced) and what's there to play with
    spaced_text(dl, f, small, ImVec2(m, 34 * s), kSoft, "ODYSSEY RECOMP", 3.5f * s);
    {
        int n = 0;
        SDL_JoystickID *ids = SDL_GetGamepads(&n);
        char what[160];
        const char *name = n > 0 ? SDL_GetGamepadNameForID(ids[0]) : NULL;
        if (n > 0) snprintf(what, sizeof what, "%s connected", name && *name ? name : "Controller");
        else snprintf(what, sizeof what, "Keyboard and mouse");
        SDL_free(ids);
        float tw = f->CalcTextSizeA(small, FLT_MAX, 0, what).x, ir = small * 0.55f;
        float x = D.x - m - tw;
        if (n > 0) icon(dl, 2, ImVec2(x - ir * 1.9f, 34 * s + small * 0.5f), ir, kSoft, kSkyTop);
        dl->AddText(f, small, ImVec2(x, 34 * s), kSoft, what);
    }

    // a newer release (runtime/update.c): offered at the top, taken in place
    {
        int us = update_state();
        char lbl[160] = "";
        bool button = false;
        if (us == UPDATE_AVAILABLE) snprintf(lbl, sizeof lbl, "Update %s is out - install it", update_latest()), button = true;
        else if (us == UPDATE_DOWNLOADING) snprintf(lbl, sizeof lbl, update_progress() < 0.5f ? "Downloading update %s... %d MB" : "Unpacking update %s...", update_latest(), update_downloaded_mb());
        else if (us == UPDATE_READY) snprintf(lbl, sizeof lbl, "Update %s ready - restart now", update_latest()), button = true;
        else if (us == UPDATE_FAILED) snprintf(lbl, sizeof lbl, "Update failed: %s - try again", update_error()), button = true;
        if (lbl[0]) {
            ImVec2 ts = f->CalcTextSizeA(small, FLT_MAX, 0, lbl);
            ImVec2 bp(D.x * 0.5f - ts.x * 0.5f - 16 * s, 26 * s), bz(ts.x + 32 * s, ts.y + 16 * s);
            ImGui::SetCursorScreenPos(bp);
            bool clicked = button && ImGui::InvisibleButton("##update", bz, ImGuiButtonFlags_EnableNav);
            if (!button) ImGui::Dummy(bz);
            bool hot = button && (ImGui::IsItemHovered() || (ImGui::IsItemFocused() && ImGui::GetCurrentContext()->NavCursorVisible));
            dl->AddRectFilled(bp, ImVec2(bp.x + bz.x, bp.y + bz.y), button ? (hot ? kPlayHot : kPlay) : kTile, 10 * s);
            dl->AddText(f, small, ImVec2(bp.x + 16 * s, bp.y + 8 * s), IM_COL32(255, 255, 255, 255), lbl);
            if (clicked) g_action = us == UPDATE_READY ? ACT_UPDATE_RESTART : ACT_UPDATE;
        }
    }

    // the logo (or the name), centred over the tiles
    float row_w = fminf(D.x - 2 * m, 1560 * s), gap = 24 * s, th = fminf(D.y * 0.25f, 290 * s);
    float ty = D.y * 0.64f;
    {
        float aspect = 1;
        ImTextureID logo = launcher_logo(&aspect);
        float top = 84 * s, bottom = ty - 44 * s, lh = bottom - top, lw = lh * aspect;
        if (lw > D.x * 0.62f) lw = D.x * 0.62f, lh = lw / aspect;
        float cy = (top + bottom) * 0.5f;
        if (logo) {
            // a soft glow behind it
            for (int i = 0; i < 24; i++)  // (many faint discs: no visible steps)
                dl->AddCircleFilled(ImVec2(D.x * 0.5f, cy), lw * (0.2f + 0.0145f * i), IM_COL32(120, 200, 230, 3), 128);
            // it floats: up and down, turning a little (5.5 s)
            float t = SDL_GetTicks() / 1000.0f * 1.14f, bob = sinf(t) * 9 * s, ang = sinf(t + 1.2f) * 0.021f;
            float ca = cosf(ang), sa = sinf(ang), hx = lw * 0.5f, hy = lh * 0.5f;
            ImVec2 cc(D.x * 0.5f, cy + bob), q[4];
            const float cx4[4] = {-1, 1, 1, -1}, cy4[4] = {-1, -1, 1, 1};
            for (int i = 0; i < 4; i++) q[i] = ImVec2(cc.x + cx4[i] * hx * ca - cy4[i] * hy * sa, cc.y + cx4[i] * hx * sa + cy4[i] * hy * ca);
            dl->AddImageQuad(logo, q[0], q[1], q[2], q[3]);
        } else {
            float big = fb->FontSize * 1.5f * s, sp = 6 * s;
            const char *t = "ODYSSEY RECOMP";
            float w = spaced_width(fb, big, t, sp);
            spaced_text(dl, fb, big, ImVec2((D.x - w) * 0.5f, cy - big * 0.75f), IM_COL32(255, 255, 255, 255), t, sp);
            const char *sub = "Super Mario Odyssey, native on PC";
            float ss = f->FontSize * 0.85f * s, sw = f->CalcTextSizeA(ss, FLT_MAX, 0, sub).x;
            dl->AddText(f, ss, ImVec2((D.x - sw) * 0.5f, cy + big * 0.45f), kSoft, sub);
        }
    }

    // the tiles (behind the settings panel: still drawn, not usable)
    bool panel = g_panel != -2;
    ImGui::PushStyleVar(ImGuiStyleVar_DisabledAlpha, 1.0f);
    bool starting = g_starting.load();
    ImGui::BeginDisabled(panel || starting);
    // the menu: stars along the planet's rim, Play in the middle
    (void)row_w, (void)gap, (void)th;
    float my = D.y * 0.8f, step = fminf(D.x * 0.16f, 300 * s);
    char play_label[16] = "Play";
    if (starting) snprintf(play_label, sizeof play_label, "Starting%.*s", (int)((SDL_GetTicks() / 400) % 4), "...");
    if (star_item("##settings", ImVec2(D.x * 0.5f - step * 1.8f, my), "Settings", false, f, fb, s)) open_panel(0);
    if (star_item("##controls", ImVec2(D.x * 0.5f - step * 0.95f, my), "Controls", false, f, fb, s)) open_panel(8);
    if (star_item("##play", ImVec2(D.x * 0.5f, my), play_label, true, f, fb, s)) g_action = ACT_PLAY;
    if (g_frames < 4 && !panel) {  // the controller's cursor starts on Play
        ImGui::SetFocusID(ImGui::GetItemID(), ImGui::GetCurrentWindow());
        ImGui::SetNavCursorVisible(true);
    }
    if (star_item("##game", ImVec2(D.x * 0.5f + step * 0.95f, my), "Game", false, f, fb, s)) {
        g_panel = PANEL_GAME;
        g_frames = 0;
    }
    if (star_item("##quit", ImVec2(D.x * 0.5f + step * 1.8f, my), "Quit", false, f, fb, s)) g_action = ACT_QUIT;

    // bottom line: what the buttons do, Quit at the right, the notice in the middle
    {
        float y = D.y - 30 * s - small, hx = m;
        // the buttons that select / go back here (menu.mm key_from_pad: the Controls tab's Button layout), in the
        // controller's own names
        int fam = bind_label_family();
        bool names = bind_names_layout();
        int sel = names ? SDL_GAMEPAD_BUTTON_SOUTH : SDL_GAMEPAD_BUTTON_EAST, back = names ? SDL_GAMEPAD_BUTTON_EAST : SDL_GAMEPAD_BUTTON_SOUTH;
        hx = button_hint(dl, f, small, ImVec2(hx, y), bind_pad_label(sel, fam), "Select");
        button_hint(dl, f, small, ImVec2(hx, y), bind_pad_label(back, fam), "Back");
        const char *note = "A fan project, not affiliated with Nintendo";
        float ns = small * 0.85f, nw = f->CalcTextSizeA(ns, FLT_MAX, 0, note).x;
        dl->AddText(f, ns, ImVec2((D.x - nw) * 0.5f, y + (small - ns) * 0.5f), kFaint, note);
        {   // the version, bottom right before Quit (0.2.7): and whether it's the newest
            char ver[96];
            int us = update_state();
            snprintf(ver, sizeof ver, "v%s%s", APP_VERSION,
                     us == UPDATE_READY || us == UPDATE_DOWNLOADING || us == UPDATE_AVAILABLE ? "  -  update on its way"
                     : update_checked() ? "  -  up to date" : "");
            float vs = small * 0.85f, vw = f->CalcTextSizeA(vs, FLT_MAX, 0, ver).x;
            dl->AddText(f, vs, ImVec2(D.x - m - vw, y + (small - vs) * 0.5f), kFaint, ver);
        }
    }
    ImGui::EndDisabled();
    ImGui::PopStyleVar();
    if (panel) dl->AddRectFilled(ImVec2(0, 0), D, IM_COL32(0, 0, 0, 150));
#ifndef __APPLE__
    if (starting) loading_draw(dl, D, f, fb, s);
#endif
    ImGui::PopFont();
    ImGui::End();
    if (panel && g_panel == PANEL_GAME) game_panel_draw(f, fb, s);
    else if (panel) panel_draw(f, fb, s);
    g_frames++;
}

// ------------------------------------------------------------------ the loop (main thread)
static bool wanted(void) {
    if (const char *v = getenv("ODYSSEY_LAUNCHER")) return atoi(v) != 0;
    // scripted test runs go straight to the game (as the window's focus: device.c)
    static const char *const scripted[] = {"ODYSSEY_HIDDEN", "ODYSSEY_INPUT", "ODYSSEY_NO_USER_INPUT", "ODYSSEY_PLACE",
                                           "ODYSSEY_DOORJUMP_TEST", "ODYSSEY_HOST_INPUT", "ODYSSEY_BIND_TEST"};
    for (const char *e : scripted)
        if (getenv(e)) return false;
    return true;
}

static void open_data_folder(void) {
    const char *root = rt_data_root();
    char url[2400];
    size_t k = (size_t)snprintf(url, sizeof url, "file://%s", root[0] == '/' ? "" : "/");
    for (const char *p = root; *p && k + 4 < sizeof url; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '\\') url[k++] = '/';
        else if (c <= ' ' || c == '%' || c == '#' || c == '?' || c >= 0x80) k += (size_t)snprintf(url + k, sizeof url - k, "%%%02X", c);
        else url[k++] = (char)c;
    }
    url[k] = 0;
    if (!SDL_OpenURL(url)) LOG("[launcher] can't open %s: %s\n", url, SDL_GetError());
}

int launcher_run(const char *root) {
    if (!wanted()) return LAUNCH_PLAY;
    snprintf(g_root, sizeof g_root, "%s", root);
    ui_window_init();
    SDL_Window *w = ui_window();
    if (!g_logo) g_logo_tried = false;  // (set up just now: the files are there this time)
    g_frames = 0;
    g_action = ACT_NONE;
    g_panel = -2;
    if (const char *p = getenv("ODYSSEY_LAUNCHER_PANEL")) open_panel(atoi(p));  // (test) a settings page open
    static const char *shot = getenv("ODYSSEY_LAUNCHER_SHOT");  // (test) <frame>: the page as build/launcher.png
    static const char *autoplay = getenv("ODYSSEY_LAUNCHER_PLAY");  // (test) <frame>: Play pressed then
    LOG("[launcher] open\n");
    update_check_start();
    vk_shader_cache_cleanup();  // (0.2.6: cache/spirv -> cache/shaders.pack)
    menu_launcher_mode(true);
    g_in_loop = true;
    // (test) the player's own keys and controller don't reach a scripted run's launcher (as the game: hle/input.c)
    const char *nu = getenv("ODYSSEY_NO_USER_INPUT");
    bool no_user = nu && atoi(nu) != 0;
    long frame = 0;
    for (;;) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_EVENT_QUIT) {
                LOG("[launcher] closed\n");
#ifndef __APPLE__
                if (g_starting.exchange(false)) vk_prepare_cancel();  // (what it prepared stays for the next start)
#endif
                g_in_loop = false;
                menu_launcher_mode(false);
                return LAUNCH_QUIT;
            }
            if (!no_user && !g_starting.load()) menu_handle_event(&e);
        }
        menu_apply_window_requests(w);
        int act = g_action.exchange(ACT_NONE);
        if (autoplay && frame == atol(autoplay)) act = ACT_PLAY;
#ifndef __APPLE__
        // Play: the game's shaders are made ready first (a few seconds; about a minute after an update or a driver
        // change) by a process of its own, while this loop goes on drawing - the window used to stand still meanwhile
        if (g_starting.load()) {
            float fr = 0;
            if (vk_prepare_step(&fr)) break;
            g_start_frac.store(fr);
            act = ACT_NONE;
        } else if (act == ACT_PLAY && vk_prepare_begin()) {
            LOG("[launcher] play: getting the game ready\n");
            settings_save();
            g_panel = -2;
            g_start_frac.store(0);
            g_starting.store(true);
            act = ACT_NONE;
        }
#endif
        if (act == ACT_FOLDER) open_data_folder();
        if (act == ACT_UPDATE) update_install_start();
        if (update_state() == UPDATE_READY && getenv("ODYSSEY_UPDATE_APPLY_TEST")) act = ACT_UPDATE_RESTART;  // (test)
        if (act == ACT_UPDATE_RESTART) { settings_save(); update_apply_and_exit(); }
        if (act == ACT_QUIT) {
            LOG("[launcher] quit\n");
            settings_save();
            g_in_loop = false;
            menu_launcher_mode(false);
            return LAUNCH_QUIT;
        }
        if (act == ACT_CHANGE || act == ACT_REBUILD) {  // (main.c: the setup page, then the launcher again)
            LOG("[launcher] %s\n", act == ACT_CHANGE ? "another game folder" : "rebuild the game code");
            g_panel = -2;
            g_in_loop = false;
            menu_launcher_mode(false);
            return act == ACT_CHANGE ? LAUNCH_CHANGE : LAUNCH_REBUILD;
        }
        if (act == ACT_PLAY) break;
#ifdef __APPLE__
        @autoreleasepool {
            CAMetalLayer *layer = (__bridge CAMetalLayer *)ui_metal_layer();
            id<MTLDevice> dev = (__bridge id<MTLDevice>)ui_metal_device();
            static id<MTLCommandQueue> queue;
            if (!queue) queue = [dev newCommandQueue];
            id<CAMetalDrawable> d = layer ? [layer nextDrawable] : nil;
            if (d) {
                id<MTLCommandBuffer> cb = [queue commandBuffer];
                menu_render(dev, cb, d.texture);
                [cb presentDrawable:d];
                [cb commit];
            } else {
                SDL_Delay(16);
            }
        }
#else
        static const float bg[4] = {7 / 255.0f, 24 / 255.0f, 34 / 255.0f, 1};
        if (vk_frame_begin(bg)) {
            int pw, ph;
            SDL_GetWindowSizeInPixels(w, &pw, &ph);
            menu_render(vk_frame_cmd(), (uint32_t)pw, (uint32_t)ph);
            frame++;
            bool s = shot && frame == atol(shot);
            vk_frame_end(s ? "build/launcher.png" : NULL);
        } else {
            SDL_Delay(16);
        }
#endif
    }
    LOG("[launcher] play\n");
    settings_save();
    g_starting.store(false);
    g_panel = -2;
    g_in_loop = false;
    menu_launcher_mode(false);
    return LAUNCH_PLAY;
}

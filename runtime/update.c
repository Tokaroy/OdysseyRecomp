// Updates from inside the app: the launcher asks GitHub for the latest release of rwwo8/OdysseyRecomp (the public
// releases API: nothing about the player is sent). When it is newer than this program, it is downloaded right away in
// the background (0.2.5: no click needed; ODYSSEY_UPDATE_AUTO=0: only offered) and
// unpacked into update/, and the launcher shows "Update ready - restart now": taking it hands over to a small script
// that waits for this program to end, copies the new program files over the old ones and starts the new version. The
// release holds program files only (never saves, settings, mods, the game's files or the game code), so save/,
// odyssey.ini, mods/, extracted/ and cache/ stay as they are; the new version builds its game code again on its first
// start if it has to, as after any update. Windows: the release's -windows.zip with Windows' own curl.exe / tar.exe;
// Linux (0.2.5): the -linux-x86_64.tar.gz with the system's curl and tar, into the folder OdysseyRecomp.sh is in. Not
// in a source checkout (rt_dev_mode) or a test run. ODYSSEY_UPDATE_CHECK=0: never asks; ODYSSEY_UPDATE_TAG=<tag> (and
// ODYSSEY_UPDATE_URL=<archive>): pretend that's the latest.
#include "update.h"

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "paths.h"
#include "platform.h"
#include "rt.h"
#include "version.h"

#if defined(_WIN32) || defined(__linux__)
#ifdef _WIN32
#include <windows.h>
#include <direct.h>
#define MKDIR(p) _mkdir(p)
#define ASSET_SUFFIX "-windows.zip"
#define ARCHIVE "update/new.zip"
#define PROGRAM_IN_ARCHIVE "update/new/Odyssey Recomp/OdysseyRecomp.exe"
static void sleep_ms(int ms) { Sleep((DWORD)ms); }
#else
#include <signal.h>
#include <unistd.h>
#define MKDIR(p) mkdir(p, 0755)
#define ASSET_SUFFIX "-linux-x86_64.tar.gz"
#define ARCHIVE "update/new.tar.gz"
#define PROGRAM_IN_ARCHIVE "update/new/Odyssey Recomp/usr/bin/OdysseyRecomp"
static void sleep_ms(int ms) { usleep((useconds_t)ms * 1000); }
#endif

#define RELEASES_API "https://api.github.com/repos/rwwo8/OdysseyRecomp/releases/latest"

static _Atomic int g_state;  // UPDATE_*
static char g_tag[64], g_url[1024], g_error[200];
static _Atomic float g_frac;

int update_state(void) { return atomic_load(&g_state); }
const char *update_latest(void) { return g_tag; }
const char *update_error(void) { return g_error; }
float update_progress(void) { return atomic_load(&g_frac); }
int update_downloaded_mb(void) {  // (UPDATE_DOWNLOADING: how much of the archive is there)
    struct stat st;
    return stat(ARCHIVE, &st) == 0 ? (int)(st.st_size >> 20) : 0;
}

// "0.2.10" > "0.2.9": the numbers compared one by one
static int version_cmp(const char *a, const char *b) {
    for (int part = 0; part < 8; part++) {
        long x = 0, y = 0;
        while (*a >= '0' && *a <= '9') x = x * 10 + (*a++ - '0');
        while (*b >= '0' && *b <= '9') y = y * 10 + (*b++ - '0');
        if (x != y) return x < y ? -1 : 1;
        if (*a != '.' && *b != '.') break;
        if (*a == '.') a++;
        if (*b == '.') b++;
    }
    return 0;
}

// the system's own curl / tar (Windows: System32's, Windows 10 1803 and later; Linux: on the PATH)
static const char *sys_tool(const char *name) {
#ifdef _WIN32
    static char buf[4][MAX_PATH + 32];
    static int k;
    char *b = buf[k++ & 3];
    UINT n = GetSystemDirectoryA(b, MAX_PATH);
    if (!n || n >= MAX_PATH) return name;
    snprintf(b + n, sizeof buf[0] - n, "\\%s.exe", name);
    return b;
#else
    return name;
#endif
}

static bool run_wait(const char *const argv[], const char *log, int timeout_s) {
    PlatProc p = plat_spawn(argv, log, false);
    if (!p) return false;
    for (int i = 0; i < timeout_s * 20; i++) {
        int c = plat_proc_wait(p, false);
        if (c >= 0) return c == 0;
        sleep_ms(50);
    }
    plat_proc_kill(p);
    return false;
}

static char *read_file(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *s = n > 0 && n < (8 << 20) ? malloc((size_t)n + 1) : NULL;
    if (s && fread(s, 1, (size_t)n, f) == (size_t)n) s[n] = 0;
    else { free(s); s = NULL; }
    fclose(f);
    return s;
}

// the string value after "key": in a JSON text, from `from` on (no escapes in what we look for: tags and URLs)
static bool json_str(const char *from, const char *key, char *out, size_t n, const char **end) {
    char k[64];
    snprintf(k, sizeof k, "\"%s\"", key);
    const char *p = strstr(from, k);
    if (!p) return false;
    p = strchr(p + strlen(k), ':');
    if (!p) return false;
    p = strchr(p, '"');
    if (!p) return false;
    const char *q = strchr(p + 1, '"');
    if (!q || (size_t)(q - p - 1) >= n) return false;
    memcpy(out, p + 1, (size_t)(q - p - 1));
    out[q - p - 1] = 0;
    if (end) *end = q + 1;
    return true;
}

static bool auto_download(void) {
    const char *e = getenv("ODYSSEY_UPDATE_AUTO");
    return !e || atoi(e) != 0;
}

static void *check_thread(void *a) {
    (void)a;
    MKDIR("update");
    const char *fake = getenv("ODYSSEY_UPDATE_TAG");
    if (fake && *fake) {
        snprintf(g_tag, sizeof g_tag, "%s", fake);
        snprintf(g_url, sizeof g_url, "%s", getenv("ODYSSEY_UPDATE_URL") ? getenv("ODYSSEY_UPDATE_URL") : "");
    } else {
        const char *argv[] = {sys_tool("curl"), "-s", "-L", "-m", "15", "-H", "Accept: application/vnd.github+json", "-o",
                              "update/latest.json", RELEASES_API, NULL};
        if (!run_wait(argv, "update/check.log", 20)) { atomic_store(&g_state, UPDATE_NONE); return NULL; }
        char *j = read_file("update/latest.json");
        remove("update/latest.json");
        if (!j) { atomic_store(&g_state, UPDATE_NONE); return NULL; }
        bool ok = json_str(j, "tag_name", g_tag, sizeof g_tag, NULL);
        g_url[0] = 0;
        size_t sl = strlen(ASSET_SUFFIX);
        for (const char *p = j; ok && json_str(p, "browser_download_url", g_url, sizeof g_url, &p);) {
            size_t n = strlen(g_url);
            if (n > sl && !strcmp(g_url + n - sl, ASSET_SUFFIX)) break;
            g_url[0] = 0;
        }
        free(j);
        if (!ok || !g_url[0]) { atomic_store(&g_state, UPDATE_NONE); return NULL; }
    }
    const char *t = g_tag[0] == 'v' ? g_tag + 1 : g_tag;
    bool newer = version_cmp(t, APP_VERSION) > 0;
    LOG("[update] latest release %s, this is %s%s\n", g_tag, APP_VERSION, newer ? ": an update is there" : "");
    atomic_store(&g_state, newer && g_url[0] ? UPDATE_AVAILABLE : UPDATE_NONE);
    if (atomic_load(&g_state) == UPDATE_AVAILABLE && (auto_download() || getenv("ODYSSEY_UPDATE_INSTALL_TEST")))
        update_install_start();  // (downloaded right away: the player only restarts)
    return NULL;
}

void update_check_start(void) {
    static bool started;
    if (started) return;
    started = true;
    const char *e = getenv("ODYSSEY_UPDATE_CHECK");
    if ((e && !atoi(e)) || rt_dev_mode() || ((getenv("ODYSSEY_HIDDEN") || getenv("ODYSSEY_INPUT")) && !getenv("ODYSSEY_UPDATE_TAG"))) return;
    atomic_store(&g_state, UPDATE_CHECKING);
    pthread_t th;
    if (pthread_create(&th, NULL, check_thread, NULL) == 0) pthread_detach(th);
    else atomic_store(&g_state, UPDATE_NONE);
}

static void fail(const char *why) {
    snprintf(g_error, sizeof g_error, "%s", why);
    LOG("[update] failed: %s\n", why);
    atomic_store(&g_state, UPDATE_FAILED);
}

// The folder the release's files go into: Windows, the exe's; Linux, the one OdysseyRecomp.sh is in (the exe is in
// its usr/bin)
static bool install_dir(char *exe, size_t en, char *dir, size_t dn) {
    if (!plat_exe_path(exe, en)) return false;
    snprintf(dir, dn, "%s", exe);
    for (int up = 0; up < (
#ifdef _WIN32
                               1
#else
                               3
#endif
                           ); up++) {
        char *sl = strrchr(dir, '\\'), *fs = strrchr(dir, '/');
        if (fs > sl) sl = fs;
        if (!sl) return false;
        *sl = 0;
    }
    return true;
}

static void *install_thread(void *a) {
    (void)a;
    char exe[1100], dir[1100];
    if (!install_dir(exe, sizeof exe, dir, sizeof dir)) { fail("This program's folder wasn't found"); return NULL; }
    MKDIR("update");
    remove(ARCHIVE);
    atomic_store(&g_frac, 0.05f);
    LOG("[update] downloading %s\n", g_url);
    const char *dl[] = {sys_tool("curl"), "-s", "-L", "--fail", "-m", "1800", "-o", ARCHIVE, g_url, NULL};
    if (!run_wait(dl, "update/download.log", 1860)) { fail("The download didn't finish (no connection?)"); return NULL; }
    struct stat st;
    if (stat(ARCHIVE, &st) != 0 || st.st_size < (1 << 20)) { fail("The download is incomplete"); return NULL; }
    atomic_store(&g_frac, 0.8f);
    plat_remove_tree("update/new");
    MKDIR("update/new");
    const char *ux[] = {sys_tool("tar"), "-xf", ARCHIVE, "-C", "update/new", NULL};
    if (!run_wait(ux, "update/unpack.log", 600)) { fail("The download couldn't be unpacked"); return NULL; }
    if (stat(PROGRAM_IN_ARCHIVE, &st) != 0) { fail("The download holds no program"); return NULL; }
    atomic_store(&g_frac, 0.95f);
    // the hand-over: wait for this process to end, copy the new files over (only what the release has), start it
    char root[1100];
    snprintf(root, sizeof root, "%s", rt_data_root());
#ifdef _WIN32
    FILE *f = fopen("update/apply.cmd", "w");
    if (!f) { fail("update/apply.cmd couldn't be written"); return NULL; }
    fprintf(f, "@echo off\r\n:wait\r\ntasklist /FI \"PID eq %lu\" 2>nul | find \"%lu\" >nul && (ping -n 2 127.0.0.1 >nul & goto wait)\r\n",
            GetCurrentProcessId(), GetCurrentProcessId());
    fprintf(f, "robocopy \"%s\\update\\new\\Odyssey Recomp\" \"%s\" /E /R:5 /W:1 /NFL /NDL /NJH /NJS /NP >\"%s\\update\\apply.log\"\r\n",
            root, dir, root);
    fprintf(f, "start \"\" \"%s\"\r\n", exe);
    fprintf(f, "rmdir /s /q \"%s\\update\\new\" & del \"%s\\update\\new.zip\"\r\n", root, root);
#else
    FILE *f = fopen("update/apply.sh", "w");
    if (!f) { fail("update/apply.sh couldn't be written"); return NULL; }
    fprintf(f, "#!/bin/sh\nwhile kill -0 %d 2>/dev/null; do sleep 1; done\n", (int)getpid());
    fprintf(f, "cp -a \"%s/update/new/Odyssey Recomp/.\" \"%s/\" > \"%s/update/apply.log\" 2>&1\n", root, dir, root);
    fprintf(f, "rm -rf \"%s/update/new\" \"%s/%s\"\nexec \"%s/OdysseyRecomp.sh\"\n", root, root, ARCHIVE, dir);
#endif
    fclose(f);
    atomic_store(&g_frac, 1);
    atomic_store(&g_state, UPDATE_READY);
    return NULL;
}

void update_install_start(void) {
    int s = atomic_load(&g_state);
    if (s != UPDATE_AVAILABLE && s != UPDATE_FAILED) return;
    atomic_store(&g_state, UPDATE_DOWNLOADING);
    g_error[0] = 0;
    pthread_t th;
    if (pthread_create(&th, NULL, install_thread, NULL) == 0) pthread_detach(th);
    else fail("couldn't start");
}

void update_apply_and_exit(void) {
    if (atomic_load(&g_state) != UPDATE_READY) return;
    LOG("[update] installing %s: this program ends, the new one starts\n", g_tag);
#ifdef _WIN32
    // (not through plat_spawn: its children end with this process - the job object - and this one must outlive it)
    wchar_t cmd[1400];
    char c8[1300];
    snprintf(c8, sizeof c8, "cmd.exe /c \"\"%s\\update\\apply.cmd\"\"", rt_data_root());
    MultiByteToWideChar(CP_UTF8, 0, c8, -1, cmd, 1400);
    STARTUPINFOW si = {.cb = sizeof si};
    PROCESS_INFORMATION pi;
    BOOL ok = CreateProcessW(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW | CREATE_BREAKAWAY_FROM_JOB | CREATE_NEW_PROCESS_GROUP,
                             NULL, NULL, &si, &pi);
    if (!ok) ok = CreateProcessW(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP, NULL, NULL, &si, &pi);
    if (!ok) { fail("The installer didn't start"); return; }
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
#else
    char script[1200];
    snprintf(script, sizeof script, "%s/update/apply.sh", rt_data_root());
    pid_t pid = fork();
    if (pid < 0) { fail("The installer didn't start"); return; }
    if (pid == 0) {  // (its own session: it outlives this process)
        setsid();
        execl("/bin/sh", "sh", script, (char *)NULL);
        _exit(127);
    }
#endif
    plat_terminate();
}

#else  // (macOS: updates come with the app as before)
int update_state(void) { return UPDATE_NONE; }
const char *update_latest(void) { return ""; }
const char *update_error(void) { return ""; }
float update_progress(void) { return 0; }
int update_downloaded_mb(void) { return 0; }
void update_check_start(void) {}
void update_install_start(void) {}
void update_apply_and_exit(void) {}
#endif

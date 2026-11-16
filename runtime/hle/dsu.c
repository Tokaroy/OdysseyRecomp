// Motion from a DSU server (the "cemuhook" protocol, 0.2.6 - GitHub #21): tools like sc2dsu (Steam Controller),
// BetterJoy, DS4Windows and DSU servers for phones send a controller's gyro and accelerometer over UDP, as Switch
// emulators read them. This asks the server (odyssey.ini dsu_server, 127.0.0.1:26760 by default; dsu = 0: off) for its
// pads' data every 2 s and keeps the newest sample of slot 0; runtime/hle/input.c uses it when the controller in use
// reports no gyro of its own (an Xbox-type pad as Steam Input shows the Steam Controller, the keyboard).
// Packet layout (cemuhook): a 16-byte header {"DSUC"/"DSUS", u16 version 1001, u16 length after the header, u32 crc32
// of the packet with this field 0, u32 id}, then u32 message type. Pad data (0x100002) answers: slot at +20, its state
// at +21 (2: connected), the motion timestamp (us) at +68, accelerometer x y z (g) at +76, gyro pitch yaw roll (deg/s)
// at +88. Axes into the Switch's as Switch emulators map them.
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
typedef SOCKET sock_t;
#define SOCK_BAD INVALID_SOCKET
#else
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
typedef int sock_t;
#define SOCK_BAD (-1)
#define closesocket close
#endif

#include "../platform.h"
#include "../rt.h"
#include "../settings.h"

static pthread_mutex_t dsu_lock = PTHREAD_MUTEX_INITIALIZER;
static float dsu_acc[3], dsu_gyro[3];
static uint64_t dsu_when;  // (plat_now_ns of the newest sample; 0: none yet)

static uint32_t crc32_of(const uint8_t *p, size_t n) {
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) {
        c ^= p[i];
        for (int k = 0; k < 8; k++) c = c >> 1 ^ (0xEDB88320u & (0u - (c & 1)));
    }
    return ~c;
}

static void put16(uint8_t *p, uint16_t v) { memcpy(p, &v, 2); }
static void put32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }
static float getf(const uint8_t *p) { float v; memcpy(&v, p, 4); return v; }

static void *dsu_thread(void *a) {
    (void)a;
#ifdef _WIN32
    WSADATA wd;
    if (WSAStartup(MAKEWORD(2, 2), &wd) != 0) return NULL;
#endif
    char host[64] = "127.0.0.1";
    int port = 26760;
    const char *cfg = g_settings.dsu_server[0] ? g_settings.dsu_server : "127.0.0.1:26760";
    sscanf(cfg, "%63[^:]:%d", host, &port);
    sock_t s = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (s == SOCK_BAD) return NULL;
    struct sockaddr_in to = {0};
    to.sin_family = AF_INET;
    to.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, host, &to.sin_addr) != 1) { closesocket(s); return NULL; }
#ifdef _WIN32
    DWORD tmo = 500;
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, (const char *)&tmo, sizeof tmo);
#else
    struct timeval tv = {0, 500000};
    setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
#endif
    uint32_t id = (uint32_t)plat_now_ns();
    uint64_t asked = 0;
    bool told = false;
    for (;;) {
        uint64_t now = plat_now_ns();
        if (now - asked > 2000000000ull) {  // (servers forget a client after ~5 s without a request)
            uint8_t q[28] = {'D', 'S', 'U', 'C'};
            put16(q + 4, 1001), put16(q + 6, sizeof q - 16), put32(q + 12, id), put32(q + 16, 0x100002);
            q[20] = 0;  // (flags 0: every pad)
            put32(q + 8, crc32_of(q, sizeof q));
            sendto(s, (const char *)q, sizeof q, 0, (struct sockaddr *)&to, sizeof to);
            asked = now;
        }
        uint8_t b[256];
        int n = (int)recv(s, (char *)b, sizeof b, 0);
        if (n < 100 || memcmp(b, "DSUS", 4)) continue;
        uint32_t type, crc;
        memcpy(&type, b + 16, 4), memcpy(&crc, b + 8, 4);
        put32(b + 8, 0);
        if (type != 0x100002 || crc32_of(b, (size_t)n) != crc || b[20] != 0 || b[21] != 2) continue;
        float ax = getf(b + 76), ay = getf(b + 80), az = getf(b + 84);
        float gp = getf(b + 88), gy = getf(b + 92), gr = getf(b + 96);
        pthread_mutex_lock(&dsu_lock);
        dsu_acc[0] = ax, dsu_acc[1] = -az, dsu_acc[2] = ay;  // (g, Switch axes)
        dsu_gyro[0] = gp / 360.0f, dsu_gyro[1] = -gr / 360.0f, dsu_gyro[2] = gy / 360.0f;  // (turns/s)
        dsu_when = plat_now_ns();
        pthread_mutex_unlock(&dsu_lock);
        if (!told) { told = true; LOG("[input] motion from the DSU server at %s:%d\n", host, port); }
    }
    return NULL;
}

void dsu_start(void) {
    static bool started;
    if (started || !g_settings.dsu) return;
    started = true;
    pthread_t t;
    if (pthread_create(&t, NULL, dsu_thread, NULL) == 0) pthread_detach(t);
}

// The newest sample when it's fresh (under 100 ms old): Switch axes, accelerometer in g, gyro in turns per second
bool dsu_motion(float acc[3], float gyro[3]) {
    pthread_mutex_lock(&dsu_lock);
    bool ok = dsu_when && plat_now_ns() - dsu_when < 100000000ull;
    if (ok) memcpy(acc, dsu_acc, sizeof dsu_acc), memcpy(gyro, dsu_gyro, sizeof dsu_gyro);
    pthread_mutex_unlock(&dsu_lock);
    return ok;
}

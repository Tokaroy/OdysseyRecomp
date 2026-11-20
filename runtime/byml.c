// BYML reading (byml.h). Layout (little endian): "YB", version (2-3), the key table's offset, the string table's,
// the root node's. A table (0xC2): its count in the low 24 bits after the type byte, then that many offsets from the
// table's start. A dictionary (0xC1): count, then 8 bytes an entry - key index (24 bits), type, value - sorted by key.
// An array (0xC0): count, the types (a byte each, padded to 4), then the values (4 bytes each).
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "byml.h"
#include "romfs_read.h"

static uint32_t rd32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

static bool in(const Byml *b, uint64_t off, uint64_t len) { return off + len <= b->n; }

bool byml_open(Byml *b, const uint8_t *d, size_t n) {
    memset(b, 0, sizeof *b);
    if (!d || n < 16 || d[0] != 'Y' || d[1] != 'B') return false;
    b->d = d, b->n = n;
    b->keys = rd32(d + 4), b->strs = rd32(d + 8), b->root = rd32(d + 12);
    return in(b, b->root, 4) && (!b->keys || in(b, b->keys, 4)) && (!b->strs || in(b, b->strs, 4));
}

static const char *table_str(const Byml *b, uint32_t table, uint32_t i) {
    if (!table || !in(b, table, 4) || b->d[table] != 0xC2) return NULL;
    uint32_t cnt = rd32(b->d + table) >> 8;
    if (i >= cnt || !in(b, table + 4 + 4ull * i, 4)) return NULL;
    uint32_t off = table + rd32(b->d + table + 4 + 4 * i);
    if (off >= b->n || !memchr(b->d + off, 0, b->n - off)) return NULL;
    return (const char *)b->d + off;
}

const char *byml_string(const Byml *b, uint32_t index) { return table_str(b, b->strs, index); }

int byml_count(const Byml *b, uint32_t node) {
    if (!in(b, node, 4) || (b->d[node] != BYML_ARRAY && b->d[node] != BYML_DICT)) return -1;
    return (int)(rd32(b->d + node) >> 8);
}

bool byml_at(const Byml *b, uint32_t array, int i, uint8_t *type, uint32_t *val) {
    int n = byml_count(b, array);
    if (n < 0 || b->d[array] != BYML_ARRAY || i < 0 || i >= n) return false;
    uint64_t vals = array + 4 + (((uint64_t)n + 3) & ~3ull);
    if (!in(b, vals + 4ull * i, 4)) return false;
    *type = b->d[array + 4 + i];
    *val = rd32(b->d + vals + 4ull * i);
    return true;
}

bool byml_get(const Byml *b, uint32_t dict, const char *key, uint8_t *type, uint32_t *val) {
    int n = byml_count(b, dict);
    if (n < 0 || b->d[dict] != BYML_DICT || !in(b, dict + 4, 8ull * n)) return false;
    for (int i = 0; i < n; i++) {  // (sorted, but tables here are small: a scan)
        const uint8_t *e = b->d + dict + 4 + 8 * i;
        const char *k = table_str(b, b->keys, rd32(e) & 0xFFFFFF);
        if (k && !strcmp(k, key)) {
            *type = e[3];
            *val = rd32(e + 4);
            return true;
        }
    }
    return false;
}

const char *byml_get_str(const Byml *b, uint32_t dict, const char *key) {
    uint8_t t;
    uint32_t v;
    return byml_get(b, dict, key, &t, &v) && t == BYML_STRING ? byml_string(b, v) : NULL;
}

bool byml_get_bool(const Byml *b, uint32_t dict, const char *key, bool dflt) {
    uint8_t t;
    uint32_t v;
    return byml_get(b, dict, key, &t, &v) && t == BYML_BOOL ? v != 0 : dflt;
}

static uint8_t *read_loose(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *d = sz > 0 && sz < (64 << 20) ? malloc((size_t)sz) : NULL;
    if (d && fread(d, 1, (size_t)sz, f) != (size_t)sz) free(d), d = NULL;
    fclose(f);
    if (d) *n = (size_t)sz;
    return d;
}

uint8_t *game_file_read(const char *path, size_t *n) {
    uint8_t *d = romfs_read_file("extracted/romfs.bin", path, n);
    if (d) return d;
    char p[1100];
    snprintf(p, sizeof p, "extracted/romfs/%s", path);  // (a source checkout before its RomFS image is made)
    return read_loose(p, n);
}

uint8_t *game_szs_member(const char *szs_path, const char *member, size_t *n) {
    size_t zn = 0, dn = 0, mn = 0;
    uint8_t *z = game_file_read(szs_path, &zn);
    if (!z) return NULL;
    uint8_t *d = yaz0_decode(z, zn, &dn);
    free(z);
    if (!d) return NULL;
    const uint8_t *m = sarc_find(d, dn, member, &mn);
    uint8_t *out = m ? malloc(mn ? mn : 1) : NULL;
    if (out) memcpy(out, m, mn), *n = mn;
    free(d);
    return out;
}

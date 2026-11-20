#pragma once
// Reading Nintendo's BYML data (version 2-3, little endian: the game's SystemData tables) on the host, in place.
// A node is its offset in the data; values come as (type, raw 32 bits): strings are indices into the string table.
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

enum { BYML_STRING = 0xA0, BYML_ARRAY = 0xC0, BYML_DICT = 0xC1, BYML_BOOL = 0xD0, BYML_INT = 0xD1, BYML_FLOAT = 0xD2,
       BYML_UINT = 0xD3 };

typedef struct {
    const uint8_t *d;
    size_t n;
    uint32_t keys, strs, root;  // (offsets; 0: none)
} Byml;

bool byml_open(Byml *b, const uint8_t *d, size_t n);
int byml_count(const Byml *b, uint32_t node);                                            // -1: not a container
bool byml_at(const Byml *b, uint32_t array, int i, uint8_t *type, uint32_t *val);         // an array's i-th value
bool byml_get(const Byml *b, uint32_t dict, const char *key, uint8_t *type, uint32_t *val);  // a dictionary's value
const char *byml_string(const Byml *b, uint32_t index);                                  // NULL: out of range
// conveniences: a dictionary's string / bool (dflt when missing or of another type)
const char *byml_get_str(const Byml *b, uint32_t dict, const char *key);
bool byml_get_bool(const Byml *b, uint32_t dict, const char *key, bool dflt);

// A file of the game's RomFS (extracted/romfs.bin, else the extracted/romfs folder), and inside it, when it is a
// Yaz0-compressed SARC (.szs), the named file. malloc'd; NULL: not there.
uint8_t *game_file_read(const char *path, size_t *n);
uint8_t *game_szs_member(const char *szs_path, const char *member, size_t *n);

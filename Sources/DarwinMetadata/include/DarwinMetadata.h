#ifndef DARWIN_METADATA_H
#define DARWIN_METADATA_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    uint32_t offset;
    uint32_t parent;
    int64_t size;
    int64_t modified;
} DMRecord;

typedef struct {
    uint32_t denied, disappeared, pending, other_mount, fallback;
} DMCounts;

typedef void (*DMEntryCallback)(void *, const uint8_t *, size_t, int64_t, int64_t, uint32_t, uint32_t);
int dm_list(const char *path, int32_t device_a, int32_t device_b, bool ordinary,
            DMEntryCallback callback, void *context, DMCounts *counts);
uint64_t dm_resident_bytes(void);

typedef struct {
    const DMRecord *rows;
    const uint8_t *attributes;
    const uint8_t *names;
    const uint8_t *folded_names;
    const uint32_t *fold_offsets;
    const uint32_t *fold_rows;
    size_t row_count, name_bytes, fold_bytes, fold_count;
} DMQueryView;

int dm_key_class(const uint8_t *name, size_t length);
bool dm_order(const DMQueryView *view, uint32_t *by_name, uint32_t *by_path,
              uint32_t *by_size, uint32_t *by_modified);
size_t dm_query(const DMQueryView *view, const uint32_t *order,
                const uint8_t *patterns, const uint32_t *word_offsets, size_t words,
                bool path, bool descending, bool show_all, size_t offset,
                size_t limit, uint32_t *results);

#endif

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
    int32_t directory_error;
} DMCounts;

typedef void (*DMEntryCallback)(void *, const uint8_t *, size_t, int64_t, int64_t, uint32_t, uint32_t);
typedef void (*DMDeniedEntryCallback)(void *, const uint8_t *, size_t, int32_t);
int dm_list(const char *path, int32_t device_a, int32_t device_b, bool ordinary,
            DMEntryCallback callback, DMDeniedEntryCallback denied, void *context, DMCounts *counts);
int dm_list_cloud(const char *path, int32_t device, DMEntryCallback callback,
                  DMDeniedEntryCallback denied, void *context, DMCounts *counts);
bool dm_volume_uuid(const char *path, char output[37]);
uint64_t dm_resident_bytes(void);
typedef struct {
    uint64_t footprint, footprint_peak, written_bytes, heap_used, heap_reserved;
    bool available;
} DMProcessMetrics;
DMProcessMetrics dm_process_metrics(void);
void dm_release_allocator_cache(void);
uint32_t dm_directory_candidate(const DMRecord *records, const uint8_t *attributes,
                                const uint8_t *names, size_t count, uint32_t start,
                                const char *leaf, const char *path);
typedef struct { uint32_t start, end, next; } DMChildRun;
uint32_t dm_child_lookup(const DMRecord *records, const uint8_t *attributes,
                         const uint8_t *names, const DMChildRun *runs, uint32_t first,
                         const char *leaf, bool directories_only);

typedef struct {
    const DMRecord *rows;
    const uint8_t *attributes;
    const uint8_t *names;
    const uint8_t *folded_names;
    const uint32_t *fold_offsets;
    const uint32_t *fold_rows;
    const uint8_t *suppressed_rows;
    size_t row_count, name_bytes, fold_bytes, fold_count;
} DMQueryView;

bool dm_has_non_ascii(const uint8_t *name, size_t length);
void dm_name_order(const DMQueryView *view, uint32_t *order);
bool dm_column_order(const DMQueryView *view, uint32_t *order, int column);
size_t dm_query(const DMQueryView *view, const uint32_t *order,
                const uint8_t *patterns, const uint32_t *word_offsets, size_t words,
                bool path, bool descending, bool show_all, size_t offset,
                size_t limit, uint32_t *results);

#endif

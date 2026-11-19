#include "DarwinMetadata.h"
#include <arm_neon.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <string.h>

static atomic_uint query_workers;

bool dm_try_query_worker(void) {
    unsigned used = atomic_load_explicit(&query_workers, memory_order_relaxed);
    while (used < 3) {
        if (atomic_compare_exchange_weak_explicit(&query_workers, &used, used + 1,
                                                  memory_order_relaxed, memory_order_relaxed)) return true;
    }
    return false;
}

void dm_release_query_worker(void) {
    atomic_fetch_sub_explicit(&query_workers, 1, memory_order_relaxed);
}

static void *scratch_map(size_t size) {
    void *ptr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    return ptr == MAP_FAILED ? NULL : ptr;
}

static void scratch_release(void *ptr, size_t size) {
    if (ptr) munmap(ptr, size);
}

enum { KIND_MASK = 3, ANCHOR = 0, DIRECTORY = 2, HIDDEN = 4, EXCLUDED = 16 | 32 };

static const char *original(const DMQueryView *v, uint32_t id) {
    return (const char *)v->names + v->rows[id].offset;
}

uint8_t dm_file_kind(const char *name, uint8_t attribute) {
    // Keep the sorted suffix list and the acceptance document in sync.
    static const struct { const char *suffix; uint8_t kind; } formats[] = {
        {"3fr", DM_KIND_IMAGE}, {"3gp", DM_KIND_VIDEO}, {"7z", DM_KIND_ARCHIVE},
        {"aac", DM_KIND_AUDIO}, {"aif", DM_KIND_AUDIO}, {"aiff", DM_KIND_AUDIO},
        {"alac", DM_KIND_AUDIO}, {"arw", DM_KIND_IMAGE}, {"avi", DM_KIND_VIDEO},
        {"avif", DM_KIND_IMAGE}, {"bmp", DM_KIND_IMAGE}, {"bz2", DM_KIND_ARCHIVE},
        {"cr2", DM_KIND_IMAGE}, {"cr3", DM_KIND_IMAGE}, {"csv", DM_KIND_DOCUMENT},
        {"dmg", DM_KIND_ARCHIVE}, {"dng", DM_KIND_IMAGE}, {"doc", DM_KIND_DOCUMENT},
        {"docm", DM_KIND_DOCUMENT}, {"docx", DM_KIND_DOCUMENT}, {"dps", DM_KIND_DOCUMENT},
        {"epub", DM_KIND_DOCUMENT}, {"et", DM_KIND_DOCUMENT}, {"flac", DM_KIND_AUDIO},
        {"flv", DM_KIND_VIDEO}, {"gif", DM_KIND_IMAGE}, {"gz", DM_KIND_ARCHIVE},
        {"heic", DM_KIND_IMAGE}, {"heif", DM_KIND_IMAGE}, {"icns", DM_KIND_IMAGE},
        {"ico", DM_KIND_IMAGE}, {"iso", DM_KIND_ARCHIVE}, {"j2k", DM_KIND_IMAGE},
        {"jp2", DM_KIND_IMAGE}, {"jpeg", DM_KIND_IMAGE}, {"jpg", DM_KIND_IMAGE},
        {"key", DM_KIND_DOCUMENT}, {"m2ts", DM_KIND_VIDEO}, {"m4a", DM_KIND_AUDIO},
        {"m4v", DM_KIND_VIDEO}, {"md", DM_KIND_DOCUMENT}, {"mid", DM_KIND_AUDIO},
        {"midi", DM_KIND_AUDIO}, {"mkv", DM_KIND_VIDEO}, {"mov", DM_KIND_VIDEO},
        {"mp3", DM_KIND_AUDIO}, {"mp4", DM_KIND_VIDEO}, {"mpeg", DM_KIND_VIDEO},
        {"mpg", DM_KIND_VIDEO}, {"mts", DM_KIND_VIDEO}, {"nef", DM_KIND_IMAGE},
        {"nrw", DM_KIND_IMAGE}, {"numbers", DM_KIND_DOCUMENT}, {"odp", DM_KIND_DOCUMENT},
        {"ods", DM_KIND_DOCUMENT}, {"odt", DM_KIND_DOCUMENT}, {"ogg", DM_KIND_AUDIO},
        {"opus", DM_KIND_AUDIO}, {"orf", DM_KIND_IMAGE}, {"pages", DM_KIND_DOCUMENT},
        {"pdf", DM_KIND_DOCUMENT}, {"pef", DM_KIND_IMAGE}, {"png", DM_KIND_IMAGE},
        {"ppt", DM_KIND_DOCUMENT}, {"pptm", DM_KIND_DOCUMENT}, {"pptx", DM_KIND_DOCUMENT},
        {"psd", DM_KIND_IMAGE}, {"raf", DM_KIND_IMAGE}, {"rar", DM_KIND_ARCHIVE},
        {"raw", DM_KIND_IMAGE}, {"rtf", DM_KIND_DOCUMENT}, {"rw2", DM_KIND_IMAGE},
        {"srf", DM_KIND_IMAGE}, {"svg", DM_KIND_IMAGE}, {"tar", DM_KIND_ARCHIVE},
        {"tbz", DM_KIND_ARCHIVE}, {"tbz2", DM_KIND_ARCHIVE}, {"tgz", DM_KIND_ARCHIVE},
        {"tif", DM_KIND_IMAGE}, {"tiff", DM_KIND_IMAGE}, {"tsv", DM_KIND_DOCUMENT},
        {"txt", DM_KIND_DOCUMENT}, {"txz", DM_KIND_ARCHIVE}, {"wav", DM_KIND_AUDIO},
        {"webm", DM_KIND_VIDEO}, {"webp", DM_KIND_IMAGE}, {"wma", DM_KIND_AUDIO},
        {"wmv", DM_KIND_VIDEO}, {"wps", DM_KIND_DOCUMENT}, {"xar", DM_KIND_ARCHIVE},
        {"xls", DM_KIND_DOCUMENT}, {"xlsm", DM_KIND_DOCUMENT}, {"xlsx", DM_KIND_DOCUMENT},
        {"xz", DM_KIND_ARCHIVE}, {"zip", DM_KIND_ARCHIVE}, {"zst", DM_KIND_ARCHIVE}
    };
    bool directory = (attribute & KIND_MASK) == DIRECTORY;
    const char *dot = strrchr(name, '.');
    if (!dot || dot == name) return DM_KIND_ANY;
    char suffix[8];
    size_t length = 0;
    for (const char *p = dot + 1; *p; p++) {
        if (length == sizeof(suffix) - 1) return DM_KIND_ANY;
        unsigned char c = (unsigned char)*p;
        suffix[length++] = (char)(c >= 'A' && c <= 'Z' ? c + ('a' - 'A') : c);
    }
    suffix[length] = '\0';
    if (directory && strcmp(suffix, "app") == 0) return DM_KIND_APPLICATION;
    size_t lo = 0, hi = sizeof(formats) / sizeof(*formats);
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        int order = strcmp(suffix, formats[mid].suffix);
        if (order == 0) return formats[mid].kind;
        if (order < 0) hi = mid;
        else lo = mid + 1;
    }
    return DM_KIND_ANY;
}

bool dm_classify_kinds(const DMQueryView *v, uint8_t *kinds, size_t first) {
    bool leaf_root = false;
    for (uint32_t id = (uint32_t)first; id < v->row_count; id++) {
        kinds[id] = (v->attributes[id] & KIND_MASK) == ANCHOR
            ? DM_KIND_ANY : dm_file_kind(original(v, id), v->attributes[id]);
        if ((v->attributes[id] & 1) && v->rows[id].parent == UINT32_MAX) leaf_root = true;
    }
    return leaf_root;
}

static bool matches_kind(const DMQueryView *v, uint32_t id, uint8_t kind) {
    if (kind == DM_KIND_ANY) return true;
    if (kind == DM_KIND_FOLDER) return (v->attributes[id] & KIND_MASK) == DIRECTORY;
    return v->file_kinds[id] == kind;
}

static const char *key(const DMQueryView *v, uint32_t id) {
    uint32_t offset = v->fold_offsets[id];
    return offset == UINT32_MAX ? original(v, id) : (const char *)v->folded_names + offset;
}

uint32_t dm_directory_candidate(const DMRecord *records, const uint8_t *attributes,
                                const uint8_t *names, size_t count, uint32_t start,
                                const char *leaf, const char *path) {
    for (uint32_t row = start; row < count; row++) {
        uint8_t kind = attributes[row] & KIND_MASK;
        if ((kind == DIRECTORY || kind == ANCHOR) &&
            strcmp((const char *)names + records[row].offset, kind == ANCHOR ? path : leaf) == 0) return row;
    }
    return UINT32_MAX;
}

uint32_t dm_child_lookup(const DMRecord *records, const uint8_t *attributes,
                         const uint8_t *names, const DMChildRun *runs, uint32_t first,
                         const char *leaf, bool directories_only) {
    for (uint32_t run = first; run != UINT32_MAX; run = runs[run].next) {
        for (uint32_t row = runs[run].start; row < runs[run].end; row++) {
            if ((!directories_only || (attributes[row] & KIND_MASK) == DIRECTORY) &&
                strcmp((const char *)names + records[row].offset, leaf) == 0) return row;
        }
    }
    return UINT32_MAX;
}

bool dm_has_non_ascii(const uint8_t *name, size_t length) {
    while (length >= 16) {
        if (vmaxvq_u8(vld1q_u8(name)) >= 128) return true;
        name += 16;
        length -= 16;
    }
    for (size_t i = 0; i < length; i++)
        if (name[i] >= 128) return true;
    return false;
}

static inline uint8_t ascii_fold(uint8_t byte) {
    return (unsigned)(byte - 'A') <= 'Z' - 'A' ? byte | 0x20 : byte;
}

static inline bool ascii_letter(uint8_t folded) {
    return (unsigned)(folded - 'a') <= 'z' - 'a';
}

static int folded_order(const char *left, const char *right) {
    for (;; left++, right++) {
        int a = ascii_fold((uint8_t)*left), b = ascii_fold((uint8_t)*right);
        if (a != b || !a) return a - b;
    }
}

static bool folded_prefix(const char *value, const char *lower, size_t length) {
    for (size_t i = 0; i < length; i++)
        if (ascii_fold((uint8_t)value[i]) != (uint8_t)lower[i]) return false;
    return true;
}

static bool folded_contains(const char *value, const char *lower) {
    size_t length = strlen(lower);
    uint8_t first = (uint8_t)lower[0];
    unsigned mask = ascii_letter(first) ? 0x20 : 0;
    for (; *value; value++) {
        if (((uint8_t)*value | mask) == first && folded_prefix(value + 1, lower + 1, length - 1))
            return true;
    }
    return false;
}

static int name_order(void *context, const void *a, const void *b) {
    const DMQueryView *v = context;
    uint32_t left = *(const uint32_t *)a, right = *(const uint32_t *)b;
    int compare = folded_order(key(v, left), key(v, right));
    if (compare) return compare;
    compare = strcmp(original(v, left), original(v, right));
    if (compare) return compare;
    return (left > right) - (left < right);
}

typedef struct { uint32_t offset, length; bool ends_in_slash; } DirectoryKey;
typedef struct { const char *pool; const DirectoryKey *keys; } DirectoryOrder;

static int directory_order(void *context, const void *a, const void *b) {
    const DirectoryOrder *order = context;
    return strcmp(order->pool + order->keys[*(const uint32_t *)a].offset,
                  order->pool + order->keys[*(const uint32_t *)b].offset);
}

static bool get_directory_ranks(const DMQueryView *v, uint32_t *ranks) {
    size_t n = v->row_count, bytes = 0, count = 0;
    DirectoryKey *keys = scratch_map(n * sizeof(*keys));
    uint32_t *directories = scratch_map(n * sizeof(*directories));
    char *pool = MAP_FAILED;
    bool ok = keys && directories;
    if (!ok) goto done;
    for (uint32_t i = 0; i < n; i++) {
        uint8_t kind = v->attributes[i] & KIND_MASK;
        if (kind != ANCHOR && kind != DIRECTORY) continue;
        uint32_t parent = v->rows[i].parent;
        DirectoryKey before = parent == UINT32_MAX ? (DirectoryKey){0} : keys[parent];
        const char *word = key(v, i);
        size_t length = strlen(word);
        bool slash = before.length && !before.ends_in_slash;
        size_t whole = before.length + (size_t)slash + length;
        if (whole + 1 > UINT32_MAX - bytes) { ok = false; goto done; }
        keys[i] = (DirectoryKey){(uint32_t)bytes, (uint32_t)whole,
                                length ? word[length - 1] == '/' : slash || before.ends_in_slash};
        bytes += whole + 1;
        directories[count++] = i;
    }
    if (!count) goto done;
    pool = mmap(NULL, bytes, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (pool == MAP_FAILED) { ok = false; goto done; }

    for (size_t j = 0; j < count; j++) {
        uint32_t id = directories[j], parent = v->rows[id].parent;
        char *destination = pool + keys[id].offset;
        size_t prefix = 0;
        if (parent != UINT32_MAX) {
            DirectoryKey before = keys[parent];
            prefix = before.length;
            memcpy(destination, pool + before.offset, prefix);
            if (prefix && !before.ends_in_slash) destination[prefix++] = '/';
        }
        const char *word = key(v, id);
        for (size_t i = 0; i <= keys[id].length - prefix; i++)
            destination[prefix + i] = (char)ascii_fold((uint8_t)word[i]);
    }

    DirectoryOrder order = {pool, keys};
    qsort_r(directories, count, sizeof(*directories), &order, directory_order);
    uint32_t rank = 0;
    const char *prior = "";
    for (size_t j = 0; j < count; j++) {
        uint32_t id = directories[j];
        const char *path = pool + keys[id].offset;
        if (strcmp(path, prior)) { rank++; prior = path; }
        ranks[id] = rank;
    }
done:
    if (pool != MAP_FAILED) munmap(pool, bytes);
    scratch_release(directories, n * sizeof(*directories));
    scratch_release(keys, n * sizeof(*keys));
    return ok;
}

static uint64_t sort_key(const DMQueryView *v, uint32_t id, int column, const uint32_t *ranks) {
    DMRecord row = v->rows[id];
    if (column == 1) return row.parent == UINT32_MAX ? 0 : ranks[row.parent];
    return ((uint64_t)(column == 2 ? row.size : row.modified)) ^ (UINT64_C(1) << 63);
}

/// Stable radix sort preserves the full name tie-breaker.
static void stable_order(const DMQueryView *v, uint32_t *result, uint32_t *scratch,
                         int column, const uint32_t *ranks) {
    uint32_t *source = result, *target = scratch;
    unsigned passes = column == 1 ? 4 : 8;
    for (unsigned pass = 0; pass < passes; pass++) {
        uint32_t positions[256] = {0};
        for (size_t i = 0; i < v->row_count; i++) {
            uint8_t digit = (uint8_t)(sort_key(v, source[i], column, ranks) >> (8 * pass));
            positions[digit]++;
        }
        uint32_t location = 0;
        for (unsigned i = 0; i < 256; i++) {
            uint32_t count = positions[i];
            positions[i] = location;
            location += count;
        }
        for (size_t i = 0; i < v->row_count; i++) {
            uint32_t id = source[i];
            uint8_t digit = (uint8_t)(sort_key(v, id, column, ranks) >> (8 * pass));
            target[positions[digit]++] = id;
        }
        uint32_t *swap = source; source = target; target = swap;
    }
}

void dm_name_order(const DMQueryView *v, uint32_t *order) {
    for (uint32_t i = 0; i < v->row_count; i++) order[i] = i;
    qsort_r(order, v->row_count, sizeof(*order), (void *)v, name_order);
}

void dm_extend_name_order(const DMQueryView *v, const uint32_t *prefix, size_t count, uint32_t *order) {
    for (size_t i = count; i < v->row_count; i++) order[i] = (uint32_t)i;
    qsort_r(order + count, v->row_count - count, sizeof(*order), (void *)v, name_order);
    size_t prior = 0, added = count, next = 0;
    // The suffix starts after the entire old order. Until the prefix is
    // consumed, the merge destination is strictly before unread suffix data.
    while (prior < count) {
        if (added == v->row_count || name_order((void *)v, prefix + prior, order + added) <= 0)
            order[next++] = prefix[prior++];
        else
            order[next++] = order[added++];
    }
}

bool dm_column_order(const DMQueryView *v, uint32_t *order, int column) {
    if (!v->row_count) return true;
    size_t bytes = v->row_count * sizeof(uint32_t);
    uint32_t *ranks = column == 1 ? scratch_map(bytes) : NULL;
    uint32_t *scratch = scratch_map(bytes);
    bool ok = scratch && (column != 1 || (ranks && get_directory_ranks(v, ranks)));
    if (ok) stable_order(v, order, scratch, column, ranks);
    scratch_release(ranks, bytes);
    scratch_release(scratch, bytes);
    return ok;
}

static bool visible(uint8_t attrs, bool all) {
    return (attrs & KIND_MASK) != ANCHOR && !(attrs & EXCLUDED) && (all || !(attrs & HIDDEN));
}

enum { MAX_SPARSE_NAME_MATCHES = 4096 };

typedef struct {
    uint8_t *bitmap;
    uint32_t *sparse;
    size_t count;
    bool failed;
    bool track_ancestors, matched_ancestor;
} NameHits;

static void record_name_hit(const DMQueryView *v, NameHits *hits, uint32_t row) {
    if (hits->failed) return;
    if (hits->sparse && hits->count == MAX_SPARSE_NAME_MATCHES) {
        hits->bitmap = scratch_map(v->row_count);
        if (!hits->bitmap) { hits->failed = true; return; }
        for (size_t i = 0; i < hits->count; i++) hits->bitmap[hits->sparse[i]] = 1;
        hits->sparse = NULL;
    }
    if (hits->bitmap) hits->bitmap[row] = 1;
    else hits->sparse[hits->count] = row;
    hits->count++;
    if (hits->track_ancestors && !(v->attributes[row] & 1)) hits->matched_ancestor = true;
}

static uint32_t row_at(const DMQueryView *v, size_t position, bool folded, size_t low, size_t high) {
    while (low + 1 < high) {
        size_t middle = low + (high - low) / 2;
        uint32_t offset = folded ? v->fold_offsets[v->fold_rows[middle]] : v->rows[middle].offset;
        if (offset <= position) low = middle; else high = middle;
    }
    return folded ? v->fold_rows[low] : (uint32_t)low;
}

typedef struct {
    const char *word;
    size_t length;
    uint64_t first, last, first_case, last_case;
} NamePattern;

typedef struct { size_t skip, first_row, end_row; } NamePosition;

static uint64_t load_word(const void *source) {
    uint64_t value;
    memcpy(&value, source, sizeof(value));
    return value;
}

static uint64_t case_mask(const char *word) {
    uint8_t mask[8];
    for (size_t i = 0; i < sizeof(mask); i++)
        mask[i] = ascii_letter((uint8_t)word[i]) ? 0x20 : 0;
    return load_word(mask);
}

static bool matches_name_bytes(const uint8_t *bytes, const NamePattern *pattern, bool folded) {
    size_t length = pattern->length;
    if (folded) return memcmp(bytes, pattern->word, length) == 0;
    if (length < 8) return folded_prefix((const char *)bytes, pattern->word, length);
    if ((load_word(bytes) | pattern->first_case) != pattern->first) return false;
    if ((load_word(bytes + length - 8) | pattern->last_case) != pattern->last) return false;
    // The two verified ranges may overlap. Long words have a gap to check.
    return length <= 16 || folded_prefix((const char *)bytes + 8, pattern->word + 8, length - 16);
}

static void hit_at(const DMQueryView *v, const NamePattern *pattern,
                   const uint8_t *pool, size_t start, bool folded, NameHits *hits, NamePosition *position) {
    if (start < position->skip || !matches_name_bytes(pool + start, pattern, folded)) return;
    uint32_t id = row_at(v, start, folded, position->first_row, position->end_row);
    uint32_t offset = folded ? v->fold_offsets[id] : v->rows[id].offset;
    position->skip = offset + strlen((const char *)pool + offset) + 1;
    // Each scan advances past the entire matched name. Rows with a separate
    // normalized key are recorded only from the normalized pool.
    if (folded || v->fold_offsets[id] == UINT32_MAX) record_name_hit(v, hits, id);
}

static void match_lanes(const DMQueryView *v, const NamePattern *pattern,
                          const uint8_t *pool, size_t base, bool folded,
                          NameHits *hits, NamePosition *position, uint64_t lanes) {
    while (lanes) {
        unsigned bit = (unsigned)__builtin_ctzll(lanes);
        hit_at(v, pattern, pool, base + bit / 8, folded, hits, position);
        lanes &= ~(UINT64_C(0xff) << bit);
    }
}

// The last word in each block stores the row owning the first byte. Exact
// matches can locate their row without binary-searching the whole corpus.
enum { NAME_FILTER_BYTES = 4096, NAME_FILTER_ROW = 32, NAME_FILTER_WORDS = 33 };

size_t dm_name_filter_words(size_t bytes) {
    return bytes < 65536 ? 0 : ((bytes - 1) / NAME_FILTER_BYTES + 1) * NAME_FILTER_WORDS;
}

static unsigned name_filter_bit(uint32_t three_bytes) {
    uint32_t key = three_bytes & UINT32_C(0xffffff);
    return ((key * UINT32_C(0x9e3779b1)) ^ ((key >> 9) * UINT32_C(0x85ebca77))) >> 21;
}

void dm_prepare_name_filter(const uint8_t *names, size_t bytes, const DMRecord *rows, size_t row_count,
                            size_t previous_bytes, uint64_t *filter) {
    if (!dm_name_filter_words(bytes)) return;
    size_t start = previous_bytes > 2 ? (previous_bytes - 2) / NAME_FILTER_BYTES * NAME_FILTER_BYTES : 0;
    size_t row = start ? filter[start / NAME_FILTER_BYTES * NAME_FILTER_WORDS + NAME_FILTER_ROW] : 0;
    for (size_t block = start; block < bytes; block += NAME_FILTER_BYTES) {
        uint64_t *bits = filter + block / NAME_FILTER_BYTES * NAME_FILTER_WORDS;
        while (row + 1 < row_count && rows[row + 1].offset <= block) row++;
        bits[NAME_FILTER_ROW] = row;
        // A hash collision can only admit extra candidates for exact matching.
        memset(bits, 0, NAME_FILTER_ROW * sizeof(*bits));
        size_t end = block + NAME_FILTER_BYTES < bytes - 2 ? block + NAME_FILTER_BYTES : bytes - 2;
        if (end <= block) continue;
        uint32_t value = ((uint32_t)ascii_fold(names[block]) << 8) | ascii_fold(names[block + 1]);
        for (size_t i = block; i < end; i++) {
            value = (value << 8) | ascii_fold(names[i + 2]);
            unsigned bit = name_filter_bit(value);
            bits[bit >> 6] |= UINT64_C(1) << (bit & 63);
        }
    }
}

typedef struct { size_t shift; unsigned bit; } NameFilterProbe;

static NameFilterProbe name_filter_probe(const char *word, size_t shift) {
    const uint8_t *start = (const uint8_t *)word + shift;
    uint32_t value = ((uint32_t)start[0] << 16) | ((uint32_t)start[1] << 8) | start[2];
    return (NameFilterProbe){shift, name_filter_bit(value)};
}

static bool name_filter_may_match(const uint64_t *filter, size_t first, size_t last, NameFilterProbe probe) {
    // The possible starting offsets of this mandatory three-byte sequence
    // cover at most two blocks, including matches that cross a boundary.
    size_t a = (first + probe.shift) / NAME_FILTER_BYTES * NAME_FILTER_WORDS;
    size_t b = (last + probe.shift) / NAME_FILTER_BYTES * NAME_FILTER_WORDS;
    unsigned word = probe.bit >> 6;
    return (filter[a + word] | filter[b + word]) & (UINT64_C(1) << (probe.bit & 63));
}

/// Scan the byte pools in 16-byte blocks. Exact verification still uses the whole word.
static void pool_hits(const DMQueryView *v, const char *word, bool folded, NameHits *hits) {
    const uint8_t *pool = folded ? v->folded_names : v->names;
    size_t bytes = folded ? v->fold_bytes : v->name_bytes;
    size_t length = strlen(word);
    if (!bytes || length < 2 || length > bytes) return;
    NamePattern pattern = {.word = word, .length = length};
    if (!folded && length >= 8) {
        pattern.first = load_word(word);
        pattern.last = load_word(word + length - 8);
        pattern.first_case = case_mask(word);
        pattern.last_case = case_mask(word + length - 8);
    }
    size_t end = bytes - length + 1;
    NamePosition lookup = {.end_row = folded ? v->fold_count : v->row_count};
    const bool filtered = !folded && v->name_filter && length >= 3;
    NameFilterProbe probes[5];
    size_t probe_count = 0;
    if (filtered) {
        probes[probe_count++] = name_filter_probe(word, 0);
        if (length > 3) probes[probe_count++] = name_filter_probe(word, length - 3);
        if (length >= 7) probes[probe_count++] = name_filter_probe(word, (length - 3) / 2);
        if (length >= 8) {
            probes[probe_count++] = name_filter_probe(word, 1);
            probes[probe_count++] = name_filter_probe(word, length - 4);
        }
    }
    uint8x16_t first = vdupq_n_u8((uint8_t)word[0]);
    uint8x16_t last = vdupq_n_u8((uint8_t)word[length - 1]);
    uint8x16_t first_mask = vdupq_n_u8(!folded && ascii_letter((uint8_t)word[0]) ? 0x20 : 0);
    uint8x16_t last_mask = vdupq_n_u8(!folded && ascii_letter((uint8_t)word[length - 1]) ? 0x20 : 0);
    const size_t span = filtered ? NAME_FILTER_BYTES : end;
    for (size_t block = 0; block < end; block += span) {
        size_t limit = end - block < span ? end : block + span;
        bool may_match = true;
        for (size_t i = 0; i < probe_count; i++) {
            if (!name_filter_may_match(v->name_filter, block, limit - 1, probes[i])) {
                may_match = false;
                break;
            }
        }
        if (!may_match) continue;
        if (filtered) {
            const uint64_t *block_rows = v->name_filter + block / NAME_FILTER_BYTES * NAME_FILTER_WORDS;
            lookup.first_row = block_rows[NAME_FILTER_ROW];
            lookup.end_row = block + NAME_FILTER_BYTES < bytes
                ? block_rows[NAME_FILTER_WORDS + NAME_FILTER_ROW] + 1 : v->row_count;
        }
        size_t position = block;
        for (; limit - position >= 16; position += 16) {
            uint8x16_t a = vceqq_u8(vorrq_u8(vld1q_u8(pool + position), first_mask), first);
            uint8x16_t b = vceqq_u8(vorrq_u8(vld1q_u8(pool + position + length - 1), last_mask), last);
            uint64x2_t masks = vreinterpretq_u64_u8(vandq_u8(a, b));
            match_lanes(v, &pattern, pool, position, folded, hits, &lookup, vgetq_lane_u64(masks, 0));
            match_lanes(v, &pattern, pool, position + 8, folded, hits, &lookup, vgetq_lane_u64(masks, 1));
        }
        for (; position < limit; position++)
            hit_at(v, &pattern, pool, position, folded, hits, &lookup);
    }
}

static void collect_name_hits(const DMQueryView *v, const char *word, NameHits *hits) {
    if (word[0] && !word[1]) {
        char letters[] = {word[0], ascii_letter((uint8_t)word[0]) ? word[0] - 32 : 0, 0};
        for (uint32_t i = 0; i < v->row_count; i++) {
            const char *name = key(v, i);
            if (strchr(name, letters[0]) ||
                (letters[1] && v->fold_offsets[i] == UINT32_MAX && strchr(name, letters[1])))
                record_name_hit(v, hits, i);
        }
        return;
    }
    pool_hits(v, word, false, hits);
    pool_hits(v, word, true, hits);
}

static uint32_t advance(const char *pattern, uint32_t length, const uint32_t *fallback,
                        uint32_t state, char byte) {
    while (state && (state == length || pattern[state] != byte)) state = fallback[state - 1];
    return pattern[state] == byte ? state + 1 : state;
}

typedef struct {
    const char *word;
    uint32_t stem;
    const uint32_t *fallback;
    void *states;
    bool narrow;
} SlashPattern;

static uint32_t slash_state(const SlashPattern *pattern, uint32_t row) {
    return pattern->narrow ? ((uint8_t *)pattern->states)[row] : ((uint32_t *)pattern->states)[row];
}

static uint32_t advance_slash_state(const SlashPattern *pattern, const char *name, uint32_t state) {
    const char *p = name;
    for (; *p; p++)
        state = advance(pattern->word, pattern->stem, pattern->fallback, state, (char)ascii_fold((uint8_t)*p));
    if (p == name || p[-1] != '/') state = advance(pattern->word, pattern->stem, pattern->fallback, state, '/');
    return state;
}

static uint32_t save_slash_state(const SlashPattern *pattern, uint32_t row, const char *name, uint32_t state) {
    state = advance_slash_state(pattern, name, state);
    if (pattern->narrow) ((uint8_t *)pattern->states)[row] = (uint8_t)state;
    else ((uint32_t *)pattern->states)[row] = state;
    return state;
}

static void slash_fallback(const char *word, uint32_t stem, uint32_t *fallback) {
    fallback[0] = 0;
    for (uint32_t i = 1; i < stem; i++)
        fallback[i] = advance(word, stem, fallback, fallback[i - 1], word[i]);
}

static bool slash_reaches_row(const DMQueryView *v, uint32_t row, const void *context) {
    const SlashPattern *pattern = context;
    uint32_t parent = v->rows[row].parent;
    const char *name = key(v, row);
    if (parent == UINT32_MAX && folded_contains(name, pattern->word)) return true;
    uint32_t before = parent == UINT32_MAX ? 0 : slash_state(pattern, parent);
    return save_slash_state(pattern, row, name, before) == pattern->stem;
}

// A non-root path match needs a directory whose path reaches the last slash
// of the pattern. Reject absent branches by visiting only anchors and folders.
static bool visit_directories(const DMQueryView *v, bool (*visit)(const DMQueryView *, uint32_t, const void *),
                              const void *context) {
    uint32_t i = 0;
    uint8x16_t leaf_bit = vdupq_n_u8(1);
    uint8x16_t zero = vdupq_n_u8(0);
    for (; v->row_count - i >= 16; i += 16) {
        uint8x16_t attrs = vld1q_u8(v->attributes + i);
        uint64x2_t dirs = vreinterpretq_u64_u8(vceqq_u8(vandq_u8(attrs, leaf_bit), zero));
        uint64_t first = vgetq_lane_u64(dirs, 0), last = vgetq_lane_u64(dirs, 1);
        while (first) {
            unsigned bit = (unsigned)__builtin_ctzll(first);
            if (visit(v, i + bit / 8, context)) return true;
            first &= ~(UINT64_C(255) << bit);
        }
        while (last) {
            unsigned bit = (unsigned)__builtin_ctzll(last);
            if (visit(v, i + 8 + bit / 8, context)) return true;
            last &= ~(UINT64_C(255) << bit);
        }
    }
    for (; i < v->row_count; i++)
        if (!(v->attributes[i] & 1) && visit(v, i, context)) return true;
    return false;
}

static bool slash_ancestor(const DMQueryView *, const SlashPattern *, const char *, size_t,
                           uint32_t *, uint32_t, uint32_t *);

typedef struct {
    const DMQueryView *view;
    const SlashPattern *pattern;
    const char *tail;
    size_t tail_length, begin, end, needed;
    uint8_t *hits;
    uint32_t *earlier;
    uint8_t kind;
    bool all, complete;
    size_t count;
    uint32_t sole;
} SlashRange;

static void *match_slash_range(void *context) {
    SlashRange *range = context;
    const DMQueryView *v = range->view;
    const SlashPattern *pattern = range->pattern;
    uint8_t *hits = range->hits;
    uint32_t last_parent = UINT32_MAX, inherited = 0;
    bool prior_match = false;
    for (uint32_t i = (uint32_t)range->begin; i < range->end; i++) {
        uint32_t parent = v->rows[i].parent;
        bool root = parent == UINT32_MAX;
        if (parent != last_parent) {
            last_parent = parent;
            if (!root && parent < range->begin) {
                uint32_t value;
                if (!slash_ancestor(v, pattern, range->tail, range->tail_length, range->earlier, parent, &value))
                    return NULL;
                prior_match = value == UINT32_MAX;
                inherited = prior_match ? 0 : value - 1;
            } else {
                prior_match = !root && hits[parent];
                inherited = root || prior_match ? 0 : slash_state(pattern, parent);
            }
        }
        bool match = prior_match;
        if (!match && (root || inherited == pattern->stem)) {
            const char *name = key(v, i);
            match = root ? folded_contains(name, pattern->word) : folded_prefix(name, range->tail, range->tail_length);
        }
        hits[i] = (uint8_t)match;
        if (match) {
            if (range->count < range->needed && visible(v->attributes[i], range->all) && matches_kind(v, i, range->kind) &&
                (!v->suppressed_rows || !(v->suppressed_rows[i >> 3] & (1U << (i & 7))))) {
                if (range->count++ == 0) range->sole = i;
            }
            continue;
        }
        if (!(v->attributes[i] & 1)) save_slash_state(pattern, i, key(v, i), inherited);
    }
    range->complete = true;
    return NULL;
}

// The second range computes out-of-range ancestor states locally. The
// workers only write rows and states in their own ranges.
static bool split_slash_range(SlashRange *left) {
    SlashRange right = *left;
    right.begin = left->end / 2;
    size_t bytes = right.begin * sizeof(uint32_t);
    right.earlier = scratch_map(bytes);
    if (!right.earlier) return false;
    pthread_t worker;
    bool started = pthread_create(&worker, NULL, match_slash_range, &right) == 0;
    if (started) {
        left->end = right.begin;
        match_slash_range(left);
        pthread_join(worker, NULL);
    }
    scratch_release(right.earlier, bytes);
    if (!right.complete) return false;
    if (!left->count) left->sole = right.sole;
    size_t remaining = left->needed - left->count;
    left->count += right.count < remaining ? right.count : remaining;
    return true;
}

// A slash-bearing word can end in a basename only when its stem ends at
// the parent slash and its remaining tail is a prefix of the basename.
static bool slash_hits(const DMQueryView *v, const char *word, uint8_t *hits,
                       bool all, uint8_t file_kind, size_t needed, bool allow_split,
                       size_t *visible_matches, uint32_t *sole_match) {
    const char *tail = strrchr(word, '/') + 1;
    uint32_t stem = (uint32_t)(tail - word);
    uint32_t *fallback = calloc(stem, sizeof(*fallback));
    bool narrow = stem <= UINT8_MAX;
    size_t states_bytes = v->row_count * (narrow ? sizeof(uint8_t) : sizeof(uint32_t));
    void *states = scratch_map(states_bytes);
    if (!fallback || !states) { free(fallback); scratch_release(states, states_bytes); return false; }
    *visible_matches = 0;
    slash_fallback(word, stem, fallback);
    SlashPattern pattern = {.word = word, .stem = stem, .fallback = fallback, .states = states, .narrow = narrow};
    if (v->has_leaf_root || visit_directories(v, slash_reaches_row, &pattern)) {
        SlashRange range = {.view = v, .pattern = &pattern, .tail = tail, .tail_length = strlen(tail),
                            .end = v->row_count, .hits = hits, .all = all, .kind = file_kind, .needed = needed};
        bool split = false;
        if (allow_split && v->row_count >= 1500000 && dm_try_query_worker()) {
            split = split_slash_range(&range);
            dm_release_query_worker();
        }
        if (!split) {
            range.end = v->row_count;
            range.count = 0;
            match_slash_range(&range);
        }
        *visible_matches = range.count;
        *sole_match = range.sole;
    }
    free(fallback);
    scratch_release(states, states_bytes);
    return true;
}

// Memo entries are zero before evaluation, a prefix length plus one, or
// UINT32_MAX once the directory path contains the full word.
static bool slash_ancestor(const DMQueryView *v, const SlashPattern *p, const char *tail, size_t tail_length,
                           uint32_t *memo, uint32_t ancestor, uint32_t *result) {
    uint32_t chain[64];
    size_t depth = 0;
    while (ancestor != UINT32_MAX && memo[ancestor] == 0) {
        if (depth == sizeof(chain) / sizeof(chain[0])) return false;
        chain[depth++] = ancestor;
        ancestor = v->rows[ancestor].parent;
    }
    uint32_t inherited = ancestor == UINT32_MAX ? 1 : memo[ancestor];
    while (depth > 0) {
        uint32_t directory = chain[--depth];
        bool root = v->rows[directory].parent == UINT32_MAX;
        const char *name = key(v, directory);
        if (inherited == UINT32_MAX ||
            (root ? folded_contains(name, p->word)
                  : inherited - 1 == p->stem && folded_prefix(name, tail, tail_length))) {
            inherited = UINT32_MAX;
        } else {
            inherited = advance_slash_state(p, name, inherited - 1) + 1;
        }
        memo[directory] = inherited;
    }
    *result = inherited;
    return true;
}

static bool slash_row_matches(const DMQueryView *v, const SlashPattern *p, const char *tail, size_t tail_length,
                              uint32_t *memo, uint32_t row, bool *matches) {
    uint32_t parent = v->rows[row].parent;
    uint32_t inherited;
    if (!slash_ancestor(v, p, tail, tail_length, memo, parent, &inherited)) return false;
    if (inherited == UINT32_MAX) *matches = true;
    else if (parent == UINT32_MAX) *matches = folded_contains(key(v, row), p->word);
    else *matches = inherited - 1 == p->stem && folded_prefix(key(v, row), tail, tail_length);
    return true;
}

static bool slash_matches_root(const DMQueryView *v, uint32_t row, const void *context) {
    const SlashPattern *pattern = context;
    return v->rows[row].parent == UINT32_MAX && folded_contains(key(v, row), pattern->word);
}

static size_t name_prefix_bound(const DMQueryView *v, const uint32_t *order, const char *prefix, bool after) {
    size_t left = 0, right = v->row_count;
    while (left < right) {
        size_t mid = left + (right - left) / 2;
        const char *name = key(v, order[mid]), *letter = prefix;
        int relation = 0;
        for (; *letter && !relation; letter++, name++)
            relation = ascii_fold((uint8_t)*name) - (uint8_t)*letter;
        if (relation < 0 || (!relation && after)) left = mid + 1;
        else right = mid;
    }
    return left;
}

static bool visible_candidate(const DMQueryView *v, uint32_t row, bool all, uint8_t kind) {
    return visible(v->attributes[row], all) && matches_kind(v, row, kind) &&
        (!v->suppressed_rows || !(v->suppressed_rows[row >> 3] & (1U << (row & 7))));
}

// Dense results often fill the requested page near the start of the selected
// sort order. Certify that prefix exactly before building a volume-wide match
// bitmap. Sparse or unusually deep requests fall back to the linear matcher.
static size_t slash_ordered_prefix(const DMQueryView *v, const uint32_t *order, const char *word,
                                  const char *tail, bool name_ordered, bool descending, bool all, uint8_t kind,
                                  size_t offset, size_t limit, uint32_t *results) {
    enum { MAX_STEM = 255, BUDGET = 2048, FIRST_PROBE = 256 };
    size_t stem = (size_t)(tail - word);
    if (stem > MAX_STEM || v->row_count < 50000 || offset > 512 || limit > 512 - offset) return SIZE_MAX;
    size_t bytes = v->row_count * sizeof(uint32_t);
    uint32_t *memo = scratch_map(bytes);
    if (!memo) return SIZE_MAX;

    uint32_t fallback[MAX_STEM];
    slash_fallback(word, (uint32_t)stem, fallback);
    SlashPattern pattern = {.word = word, .stem = (uint32_t)stem, .fallback = fallback};
    size_t skipped = 0, emitted = 0, tail_length = strlen(tail);
    size_t rank = 0;
    for (; rank < BUDGET && emitted < limit; rank++) {
        if (rank == FIRST_PROBE && (skipped + emitted) * (BUDGET / FIRST_PROBE) < offset + limit) break;
        uint32_t row = order[descending ? v->row_count - rank - 1 : rank];
        if (!visible_candidate(v, row, all, kind)) continue;
        bool matches;
        if (!slash_row_matches(v, &pattern, tail, tail_length, memo, row, &matches)) break;
        if (!matches) continue;
        if (skipped < offset) skipped++;
        else results[emitted++] = row;
    }
    if (emitted < limit && !v->has_leaf_root && name_ordered) {
        // If the tail occurs at the start of only a few names, prove that
        // no ancestor can introduce any other candidates before taking the page.
        size_t begin = name_prefix_bound(v, order, tail, false);
        size_t end = name_prefix_bound(v, order, tail, true);
        size_t count = end - begin;
        if (count <= 4096 && !visit_directories(v, slash_matches_root, &pattern)) {
            skipped = emitted = 0;
            for (rank = 0; rank < count; rank++) {
                uint32_t row = order[descending ? end - rank - 1 : begin + rank];
                bool matches;
                if (!slash_row_matches(v, &pattern, tail, tail_length, memo, row, &matches) ||
                    (matches && !(v->attributes[row] & 1))) break;
                if (!matches || emitted == limit || !visible_candidate(v, row, all, kind)) continue;
                if (skipped < offset) skipped++;
                else results[emitted++] = row;
            }
            if (rank == count) {
                scratch_release(memo, bytes);
                return emitted;
            }
            emitted = 0;
        }
    }
    scratch_release(memo, bytes);
    return emitted == limit ? emitted : SIZE_MAX;
}

static bool all_words(const char *name, const uint8_t *patterns, const uint32_t *offsets, size_t words) {
    for (size_t j = 0; j < words; j++) {
        if (!folded_contains(name, (const char *)patterns + offsets[j])) return false;
    }
    return true;
}

static size_t select_order(const DMQueryView *v, const uint32_t *ids, const uint8_t *matches,
                           const uint8_t *patterns, const uint32_t *offsets, size_t words,
                           bool descending, bool all, uint8_t kind, size_t offset, size_t limit,
                           size_t budget, uint32_t *out) {
    size_t emitted = 0, skipped = 0;
    for (size_t i = 0; i < budget && emitted < limit; i++) {
        uint32_t id = ids[descending ? v->row_count - i - 1 : i];
        if (matches && !matches[id]) continue;
        if (!visible(v->attributes[id], all) || !matches_kind(v, id, kind) ||
            (v->suppressed_rows && (v->suppressed_rows[id >> 3] & (1U << (id & 7))))) continue;
        if (!matches && words && !all_words(key(v, id), patterns, offsets, words)) continue;
        if (skipped < offset) { skipped++; continue; }
        out[emitted++] = id;
    }
    return emitted;
}

static bool later_in_name_page(const DMQueryView *v, const uint32_t *a, const uint32_t *b, bool descending) {
    int comparison = name_order((void *)v, a, b);
    return descending ? comparison < 0 : comparison > 0;
}

// The heap root is the least useful of the candidates retained for this page.
static void sift_name_candidates(const DMQueryView *v, uint32_t *rows, size_t count,
                                 size_t at, bool descending) {
    uint32_t row = rows[at];
    for (size_t child = 2 * at + 1; child < count; child = 2 * at + 1) {
        if (child + 1 < count && later_in_name_page(v, rows + child + 1, rows + child, descending))
            child++;
        if (!later_in_name_page(v, rows + child, &row, descending)) break;
        rows[at] = rows[child];
        at = child;
    }
    rows[at] = row;
}

// Keep only the candidates needed to reach the requested page. Heap updates
// stay behind the unread part of the candidate array.
static size_t select_sparse_names(const DMQueryView *v, uint32_t *selected, size_t name_matches,
                                  const uint8_t *patterns, const uint32_t *offsets, size_t words,
                                  bool descending, bool all, uint8_t kind, size_t offset, size_t limit,
                                  uint32_t *out) {
    if (offset >= name_matches) return 0;
    size_t count = 0;
    size_t keep = limit < name_matches - offset ? offset + limit : name_matches;
    if (!keep) return 0;
    for (size_t i = 0; i < name_matches; i++) {
        uint32_t id = selected[i];
        if (!visible(v->attributes[id], all) || !matches_kind(v, id, kind) ||
            (v->suppressed_rows && (v->suppressed_rows[id >> 3] & (1U << (id & 7))))) continue;
        if (words > 1 && !all_words(key(v, id), patterns, offsets, words)) continue;
        if (count < keep) {
            selected[count++] = id;
            if (count == keep && keep < name_matches)
                for (size_t i = count / 2; i > 0; i--)
                    sift_name_candidates(v, selected, count, i - 1, descending);
        } else if (later_in_name_page(v, selected, &id, descending)) {
            selected[0] = id;
            sift_name_candidates(v, selected, count, 0, descending);
        }
    }
    if (offset >= count) return 0;
    qsort_r(selected, count, sizeof(*selected), (void *)v, name_order);
    size_t emitted = count - offset < limit ? count - offset : limit;
    for (size_t i = 0; i < emitted; i++)
        out[i] = selected[descending ? count - 1 - offset - i : offset + i];
    return emitted;
}

static size_t query_name(const DMQueryView *v, const uint32_t *order,
                         const uint8_t *patterns, const uint32_t *offsets, size_t words,
                         bool name_ordered, bool descending, bool all, uint8_t kind, size_t offset,
                         size_t limit, uint32_t *results) {
    uint32_t candidates[MAX_SPARSE_NAME_MATCHES];
    NameHits hits = {0};
    if (name_ordered) hits.sparse = candidates;
    else if (!(hits.bitmap = scratch_map(v->row_count))) return SIZE_MAX;
    const char *longest = (const char *)patterns + offsets[0];
    for (size_t i = 1; i < words; i++) {
        const char *word = (const char *)patterns + offsets[i];
        if (strlen(word) > strlen(longest)) longest = word;
    }
    collect_name_hits(v, longest, &hits);
    if (hits.failed) return SIZE_MAX;
    if (hits.sparse)
        return select_sparse_names(v, candidates, hits.count, patterns, offsets, words,
                                   descending, all, kind, offset, limit, results);
    if (words > 1 && hits.count) {
        for (uint32_t i = 0; i < v->row_count; i++)
            if (hits.bitmap[i] && !all_words(key(v, i), patterns, offsets, words)) hits.bitmap[i] = 0;
    }
    size_t emitted = hits.count ? select_order(v, order, hits.bitmap, NULL, NULL, 0,
                                              descending, all, kind, offset, limit, v->row_count, results) : 0;
    scratch_release(hits.bitmap, v->row_count);
    return emitted;
}

typedef struct {
    const DMQueryView *view;
    const char *word;
    uint8_t *hits;
    bool ok;
    bool any;
    bool all;
    uint8_t kind;
    size_t needed;
    bool allow_split;
    size_t visible_matches;
    uint32_t sole_match;
} PathWord;

static void *path_word(void *argument) {
    PathWord *task = argument;
    const DMQueryView *view = task->view;
    uint8_t *hits = task->hits;
    task->ok = true;
    if (strchr(task->word, '/')) {
        task->ok = slash_hits(view, task->word, hits, task->all, task->kind, task->needed, task->allow_split,
                              &task->visible_matches, &task->sole_match);
        task->any = task->ok && task->visible_matches != 0;
        return NULL;
    }
    memset(hits, 0, view->row_count);
    task->visible_matches = SIZE_MAX;
    NameHits names = {.bitmap = hits, .track_ancestors = true};
    collect_name_hits(view, task->word, &names);
    task->any = names.count != 0;
    if (names.matched_ancestor) {
        uint32_t parent = UINT32_MAX;
        bool inherited = false;
        for (uint32_t i = 0; i < view->row_count; i++) {
            uint32_t next = view->rows[i].parent;
            if (next != parent) {
                parent = next;
                inherited = parent != UINT32_MAX && hits[parent];
            }
            if (inherited) hits[i] = 1;
        }
    }
    return NULL;
}

size_t dm_query(const DMQueryView *v, const uint32_t *order,
                const uint8_t *patterns, const uint32_t *offsets, size_t words,
                bool path, bool name_ordered, bool descending, bool all, uint8_t kind, size_t offset,
                size_t limit, uint32_t *results) {
    size_t n = v->row_count;
    if (!path || !words) {
        size_t budget = !words || n < 2048 ? n : 2048;
        size_t emitted = select_order(v, order, NULL, patterns, offsets, words,
                                      descending, all, kind, offset, limit, budget, results);
        if (emitted == limit || budget == n) return emitted;
    }
    if (!path)
        return query_name(v, order, patterns, offsets, words, name_ordered, descending,
                          all, kind, offset, limit, results);
    if (words == 1) {
        const char *word = (const char *)patterns + offsets[0];
        const char *slash = strrchr(word, '/');
        if (slash) {
            size_t page = slash_ordered_prefix(v, order, word, slash + 1, name_ordered,
                                              descending, all, kind, offset, limit, results);
            if (page != SIZE_MAX) return page;
        }
    }

    uint8_t *matches = scratch_map(n);
    uint8_t *single = words > 1 ? scratch_map(n) : matches;
    if (!matches || !single) {
        scratch_release(matches, n);
        if (single != matches) scratch_release(single, n);
        return SIZE_MAX;
    }
    size_t needed = 1;
    if (words == 1) {
        needed = limit > SIZE_MAX - offset ? SIZE_MAX : offset + limit;
        // Seeing one match must still distinguish a unique result from a full page of one.
        if (needed < 2) needed = 2;
    }
    PathWord first = {.view = v, .word = (const char *)patterns + offsets[0], .hits = matches,
                      .all = all, .kind = kind, .needed = needed, .allow_split = words == 1};
    bool ok, any;
    size_t next = 1;
    if (words > 1 && n >= 50000 && dm_try_query_worker()) {
        PathWord second = {.view = v, .word = (const char *)patterns + offsets[1], .hits = single,
                           .all = all, .kind = kind, .needed = 1};
        pthread_t thread;
        bool started = pthread_create(&thread, NULL, path_word, &second) == 0;
        if (!started) dm_release_query_worker();
        path_word(&first);
        if (started) {
            pthread_join(thread, NULL);
            dm_release_query_worker();
        } else {
            path_word(&second);
        }
        ok = first.ok && second.ok;
        any = first.any && second.any;
        if (ok && any) for (size_t i = 0; i < n; i++) matches[i] &= single[i];
        next = 2;
    } else {
        path_word(&first);
        ok = first.ok;
        any = first.any;
    }
    uint32_t only_path_hit = UINT32_MAX;
    if (words == 1 && first.visible_matches != SIZE_MAX) {
        size_t available = first.visible_matches > offset ? first.visible_matches - offset : 0;
        if (available < limit) limit = available;
        if (first.visible_matches == 1 && limit == 1) only_path_hit = first.sole_match;
    }
    for (size_t j = next; j < words && ok && any; j++) {
        PathWord task = {.view = v, .word = (const char *)patterns + offsets[j], .hits = single,
                         .all = all, .kind = kind, .needed = 1};
        path_word(&task);
        ok = task.ok;
        any = task.any;
        if (ok && any) for (size_t i = 0; i < n; i++) matches[i] &= single[i];
    }
    size_t result;
    if (only_path_hit != UINT32_MAX) {
        // One visible candidate has the same rank for every column and direction.
        results[0] = only_path_hit;
        result = 1;
    } else {
        result = !ok ? SIZE_MAX : !any ? 0 :
            select_order(v, order, matches, NULL, NULL, 0, descending, all, kind, offset, limit, n, results);
    }
    if (single != matches) scratch_release(single, n);
    scratch_release(matches, n);
    return result;
}

#include "DarwinMetadata.h"
#include <arm_neon.h>
#include <pthread.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <string.h>

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

static uint32_t row_at(const DMQueryView *v, size_t position, bool folded) {
    size_t low = 0, high = folded ? v->fold_count : v->row_count;
    while (low + 1 < high) {
        size_t middle = low + (high - low) / 2;
        uint32_t offset = folded ? v->fold_offsets[v->fold_rows[middle]] : v->rows[middle].offset;
        if (offset <= position) low = middle; else high = middle;
    }
    return folded ? v->fold_rows[low] : (uint32_t)low;
}

static bool hit_at(const DMQueryView *v, const char *word, size_t length,
                   const uint8_t *pool, size_t start, bool folded, uint8_t *hits, size_t *skip) {
    if (start < *skip) return false;
    if (folded ? memcmp(pool + start, word, length) != 0 :
        !folded_prefix((const char *)pool + start, word, length)) return false;
    uint32_t id = row_at(v, start, folded);
    uint32_t offset = folded ? v->fold_offsets[id] : v->rows[id].offset;
    *skip = offset + strlen((const char *)pool + offset) + 1;
    if (hits[id] || (!folded && v->fold_offsets[id] != UINT32_MAX)) return false;
    hits[id] = 1;
    return true;
}

static size_t match_lanes(const DMQueryView *v, const char *word, size_t length,
                          const uint8_t *pool, size_t base, bool folded,
                          uint8_t *hits, size_t *skip, uint64_t lanes) {
    size_t found = 0;
    while (lanes) {
        unsigned bit = (unsigned)__builtin_ctzll(lanes);
        found += hit_at(v, word, length, pool, base + bit / 8, folded, hits, skip);
        lanes &= ~(UINT64_C(0xff) << bit);
    }
    return found;
}

/// Scan the byte pools in 16-byte blocks. Exact verification still uses the whole word.
static size_t pool_hits(const DMQueryView *v, const char *word, bool folded, uint8_t *hits) {
    const uint8_t *pool = folded ? v->folded_names : v->names;
    size_t bytes = folded ? v->fold_bytes : v->name_bytes;
    size_t length = strlen(word);
    if (!bytes || length < 2 || length > bytes) return 0;
    size_t found = 0, skip = 0, position = 0, end = bytes - length + 1;
    uint8x16_t first = vdupq_n_u8((uint8_t)word[0]);
    uint8x16_t last = vdupq_n_u8((uint8_t)word[length - 1]);
    uint8x16_t first_mask = vdupq_n_u8(!folded && ascii_letter((uint8_t)word[0]) ? 0x20 : 0);
    uint8x16_t last_mask = vdupq_n_u8(!folded && ascii_letter((uint8_t)word[length - 1]) ? 0x20 : 0);
    for (; end - position >= 16; position += 16) {
        uint8x16_t a = vceqq_u8(vorrq_u8(vld1q_u8(pool + position), first_mask), first);
        uint8x16_t b = vceqq_u8(vorrq_u8(vld1q_u8(pool + position + length - 1), last_mask), last);
        uint64x2_t masks = vreinterpretq_u64_u8(vandq_u8(a, b));
        found += match_lanes(v, word, length, pool, position, folded, hits, &skip, vgetq_lane_u64(masks, 0));
        found += match_lanes(v, word, length, pool, position + 8, folded, hits, &skip, vgetq_lane_u64(masks, 1));
    }
    for (; position < end; position++)
        found += hit_at(v, word, length, pool, position, folded, hits, &skip);
    return found;
}

static size_t name_hits(const DMQueryView *v, const char *word, uint8_t *hits) {
    if (word[0] && !word[1]) {
        size_t count = 0;
        char letters[] = {word[0], ascii_letter((uint8_t)word[0]) ? word[0] - 32 : 0, 0};
        for (uint32_t i = 0; i < v->row_count; i++) {
            const char *name = key(v, i);
            hits[i] = strchr(name, letters[0]) != NULL ||
                (letters[1] && v->fold_offsets[i] == UINT32_MAX && strchr(name, letters[1]) != NULL);
            count += hits[i];
        }
        return count;
    }
    size_t count = pool_hits(v, word, false, hits);
    return count + pool_hits(v, word, true, hits);
}

static uint32_t advance(const char *pattern, uint32_t length, const uint32_t *fallback,
                        uint32_t state, char byte) {
    while (state && (state == length || pattern[state] != byte)) state = fallback[state - 1];
    return pattern[state] == byte ? state + 1 : state;
}

// A slash-bearing word can end in a basename only when its stem ends at
// the parent slash and its remaining tail is a prefix of the basename.
static bool slash_hits(const DMQueryView *v, const char *word, uint8_t *hits,
                       bool all, size_t *visible_matches, uint32_t *sole_match) {
    const char *tail = strrchr(word, '/') + 1;
    uint32_t stem = (uint32_t)(tail - word);
    size_t tail_length = strlen(tail);
    uint32_t *fallback = calloc(stem, sizeof(*fallback));
    size_t states_bytes = v->row_count * sizeof(uint32_t);
    uint32_t *states = scratch_map(states_bytes);
    if (!fallback || !states) { free(fallback); scratch_release(states, states_bytes); return false; }
    *visible_matches = 0;
    for (uint32_t i = 1; i < stem; i++)
        fallback[i] = advance(word, stem, fallback, fallback[i - 1], word[i]);

    for (uint32_t i = 0; i < v->row_count; i++) {
        uint32_t parent = v->rows[i].parent;
        bool root = parent == UINT32_MAX;
        uint8_t kind = v->attributes[i] & KIND_MASK;
        uint32_t inherited = root ? 0 : states[parent];
        bool prior_match = !root && hits[parent];
        const char *name = key(v, i);
        hits[i] = (uint8_t)(prior_match || (root ? folded_contains(name, word) :
                   inherited == stem && folded_prefix(name, tail, tail_length)));
        if (hits[i]) {
            if (visible(v->attributes[i], all) &&
                (!v->suppressed_rows || !(v->suppressed_rows[i >> 3] & (1U << (i & 7))))) {
                if ((*visible_matches)++ == 0) *sole_match = i;
            }
            continue;
        }
        if (kind != ANCHOR && kind != DIRECTORY) continue;
        uint32_t state = inherited;
        const char *p = name;
        for (; *p; p++) state = advance(word, stem, fallback, state, (char)ascii_fold((uint8_t)*p));
        if (p == name || p[-1] != '/') state = advance(word, stem, fallback, state, '/');
        states[i] = state;
    }
    free(fallback);
    scratch_release(states, states_bytes);
    return true;
}

static bool all_words(const char *name, const uint8_t *patterns, const uint32_t *offsets, size_t words) {
    for (size_t j = 0; j < words; j++) {
        if (!folded_contains(name, (const char *)patterns + offsets[j])) return false;
    }
    return true;
}

static size_t select_order(const DMQueryView *v, const uint32_t *ids, const uint8_t *matches,
                           const uint8_t *patterns, const uint32_t *offsets, size_t words,
                           bool descending, bool all, size_t offset, size_t limit,
                           size_t budget, uint32_t *out) {
    size_t emitted = 0, skipped = 0;
    for (size_t i = 0; i < budget && emitted < limit; i++) {
        uint32_t id = ids[descending ? v->row_count - i - 1 : i];
        if (!visible(v->attributes[id], all) ||
            (v->suppressed_rows && (v->suppressed_rows[id >> 3] & (1U << (id & 7))))) continue;
        if (matches ? !matches[id] : words && !all_words(key(v, id), patterns, offsets, words)) continue;
        if (skipped < offset) { skipped++; continue; }
        out[emitted++] = id;
    }
    return emitted;
}

typedef struct {
    const DMQueryView *view;
    const char *word;
    uint8_t *hits;
    bool ok;
    bool any;
    bool all;
    size_t visible_matches;
    uint32_t sole_match;
} PathWord;

static void *path_word(void *argument) {
    PathWord *task = argument;
    const DMQueryView *view = task->view;
    uint8_t *hits = task->hits;
    memset(hits, 0, view->row_count);
    task->ok = true;
    if (strchr(task->word, '/')) {
        task->ok = slash_hits(view, task->word, hits, task->all, &task->visible_matches, &task->sole_match);
        task->any = task->ok && task->visible_matches != 0;
        return NULL;
    }
    task->visible_matches = SIZE_MAX;
    task->any = name_hits(view, task->word, hits) != 0;
    if (task->any) {
        for (uint32_t i = 0; i < view->row_count; i++) {
            uint32_t parent = view->rows[i].parent;
            if (parent != UINT32_MAX) hits[i] |= hits[parent];
        }
    }
    return NULL;
}

size_t dm_query(const DMQueryView *v, const uint32_t *order,
                const uint8_t *patterns, const uint32_t *offsets, size_t words,
                bool path, bool descending, bool all, size_t offset,
                size_t limit, uint32_t *results) {
    size_t n = v->row_count;
    if (!path || !words) {
        size_t budget = !words || n < 2048 ? n : 2048;
        size_t emitted = select_order(v, order, NULL, patterns, offsets, words,
                                      descending, all, offset, limit, budget, results);
        if (emitted == limit || budget == n) return emitted;
    }

    uint8_t *matches = scratch_map(n);
    uint8_t *single = path && words > 1 ? scratch_map(n) : matches;
    if (!matches || !single) {
        scratch_release(matches, n);
        if (single != matches) scratch_release(single, n);
        return SIZE_MAX;
    }
    bool ok = true, any = true;
    uint32_t only_path_hit = UINT32_MAX;
    if (!path) {
        const char *longest = (const char *)patterns + offsets[0];
        for (size_t i = 1; i < words; i++) {
            const char *word = (const char *)patterns + offsets[i];
            if (strlen(word) > strlen(longest)) longest = word;
        }
        any = name_hits(v, longest, matches) > 0;
        if (any && words > 1) {
            for (uint32_t i = 0; i < n; i++)
                if (matches[i] && !all_words(key(v, i), patterns, offsets, words)) matches[i] = 0;
        }
    } else {
        PathWord first = {.view = v, .word = (const char *)patterns + offsets[0], .hits = matches, .all = all};
        size_t next = 1;
        if (words > 1 && n >= 50000) {
            PathWord second = {.view = v, .word = (const char *)patterns + offsets[1], .hits = single, .all = all};
            pthread_t thread;
            bool started = pthread_create(&thread, NULL, path_word, &second) == 0;
            path_word(&first);
            if (started) pthread_join(thread, NULL); else path_word(&second);
            ok = first.ok && second.ok;
            any = first.any && second.any;
            if (ok && any) for (size_t i = 0; i < n; i++) matches[i] &= single[i];
            next = 2;
        } else {
            path_word(&first);
            ok = first.ok;
            any = first.any;
        }
        if (words == 1 && first.visible_matches != SIZE_MAX) {
            size_t available = first.visible_matches > offset ? first.visible_matches - offset : 0;
            if (available < limit) limit = available;
            if (first.visible_matches == 1 && limit == 1) only_path_hit = first.sole_match;
        }
        for (size_t j = next; j < words && ok && any; j++) {
            PathWord task = {.view = v, .word = (const char *)patterns + offsets[j], .hits = single, .all = all};
            path_word(&task);
            ok = task.ok;
            any = task.any;
            if (ok && any) for (size_t i = 0; i < n; i++) matches[i] &= single[i];
        }
    }
    size_t result;
    if (only_path_hit != UINT32_MAX) {
        // One visible candidate has the same rank for every column and direction.
        results[0] = only_path_hit;
        result = 1;
    } else {
        result = !ok ? SIZE_MAX : !any ? 0 :
            select_order(v, order, matches, NULL, NULL, 0, descending, all, offset, limit, n, results);
    }
    if (single != matches) scratch_release(single, n);
    scratch_release(matches, n);
    return result;
}

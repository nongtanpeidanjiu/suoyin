#include "DarwinMetadata.h"
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <mach/mach.h>
#include <unistd.h>
#include <dirent.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <malloc/malloc.h>
#include <libproc.h>
#include <sys/resource.h>
#include <uuid/uuid.h>

static int expected_error(int error, DMCounts *counts) {
    switch (error) {
    case EACCES: case EPERM: counts->denied++; return 0;
    case ENOENT: case ENOTDIR: case ELOOP: counts->disappeared++; return 0;
    default: return error;
    }
}

static int64_t timestamp(struct timespec time) {
    int64_t nanos, result;
    if (__builtin_mul_overflow((int64_t)time.tv_sec, (int64_t)1000000000, &nanos) ||
        __builtin_add_overflow(nanos, (int64_t)time.tv_nsec, &result))
        return time.tv_sec < 0 ? INT64_MIN : INT64_MAX;
    return result;
}

static uint32_t node_type(mode_t mode) {
    if (S_ISDIR(mode)) return VDIR;
    if (S_ISREG(mode)) return VREG;
    if (S_ISLNK(mode)) return VLNK;
    return VNON;
}

static int stat_entry(int fd, const char *name, DMEntryCallback callback,
                      void *context, DMCounts *counts) {
    struct stat st;
    int result;
    do { result = fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW); } while (result < 0 && errno == EINTR);
    if (result < 0) return expected_error(errno, counts);
    callback(context, (const uint8_t *)name, strlen(name), st.st_size,
             timestamp(st.st_mtimespec), st.st_flags, node_type(st.st_mode));
    return 0;
}

static int ordinary_list(int fd, DMEntryCallback callback, void *context, DMCounts *counts) {
    DIR *directory = fdopendir(fd);
    if (!directory) {
        int error = errno;
        close(fd);
        return expected_error(error, counts);
    }
    int error = 0;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(directory);
        if (!entry && errno == EINTR) continue;
        if (!entry) { error = expected_error(errno, counts); break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        error = stat_entry(dirfd(directory), entry->d_name, callback, context, counts);
        if (error) break;
    }
    closedir(directory);
    return error;
}

static bool unpack(const unsigned char **p, const unsigned char *end, void *out, size_t size) {
    if ((size_t)(end - *p) < size) return false;
    memcpy(out, *p, size);
    *p += size;
    return true;
}

static int bulk_record(int fd, const unsigned char *record, const unsigned char *end,
                       DMEntryCallback callback, void *context, DMCounts *counts) {
    const unsigned char *cursor = record + sizeof(uint32_t);
    attribute_set_t returned;
    if (!unpack(&cursor, end, &returned, sizeof(returned))) return EPROTO;
    uint32_t row_error = 0;
    if ((returned.commonattr & ATTR_CMN_ERROR) &&
        !unpack(&cursor, end, &row_error, sizeof(row_error))) return EPROTO;
    if (row_error) return expected_error((int)row_error, counts);
    if (!(returned.commonattr & ATTR_CMN_NAME)) return EPROTO;

    const unsigned char *ref = cursor;
    attrreference_t name_ref;
    if (!unpack(&cursor, end, &name_ref, sizeof(name_ref))) return EPROTO;
    if (name_ref.attr_dataoffset < (int)sizeof(name_ref) ||
        name_ref.attr_dataoffset > end - ref || name_ref.attr_length == 0) return EPROTO;
    const unsigned char *name = ref + name_ref.attr_dataoffset;
    if (name_ref.attr_length > end - name ||
        name[name_ref.attr_length - 1] != 0 ||
        memchr(name, 0, name_ref.attr_length - 1)) return EPROTO;

    const uint32_t needed = ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FLAGS;
    if ((returned.commonattr & needed) != needed)
        return stat_entry(fd, (const char *)name, callback, context, counts);
    uint32_t type, flags;
    struct timespec modified;
    if (!unpack(&cursor, name, &type, sizeof(type)) ||
        !unpack(&cursor, name, &modified, sizeof(modified)) ||
        !unpack(&cursor, name, &flags, sizeof(flags))) return EPROTO;
    if (type != VREG || !(returned.fileattr & ATTR_FILE_DATALENGTH))
        return stat_entry(fd, (const char *)name, callback, context, counts);
    int64_t size;
    if (!unpack(&cursor, name, &size, sizeof(size))) return EPROTO;
    callback(context, name, name_ref.attr_length - 1, size, timestamp(modified), flags, type);
    return 0;
}

static int list(const char *path, int32_t device_a, int32_t device_b, bool ordinary,
                bool load_directory, DMEntryCallback callback, void *context, DMCounts *counts) {
    struct stat st;
    int result;
    do { result = lstat(path, &st); } while (result < 0 && errno == EINTR);
    if (result < 0) return expected_error(errno, counts);
    if (!S_ISDIR(st.st_mode)) return expected_error(ENOTDIR, counts);
    if (st.st_dev != device_a && st.st_dev != device_b) { counts->other_mount++; return 0; }
    if (!load_directory && (st.st_flags & SF_DATALESS)) { counts->pending++; return 0; }

    int fd;
    do { fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); } while (fd < 0 && errno == EINTR);
    if (fd < 0) return expected_error(errno, counts);
    do { result = fstat(fd, &st); } while (result < 0 && errno == EINTR);
    if (result < 0) { int error = errno; close(fd); return expected_error(error, counts); }
    if (st.st_dev != device_a && st.st_dev != device_b) { close(fd); counts->other_mount++; return 0; }
    if (!load_directory && (st.st_flags & SF_DATALESS)) { close(fd); counts->pending++; return 0; }
    if (ordinary) return ordinary_list(fd, callback, context, counts);

    struct attrlist attrs = {
        .bitmapcount = ATTR_BIT_MAP_COUNT,
        .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME |
                      ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FLAGS,
        .fileattr = ATTR_FILE_DATALENGTH
    };
    _Alignas(8) unsigned char buffer[65536];
    bool started = false;
    int error = 0;
    for (;;) {
        int number = getattrlistbulk(fd, &attrs, buffer, sizeof(buffer), 0);
        if (number < 0) {
            int code = errno;
            if (code == EINTR) continue;
            if (!started && (code == ENOTSUP || code == EOPNOTSUPP || code == ENOSYS)) {
                if (lseek(fd, 0, SEEK_SET) < 0) { error = errno; break; }
                counts->fallback++;
                return ordinary_list(fd, callback, context, counts);
            }
            error = expected_error(code, counts);
            break;
        }
        if (number == 0) break;
        started = true;
        const unsigned char *record = buffer;
        for (int i = 0; i < number; i++) {
            const unsigned char *cursor = record;
            uint32_t length;
            if (!unpack(&cursor, buffer + sizeof(buffer), &length, sizeof(length)) ||
                length < sizeof(length) || length > buffer + sizeof(buffer) - record) {
                error = EPROTO;
                break;
            }
            error = bulk_record(fd, record, record + length, callback, context, counts);
            if (error) break;
            record += length;
        }
        if (error) break;
    }
    close(fd);
    return error;
}

int dm_list(const char *path, int32_t device_a, int32_t device_b, bool ordinary,
            DMEntryCallback callback, void *context, DMCounts *counts) {
    return list(path, device_a, device_b, ordinary, false, callback, context, counts);
}

int dm_list_cloud(const char *path, int32_t device, DMEntryCallback callback,
                  void *context, DMCounts *counts) {
    // Opening the directory may ask the provider for its listing. Regular
    // files are only inspected with getattrlistbulk or fstatat.
    return list(path, device, device, false, true, callback, context, counts);
}

bool dm_volume_uuid(const char *path, char output[37]) {
    struct attrlist attributes = {
        .bitmapcount = ATTR_BIT_MAP_COUNT,
        .volattr = ATTR_VOL_INFO | ATTR_VOL_UUID
    };
    struct { uint32_t length; uuid_t uuid; } result = {0};
    if (getattrlist(path, &attributes, &result, sizeof(result), 0) != 0 ||
        result.length < sizeof(result) || uuid_is_null(result.uuid)) return false;
    uuid_unparse_upper(result.uuid, output);
    return true;
}

uint64_t dm_resident_bytes(void) {
    mach_task_basic_info_data_t info;
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), MACH_TASK_BASIC_INFO, (task_info_t)&info, &count);
    return result == KERN_SUCCESS ? info.resident_size : 0;
}

DMProcessMetrics dm_process_metrics(void) {
    DMProcessMetrics result = {0};
    struct rusage_info_v4 usage = {0};
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V4, (rusage_info_t *)&usage) == 0) {
        result.available = true;
        result.footprint = usage.ri_phys_footprint;
        result.footprint_peak = usage.ri_lifetime_max_phys_footprint;
        result.written_bytes = usage.ri_diskio_byteswritten;
    }
    malloc_statistics_t heap = {0};
    malloc_zone_statistics(NULL, &heap);
    result.heap_used = heap.size_in_use;
    result.heap_reserved = heap.size_allocated;
    return result;
}

void dm_release_allocator_cache(void) {
    malloc_zone_pressure_relief(NULL, 0);
}

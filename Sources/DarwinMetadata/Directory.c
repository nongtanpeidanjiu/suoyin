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
#include <time.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/storage/IOStorageDeviceCharacteristics.h>

static int expected_error(int error, DMCounts *counts) {
    switch (error) {
    case EACCES: case EPERM: counts->denied++; return 0;
    case ENOENT: case ENOTDIR: case ELOOP: counts->disappeared++; return 0;
    default: return error;
    }
}

static int directory_error(int error, DMCounts *counts) {
    if (error == EACCES || error == EPERM) counts->directory_error = error;
    return expected_error(error, counts);
}

static int entry_error(int error, const unsigned char *name, size_t length,
                       DMDeniedEntryCallback denied, void *context, DMCounts *counts) {
    if (error == EACCES || error == EPERM) denied(context, name, length, error);
    return expected_error(error, counts);
}

static int64_t timestamp(struct timespec time) {
    int64_t nanos, result;
    if (__builtin_mul_overflow((int64_t)time.tv_sec, (int64_t)1000000000, &nanos) ||
        __builtin_add_overflow(nanos, (int64_t)time.tv_nsec, &result))
        return time.tv_sec < 0 ? INT64_MIN : INT64_MAX;
    return result;
}

static DMDirectoryStamp directory_stamp(const struct stat *st) {
    return (DMDirectoryStamp){st->st_ino, timestamp(st->st_mtimespec),
                             timestamp(st->st_ctimespec), timestamp(st->st_birthtimespec), st->st_size};
}

int dm_directory_stamp(const char *path, int32_t device, DMDirectoryStamp *stamp) {
    int fd;
    do { fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); }
    while (fd < 0 && errno == EINTR);
    if (fd < 0) return errno;
    struct stat st;
    int result;
    do { result = fstat(fd, &st); } while (result < 0 && errno == EINTR);
    int error = result < 0 ? errno : 0;
    close(fd);
    if (error) return error;
    if (st.st_dev != device || (st.st_flags & SF_DATALESS)) return ESTALE;
    *stamp = directory_stamp(&st);
    return 0;
}

int dm_media_kind(uint32_t service) {
    if (!service) return 0;
    CFTypeRef value = IORegistryEntrySearchCFProperty(service, kIOServicePlane,
        CFSTR(kIOPropertyDeviceCharacteristicsKey), kCFAllocatorDefault,
        kIORegistryIterateRecursively | kIORegistryIterateParents);
    if (!value) return 0;
    int kind = 0;
    if (CFGetTypeID(value) == CFDictionaryGetTypeID()) {
        CFTypeRef medium = CFDictionaryGetValue(value, CFSTR(kIOPropertyMediumTypeKey));
        if (medium && CFEqual(medium, CFSTR(kIOPropertyMediumTypeSolidStateKey))) kind = 2;
        if (medium && CFEqual(medium, CFSTR(kIOPropertyMediumTypeRotationalKey))) kind = 1;
    }
    CFRelease(value);
    return kind;
}

static int finish_listing(int fd, int error, DMCounts *counts) {
    if (error || !counts->capture_stamp || counts->denied || counts->disappeared) return error;
    struct stat st;
    int result;
    do { result = fstat(fd, &st); } while (result < 0 && errno == EINTR);
    if (result < 0) return directory_error(errno, counts);
    const DMDirectoryStamp end = directory_stamp(&st);
    counts->stamp_valid = end.inode == counts->stamp.inode &&
        end.modified == counts->stamp.modified && end.changed == counts->stamp.changed &&
        end.created == counts->stamp.created && end.size == counts->stamp.size;
    return 0;
}

static uint32_t node_type(mode_t mode) {
    if (S_ISDIR(mode)) return VDIR;
    if (S_ISREG(mode)) return VREG;
    if (S_ISLNK(mode)) return VLNK;
    return VNON;
}

static int stat_entry(int fd, const char *name, DMEntryCallback callback,
                      DMDeniedEntryCallback denied, void *context, DMCounts *counts) {
    struct stat st;
    int result;
    uint64_t start = counts->profile ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0;
    do { result = fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW); } while (result < 0 && errno == EINTR);
    int error = result < 0 ? errno : 0;
    if (counts->profile) {
        counts->stat_calls++;
        counts->stat_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
    }
    if (error) return entry_error(error, (const uint8_t *)name, strlen(name), denied, context, counts);
    callback(context, (const uint8_t *)name, strlen(name), st.st_size,
             timestamp(st.st_mtimespec), st.st_flags, node_type(st.st_mode));
    return 0;
}

static int ordinary_list(int fd, DMEntryCallback callback, DMDeniedEntryCallback denied,
                         void *context, DMCounts *counts) {
    DIR *directory = fdopendir(fd);
    if (!directory) {
        int error = errno;
        close(fd);
        return directory_error(error, counts);
    }
    int error = 0;
    for (;;) {
        uint64_t start = counts->profile ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0;
        errno = 0;
        struct dirent *entry = readdir(directory);
        int code = errno;
        if (counts->profile) {
            counts->readdir_calls++;
            counts->readdir_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
        }
        if (!entry && code == EINTR) continue;
        if (!entry) { error = directory_error(code, counts); break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        error = stat_entry(dirfd(directory), entry->d_name, callback, denied, context, counts);
        if (error) break;
    }
    error = finish_listing(dirfd(directory), error, counts);
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
                       DMEntryCallback callback, DMDeniedEntryCallback denied, void *context, DMCounts *counts) {
    const unsigned char *cursor = record + sizeof(uint32_t);
    attribute_set_t returned;
    if (!unpack(&cursor, end, &returned, sizeof(returned))) return EPROTO;
    uint32_t row_error = 0;
    if ((returned.commonattr & ATTR_CMN_ERROR) &&
        !unpack(&cursor, end, &row_error, sizeof(row_error))) return EPROTO;
    if (row_error && (row_error != EACCES && row_error != EPERM))
        return expected_error((int)row_error, counts);
    if (row_error && !(returned.commonattr & ATTR_CMN_NAME))
        return entry_error((int)row_error, NULL, 0, denied, context, counts);
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
    if (row_error) return entry_error((int)row_error, name, name_ref.attr_length - 1, denied, context, counts);

    const uint32_t needed = ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FLAGS;
    if ((returned.commonattr & needed) != needed)
        return stat_entry(fd, (const char *)name, callback, denied, context, counts);
    uint32_t type, flags;
    struct timespec modified;
    if (!unpack(&cursor, name, &type, sizeof(type)) ||
        !unpack(&cursor, name, &modified, sizeof(modified)) ||
        !unpack(&cursor, name, &flags, sizeof(flags))) return EPROTO;
    bool directory_length = type == VDIR && counts->directory_lengths &&
                            (returned.dirattr & ATTR_DIR_DATALENGTH);
    if (!directory_length && (type != VREG || !(returned.fileattr & ATTR_FILE_DATALENGTH)))
        return stat_entry(fd, (const char *)name, callback, denied, context, counts);
    int64_t size;
    if (!unpack(&cursor, name, &size, sizeof(size))) return EPROTO;
    if (directory_length && counts->profile) counts->directory_length_rows++;
    callback(context, name, name_ref.attr_length - 1, size, timestamp(modified), flags, type);
    return 0;
}

static int list(const char *path, int32_t device_a, int32_t device_b, bool ordinary,
                bool load_directory, DMEntryCallback callback, DMDeniedEntryCallback denied,
                void *context, DMCounts *counts) {
    struct stat st;
    int result;
    uint64_t start = counts->profile ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0;
    do { result = lstat(path, &st); } while (result < 0 && errno == EINTR);
    if (result < 0) return directory_error(errno, counts);
    if (!S_ISDIR(st.st_mode)) return expected_error(ENOTDIR, counts);
    if (st.st_dev != device_a && st.st_dev != device_b) { counts->other_mount++; return 0; }
    if (!load_directory && (st.st_flags & SF_DATALESS)) { counts->pending++; return 0; }

    int fd;
    do { fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); } while (fd < 0 && errno == EINTR);
    if (fd < 0) return directory_error(errno, counts);
    do { result = fstat(fd, &st); } while (result < 0 && errno == EINTR);
    if (result < 0) { int error = errno; close(fd); return directory_error(error, counts); }
    if (st.st_dev != device_a && st.st_dev != device_b) { close(fd); counts->other_mount++; return 0; }
    if (!load_directory && (st.st_flags & SF_DATALESS)) { close(fd); counts->pending++; return 0; }
    if (counts->profile) counts->open_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start;
    if (counts->capture_stamp) counts->stamp = directory_stamp(&st);
    if (ordinary) return ordinary_list(fd, callback, denied, context, counts);

    struct attrlist attrs = {
        .bitmapcount = ATTR_BIT_MAP_COUNT,
        .commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME |
                      ATTR_CMN_OBJTYPE | ATTR_CMN_MODTIME | ATTR_CMN_FLAGS,
        .dirattr = counts->directory_lengths ? ATTR_DIR_DATALENGTH : 0,
        .fileattr = ATTR_FILE_DATALENGTH
    };
    _Alignas(8) unsigned char buffer[65536];
    bool started = false;
    int error = 0;
    for (;;) {
        uint64_t before = counts->profile ? clock_gettime_nsec_np(CLOCK_UPTIME_RAW) : 0;
        int number = getattrlistbulk(fd, &attrs, buffer, sizeof(buffer), 0);
        int code = errno;
        if (counts->profile) {
            counts->bulk_calls++;
            counts->bulk_ns += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - before;
        }
        if (number < 0) {
            if (code == EINTR) continue;
            if (!started && code == EINVAL && attrs.dirattr) {
                if (lseek(fd, 0, SEEK_SET) < 0) { error = errno; break; }
                attrs.dirattr = 0;
                continue;
            }
            if (!started && (code == ENOTSUP || code == EOPNOTSUPP || code == ENOSYS)) {
                if (lseek(fd, 0, SEEK_SET) < 0) { error = errno; break; }
                counts->fallback++;
                return ordinary_list(fd, callback, denied, context, counts);
            }
            error = directory_error(code, counts);
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
            error = bulk_record(fd, record, record + length, callback, denied, context, counts);
            if (error) break;
            record += length;
        }
        if (error) break;
    }
    error = finish_listing(fd, error, counts);
    close(fd);
    return error;
}

int dm_list(const char *path, int32_t device_a, int32_t device_b, bool ordinary,
            DMEntryCallback callback, DMDeniedEntryCallback denied, void *context, DMCounts *counts) {
    return list(path, device_a, device_b, ordinary, false, callback, denied, context, counts);
}

int dm_list_cloud(const char *path, int32_t device, DMEntryCallback callback,
                  DMDeniedEntryCallback denied, void *context, DMCounts *counts) {
    // Opening the directory may ask the provider for its listing. Regular
    // files are only inspected with getattrlistbulk or fstatat.
    return list(path, device, device, false, true, callback, denied, context, counts);
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

//  Minimal declarations for the libarchive that ships with macOS.
//
//  macOS provides /usr/lib/libarchive.2.dylib (libarchive 3.7.4) and the SDK
//  provides a linkable stub (libarchive.2.tbd), but it does NOT ship
//  archive.h / archive_entry.h. So we declare the handful of entry points we
//  actually use. Every symbol below was verified present in
//  $(xcrun --show-sdk-path)/usr/lib/libarchive.2.tbd.

#ifndef CLIBARCHIVE_H
#define CLIBARCHIVE_H

#include <sys/types.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct archive;
struct archive_entry;

// Return codes.
#define CA_EOF     1
#define CA_OK      0
#define CA_RETRY (-10)
#define CA_WARN  (-20)
#define CA_FAILED (-25)
#define CA_FATAL (-30)

// Regular-file bit from archive_entry_filetype().
#define CA_IFREG 0100000

struct archive *archive_read_new(void);

int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_rar(struct archive *);
int archive_read_support_format_rar5(struct archive *);
int archive_read_support_format_zip(struct archive *);
int archive_read_support_format_7zip(struct archive *);

int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
ssize_t archive_read_data(struct archive *, void *buff, size_t len);
int archive_read_free(struct archive *);

const char *archive_error_string(struct archive *);
int archive_errno(struct archive *);

const char *archive_entry_pathname_utf8(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);

#ifdef __cplusplus
}
#endif

#endif /* CLIBARCHIVE_H */

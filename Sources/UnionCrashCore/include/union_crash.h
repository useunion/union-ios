/*
 * The part of crash reporting that cannot be written in Swift.
 *
 * A signal handler runs on a thread that is already dying, possibly holding the malloc lock, with no
 * guarantee that the Objective-C runtime is in a usable state. Everything it touches has to be
 * async-signal-safe: no allocation, no Obj-C, no locks, no `String`, no Swift runtime at all — and
 * Swift cannot promise any of that, because even a retain is a runtime call. So the handler lives
 * here, in C, and does exactly one thing: fill a preallocated buffer and `write()` it to a file
 * descriptor that was opened before the crash.
 *
 * Everything that needs a real API — reading the report, turning it into JSON, uploading it — happens
 * on the next launch, in Swift, in a healthy process. The division is not stylistic: the process that
 * died is not the process that sends the report.
 */
#ifndef UNION_CRASH_H
#define UNION_CRASH_H

#include <stdint.h>
#include <stddef.h>
#include <mach/port.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Contract limits, mirrored from `packages/contract/src/limits.ts` (`LIMITS.crash`). */
#define UNION_CRASH_MAX_THREADS 48
#define UNION_CRASH_MAX_FRAMES 128
#define UNION_CRASH_MAX_IMAGES 512
#define UNION_CRASH_MAX_BREADCRUMBS 64
#define UNION_CRASH_BREADCRUMB_NAME 128
#define UNION_CRASH_THREAD_NAME 64
#define UNION_CRASH_IMAGE_NAME 256

/** Record format version. Bumped when the binary layout below changes. */
#define UNION_CRASH_RECORD_VERSION 1

/** What ended the process. Mirrors `CrashKind` for the two shapes the handler can produce. */
typedef enum {
    UNION_CRASH_CAUSE_SIGNAL = 1,
    UNION_CRASH_CAUSE_MACH = 2,
    UNION_CRASH_CAUSE_EXCEPTION = 3,
} union_crash_cause;

/**
 * One loaded binary, snapshotted **at install time**.
 *
 * `_dyld_image_count` and friends take a lock, so calling them from a handler can deadlock against
 * the thread that was in the middle of `dlopen`. The snapshot is therefore taken while the process
 * is healthy, and the documented consequence is that a library loaded after install has no entry —
 * its frames arrive with `image: null`, which the contract allows and the panel renders as an
 * address in no known image. That is a true statement about what we know; a guessed image would not
 * be.
 */
typedef struct {
    uint64_t load_addr;
    uint64_t size;
    uint8_t uuid[16];
    uint8_t has_uuid;
    uint8_t is_app;
    char name[UNION_CRASH_IMAGE_NAME];
} union_crash_image;

/**
 * Installs the handlers and opens `report_path` for writing.
 *
 * The file is created empty and stays empty unless the process dies: **zero bytes means no crash**,
 * which is how the next launch tells "nothing happened" apart from "something happened and we have
 * it". Returns 0 on success, -1 if the file could not be opened (in which case nothing is installed —
 * a handler with nowhere to write would spend the last instructions of the process producing nothing).
 */
int union_crash_install(const char *report_path);

/** Removes the handlers and closes the descriptor. Safe to call when nothing is installed. */
void union_crash_uninstall(void);

/** True once the handler has written a record in this process. */
int union_crash_did_write(void);

/**
 * Whether the app was in the foreground, as last reported by Swift.
 *
 * A byte, written by a plain store, because the handler may only read one — `UIApplication.state`
 * is main-thread-only and not signal-safe. `-1` = never reported, and stays absent on the wire
 * rather than becoming a confident `false`.
 */
void union_crash_set_foreground(int foreground);

/**
 * Appends a breadcrumb to a preallocated ring buffer the handler can dump.
 *
 * Names only — the buffer has no field for a value, mirroring `Breadcrumb` in the contract. That is
 * the privacy decision of this feature, and it is held by the shape of this struct rather than by
 * anybody remembering it: breadcrumbs bypass the event pipeline, so the remote kill switch never
 * filtered them, and a value field here would carry event properties out of screens the app believed
 * were excluded.
 */
void union_crash_add_breadcrumb(uint8_t kind, const char *name, int64_t ts_ms);

/** Snapshots the loaded images. Called from healthy code, never from a handler. Returns the count. */
int union_crash_images(union_crash_image *out, int max);

/**
 * Captures a record from a **living** process: the same thread enumeration, frame walk and
 * serialisation the handler performs, followed by resuming the threads it suspended.
 *
 * Two callers, and they are the reason this is not a test-only hook. A hang is reported while the
 * app is still running — the whole point is that the main thread is stuck and the watchdog is not —
 * so the blocked stack has to be captured by healthy code. And tests cannot crash the test runner,
 * so this is the only way to exercise the walker at all.
 *
 * `crashed_thread` is the thread to mark as the crashed one, or `MACH_PORT_NULL` for the caller's
 * own thread. For a hang that is the main thread, never the watchdog that noticed.
 */
int union_crash_capture_live(const char *path, int signum, mach_port_t crashed_thread);

#ifdef __cplusplus
}
#endif

#endif /* UNION_CRASH_H */

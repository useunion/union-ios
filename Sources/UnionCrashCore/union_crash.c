#include "include/union_crash.h"

#include <errno.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

/*
 * Layout of one record, little-endian, written with a single `write()`.
 *
 * Binary rather than JSON because a handler must not call `snprintf`: it is not async-signal-safe,
 * it can allocate, and a locale-aware formatter is the last thing this code should depend on. The
 * parser on the other side is `CrashRecord.swift`, and `UNION_CRASH_RECORD_VERSION` is the seam.
 *
 *   magic 'U','C','R','1'          4
 *   version                        u16
 *   cause                          u16
 *   crashed_at_ms                  i64   CLOCK_REALTIME, the client's wall clock at death
 *   uptime_ms                      i64   monotonic, process start → death
 *   signum, sigcode                i32 i32
 *   mach_exception                 u32
 *   mach_code, mach_subcode        u64 u64
 *   fault_addr                     u64
 *   foreground                     i8    -1 = never reported
 *   thread_count                   u16
 *   crashed_thread                 u16
 *   breadcrumb_count               u16
 *   threads[thread_count]:
 *     index u32, crashed u8, truncated u8, frame_count u16, name[64], frames[frame_count] u64
 *   breadcrumbs[breadcrumb_count]:
 *     ts i64, kind u8, len u8, name[len]
 */

#define UNION_CRASH_BUFFER_BYTES (192 * 1024)

/* Every one of these lives in BSS: a handler cannot allocate, so all of it is reserved up front. */
static uint8_t g_buffer[UNION_CRASH_BUFFER_BYTES];
static int g_fd = -1;
static atomic_int g_wrote = 0;
static atomic_int g_installed = 0;
static volatile int8_t g_foreground = -1;
static uint64_t g_started_ms = 0;

static union_crash_image g_images[UNION_CRASH_MAX_IMAGES];
static int g_image_count = 0;

typedef struct {
    int64_t ts;
    uint8_t kind;
    uint8_t len;
    char name[UNION_CRASH_BREADCRUMB_NAME];
} union_crash_crumb;

static union_crash_crumb g_crumbs[UNION_CRASH_MAX_BREADCRUMBS];
/*
 * A monotonically increasing write cursor, never wrapped in place: the handler reads `total` once and
 * derives the window, so a breadcrumb being written concurrently can be missed but never half-read
 * into the middle of an older one.
 */
static atomic_ullong g_crumb_total = 0;

static const int g_signals[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP, SIGSYS};
static const int g_signal_count = (int)(sizeof(g_signals) / sizeof(g_signals[0]));
static struct sigaction g_previous[sizeof(g_signals) / sizeof(g_signals[0])];
static char g_altstack[SIGSTKSZ * 2];

static mach_port_t g_exception_port = MACH_PORT_NULL;
static exception_mask_t g_previous_masks[EXC_TYPES_COUNT];
static mach_port_t g_previous_ports[EXC_TYPES_COUNT];
static exception_behavior_t g_previous_behaviors[EXC_TYPES_COUNT];
static thread_state_flavor_t g_previous_flavors[EXC_TYPES_COUNT];
static mach_msg_type_number_t g_previous_count = 0;
static pthread_t g_exception_thread;
static thread_t g_exception_machthread = MACH_PORT_NULL;

/* ------------------------------------------------------------------ clocks --- */

static int64_t union_crash_wall_ms(void) {
    struct timespec ts;
    /* clock_gettime is on POSIX's async-signal-safe list; `gettimeofday` is not. */
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) return 0;
    return (int64_t)ts.tv_sec * 1000 + (int64_t)(ts.tv_nsec / 1000000);
}

static uint64_t union_crash_mono_ms(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)(ts.tv_nsec / 1000000);
}

/* ------------------------------------------------------------------ buffer --- */

typedef struct {
    uint8_t *bytes;
    size_t capacity;
    size_t length;
} union_crash_writer;

static void union_crash_put(union_crash_writer *w, const void *src, size_t n) {
    if (w->length + n > w->capacity) return; /* Truncation is bounded and reported by the counts. */
    memcpy(w->bytes + w->length, src, n);
    w->length += n;
}

static void union_crash_put_u8(union_crash_writer *w, uint8_t v) { union_crash_put(w, &v, 1); }
static void union_crash_put_u16(union_crash_writer *w, uint16_t v) { union_crash_put(w, &v, 2); }
static void union_crash_put_u32(union_crash_writer *w, uint32_t v) { union_crash_put(w, &v, 4); }
static void union_crash_put_u64(union_crash_writer *w, uint64_t v) { union_crash_put(w, &v, 8); }
static void union_crash_put_i64(union_crash_writer *w, int64_t v) { union_crash_put(w, &v, 8); }

/* -------------------------------------------------------------- memory read --- */

/**
 * Reads our own memory the way a handler is allowed to: a mach trap, which returns an error for an
 * unmapped page instead of raising a second fault inside the first one.
 */
static int union_crash_read(uint64_t address, void *out, size_t size) {
    vm_size_t read = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)address,
                                         (vm_size_t)size, (vm_address_t)out, &read);
    return (kr == KERN_SUCCESS && read == size) ? 0 : -1;
}

/* ------------------------------------------------------------- frame walking --- */

typedef struct {
    uint64_t pc;
    uint64_t fp;
    uint64_t lr;
} union_crash_regs;

static int union_crash_regs_of(thread_t thread, union_crash_regs *out) {
#if defined(__arm64__) || defined(__aarch64__)
    arm_thread_state64_t state;
    mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count) != KERN_SUCCESS) {
        return -1;
    }
    /*
     * Through the accessors, not the raw fields: on arm64e the pc and lr are signed pointers, and a
     * raw read would hand the symbolicator an address with authentication bits still in it — an
     * address that resolves to nothing and looks exactly like a corrupt stack.
     */
    out->pc = (uint64_t)arm_thread_state64_get_pc(state);
    out->lr = (uint64_t)arm_thread_state64_get_lr(state);
    out->fp = (uint64_t)arm_thread_state64_get_fp(state);
    return 0;
#elif defined(__x86_64__)
    x86_thread_state64_t state;
    mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    if (thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &count) != KERN_SUCCESS) {
        return -1;
    }
    out->pc = state.__rip;
    out->lr = 0; /* No link register; the return address is on the stack. */
    out->fp = state.__rbp;
    return 0;
#else
    (void)thread;
    (void)out;
    return -1;
#endif
}

/**
 * Walks the frame-pointer chain.
 *
 * Deliberately not `backtrace()`: that resolves through libunwind, which allocates and takes locks.
 * The chain is validated at every step — the next frame pointer has to be higher than the current
 * one and readable — so a corrupt stack ends the walk instead of producing a plausible fiction or
 * looping forever.
 */
static int union_crash_walk(thread_t thread, uint64_t *frames, int max, int *truncated) {
    union_crash_regs regs;
    *truncated = 0;
    if (union_crash_regs_of(thread, &regs) != 0) return 0;

    int count = 0;
    if (regs.pc != 0 && count < max) frames[count++] = regs.pc;
    if (regs.lr != 0 && count < max) frames[count++] = regs.lr;

    uint64_t fp = regs.fp;
    while (fp != 0 && count < max) {
        struct {
            uint64_t next_fp;
            uint64_t return_addr;
        } frame;
        if (union_crash_read(fp, &frame, sizeof(frame)) != 0) break;
        if (frame.return_addr == 0) break;
        frames[count++] = frame.return_addr;
        if (frame.next_fp <= fp) break; /* Stacks grow down, so the chain must climb. */
        fp = frame.next_fp;
    }
    if (count >= max && fp != 0) *truncated = 1;
    return count;
}

static void union_crash_thread_name(thread_t thread, char *out, size_t size) {
    memset(out, 0, size);
    /*
     * The dispatch queue label, read out of the thread's identifier info. `pthread_getname_np` needs
     * a pthread_t, and mapping a mach thread back to one is not something a handler may do.
     */
    thread_identifier_info_data_t info;
    mach_msg_type_number_t count = THREAD_IDENTIFIER_INFO_COUNT;
    if (thread_info(thread, THREAD_IDENTIFIER_INFO, (thread_info_t)&info, &count) != KERN_SUCCESS) return;
    if (info.thread_handle == 0) return;
    struct {
        uint64_t label_ptr;
    } queue;
    if (union_crash_read((uint64_t)info.dispatch_qaddr, &queue, sizeof(queue)) != 0) return;
    if (queue.label_ptr == 0) return;
    char raw[UNION_CRASH_THREAD_NAME];
    if (union_crash_read(queue.label_ptr, raw, sizeof(raw)) != 0) return;
    raw[sizeof(raw) - 1] = 0;
    size_t n = strnlen(raw, sizeof(raw) - 1);
    if (n >= size) n = size - 1;
    memcpy(out, raw, n);
}

/* ------------------------------------------------------------------- record --- */

static size_t union_crash_serialize(union_crash_cause cause,
                                    int signum,
                                    int sigcode,
                                    uint32_t mach_exception,
                                    uint64_t mach_code,
                                    uint64_t mach_subcode,
                                    uint64_t fault_addr,
                                    thread_t crashed_thread,
                                    thread_t *threads,
                                    mach_msg_type_number_t thread_count) {
    union_crash_writer w = {g_buffer, sizeof(g_buffer), 0};
    union_crash_put(&w, "UCR1", 4);
    union_crash_put_u16(&w, UNION_CRASH_RECORD_VERSION);
    union_crash_put_u16(&w, (uint16_t)cause);
    union_crash_put_i64(&w, union_crash_wall_ms());
    uint64_t now = union_crash_mono_ms();
    union_crash_put_i64(&w, (int64_t)(now > g_started_ms ? now - g_started_ms : 0));
    union_crash_put_u32(&w, (uint32_t)signum);
    union_crash_put_u32(&w, (uint32_t)sigcode);
    union_crash_put_u32(&w, mach_exception);
    union_crash_put_u64(&w, mach_code);
    union_crash_put_u64(&w, mach_subcode);
    union_crash_put_u64(&w, fault_addr);
    union_crash_put_u8(&w, (uint8_t)g_foreground);

    int emit = (int)thread_count;
    if (emit > UNION_CRASH_MAX_THREADS) emit = UNION_CRASH_MAX_THREADS;

    /*
     * The crashed thread is always in the dump, even when the process has more threads than the cap.
     * Losing it to a cap would leave a fatal report with no crashed thread — which the contract
     * rejects, correctly: there would be nothing to fingerprint.
     */
    int crashed_index = -1;
    for (int i = 0; i < (int)thread_count; i++) {
        if (threads[i] == crashed_thread) { crashed_index = i; break; }
    }
    if (crashed_index >= emit && crashed_index >= 0) {
        thread_t swap = threads[0];
        threads[0] = threads[crashed_index];
        threads[crashed_index] = swap;
        crashed_index = 0;
    }

    size_t thread_count_offset = w.length;
    union_crash_put_u16(&w, 0);
    union_crash_put_u16(&w, (uint16_t)(crashed_index < 0 ? 0xffff : crashed_index));
    size_t crumb_count_offset = w.length;
    union_crash_put_u16(&w, 0);

    uint16_t written_threads = 0;
    for (int i = 0; i < emit; i++) {
        uint64_t frames[UNION_CRASH_MAX_FRAMES];
        int truncated = 0;
        int frames_count = union_crash_walk(threads[i], frames, UNION_CRASH_MAX_FRAMES, &truncated);
        char name[UNION_CRASH_THREAD_NAME];
        union_crash_thread_name(threads[i], name, sizeof(name));

        union_crash_put_u32(&w, (uint32_t)i);
        union_crash_put_u8(&w, threads[i] == crashed_thread ? 1 : 0);
        union_crash_put_u8(&w, (uint8_t)truncated);
        union_crash_put_u16(&w, (uint16_t)frames_count);
        union_crash_put(&w, name, sizeof(name));
        for (int f = 0; f < frames_count; f++) union_crash_put_u64(&w, frames[f]);
        written_threads++;
    }
    memcpy(g_buffer + thread_count_offset, &written_threads, 2);

    unsigned long long total = atomic_load(&g_crumb_total);
    int available = total > UNION_CRASH_MAX_BREADCRUMBS ? UNION_CRASH_MAX_BREADCRUMBS : (int)total;
    uint16_t written_crumbs = 0;
    for (int i = 0; i < available; i++) {
        unsigned long long index = total - available + i;
        union_crash_crumb *crumb = &g_crumbs[index % UNION_CRASH_MAX_BREADCRUMBS];
        uint8_t len = crumb->len;
        if (len == 0 || len > UNION_CRASH_BREADCRUMB_NAME) continue;
        union_crash_put_i64(&w, crumb->ts);
        union_crash_put_u8(&w, crumb->kind);
        union_crash_put_u8(&w, len);
        union_crash_put(&w, crumb->name, len);
        written_crumbs++;
    }
    memcpy(g_buffer + crumb_count_offset, &written_crumbs, 2);
    return w.length;
}

/**
 * Suspends every thread but this one, so the frame walk sees stacks that are standing still.
 *
 * Not resumed on the crash paths: the process is about to be replaced by the kernel's own handling,
 * and resuming threads whose stacks we have already reported would let them run a few more
 * instructions for no benefit.
 */
static void union_crash_suspend_others(thread_t self, thread_t *threads, mach_msg_type_number_t count) {
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        if (threads[i] != self) thread_suspend(threads[i]);
    }
}

static void union_crash_resume_others(thread_t self, thread_t *threads, mach_msg_type_number_t count) {
    for (mach_msg_type_number_t i = 0; i < count; i++) {
        if (threads[i] != self) thread_resume(threads[i]);
    }
}

static void union_crash_write(union_crash_cause cause,
                              int signum,
                              int sigcode,
                              uint32_t mach_exception,
                              uint64_t mach_code,
                              uint64_t mach_subcode,
                              uint64_t fault_addr,
                              thread_t crashed_thread) {
    /*
     * First writer wins, and there will be two candidates: a mach exception that we let fall through
     * lands as a signal a moment later. The second report would describe the same death from inside
     * our own handler's stack.
     */
    int expected = 0;
    if (!atomic_compare_exchange_strong(&g_wrote, &expected, 1)) return;
    if (g_fd < 0) return;

    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
        threads = NULL;
        count = 0;
    }
    thread_t self = mach_thread_self();
    if (threads) union_crash_suspend_others(self, threads, count);

    size_t length = union_crash_serialize(cause, signum, sigcode, mach_exception, mach_code,
                                          mach_subcode, fault_addr, crashed_thread, threads, count);

    size_t offset = 0;
    while (offset < length) {
        ssize_t n = write(g_fd, g_buffer + offset, length - offset);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            break;
        }
        offset += (size_t)n;
    }
    fsync(g_fd);
    mach_port_deallocate(mach_task_self(), self);
}

/* ------------------------------------------------------------------ signals --- */

static void union_crash_signal_handler(int signum, siginfo_t *info, void *context) {
    (void)context;
    thread_t self = mach_thread_self();
    union_crash_write(UNION_CRASH_CAUSE_SIGNAL, signum, info ? info->si_code : 0, 0, 0, 0,
                      info ? (uint64_t)info->si_addr : 0, self);
    mach_port_deallocate(mach_task_self(), self);

    /*
     * Hand the process back to whoever had the signal before us, and if nobody did, to the default
     * disposition. Swallowing it would leave the app in an undefined state pretending to run, and
     * the crash we just recorded would never appear in Apple's own crash log either.
     */
    for (int i = 0; i < g_signal_count; i++) {
        if (g_signals[i] != signum) continue;
        sigaction(signum, &g_previous[i], NULL);
        break;
    }
    raise(signum);
}

static void union_crash_install_signals(void) {
    stack_t altstack;
    altstack.ss_sp = g_altstack;
    altstack.ss_size = sizeof(g_altstack);
    altstack.ss_flags = 0;
    /* A stack overflow faults on the guard page; without an alternate stack the handler cannot run. */
    sigaltstack(&altstack, NULL);

    struct sigaction action;
    memset(&action, 0, sizeof(action));
    sigemptyset(&action.sa_mask);
    action.sa_sigaction = union_crash_signal_handler;
    action.sa_flags = SA_SIGINFO | SA_ONSTACK;
    for (int i = 0; i < g_signal_count; i++) {
        sigaction(g_signals[i], &action, &g_previous[i]);
    }
}

static void union_crash_uninstall_signals(void) {
    for (int i = 0; i < g_signal_count; i++) {
        sigaction(g_signals[i], &g_previous[i], NULL);
    }
}

/* --------------------------------------------------------- mach exceptions --- */

/*
 * The exception message, as the kernel sends it with MACH_EXCEPTION_CODES.
 *
 * Written out rather than generated from `exc.defs` because MIG's generated server would call into
 * code we do not control from a thread that must stay minimal, and because the 64-bit code variant
 * is the only one we ask for.
 */
typedef struct {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t thread;
    mach_msg_port_descriptor_t task;
    NDR_record_t ndr;
    exception_type_t exception;
    mach_msg_type_number_t code_count;
    int64_t code[2];
    char padding[512];
} union_crash_exc_request;

typedef struct {
    mach_msg_header_t header;
    NDR_record_t ndr;
    kern_return_t result;
} union_crash_exc_reply;

/**
 * Why a mach exception handler exists at all, next to the signal handlers.
 *
 * Signals arrive after the kernel has already decided the thread is dead, and for some failures they
 * arrive with less: a `EXC_BAD_ACCESS` carries the faulting address and the kind of access, which
 * `SIGSEGV`'s `si_code` flattens. It is also the only path that sees a stack overflow in a thread
 * whose alternate stack was never set up.
 */
static void *union_crash_exception_server(void *unused) {
    (void)unused;
    pthread_setname_np("app.union.crash-handler");
    g_exception_machthread = mach_thread_self();

    for (;;) {
        union_crash_exc_request request;
        memset(&request, 0, sizeof(request));
        mach_msg_return_t kr = mach_msg(&request.header, MACH_RCV_MSG, 0, sizeof(request),
                                        g_exception_port, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
        if (kr != MACH_MSG_SUCCESS) {
            if (kr == MACH_RCV_PORT_CHANGED || kr == MACH_RCV_INVALID_NAME) break; /* uninstalled */
            continue;
        }

        uint64_t code = request.code_count > 0 ? (uint64_t)request.code[0] : 0;
        uint64_t subcode = request.code_count > 1 ? (uint64_t)request.code[1] : 0;
        union_crash_write(UNION_CRASH_CAUSE_MACH, 0, 0, (uint32_t)request.exception, code, subcode,
                          subcode, request.thread.name);

        /*
         * Put the ports back the way we found them and answer KERN_FAILURE, which asks the kernel to
         * carry on with the handling it would have done without us — the signal path, and then
         * Apple's own crash reporter. A report only we hold is a report the developer cannot
         * cross-check, and refusing to forward would also hide the crash from Xcode's organizer.
         */
        for (mach_msg_type_number_t i = 0; i < g_previous_count; i++) {
            if (g_previous_ports[i] == MACH_PORT_NULL) continue;
            task_set_exception_ports(mach_task_self(), g_previous_masks[i], g_previous_ports[i],
                                     g_previous_behaviors[i], g_previous_flavors[i]);
        }

        union_crash_exc_reply reply;
        memset(&reply, 0, sizeof(reply));
        reply.header.msgh_bits = MACH_MSGH_BITS(MACH_MSGH_BITS_REMOTE(request.header.msgh_bits), 0);
        reply.header.msgh_size = sizeof(reply);
        reply.header.msgh_remote_port = request.header.msgh_remote_port;
        reply.header.msgh_local_port = MACH_PORT_NULL;
        reply.header.msgh_id = request.header.msgh_id + 100;
        reply.ndr = NDR_record;
        reply.result = KERN_FAILURE;
        mach_msg(&reply.header, MACH_SEND_MSG, sizeof(reply), 0, MACH_PORT_NULL,
                 MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
    }
    return NULL;
}

static int union_crash_install_mach(void) {
    if (mach_port_allocate(mach_task_self(), MACH_PORT_RIGHT_RECEIVE, &g_exception_port) != KERN_SUCCESS) {
        return -1;
    }
    if (mach_port_insert_right(mach_task_self(), g_exception_port, g_exception_port,
                               MACH_MSG_TYPE_MAKE_SEND) != KERN_SUCCESS) {
        mach_port_deallocate(mach_task_self(), g_exception_port);
        g_exception_port = MACH_PORT_NULL;
        return -1;
    }

    exception_mask_t mask = EXC_MASK_BAD_ACCESS | EXC_MASK_BAD_INSTRUCTION | EXC_MASK_ARITHMETIC |
                            EXC_MASK_BREAKPOINT;
    g_previous_count = EXC_TYPES_COUNT;
    task_get_exception_ports(mach_task_self(), mask, g_previous_masks, &g_previous_count,
                             g_previous_ports, g_previous_behaviors, g_previous_flavors);
    if (task_set_exception_ports(mach_task_self(), mask, g_exception_port,
                                 (exception_behavior_t)(EXCEPTION_DEFAULT | MACH_EXCEPTION_CODES),
                                 THREAD_STATE_NONE) != KERN_SUCCESS) {
        return -1;
    }

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    int created = pthread_create(&g_exception_thread, &attr, union_crash_exception_server, NULL);
    pthread_attr_destroy(&attr);
    return created == 0 ? 0 : -1;
}

static void union_crash_uninstall_mach(void) {
    for (mach_msg_type_number_t i = 0; i < g_previous_count; i++) {
        if (g_previous_ports[i] == MACH_PORT_NULL) continue;
        task_set_exception_ports(mach_task_self(), g_previous_masks[i], g_previous_ports[i],
                                 g_previous_behaviors[i], g_previous_flavors[i]);
    }
    g_previous_count = 0;
    if (g_exception_port != MACH_PORT_NULL) {
        mach_port_mod_refs(mach_task_self(), g_exception_port, MACH_PORT_RIGHT_RECEIVE, -1);
        g_exception_port = MACH_PORT_NULL;
    }
}

/* ------------------------------------------------------------------- images --- */

int union_crash_images(union_crash_image *out, int max) {
    uint32_t count = _dyld_image_count();
    int written = 0;
    for (uint32_t i = 0; i < count && written < max; i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        const char *name = _dyld_get_image_name(i);
        if (!header || !name) continue;

        union_crash_image *image = &out[written];
        memset(image, 0, sizeof(*image));
        image->load_addr = (uint64_t)(uintptr_t)header;
        size_t name_length = strnlen(name, UNION_CRASH_IMAGE_NAME - 1);
        memcpy(image->name, name, name_length);
        /*
         * The main executable is the app; index 0 is guaranteed to be it. `is_app` is the one bit the
         * fingerprint reads, so it must not be guessed from a path prefix — a framework inside the
         * bundle lives under the same path as the executable.
         */
        image->is_app = (i == 0) ? 1 : 0;

        const uint8_t *cursor = (const uint8_t *)header;
        uint32_t header_size = (header->magic == MH_MAGIC_64 || header->magic == MH_CIGAM_64)
                                   ? sizeof(struct mach_header_64)
                                   : sizeof(struct mach_header);
        cursor += header_size;
        uint64_t text_size = 0;
        for (uint32_t c = 0; c < header->ncmds; c++) {
            const struct load_command *command = (const struct load_command *)cursor;
            if (command->cmdsize == 0) break;
            if (command->cmd == LC_UUID) {
                const struct uuid_command *uuid = (const struct uuid_command *)command;
                memcpy(image->uuid, uuid->uuid, 16);
                image->has_uuid = 1;
            } else if (command->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
                if (strncmp(segment->segname, SEG_TEXT, sizeof(segment->segname)) == 0) {
                    text_size = segment->vmsize;
                }
            }
            cursor += command->cmdsize;
        }
        image->size = text_size;
        written++;
    }
    g_image_count = written;
    return written;
}

/* -------------------------------------------------------------------- state --- */

void union_crash_set_foreground(int foreground) {
    g_foreground = (int8_t)(foreground < 0 ? -1 : (foreground ? 1 : 0));
}

void union_crash_add_breadcrumb(uint8_t kind, const char *name, int64_t ts_ms) {
    if (!name) return;
    unsigned long long slot = atomic_fetch_add(&g_crumb_total, 1);
    union_crash_crumb *crumb = &g_crumbs[slot % UNION_CRASH_MAX_BREADCRUMBS];
    size_t length = strnlen(name, UNION_CRASH_BREADCRUMB_NAME);
    crumb->ts = ts_ms;
    crumb->kind = kind;
    memcpy(crumb->name, name, length);
    /* Length last: the handler reads it to decide whether the slot is readable at all. */
    crumb->len = (uint8_t)length;
}

int union_crash_did_write(void) { return atomic_load(&g_wrote); }

/* ------------------------------------------------------------------ install --- */

int union_crash_install(const char *report_path) {
    int expected = 0;
    if (!atomic_compare_exchange_strong(&g_installed, &expected, 1)) return 0;

    g_fd = open(report_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (g_fd < 0) {
        atomic_store(&g_installed, 0);
        return -1;
    }
    g_started_ms = union_crash_mono_ms();
    union_crash_images(g_images, UNION_CRASH_MAX_IMAGES);
    union_crash_install_signals();
    union_crash_install_mach();
    return 0;
}

void union_crash_uninstall(void) {
    int expected = 1;
    if (!atomic_compare_exchange_strong(&g_installed, &expected, 0)) return;
    union_crash_uninstall_mach();
    union_crash_uninstall_signals();
    if (g_fd >= 0) {
        close(g_fd);
        g_fd = -1;
    }
}

int union_crash_capture_live(const char *path, int signum, mach_port_t crashed_thread) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return -1;

    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) {
        close(fd);
        return -1;
    }
    thread_t self = mach_thread_self();
    thread_t marked = crashed_thread == MACH_PORT_NULL ? self : crashed_thread;
    union_crash_suspend_others(self, threads, count);
    /*
     * `g_started_ms` is only set by install, and a live capture may run in a process where nothing
     * was installed (a test). Borrowed for the call and put back, so uptime is 0 there rather than a
     * span measured from an arbitrary moment.
     */
    uint64_t started = g_started_ms;
    if (started == 0) g_started_ms = union_crash_mono_ms();
    size_t length = union_crash_serialize(UNION_CRASH_CAUSE_SIGNAL, signum, 0, 0, 0, 0, 0, marked,
                                          threads, count);
    g_started_ms = started;
    union_crash_resume_others(self, threads, count);
    mach_port_deallocate(mach_task_self(), self);

    ssize_t written = write(fd, g_buffer, length);
    close(fd);
    return written == (ssize_t)length ? 0 : -1;
}

// Runs FFmpeg's `ffmpeg` and `ffprobe` command-line programs inside the app.
//
// iOS apps can't start processes, so each tool is built as a framework whose
// `main` we call directly. What makes that safe to repeat:
//  - Globals: the tool's writable data segments are snapshotted once, right after
//    loading, and copied back before every run, so each run starts as fresh as a
//    new process would. (ffmpeg's main joins all its threads and frees its state
//    before returning, and has no atexit handlers.) Shared libav* state that lives
//    in FFmpegCore, such as the log callback, is reset explicitly.
//  - stdin/stdout/stderr: for the duration of a run, fds 0/1/2 point at the pipes
//    the caller passed (Python's subprocess pipes), then are restored. Nothing else
//    in the app writes to them (Python's own stdout/stderr are discarded on iOS).
//  - Signals: the tools are compiled with ALEMBIC_IN_PROCESS, so ffmpeg installs no
//    signal handlers; dispositions are still saved and restored as a safety net.
//  - Stopping: each run has a token. A stop aimed at a token is applied as soon as
//    that run has started, even if it arrived a moment earlier, and never affects
//    any other run.
//  - Only one tool runs at a time (run_lock; the fds are process-wide).
#include "ToolRunner.h"

#include <dlfcn.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef int (*tool_main_fn)(int, char **);

typedef struct {
    const char *framework;
    void *handle;
    tool_main_fn main;
    int segment_count;
    void *segment_addr[2];
    size_t segment_size[2];
    void *segment_copy[2];
    int loaded;
} Tool;

static Tool tools[2] = {
    {.framework = "FFmpegTool"},
    {.framework = "FFprobeTool"},
};
static pthread_mutex_t run_lock = PTHREAD_MUTEX_INITIALIZER;
static char frameworks_dir[1024];
static void (*set_log_level)(int);
static void (*set_log_flags)(int);
static void (*set_log_callback)(void *);
static void *default_log_callback;
static void (*request_stop)(void);

static atomic_long running_token;  // 0 when nothing runs
static atomic_long stop_token;     // last token a stop was aimed at

void alembic_tools_configure(const char *dir) {
    strlcpy(frameworks_dir, dir, sizeof frameworks_dir);
    signal(SIGPIPE, SIG_IGN); // a closed pipe must never kill the app
}

static int load(Tool *t, char *err, size_t errlen) {
    if (t->loaded) return 0;
    char path[1200];
    snprintf(path, sizeof path, "%s/%s.framework/%s", frameworks_dir, t->framework, t->framework);
    t->handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!t->handle) {
        snprintf(err, errlen, "%s", dlerror());
        return -1;
    }
    t->main = (tool_main_fn)dlsym(t->handle, "main");
    if (!t->main) {
        snprintf(err, errlen, "%s has no entry point", t->framework);
        return -1;
    }
    Dl_info info;
    if (!dladdr((void *)t->main, &info) || !info.dli_fbase) {
        snprintf(err, errlen, "cannot locate %s image", t->framework);
        return -1;
    }
    const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;
    // __DATA_CONST is read-only after load and never changes, so it isn't saved.
    const char *segments[] = {"__DATA", "__DATA_DIRTY"};
    t->segment_count = 0;
    for (int i = 0; i < 2; i++) {
        unsigned long size = 0;
        uint8_t *addr = getsegmentdata(header, segments[i], &size);
        if (!addr || !size) continue;
        void *copy = malloc(size);
        if (!copy) {
            snprintf(err, errlen, "out of memory loading %s", t->framework);
            return -1;
        }
        memcpy(copy, addr, size);
        int n = t->segment_count++;
        t->segment_addr[n] = addr;
        t->segment_size[n] = size;
        t->segment_copy[n] = copy;
    }
    if (t->segment_count == 0) {
        // Without a snapshot a second run would reuse freed globals: refuse instead.
        snprintf(err, errlen, "%s has no data segment to reset", t->framework);
        return -1;
    }
    if (!set_log_level) {
        set_log_level = (void (*)(int))dlsym(RTLD_DEFAULT, "av_log_set_level");
        set_log_flags = (void (*)(int))dlsym(RTLD_DEFAULT, "av_log_set_flags");
        set_log_callback = (void (*)(void *))dlsym(RTLD_DEFAULT, "av_log_set_callback");
        default_log_callback = dlsym(RTLD_DEFAULT, "av_log_default_callback");
    }
    if (t == &tools[0]) request_stop = (void (*)(void))dlsym(t->handle, "alembic_ffmpeg_request_stop");
    t->loaded = 1;
    return 0;
}

typedef struct { int fd[3]; } SavedFds;

static int redirect(int fd_in, int fd_out, int fd_err, SavedFds *saved, char *err, size_t errlen) {
    int targets[3] = {fd_in, fd_out, fd_err};
    for (int i = 0; i < 3; i++) saved->fd[i] = -1;
    for (int i = 0; i < 3; i++) {
        saved->fd[i] = dup(i);
        if (saved->fd[i] < 0) goto fail;
    }
    for (int i = 0; i < 3; i++) {
        int r;
        do { r = dup2(targets[i], i); } while (r < 0 && errno == EINTR);
        if (r < 0) {
            // Put back the ones already moved.
            for (int j = 0; j < i; j++) dup2(saved->fd[j], j);
            goto fail;
        }
    }
    return 0;
fail:
    snprintf(err, errlen, "could not connect the tool's input/output (%s)", strerror(errno));
    for (int i = 0; i < 3; i++)
        if (saved->fd[i] >= 0) close(saved->fd[i]);
    return -1;
}

static void restore(SavedFds *saved) {
    for (int i = 0; i < 3; i++) {
        int r;
        do { r = dup2(saved->fd[i], i); } while (r < 0 && errno == EINTR);
        close(saved->fd[i]);
    }
}

int alembic_tool_run(int which, int argc, char **argv, int fd_in, int fd_out, int fd_err,
                     long token, char *err, size_t errlen) {
    if (which < 0 || which > 1) return 127;
    pthread_mutex_lock(&run_lock);
    Tool *t = &tools[which];
    if (load(t, err, errlen) != 0) {
        pthread_mutex_unlock(&run_lock);
        return 127;
    }
    for (int i = 0; i < t->segment_count; i++)
        memcpy(t->segment_addr[i], t->segment_copy[i], t->segment_size[i]);
    // libav* keeps these in FFmpegCore, outside the tool's snapshot.
    if (set_log_callback && default_log_callback) set_log_callback(default_log_callback);
    if (set_log_level) set_log_level(32 /* AV_LOG_INFO */);
    if (set_log_flags) set_log_flags(0);

    struct sigaction old_int, old_term, old_xcpu;
    sigaction(SIGINT, NULL, &old_int);
    sigaction(SIGTERM, NULL, &old_term);
    sigaction(SIGXCPU, NULL, &old_xcpu);

    fflush(stdout);
    fflush(stderr);
    SavedFds saved;
    if (redirect(fd_in, fd_out, fd_err, &saved, err, errlen) != 0) {
        pthread_mutex_unlock(&run_lock);
        return 126;
    }

    atomic_store(&running_token, token);
    // A stop that arrived while this run was being set up (after the snapshot was
    // restored, so it can't be wiped) is applied now.
    if (atomic_load(&stop_token) == token && which == 0 && request_stop) request_stop();

    int rc = t->main(argc, argv);

    atomic_store(&running_token, 0);
    fflush(stdout);
    fflush(stderr);
    restore(&saved);
    sigaction(SIGINT, &old_int, NULL);
    sigaction(SIGTERM, &old_term, NULL);
    sigaction(SIGXCPU, &old_xcpu, NULL);
    signal(SIGPIPE, SIG_IGN);
    pthread_mutex_unlock(&run_lock);
    return rc;
}

void alembic_tool_stop(long token) {
    atomic_store(&stop_token, token);
    if (atomic_load(&running_token) == token && request_stop) request_stop();
}

#include <jni.h>
#include <android/looper.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <pthread.h>

// Version-pinned libdispatch SPI; the dependency audit and device tests guard upgrades.
extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *);

static int drain(int fd, int events, void *context) {
    uint64_t value;
    ssize_t result;
    do { result = read(fd, &value, sizeof(value)); } while (result < 0 && errno == EINTR);
    if (result < 0 && errno != EAGAIN) abort();
    _dispatch_main_queue_callback_4CF(NULL);
    return 1;
}

JNIEXPORT void JNICALL Java_com_example_hackernewsreader_PlatformServices_setupMainLooper(JNIEnv *env, jobject self) {
    static int installed = 0;
    if (gettid() != getpid()) abort();
    if (installed) return;
    int fd = _dispatch_get_main_queue_handle_4CF();
    if (fd < 0 || ALooper_addFd(ALooper_forThread(), fd, ALOOPER_POLL_CALLBACK,
        ALOOPER_EVENT_INPUT, drain, NULL) != 1) abort();
    installed = 1;
}

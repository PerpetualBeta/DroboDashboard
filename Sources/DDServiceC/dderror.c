// Shared error storage for both C transports, thread-local like the rest.

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

static pthread_key_t g_err_key;
static pthread_once_t g_err_once = PTHREAD_ONCE_INIT;

static void make_err_key(void) { pthread_key_create(&g_err_key, free); }

const char *dd_last_error(void)
{
    pthread_once(&g_err_once, make_err_key);
    char *err = pthread_getspecific(g_err_key);
    if (!err) {
        err = calloc(1, 512);
        pthread_setspecific(g_err_key, err);
        strlcpy(err, "no error", 512);
    }
    return err;
}

void dd_set_error(const char *fmt, ...)
{
    pthread_once(&g_err_once, make_err_key);
    char *err = pthread_getspecific(g_err_key);
    if (!err) {
        err = calloc(1, 512);
        pthread_setspecific(g_err_key, err);
    }
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(err, 512, fmt ? fmt : "unknown error", ap);
    va_end(ap);
}

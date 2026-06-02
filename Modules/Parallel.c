#include "Parallel.h"
#include <pthread.h>
#include <stdlib.h>

#ifdef __APPLE__
#  include <sys/sysctl.h>
#else
#  include <unistd.h>
#endif

typedef struct {
    Parallel_BodyFn body;
    int lo;
    int hi;
} WorkArgs;

static void *worker(void *arg) {
    WorkArgs *w = (WorkArgs *)arg;
    for (int i = w->lo; i < w->hi; i++)
        w->body(i);
    return NULL;
}

int Parallel_NumCPU(void) {
#ifdef __APPLE__
    int n = 1;
    size_t sz = sizeof(n);
    sysctlbyname("hw.logicalcpu", &n, &sz, NULL, 0);
    return n > 0 ? n : 1;
#else
    int n = (int)sysconf(_SC_NPROCESSORS_ONLN);
    return n > 0 ? n : 1;
#endif
}

void Parallel_For(int lo, int hi, Parallel_BodyFn body, int nthreads) {
    int n = hi - lo;
    if (nthreads <= 1 || n <= 1) {
        for (int i = lo; i < hi; i++) body(i);
        return;
    }
    if (nthreads > n) nthreads = n;

    pthread_t *threads = malloc((size_t)nthreads * sizeof(pthread_t));
    WorkArgs  *args    = malloc((size_t)nthreads * sizeof(WorkArgs));
    if (!threads || !args) {
        free(threads); free(args);
        for (int i = lo; i < hi; i++) body(i);
        return;
    }

    int chunk = n / nthreads;
    int rem   = n % nthreads;
    int cur   = lo;
    for (int t = 0; t < nthreads; t++) {
        args[t].body = body;
        args[t].lo   = cur;
        args[t].hi   = cur + chunk + (t < rem ? 1 : 0);
        cur = args[t].hi;
        pthread_create(&threads[t], NULL, worker, &args[t]);
    }
    for (int t = 0; t < nthreads; t++)
        pthread_join(threads[t], NULL);

    free(threads);
    free(args);
}

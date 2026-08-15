#include "Random.h"
#include <stdlib.h>
#include <time.h>

__attribute__((constructor))
static void Random_init(void) {
    srand((unsigned)time(NULL));
}

int Random_Int(int n) {
    return n > 0 ? (int)(rand() % (unsigned)n) : 0;
}

double Random_Real(void) {
    return (double)rand() / ((double)RAND_MAX + 1.0);
}

void Random_Randomize(void) {
    /* time(NULL) alone only has 1-second resolution, so two processes
     * started within the same second would reseed identically; mix in
     * clock() (CPU time since process start) for finer-grained entropy. */
    srand((unsigned)time(NULL) ^ (unsigned)clock());
}

void Random_Seed(int n) {
    srand((unsigned)n);
}

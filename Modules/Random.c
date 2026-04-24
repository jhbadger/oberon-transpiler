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

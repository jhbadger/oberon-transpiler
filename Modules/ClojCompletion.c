/*
 * ClojCompletion.c — bridge between History's completion callback and
 * Cloj_EnvSymbolsStr.  Registered once at REPL startup so that Tab
 * triggers symbol completion without Oberon→C function-pointer ABI issues.
 */

#include "ClojCompletion.h"
#include "History.h"
#include "Cloj.h"
#include <string.h>

#define PREFIX_BUF 256

static void cloj_complete(const char *prefix, char *result, int result_len) {
    char pbuf[PREFIX_BUF];
    strncpy(pbuf, prefix, PREFIX_BUF - 1);
    pbuf[PREFIX_BUF - 1] = '\0';
    Cloj_EnvSymbolsStr(pbuf, PREFIX_BUF, result, result_len);
}

void ClojCompletion_Register(void) {
    History_SetCompletionFn(cloj_complete);
}

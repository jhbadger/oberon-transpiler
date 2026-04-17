#ifndef OBERON_CODEGEN_H
#define OBERON_CODEGEN_H

#include "parser.h"
#include <stdio.h>

/* Translate an Oberon AST to C.
 * is_main=1 → emit int main(); is_main=0 → emit ModName_init(). */
void codegen(Node *module, FILE *out, int is_main);

/* Generate a C header (.h) with extern declarations of all exported
 * symbols.  Call this for every library (non-main) module.           */
void codegen_header(Node *module, FILE *out);

/* ── FFI module bindings ─────────────────────────────────────────────────
 * Modules backed by an external C library rather than compiled Oberon.
 * Call ffi_register() (from obc.c) before invoking codegen().
 * ----------------------------------------------------------------------- */
#define OBC_FFI_MAP_MAX 256

typedef struct {
    char oberon[64];   /* unqualified Oberon procedure/variable name */
    char cname[128];   /* real C symbol name                         */
} OBCFfiMap;

/* Register a C-backed module.
 * header : full #include argument, e.g. "<SDL2/SDL.h>" or "\"mylib.h\""
 * maps   : array of name remappings (may be NULL if nmaps==0)
 * nmaps  : number of entries in maps */
void ffi_register(const char *modname, const char *header,
                  const OBCFfiMap *maps, int nmaps);

/* Returns 1 if modname has been registered as an FFI module. */
int ffi_is_registered(const char *modname);

#endif

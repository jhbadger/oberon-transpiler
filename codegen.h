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

#endif

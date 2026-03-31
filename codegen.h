#ifndef OBERON_CODEGEN_H
#define OBERON_CODEGEN_H

#include "parser.h"
#include <stdio.h>

/* Translate an Oberon AST (as returned by parse_module) to C, writing
 * the result to `out`.  Does not close the file.                      */
void codegen(Node *module, FILE *out);

#endif

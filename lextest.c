/* lextest.c — dump all tokens from an Oberon source file.
 * Usage: lextest <file.mod>
 */
#include "lexer.h"
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
    if (argc < 2) { fprintf(stderr, "usage: lextest <file.mod>\n"); return 1; }
    FILE *f = fopen(argv[1], "r");
    if (!f) { perror(argv[1]); return 1; }

    Lexer lex;
    lexer_init(&lex, f);

    Token t;
    do {
        t = lexer_next(&lex);
        token_print(&t);
    } while (t.kind != TOK_EOF && t.kind != TOK_ERROR);

    fclose(f);
    return t.kind == TOK_ERROR ? 1 : 0;
}

/* parsetest.c — parse an Oberon source file and dump its AST.
 * Usage: parsetest <file.mod>
 */
#include "parser.h"
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char *argv[]) {
    if (argc < 2) { fprintf(stderr, "usage: parsetest <file.mod>\n"); return 1; }
    FILE *f = fopen(argv[1], "r");
    if (!f) { perror(argv[1]); return 1; }

    Parser p;
    parser_init(&p, f);
    Node *ast = parse_module(&p);
    fclose(f);

    if (p.errors) {
        fprintf(stderr, "%d error(s)\n", p.errors);
    }
    if (ast) ast_print(ast, 0);
    ast_free_all();
    return p.errors ? 1 : 0;
}

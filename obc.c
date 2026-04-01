/* obc2.c — Oberon-to-C transpiler using the proper lexer/parser/codegen pipeline.
 * Usage: obc2 <file.mod>
 */
#include "codegen.h"
#include "parser.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char *argv[]) {
    if (argc < 2) { fprintf(stderr, "usage: obc <file.mod>\n"); return 1; }

    FILE *in = fopen(argv[1], "r");
    if (!in) { perror(argv[1]); return 1; }

    Parser p;
    parser_init(&p, in);
    Node *ast = parse_module(&p);
    fclose(in);

    if (p.errors) {
        fprintf(stderr, "obc2: %d parse error(s) in %s\n", p.errors, argv[1]);
        ast_free_all();
        return 1;
    }

    /* Output file: replace .mod with .c */
    char cfile[512];
    strncpy(cfile, argv[1], sizeof(cfile)-5);
    char *dot = strrchr(cfile, '.');
    if (dot) strcpy(dot, ".c"); else strcat(cfile, ".c");

    FILE *out = fopen(cfile, "w");
    if (!out) { perror(cfile); ast_free_all(); return 1; }

    codegen(ast, out);
    fclose(out);
    ast_free_all();

    /* Binary name: strip extension */
    char binfile[512];
    strncpy(binfile, argv[1], sizeof(binfile)-1);
    dot = strrchr(binfile, '.'); if (dot) *dot = '\0';

    char cmd[1024];
    snprintf(cmd, sizeof(cmd), "gcc -std=c11 -Wall -Wno-unused-function -O -o %s %s -lm", binfile, cfile);
    int rc = system(cmd);
    if (rc == 0) { printf("Success: ./%s\n", binfile); remove(cfile); }
    else         { fprintf(stderr, "obc2: C compilation failed; C source left in %s\n", cfile); }

    return rc == 0 ? 0 : 1;
}

/* obc.c — Oberon-to-C transpiler driver with multi-module compilation.
 *
 * Usage: obc <main.mod>
 *
 * Recursively compiles all user-imported modules first (as library
 * modules), then compiles the main module, and links everything with
 * a single gcc invocation.
 */
#include "codegen.h"
#include "parser.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <libgen.h>   /* dirname, basename */

/* -----------------------------------------------------------------------
 * Built-in module names (handled by codegen, not as .mod files)
 * ----------------------------------------------------------------------- */
static const char *g_builtins[] = {
    "Out","In","Random","Terminal","Graphics","Math","Strings",NULL
};
static int is_builtin(const char *s) {
    for (int i=0;g_builtins[i];i++) if (!strcmp(g_builtins[i],s)) return 1;
    return 0;
}

/* -----------------------------------------------------------------------
 * Compiled-module registry (avoids compiling the same module twice)
 * ----------------------------------------------------------------------- */
#define MAX_COMPILED 64
static char g_compiled[MAX_COMPILED][256];
static int  g_ncompiled = 0;

static int already_compiled(const char *modname) {
    for (int i=0;i<g_ncompiled;i++)
        if (!strcmp(g_compiled[i], modname)) return 1;
    return 0;
}
static void mark_compiled(const char *modname) {
    if (g_ncompiled < MAX_COMPILED)
        strncpy(g_compiled[g_ncompiled++], modname, 255);
}

/* -----------------------------------------------------------------------
 * Generated C file list (fed to the final gcc link command)
 * ----------------------------------------------------------------------- */
static char g_cfiles[MAX_COMPILED][512];
static int  g_ncfiles = 0;

static void add_cfile(const char *path) {
    if (g_ncfiles < MAX_COMPILED)
        strncpy(g_cfiles[g_ncfiles++], path, 511);
}

/* -----------------------------------------------------------------------
 * Core: compile one module file.
 *
 * modfile  — absolute or relative path to the .mod source
 * is_main  — 1 = top-level program, 0 = library
 * searchdir — directory to look for further imports (same dir as source)
 *
 * Returns 0 on success, non-zero on failure.
 * ----------------------------------------------------------------------- */
static int compile_module(const char *modfile, int is_main,
                          const char *searchdir);

static int compile_module(const char *modfile, int is_main,
                          const char *searchdir)
{
    FILE *in = fopen(modfile, "r");
    if (!in) {
        fprintf(stderr, "obc: cannot open %s\n", modfile);
        return 1;
    }

    Parser p;
    parser_init(&p, in);
    Node *ast = parse_module(&p);
    fclose(in);

    if (p.errors) {
        fprintf(stderr, "obc: %d parse error(s) in %s\n", p.errors, modfile);
        ast_free_all();
        return 1;
    }

    /* ── Recursively compile user-imported modules first ────────── */
    for (Node *imp = ast->c0; imp; imp = imp->next) {
        /* Real module name: if aliased, it's in c0; otherwise it's str */
        const char *real = ((imp->flags & FLAG_HAS_ALIAS) && imp->c0)
                           ? imp->c0->str : imp->str;
        if (is_builtin(real)) continue;
        if (already_compiled(real)) continue;

        /* Build path: searchdir/RealName.mod */
        char depfile[512];
        if (searchdir && searchdir[0])
            snprintf(depfile, sizeof(depfile), "%s/%s.mod", searchdir, real);
        else
            snprintf(depfile, sizeof(depfile), "%s.mod", real);

        if (compile_module(depfile, 0, searchdir) != 0) {
            ast_free_all();
            return 1;
        }
    }

    /* ── Derive output file paths ────────────────────────────────── */
    /* Strip .mod → use same stem for .c (and .h for library) */
    char cfile[512];
    strncpy(cfile, modfile, sizeof(cfile)-5);
    char *dot = strrchr(cfile, '.');
    if (dot) strcpy(dot, ".c"); else strcat(cfile, ".c");

    /* ── Generate .c file ────────────────────────────────────────── */
    FILE *out = fopen(cfile, "w");
    if (!out) { perror(cfile); ast_free_all(); return 1; }
    codegen(ast, out, is_main);
    fclose(out);

    /* ── Generate .h file (library modules only) ─────────────────── */
    if (!is_main) {
        char hfile[512];
        strncpy(hfile, modfile, sizeof(hfile)-5);
        dot = strrchr(hfile, '.');
        if (dot) strcpy(dot, ".h"); else strcat(hfile, ".h");

        FILE *hout = fopen(hfile, "w");
        if (!hout) { perror(hfile); ast_free_all(); return 1; }
        codegen_header(ast, hout);
        fclose(hout);
    }

    /* Save module name before freeing the AST */
    char saved_modname[256];
    strncpy(saved_modname, ast->str, sizeof(saved_modname)-1);

    ast_free_all();
    add_cfile(cfile);
    if (!is_main) mark_compiled(saved_modname);
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "usage: obc <file.mod>\n");
        return 1;
    }

    const char *mainfile = argv[1];

    /* Derive binary name: strip path and extension */
    char binpath[512];
    strncpy(binpath, mainfile, sizeof(binpath)-1);
    char *dot = strrchr(binpath, '.');
    if (dot) *dot = '\0';

    /* Search directory = directory of the main file */
    char dirbuf[512];
    strncpy(dirbuf, mainfile, sizeof(dirbuf)-1);
    char *searchdir = dirname(dirbuf);

    /* ── Parse the main module to find its imports ───────────────── */
    FILE *in = fopen(mainfile, "r");
    if (!in) { perror(mainfile); return 1; }
    Parser p;
    parser_init(&p, in);
    Node *ast = parse_module(&p);
    fclose(in);
    if (p.errors) {
        fprintf(stderr, "obc: %d parse error(s) in %s\n", p.errors, mainfile);
        ast_free_all();
        return 1;
    }

    /* ── Compile each user-imported dependency ────────────────────── */
    for (Node *imp = ast->c0; imp; imp = imp->next) {
        const char *real = ((imp->flags & FLAG_HAS_ALIAS) && imp->c0)
                           ? imp->c0->str : imp->str;
        if (is_builtin(real)) continue;
        if (already_compiled(real)) continue;

        char depfile[512];
        snprintf(depfile, sizeof(depfile), "%s/%s.mod", searchdir, real);

        if (compile_module(depfile, 0, searchdir) != 0) {
            ast_free_all();
            return 1;
        }
    }

    /* ── Compile the main module ─────────────────────────────────── */
    char maincfile[512];
    strncpy(maincfile, mainfile, sizeof(maincfile)-5);
    dot = strrchr(maincfile, '.');
    if (dot) strcpy(dot, ".c"); else strcat(maincfile, ".c");

    FILE *out = fopen(maincfile, "w");
    if (!out) { perror(maincfile); ast_free_all(); return 1; }
    codegen(ast, out, 1);
    fclose(out);
    ast_free_all();

    /* ── Build gcc command: all .c files → binary ────────────────── */
    char cmd[4096];
    int pos = snprintf(cmd, sizeof(cmd),
        "gcc -std=c11 -Wall -Wno-unused-function -Wno-unused-variable "
        "-I%s -O -o %s",
        searchdir, binpath);

    /* Library modules first (in compilation order), then main */
    for (int i=0; i<g_ncfiles; i++)
        pos += snprintf(cmd+pos, sizeof(cmd)-pos, " %s", g_cfiles[i]);
    pos += snprintf(cmd+pos, sizeof(cmd)-pos, " %s -lm", maincfile);

    int rc = system(cmd);
    if (rc == 0) {
        printf("Success: ./%s\n", binpath);
        /* Clean up generated .c files */
        for (int i=0; i<g_ncfiles; i++) remove(g_cfiles[i]);
        remove(maincfile);
    } else {
        fprintf(stderr, "obc: C compilation failed\n");
    }
    return rc == 0 ? 0 : 1;
}

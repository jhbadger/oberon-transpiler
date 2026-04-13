/* obc.c — Oberon-to-C transpiler driver with multi-module compilation.
 *
 * Usage: obc [options] <main.mod>
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
#include <libgen.h>   /* dirname */

/* -----------------------------------------------------------------------
 * Built-in module names (handled by codegen, not as .mod files)
 * ----------------------------------------------------------------------- */
static const char *g_builtins[] = {
    "Out","In","Random","Terminal","Graphics","Math","Strings","Files","Args","Dict","Zip",
    "Env","OS","Time",NULL
};
static int is_builtin(const char *s) {
    for (int i = 0; g_builtins[i]; i++) if (!strcmp(g_builtins[i], s)) return 1;
    return 0;
}

/* -----------------------------------------------------------------------
 * Compiled-module registry (avoids compiling the same module twice)
 * ----------------------------------------------------------------------- */
#define MAX_COMPILED 64
static char g_compiled[MAX_COMPILED][256];
static int  g_ncompiled = 0;

static int already_compiled(const char *modname) {
    for (int i = 0; i < g_ncompiled; i++)
        if (!strcmp(g_compiled[i], modname)) return 1;
    return 0;
}
static void mark_compiled(const char *modname) {
    if (g_ncompiled < MAX_COMPILED) {
        strncpy(g_compiled[g_ncompiled], modname, sizeof(g_compiled[0]) - 1);
        g_compiled[g_ncompiled][sizeof(g_compiled[0]) - 1] = '\0';
        g_ncompiled++;
    }
}

/* -----------------------------------------------------------------------
 * Generated C file list (fed to the final gcc link command)
 * ----------------------------------------------------------------------- */
static char g_cfiles[MAX_COMPILED][512];
static int  g_ncfiles = 0;

static void add_cfile(const char *path) {
    if (g_ncfiles < MAX_COMPILED) {
        strncpy(g_cfiles[g_ncfiles], path, sizeof(g_cfiles[0]) - 1);
        g_cfiles[g_ncfiles][sizeof(g_cfiles[0]) - 1] = '\0';
        g_ncfiles++;
    }
}

/* -----------------------------------------------------------------------
 * Command-line options
 * ----------------------------------------------------------------------- */
static int         g_emit_c = 0;      /* --emit-c: keep generated .c files */
static int         g_warnings = 0;    /* --warnings: enable C compiler warnings */
static const char *g_outfile = NULL;  /* -o <outfile> */
static char        g_cli_mod_path[2048] = ""; /* --mod-path / -I */

/* -----------------------------------------------------------------------
 * Include / module search path handling
 * ----------------------------------------------------------------------- */
#define MAX_INCDIRS 128
static char g_incdirs[MAX_INCDIRS][512];
static int  g_nincdirs = 0;

static void usage(void) {
    fprintf(stderr,
        "usage: obc [--emit-c] [--warnings] [--mod-path dir1:dir2:dir3]\n"
        "           [-I dir1:dir2:dir3] [-o outfile] <file.mod>\n");
}

static void append_cli_mod_path(const char *path) {
    if (!path || !*path) return;
    if (g_cli_mod_path[0]) {
        strncat(g_cli_mod_path, ":",
                sizeof(g_cli_mod_path) - strlen(g_cli_mod_path) - 1);
    }
    strncat(g_cli_mod_path, path,
            sizeof(g_cli_mod_path) - strlen(g_cli_mod_path) - 1);
}

static const char *effective_mod_path(void) {
    if (g_cli_mod_path[0]) return g_cli_mod_path;
    {
        const char *env = getenv("OBC_MOD_PATH");
        return (env && *env) ? env : NULL;
    }
}

static void add_incdir(const char *dir) {
    if (!dir || !*dir) dir = ".";
    for (int i = 0; i < g_nincdirs; i++) {
        if (!strcmp(g_incdirs[i], dir)) return;
    }
    if (g_nincdirs < MAX_INCDIRS) {
        strncpy(g_incdirs[g_nincdirs], dir, sizeof(g_incdirs[0]) - 1);
        g_incdirs[g_nincdirs][sizeof(g_incdirs[0]) - 1] = '\0';
        g_nincdirs++;
    }
}

static void add_mod_path_incdirs(void) {
    const char *mp = effective_mod_path();
    if (!mp || !*mp) return;

    const char *p = mp;
    while (*p) {
        const char *q = p;
        while (*q && *q != ':') q++;

        if (q == p) {
            add_incdir(".");
        } else {
            char dir[512];
            size_t n = (size_t)(q - p);
            if (n >= sizeof(dir)) n = sizeof(dir) - 1;
            memcpy(dir, p, n);
            dir[n] = '\0';
            add_incdir(dir);
        }

        p = (*q == ':') ? q + 1 : q;
    }
}

static int file_exists(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    fclose(f);
    return 1;
}

static void get_dirname_str(const char *path, char *out, size_t outsz) {
    char tmp[512];
    strncpy(tmp, path, sizeof(tmp) - 1);
    tmp[sizeof(tmp) - 1] = '\0';

    {
        char *d = dirname(tmp);
        if (!d || !*d) d = ".";
        strncpy(out, d, outsz - 1);
        out[outsz - 1] = '\0';
    }
}

/* Resolve ModName -> path to ModName.mod using:
 *   1) importer_dir
 *   2) current working directory
 *   3) effective module path (--mod-path/-I or OBC_MOD_PATH)
 */
static int resolve_module_file(const char *importer_dir,
                               const char *modname,
                               char *out,
                               size_t outsz)
{
    char cand[512];

    if (importer_dir && *importer_dir) {
        snprintf(cand, sizeof(cand), "%s/%s.mod", importer_dir, modname);
        if (file_exists(cand)) {
            strncpy(out, cand, outsz - 1);
            out[outsz - 1] = '\0';
            return 1;
        }
    }

    snprintf(cand, sizeof(cand), "%s.mod", modname);
    if (file_exists(cand)) {
        strncpy(out, cand, outsz - 1);
        out[outsz - 1] = '\0';
        return 1;
    }

    {
        const char *mp = effective_mod_path();
        if (mp && *mp) {
            const char *p = mp;
            while (*p) {
                const char *q = p;
                while (*q && *q != ':') q++;

                if (q == p) {
                    snprintf(cand, sizeof(cand), "%s.mod", modname);
                } else {
                    char dir[512];
                    size_t n = (size_t)(q - p);
                    if (n >= sizeof(dir)) n = sizeof(dir) - 1;
                    memcpy(dir, p, n);
                    dir[n] = '\0';
                    snprintf(cand, sizeof(cand), "%s/%s.mod", dir, modname);
                }

                if (file_exists(cand)) {
                    strncpy(out, cand, outsz - 1);
                    out[outsz - 1] = '\0';
                    return 1;
                }

                p = (*q == ':') ? q + 1 : q;
            }
        }
    }

    return 0;
}

/* -----------------------------------------------------------------------
 * Core: compile one module file.
 *
 * modfile  — absolute or relative path to the .mod source
 * is_main  — 1 = top-level program, 0 = library
 *
 * Returns 0 on success, non-zero on failure.
 * ----------------------------------------------------------------------- */
static int compile_module(const char *modfile, int is_main);

static int compile_module(const char *modfile, int is_main)
{
    char moddir[512];
    get_dirname_str(modfile, moddir, sizeof(moddir));
    add_incdir(moddir);

    /* ── Pass 1: parse to collect user-module imports ───────────── */
    {
        FILE *in = fopen(modfile, "r");
        if (!in) {
            fprintf(stderr, "obc: cannot open %s\n", modfile);
            return 1;
        }

        Parser p;
        parser_init(&p, in);
        p.filename = modfile;
        Node *ast = parse_module(&p);
        fclose(in);

        if (p.errors) {
            fprintf(stderr, "obc: %d parse error(s) in %s\n", p.errors, modfile);
            ast_free_all();
            return 1;
        }

        /* Save import names before freeing the AST */
        char imports[64][256];
        int  n_imports = 0;
        for (Node *imp = ast->c0; imp && n_imports < 64; imp = imp->next) {
            const char *real = ((imp->flags & FLAG_HAS_ALIAS) && imp->c0)
                               ? imp->c0->str : imp->str;
            if (is_builtin(real) || already_compiled(real)) continue;
            strncpy(imports[n_imports], real, sizeof(imports[0]) - 1);
            imports[n_imports][sizeof(imports[0]) - 1] = '\0';
            n_imports++;
        }
        ast_free_all();  /* safe — we saved what we need */

        /* ── Recursively compile user-imported modules ───────────── */
        for (int i = 0; i < n_imports; i++) {
            char depfile[512];

            if (already_compiled(imports[i])) continue;

            if (!resolve_module_file(moddir, imports[i], depfile, sizeof(depfile))) {
                fprintf(stderr,
                        "obc: cannot find imported module %s (imported from %s)\n",
                        imports[i], modfile);
                return 1;
            }

            if (compile_module(depfile, 0) != 0) return 1;
        }
    }

    /* ── Pass 2: re-parse (fresh arena) and codegen ─────────────── */
    {
        FILE *in = fopen(modfile, "r");
        if (!in) {
            fprintf(stderr, "obc: cannot open %s\n", modfile);
            return 1;
        }

        Parser p;
        parser_init(&p, in);
        p.filename = modfile;
        Node *ast = parse_module(&p);
        fclose(in);

        if (p.errors) {
            fprintf(stderr, "obc: %d parse error(s) in %s\n", p.errors, modfile);
            ast_free_all();
            return 1;
        }

        /* ── Derive output file paths ────────────────────────────── */
        char cfile[512];
        strncpy(cfile, modfile, sizeof(cfile) - 1);
        cfile[sizeof(cfile) - 1] = '\0';
        {
            char *dot = strrchr(cfile, '.');
            if (dot) strcpy(dot, ".c");
            else strcat(cfile, ".c");
        }

        /* ── Generate .c file ────────────────────────────────────── */
        {
            FILE *out = fopen(cfile, "w");
            if (!out) {
                perror(cfile);
                ast_free_all();
                return 1;
            }
            codegen(ast, out, is_main);
            fclose(out);
        }

        /* ── Generate .h file (library modules only) ─────────────── */
        if (!is_main) {
            char hfile[512];
            strncpy(hfile, modfile, sizeof(hfile) - 1);
            hfile[sizeof(hfile) - 1] = '\0';
            {
                char *dot = strrchr(hfile, '.');
                if (dot) strcpy(dot, ".h");
                else strcat(hfile, ".h");
            }

            {
                FILE *hout = fopen(hfile, "w");
                if (!hout) {
                    perror(hfile);
                    ast_free_all();
                    return 1;
                }
                codegen_header(ast, hout);
                fclose(hout);
            }
        }

        /* Save module name before freeing the AST */
        {
            char saved_modname[256];
            strncpy(saved_modname, ast->str, sizeof(saved_modname) - 1);
            saved_modname[sizeof(saved_modname) - 1] = '\0';

            ast_free_all();
            add_cfile(cfile);
            if (!is_main) mark_compiled(saved_modname);
        }
    }

    return 0;
}

int main(int argc, char *argv[]) {
    const char *mainfile = NULL;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--emit-c")) {
            g_emit_c = 1;
        } else if (!strcmp(argv[i], "--warnings")) {
            g_warnings = 1;
        } else if (!strcmp(argv[i], "--mod-path")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "obc: missing argument for --mod-path\n");
                usage();
                return 1;
            }
            append_cli_mod_path(argv[++i]);
        } else if (!strncmp(argv[i], "--mod-path=", 11)) {
            append_cli_mod_path(argv[i] + 11);
        } else if (!strcmp(argv[i], "-I")) {
            if (i + 1 >= argc) {
                fprintf(stderr, "obc: missing argument for -I\n");
                usage();
                return 1;
            }
            append_cli_mod_path(argv[++i]);
        } else if (!strncmp(argv[i], "-I", 2) && argv[i][2] != '\0') {
            append_cli_mod_path(argv[i] + 2);
        } else if (!strcmp(argv[i], "-o") && i + 1 < argc) {
            g_outfile = argv[++i];
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "obc: unknown flag: %s\n", argv[i]);
            usage();
            return 1;
        } else {
            mainfile = argv[i];
        }
    }

    if (!mainfile) {
        usage();
        return 1;
    }

    /* Derive binary name from source path unless -o was given */
    char binpath[512];
    if (g_outfile) {
        strncpy(binpath, g_outfile, sizeof(binpath) - 1);
        binpath[sizeof(binpath) - 1] = '\0';
    } else {
        strncpy(binpath, mainfile, sizeof(binpath) - 1);
        binpath[sizeof(binpath) - 1] = '\0';
        {
            char *dot = strrchr(binpath, '.');
            if (dot) *dot = '\0';
        }
    }

    /* Seed include dirs used later for gcc header lookup */
    add_incdir(".");
    {
        char main_dir[512];
        get_dirname_str(mainfile, main_dir, sizeof(main_dir));
        add_incdir(main_dir);
    }
    add_mod_path_incdirs();

    /* Compile everything (dependencies first, then main) */
    if (compile_module(mainfile, 1) != 0) return 1;

    /* ── Build gcc command: all generated .c files → binary ──────── */
    {
        char cmd[8192];
        int pos = snprintf(cmd, sizeof(cmd),
            "gcc -std=c11 %s-O -o %s",
            g_warnings
                ? "-Wall -Wno-unused-function -Wno-unused-variable "
                : "-w ",
            binpath);

        for (int i = 0; i < g_nincdirs && pos < (int)sizeof(cmd); i++) {
            pos += snprintf(cmd + pos, sizeof(cmd) - (size_t)pos,
                            " -I%s", g_incdirs[i]);
        }

        for (int i = 0; i < g_ncfiles && pos < (int)sizeof(cmd); i++) {
            pos += snprintf(cmd + pos, sizeof(cmd) - (size_t)pos,
                            " %s", g_cfiles[i]);
        }

        if (pos < (int)sizeof(cmd)) {
            snprintf(cmd + pos, sizeof(cmd) - (size_t)pos, " -lm -lz");
        }

        {
            int rc = system(cmd);
            if (rc == 0) {
                printf("Success: %s\n", binpath);
                if (!g_emit_c) {
                    for (int i = 0; i < g_ncfiles; i++) remove(g_cfiles[i]);
                } else {
                    printf("C sources kept");
                    if (g_ncfiles > 0) printf(": %s", g_cfiles[0]);
                    for (int i = 1; i < g_ncfiles; i++) printf(", %s", g_cfiles[i]);
                    printf("\n");
                }
            } else {
                fprintf(stderr, "obc: C compilation failed\n");
            }
            return rc == 0 ? 0 : 1;
        }
    }
}

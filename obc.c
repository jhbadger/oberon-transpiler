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
    "Out","In","Terminal","Strings","Files","Args","Dict","Zip",
    "Env","OS","Time",NULL
};
static int is_builtin(const char *s) {
    for (int i = 0; g_builtins[i]; i++) if (!strcmp(g_builtins[i], s)) return 1;
    return 0;
}

/* -----------------------------------------------------------------------
 * FFI link flags collected from .ffi files
 * ----------------------------------------------------------------------- */
#define MAX_LDFLAGS 64
static char g_ldflags[MAX_LDFLAGS][64];
static int  g_nldflags = 0;

static void add_ldflag(const char *lib) {
    for (int i = 0; i < g_nldflags; i++)
        if (!strcmp(g_ldflags[i], lib)) return;   /* deduplicate */
    if (g_nldflags < MAX_LDFLAGS) {
        strncpy(g_ldflags[g_nldflags], lib, sizeof(g_ldflags[0])-1);
        g_ldflags[g_nldflags][sizeof(g_ldflags[0])-1] = '\0';
        g_nldflags++;
    }
}

/* -----------------------------------------------------------------------
 * Extra compiler / linker flags from PKGCONFIG directives in .ffi files
 * ----------------------------------------------------------------------- */
#define MAX_EXTRA_FLAGS 64
static char g_extra_cflags[MAX_EXTRA_FLAGS][256];
static int  g_n_extra_cflags = 0;
static char g_extra_ldirs[MAX_EXTRA_FLAGS][256];
static int  g_n_extra_ldirs = 0;

static void add_extra_cflag(const char *f) {
    for (int i = 0; i < g_n_extra_cflags; i++)
        if (!strcmp(g_extra_cflags[i], f)) return;
    if (g_n_extra_cflags < MAX_EXTRA_FLAGS) {
        strncpy(g_extra_cflags[g_n_extra_cflags], f,
                sizeof(g_extra_cflags[0]) - 1);
        g_extra_cflags[g_n_extra_cflags][sizeof(g_extra_cflags[0])-1] = '\0';
        g_n_extra_cflags++;
    }
}
static void add_extra_ldir(const char *d) {
    for (int i = 0; i < g_n_extra_ldirs; i++)
        if (!strcmp(g_extra_ldirs[i], d)) return;
    if (g_n_extra_ldirs < MAX_EXTRA_FLAGS) {
        strncpy(g_extra_ldirs[g_n_extra_ldirs], d,
                sizeof(g_extra_ldirs[0]) - 1);
        g_extra_ldirs[g_n_extra_ldirs][sizeof(g_extra_ldirs[0])-1] = '\0';
        g_n_extra_ldirs++;
    }
}

/* Run pkg-config for pkgname, parse output tokens and accumulate flags. */
static void pkgconfig_query(const char *pkgname) {
    char cmd[256];
    char buf[1024];
    FILE *pipe;
    int got_include = 0;  /* set only when pkg-config returns an actual -I flag */

    /* --cflags */
    snprintf(cmd, sizeof(cmd), "pkg-config --cflags %s 2>/dev/null", pkgname);
    pipe = popen(cmd, "r");
    if (pipe) {
        if (fgets(buf, sizeof(buf), pipe)) {
            char *tok = strtok(buf, " \t\r\n");
            while (tok) {
                if (tok[0] != '\0') {
                    add_extra_cflag(tok);
                    if (tok[0] == '-' && tok[1] == 'I') got_include = 1;
                }
                tok = strtok(NULL, " \t\r\n");
            }
        }
        pclose(pipe);
    }

    /* --libs */
    snprintf(cmd, sizeof(cmd), "pkg-config --libs %s 2>/dev/null", pkgname);
    pipe = popen(cmd, "r");
    if (pipe) {
        if (fgets(buf, sizeof(buf), pipe)) {
            char *tok = strtok(buf, " \t\r\n");
            while (tok) {
                if (tok[0] == '-' && tok[1] == 'l' && tok[2] != '\0') {
                    add_ldflag(tok + 2);
                } else if (tok[0] == '-' && tok[1] == 'L' && tok[2] != '\0') {
                    add_extra_ldir(tok);
                } else if (strcmp(tok, "-framework") == 0) {
                    /* -framework Name is a two-token flag; combine and store verbatim */
                    char *name = strtok(NULL, " \t\r\n");
                    if (name) {
                        char fw[256];
                        snprintf(fw, sizeof(fw), "-framework %s", name);
                        add_extra_ldir(fw);
                    }
                } else if (tok[0] == '-' && tok[1] == 'f') {
                    add_extra_ldir(tok);   /* other -f... flags verbatim */
                }
                tok = strtok(NULL, " \t\r\n");
            }
        }
        pclose(pipe);
    }

    /* Homebrew fallback: if pkg-config gave no -I path, try brew --prefix.
     * On macOS, pkg-config may return only -D flags (e.g. -D_THREAD_SAFE)
     * without an include path when PKG_CONFIG_PATH isn't set for homebrew. */
    if (!got_include) {
        snprintf(cmd, sizeof(cmd), "brew --prefix %s 2>/dev/null", pkgname);
        pipe = popen(cmd, "r");
        if (pipe) {
            if (fgets(buf, sizeof(buf), pipe)) {
                buf[strcspn(buf, "\r\n")] = '\0';
                if (buf[0] != '\0') {
                    char flag[512];
                    snprintf(flag, sizeof(flag), "-I%s/include", buf);
                    add_extra_cflag(flag);
                    snprintf(flag, sizeof(flag), "-L%s/lib", buf);
                    add_extra_ldir(flag);
                    add_ldflag(pkgname);
                }
            }
            pclose(pipe);
        }
    }
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
 * C file lists fed to the final gcc link command.
 *
 * g_cfiles[]     — generated from .mod (deleted after link unless --emit-c)
 * g_csrcfiles[]  — provided via CSRC in .ffi (never deleted)
 * ----------------------------------------------------------------------- */
static char g_cfiles[MAX_COMPILED][512];
static int  g_ncfiles = 0;

static char g_csrcfiles[MAX_COMPILED][512];
static int  g_ncsrcfiles = 0;

static void add_cfile(const char *path) {
    if (g_ncfiles < MAX_COMPILED) {
        strncpy(g_cfiles[g_ncfiles], path, sizeof(g_cfiles[0]) - 1);
        g_cfiles[g_ncfiles][sizeof(g_cfiles[0]) - 1] = '\0';
        g_ncfiles++;
    }
}

static void add_csrcfile(const char *path) {
    for (int i = 0; i < g_ncsrcfiles; i++)
        if (!strcmp(g_csrcfiles[i], path)) return;   /* deduplicate */
    if (g_ncsrcfiles < MAX_COMPILED) {
        strncpy(g_csrcfiles[g_ncsrcfiles], path, sizeof(g_csrcfiles[0]) - 1);
        g_csrcfiles[g_ncsrcfiles][sizeof(g_csrcfiles[0]) - 1] = '\0';
        g_ncsrcfiles++;
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
 * FFI: resolve and parse .ffi binding files
 * ----------------------------------------------------------------------- */

/* Search for Module.ffi using the same dirs as resolve_module_file. */
static int resolve_ffi_file(const char *importer_dir, const char *modname,
                             char *out, size_t outsz)
{
    char cand[512];

    if (importer_dir && *importer_dir) {
        snprintf(cand, sizeof(cand), "%s/%s.ffi", importer_dir, modname);
        if (file_exists(cand)) {
            strncpy(out, cand, outsz-1); out[outsz-1] = '\0'; return 1;
        }
    }

    snprintf(cand, sizeof(cand), "%s.ffi", modname);
    if (file_exists(cand)) {
        strncpy(out, cand, outsz-1); out[outsz-1] = '\0'; return 1;
    }

    {
        const char *mp = effective_mod_path();
        if (mp && *mp) {
            const char *p = mp;
            while (*p) {
                const char *q = p;
                while (*q && *q != ':') q++;
                char dir[512];
                size_t n = (size_t)(q - p);
                if (n >= sizeof(dir)) n = sizeof(dir)-1;
                memcpy(dir, p, n); dir[n] = '\0';
                if (n > 0)
                    snprintf(cand, sizeof(cand), "%s/%s.ffi", dir, modname);
                else
                    snprintf(cand, sizeof(cand), "%s.ffi", modname);
                if (file_exists(cand)) {
                    strncpy(out, cand, outsz-1); out[outsz-1] = '\0'; return 1;
                }
                p = (*q == ':') ? q+1 : q;
            }
        }
    }

    return 0;
}

static void trim_trailing(char *s) {
    char *e = s + strlen(s) - 1;
    while (e >= s && (*e == ' ' || *e == '\t' || *e == '\r')) *e-- = '\0';
}

/* Parse Module.ffi, register with codegen, collect link flags.
 * Returns 1 on success, 0 on error. */
static int parse_ffi_file(const char *ffifile, const char *modname)
{
    FILE *f = fopen(ffifile, "r");
    if (!f) {
        fprintf(stderr, "obc: cannot open %s\n", ffifile);
        return 0;
    }

    char header[256] = "";
    OBCFfiMap maps[OBC_FFI_MAP_MAX];
    int nmaps = 0;
    char line[512];

    while (fgets(line, sizeof(line), f)) {
        /* strip newline */
        char *nl = strchr(line, '\n'); if (nl) *nl = '\0';
        /* skip leading whitespace */
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        /* skip blank lines and comments */
        if (!*p || *p == '#') continue;

        if (strncmp(p, "HEADER", 6) == 0 && (p[6] == ' ' || p[6] == '\t')) {
            p += 7;
            while (*p == ' ' || *p == '\t') p++;
            trim_trailing(p);
            /* wrap bare names in double quotes */
            if (*p != '<' && *p != '"') {
                char tmp[256];
                snprintf(tmp, sizeof(tmp), "\"%s\"", p);
                strncpy(header, tmp, sizeof(header)-1);
            } else {
                strncpy(header, p, sizeof(header)-1);
            }
            header[sizeof(header)-1] = '\0';

        } else if (strncmp(p, "LINK_LINUX", 10) == 0 && (p[10] == ' ' || p[10] == '\t')) {
            p += 11;
            while (*p == ' ' || *p == '\t') p++;
            trim_trailing(p);
#ifdef __linux__
            if (*p) add_ldflag(p);
#endif

        } else if (strncmp(p, "LDFLAGS_MACOS", 13) == 0 && (p[13] == ' ' || p[13] == '\t')) {
            /* Verbatim linker flags for macOS (e.g. "-framework OpenGL") */
            p += 14;
            while (*p == ' ' || *p == '\t') p++;
            trim_trailing(p);
#ifdef __APPLE__
            if (*p) add_extra_ldir(p);
#endif

        } else if (strncmp(p, "LDFLAGS_LINUX", 13) == 0 && (p[13] == ' ' || p[13] == '\t')) {
            /* Verbatim linker flags for Linux (e.g. "-lGL") */
            p += 14;
            while (*p == ' ' || *p == '\t') p++;
            trim_trailing(p);
#ifdef __linux__
            if (*p) add_extra_ldir(p);
#endif

        } else if (strncmp(p, "LINK_MACOS", 10) == 0 && (p[10] == ' ' || p[10] == '\t')) {
            p += 11;
            while (*p == ' ' || *p == '\t') p++;
            trim_trailing(p);
#ifdef __APPLE__
            if (*p) add_ldflag(p);
#endif

        } else if (strncmp(p, "LINK", 4) == 0 && (p[4] == ' ' || p[4] == '\t')) {
            p += 5;
            while (*p == ' ' || *p == '\t') p++;
            trim_trailing(p);
            if (*p) add_ldflag(p);

        } else if (strncmp(p, "MAP", 3) == 0 && (p[3] == ' ' || p[3] == '\t')) {
            p += 4;
            while (*p == ' ' || *p == '\t') p++;
            if (nmaps >= OBC_FFI_MAP_MAX) continue;
            /* "OberonName CName" */
            char *sep = p;
            while (*sep && *sep != ' ' && *sep != '\t') sep++;
            size_t nlen = (size_t)(sep - p);
            if (nlen == 0 || nlen >= sizeof(maps[0].oberon)) continue;
            strncpy(maps[nmaps].oberon, p, nlen);
            maps[nmaps].oberon[nlen] = '\0';
            while (*sep == ' ' || *sep == '\t') sep++;
            trim_trailing(sep);
            if (!*sep) continue;
            strncpy(maps[nmaps].cname, sep, sizeof(maps[0].cname)-1);
            maps[nmaps].cname[sizeof(maps[0].cname)-1] = '\0';
            nmaps++;

        } else if (strncmp(p, "PKGCONFIG", 9) == 0 && (p[9]==' ' || p[9]=='\t')) {
            p += 10;
            while (*p == ' ' || *p == '\t') p++;
            trim_trailing(p);
            if (*p) pkgconfig_query(p);

        } else if (strncmp(p, "CSRC", 4) == 0 && (p[4] == ' ' || p[4] == '\t')) {
            p += 5;
            while (*p == ' ' || *p == '\t') p++;
            trim_trailing(p);
            if (*p) {
                char cpath[512];
                if (*p == '/') {
                    strncpy(cpath, p, sizeof(cpath)-1);
                    cpath[sizeof(cpath)-1] = '\0';
                } else {
                    char ffidir[512];
                    get_dirname_str(ffifile, ffidir, sizeof(ffidir));
                    snprintf(cpath, sizeof(cpath), "%s/%s", ffidir, p);
                }
                add_csrcfile(cpath);
            }

        } else {
            fprintf(stderr, "obc: %s: unrecognised directive: %s\n", ffifile, p);
        }
    }
    fclose(f);

    if (!header[0]) {
        fprintf(stderr, "obc: %s: missing HEADER directive\n", ffifile);
        return 0;
    }

    ffi_register(modname, header, maps, nmaps);
    return 1;
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

            /* Check for a .ffi binding before looking for a .mod file */
            char ffifile[512];
            if (resolve_ffi_file(moddir, imports[i], ffifile, sizeof(ffifile))) {
                if (!parse_ffi_file(ffifile, imports[i])) return 1;
                mark_compiled(imports[i]);   /* don't try to compile as Oberon */
                continue;
            }

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
            codegen(ast, out, is_main, modfile);
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
        /* Pre-compile any .cpp CSRC files to temp .o objects using g++.
         * The resulting .o paths replace the .cpp entries in g_csrcfiles. */
        for (int i = 0; i < g_ncsrcfiles; i++) {
            const char *ext = strrchr(g_csrcfiles[i], '.');
            if (!ext || (strcmp(ext, ".cpp") != 0 && strcmp(ext, ".cc") != 0
                         && strcmp(ext, ".cxx") != 0))
                continue;

            /* Build temp .o path: $TMPDIR/obc_<basename>.o */
            const char *base = strrchr(g_csrcfiles[i], '/');
            base = base ? base + 1 : g_csrcfiles[i];
            char opath[512];
            const char *tmpdir = getenv("TMPDIR");
            if (!tmpdir || !*tmpdir) tmpdir = "/tmp";
            snprintf(opath, sizeof(opath), "%s/obc_%s.o", tmpdir, base);

            char cxxcmd[4096];
            int cpos = snprintf(cxxcmd, sizeof(cxxcmd),
                                "g++ -c -O -w -o %s", opath);
            for (int j = 0; j < g_n_extra_cflags; j++)
                cpos += snprintf(cxxcmd + cpos, sizeof(cxxcmd) - (size_t)cpos,
                                 " %s", g_extra_cflags[j]);
            for (int j = 0; j < g_nincdirs; j++)
                cpos += snprintf(cxxcmd + cpos, sizeof(cxxcmd) - (size_t)cpos,
                                 " -I%s", g_incdirs[j]);
            snprintf(cxxcmd + cpos, sizeof(cxxcmd) - (size_t)cpos,
                     " %s", g_csrcfiles[i]);

            if (system(cxxcmd) != 0) {
                fprintf(stderr, "obc: g++ pre-compile failed for %s\n",
                        g_csrcfiles[i]);
                return 1;
            }
            /* Replace .cpp entry with the compiled .o */
            strncpy(g_csrcfiles[i], opath, sizeof(g_csrcfiles[0]) - 1);
            g_csrcfiles[i][sizeof(g_csrcfiles[0]) - 1] = '\0';
        }

        char cmd[8192];
        int pos = snprintf(cmd, sizeof(cmd),
            "bash -c 'set -o pipefail;gcc --std=c11 %s-O -Wno-incompatible-pointer-types -Wno-implicit-function-declaration -o %s",
            g_warnings
                ? "-Wall -Wno-unused-function -Wno-unused-variable "
                : "-w ",
            binpath);

        for (int i = 0; i < g_n_extra_cflags && pos < (int)sizeof(cmd); i++) {
            pos += snprintf(cmd + pos, sizeof(cmd) - (size_t)pos,
                            " %s", g_extra_cflags[i]);
        }

        for (int i = 0; i < g_nincdirs && pos < (int)sizeof(cmd); i++) {
            pos += snprintf(cmd + pos, sizeof(cmd) - (size_t)pos,
                            " -I%s", g_incdirs[i]);
        }

        for (int i = 0; i < g_ncfiles && pos < (int)sizeof(cmd); i++) {
            pos += snprintf(cmd + pos, sizeof(cmd) - (size_t)pos,
                            " %s", g_cfiles[i]);
        }

        for (int i = 0; i < g_ncsrcfiles && pos < (int)sizeof(cmd); i++) {
            pos += snprintf(cmd + pos, sizeof(cmd) - (size_t)pos,
                            " %s", g_csrcfiles[i]);
        }

        for (int i = 0; i < g_n_extra_ldirs && pos < (int)sizeof(cmd); i++) {
            pos += snprintf(cmd + pos, sizeof(cmd) - (size_t)pos,
                            " %s", g_extra_ldirs[i]);
        }

        for (int i = 0; i < g_nldflags && pos < (int)sizeof(cmd); i++) {
            pos += snprintf(cmd + pos, sizeof(cmd) - (size_t)pos,
                            " -l%s", g_ldflags[i]);
        }

        if (pos < (int)sizeof(cmd)) {
            snprintf(cmd + pos, sizeof(cmd) - (size_t)pos,
										 " -lm -lz 2>&1 | sed \"/: In function/d\"'");
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

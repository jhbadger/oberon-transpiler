#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

typedef struct {
    char name[50];
    char type[20];
} Symbol;

Symbol table[200];
int symbol_count = 0;

void add_symbol(const char* name, const char* type) {
    for(int i=0; i<symbol_count; i++) if(strcmp(table[i].name, name) == 0) return;
    strcpy(table[symbol_count].name, name);
    strcpy(table[symbol_count].type, type);
    symbol_count++;
}

const char* get_type(const char* name) {
    for (int i = 0; i < symbol_count; i++) {
        if (strcmp(table[i].name, name) == 0) return table[i].type;
    }
    return "INTEGER";
}

void translate(FILE *in, FILE *out) {
    char tok[100], last_id[50] = "";
    int c, in_main = 0, in_proc = 0;

    fprintf(out, "#include <stdio.h>\n#include <string.h>\n#include <stdbool.h>\n\n");
    fprintf(out, "static inline void write_i(int x) { printf(\"%%d\\n\", x); }\n");
    fprintf(out, "static inline void write_f(double x) { printf(\"%%g\\n\", x); }\n");
    fprintf(out, "static inline void write_s(const char* x) { printf(\"%%s\\n\", x); }\n\n");

    while ((c = fgetc(in)) != EOF) {
        if (isspace(c)) continue;

        if (c == '(') {
            if ((c = fgetc(in)) == '*') {
                while (!((c = fgetc(in)) == '*' && (c = fgetc(in)) == ')')) if (c == EOF) break;
                continue;
            } else ungetc(c, in); c = '(';
        }

        if (c == '"') {
            int i = 0; tok[i++] = '"';
            while ((c = fgetc(in)) != '"' && c != EOF) if (i < 98) tok[i++] = c;
            tok[i++] = '"'; tok[i] = '\0';
            fprintf(out, "%s ", tok);
            continue;
        }

        if (isalnum(c) || c == '.') {
            int i = 0; tok[i++] = c;
            while ((c = fgetc(in)) != EOF && (isalnum(c) || c == '.')) {
                if (i < 99) tok[i++] = c;
            }
            tok[i] = '\0';
            if (c != EOF) ungetc(c, in);

            // KEYWORD TRANSLATIONS
            if (strcasecmp(tok, "MODULE") == 0) {
                while ((c = fgetc(in)) != ';' && c != EOF);
            } 
            else if (strcasecmp(tok, "VAR") == 0) {
                char names[10][50];
                while (1) {
                    int n_count = 0;
                    long pos = ftell(in);
                    while (fscanf(in, " %49[a-zA-Z0-9] ", names[n_count]) == 1) {
                        n_count++;
                        char next; fscanf(in, " %c", &next);
                        if (next == ':') break;
                        if (next != ',') { fseek(in, pos, SEEK_SET); goto end_var; }
                    }
                    if (n_count == 0) break;
                    char vtype[50]; fscanf(in, " %49[a-zA-Z0-9] ;", vtype);
                    for (int j = 0; j < n_count; j++) {
                        add_symbol(names[j], vtype);
                        if (strcasecmp(vtype, "STRING") == 0) fprintf(out, "char %s[256];\n", names[j]);
                        else if (strcasecmp(vtype, "REAL") == 0) fprintf(out, "double %s;\n", names[j]);
                        else fprintf(out, "int %s;\n", names[j]);
                    }
                }
                end_var:;
            }
            else if (strcasecmp(tok, "PROCEDURE") == 0) {
                char pname[50], ppar[50], ptype[50];
                fscanf(in, " %[^ (] ( %[^ : ] : %[^ ) ] )", pname, ppar, ptype);
                add_symbol(ppar, ptype);
                while(isspace(c = fgetc(in)));
                if (c == ':') { fscanf(in, " %*s ;"); fprintf(out, "\nint %s(int %s) {\n", pname, ppar); }
                else { ungetc(c, in); fscanf(in, " ;"); fprintf(out, "\nvoid %s(int %s) {\n", pname, ppar); }
                in_proc = 1;
            } 
            else if (strcasecmp(tok, "BEGIN") == 0) {
                if (!in_proc && !in_main) { fprintf(out, "\nint main() {\n"); in_main = 1; }
            }
            else if (strcasecmp(tok, "IF") == 0) fprintf(out, "if (");
            else if (strcasecmp(tok, "THEN") == 0) fprintf(out, ") {\n");
            else if (strcasecmp(tok, "ELSE") == 0) fprintf(out, "} else {\n");
            else if (strcasecmp(tok, "WHILE") == 0) fprintf(out, "while (");
            else if (strcasecmp(tok, "DO") == 0) fprintf(out, ") {\n");
            else if (strcasecmp(tok, "RETURN") == 0) fprintf(out, "    return ");
            else if (strcasecmp(tok, "READ") == 0) {
                while ((c = fgetc(in)) != '(' && c != EOF);
                fscanf(in, " %[^)]", tok); fgetc(in);
                const char* type = get_type(tok);
                if (strcasecmp(type, "REAL") == 0) fprintf(out, "    scanf(\"%%lf\", &%s);\n", tok);
                else if (strcasecmp(type, "STRING") == 0) fprintf(out, "    scanf(\"%%s\", %s);\n", tok);
                else fprintf(out, "    scanf(\"%%d\", &%s);\n", tok);
            } 
            else if (strcasecmp(tok, "WRITE") == 0) {
                while ((c = fgetc(in)) != '(' && c != EOF);
                int p = fgetc(in);
                if (p == '"') {
                    char str[200]; int j = 0; str[j++] = '"';
                    while ((c = fgetc(in)) != '"' && c != EOF) str[j++] = c;
                    str[j++] = '"'; str[j] = '\0';
                    fprintf(out, "    printf(%s);\n", str);
                    while (fgetc(in) != ')');
                } else {
                    ungetc(p, in); fscanf(in, " %[^)]", tok); fgetc(in);
                    fprintf(out, "    _Generic((%s), int: write_i, double: write_f, char*: write_s, const char*: write_s)(%s);\n", tok, tok);
                }
            }
            else if (strcasecmp(tok, "END") == 0) {
                while ((c = fgetc(in)) != EOF && c != ';' && c != '.');
                if (c == '.') { if (in_main) fprintf(out, "    return 0;\n}\n"); } 
                else fprintf(out, "}\n");
                if (!strchr(tok, ';')) in_proc = 0; // Only reset proc if not a block end
            }
            else {
                strcpy(last_id, tok);
                fprintf(out, "%s ", tok);
            }
        } 
        else if (c == ':') {
            if ((c = fgetc(in)) == '=') {
                if (strcasecmp(get_type(last_id), "STRING") == 0) {
                    fseek(out, -(long)strlen(last_id) - 1, SEEK_CUR);
                    fprintf(out, "strcpy(%s, ", last_id);
                } else fprintf(out, " = ");
            } else ungetc(c, in);
        }
        else if (c == ';') {
            if (strcasecmp(get_type(last_id), "STRING") == 0) fprintf(out, ");\n");
            else fprintf(out, ";\n");
            strcpy(last_id, "");
        }
        else if (strchr("+-*/()<>#=", c)) {
            if (c == '#') fprintf(out, " != ");
            else if (c == '=') fprintf(out, " == ");
            else fprintf(out, " %c ", c);
        }
    }
}

int main(int argc, char *argv[]) {
    if (argc < 2) return 1;
    FILE *in = fopen(argv[1], "r"), *out = fopen("temp.c", "w+");
    if (!in || !out) return 1;
    translate(in, out);
    fclose(in); fclose(out);
    char bin[100]; strcpy(bin, argv[1]);
    char *dot = strrchr(bin, '.'); if (dot) *dot = '\0';
    char cmd[256]; sprintf(cmd, "gcc -std=c11 temp.c -o %s", bin);
    if (system(cmd) == 0) { printf("Success: ./%s\n", bin); remove("temp.c"); }
    return 0;
}
#include "lexer.h"

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* -----------------------------------------------------------------------
 * Internal helpers
 * ----------------------------------------------------------------------- */

static void advance(Lexer *lex) {
    if (lex->ch == '\n') { lex->line++; lex->col = 1; }
    else                 { lex->col++; }
    lex->ch = fgetc(lex->file);
}

static Token make_tok(TokenKind kind, const char *text, int line, int col) {
    Token t;
    t.kind     = kind;
    t.line     = line;
    t.col      = col;
    t.int_val  = 0;
    t.real_val = 0.0;
    strncpy(t.text, text, MAX_TOKEN_LEN - 1);
    t.text[MAX_TOKEN_LEN - 1] = '\0';
    return t;
}

/* -----------------------------------------------------------------------
 * Keyword table
 * ----------------------------------------------------------------------- */

typedef struct { const char *word; TokenKind kind; } Keyword;

static const Keyword keywords[] = {
    { "ARRAY",     TOK_ARRAY     },
    { "BEGIN",     TOK_BEGIN     },
    { "BY",        TOK_BY        },
    { "CASE",      TOK_CASE      },
    { "CONST",     TOK_CONST     },
    { "DIV",       TOK_DIV       },
    { "DO",        TOK_DO        },
    { "ELSE",      TOK_ELSE      },
    { "ELSIF",     TOK_ELSIF     },
    { "END",       TOK_END       },
    { "FALSE",     TOK_FALSE     },
    { "FOR",       TOK_FOR       },
    { "IF",        TOK_IF        },
    { "IMPORT",    TOK_IMPORT    },
    { "EXIT",      TOK_EXIT      },
    { "IN",        TOK_IN        },
    { "IS",        TOK_IS        },
    { "LOOP",      TOK_LOOP      },
    { "MOD",       TOK_MOD       },
    { "MODULE",    TOK_MODULE    },
    { "NIL",       TOK_NIL       },
    { "OF",        TOK_OF        },
    { "OR",        TOK_OR        },
    { "POINTER",   TOK_POINTER   },
    { "PROCEDURE", TOK_PROCEDURE },
    { "RECORD",    TOK_RECORD    },
    { "REPEAT",    TOK_REPEAT    },
    { "RETURN",    TOK_RETURN    },
    { "THEN",      TOK_THEN      },
    { "TO",        TOK_TO        },
    { "TRUE",      TOK_TRUE      },
    { "TYPE",      TOK_TYPE      },
    { "UNTIL",     TOK_UNTIL     },
    { "VAR",       TOK_VAR       },
    { "WHILE",     TOK_WHILE     },
    { "WITH",      TOK_WITH      },
    { NULL, 0 }
};

static TokenKind lookup_keyword(const char *word) {
    for (int i = 0; keywords[i].word; i++)
        if (strcmp(keywords[i].word, word) == 0)
            return keywords[i].kind;
    return TOK_IDENT;
}

/* -----------------------------------------------------------------------
 * lexer_init
 * ----------------------------------------------------------------------- */

void lexer_init(Lexer *lex, FILE *file) {
    lex->file = file;
    lex->line = 1;
    lex->col  = 1;
    lex->ch   = fgetc(file);
}

/* -----------------------------------------------------------------------
 * lexer_next  —  return the next token
 * ----------------------------------------------------------------------- */

Token lexer_next(Lexer *lex) {

    /* Skip whitespace and (* nested comments *) */
    for (;;) {
        while (lex->ch != EOF && isspace(lex->ch))
            advance(lex);

        if (lex->ch != '(')
            break;

        /* Could be '(' or start of comment '(*' */
        int saved_line = lex->line, saved_col = lex->col;
        advance(lex);          /* consume '(' */

        if (lex->ch != '*')    /* plain '(' */
            return make_tok(TOK_LPAREN, "(", saved_line, saved_col);

        /* Consume (* ... *) with nesting */
        advance(lex);          /* consume '*' */
        int depth = 1;
        while (lex->ch != EOF && depth > 0) {
            if (lex->ch == '(') {
                advance(lex);
                if (lex->ch == '*') { depth++; advance(lex); }
            } else if (lex->ch == '*') {
                advance(lex);
                if (lex->ch == ')') { depth--; advance(lex); }
            } else {
                advance(lex);
            }
        }
        /* Restart whitespace/comment loop after comment */
    }

    if (lex->ch == EOF)
        return make_tok(TOK_EOF, "", lex->line, lex->col);

    int  line = lex->line, col = lex->col;
    char text[MAX_TOKEN_LEN];
    int  tlen = 0;

    /* ----------------------------------------------------------------
     * Identifier or keyword
     * ---------------------------------------------------------------- */
    if (isalpha(lex->ch) || lex->ch == '_') {
        while (lex->ch != EOF && (isalnum(lex->ch) || lex->ch == '_')) {
            if (tlen < MAX_TOKEN_LEN - 1) text[tlen++] = (char)lex->ch;
            advance(lex);
        }
        text[tlen] = '\0';
        return make_tok(lookup_keyword(text), text, line, col);
    }

    /* ----------------------------------------------------------------
     * Numeric literal
     *
     * Oberon-07 grammar:
     *   integer  =  digit {digit}  |  digit {hexDigit} "H"
     *   real     =  digit {digit} "." {digit} [ScaleFactor]
     *   ScaleFactor = "E" ["+"|"-"] digit {digit}
     *   charCode =  digit {hexDigit} "X"
     *
     * Strategy: consume all leading hex digits, then decide on suffix.
     * Note: 'E' and 'D' are valid hex digits AND scale-factor letters;
     * the grammar resolves ambiguity because reals MUST contain a '.'.
     * ---------------------------------------------------------------- */
    if (isdigit(lex->ch)) {
        int is_hex = 0;  /* did we see A-F digits? */

        while (lex->ch != EOF && isxdigit(lex->ch)) {
            if (!isdigit(lex->ch)) is_hex = 1;
            if (tlen < MAX_TOKEN_LEN - 1) text[tlen++] = (char)lex->ch;
            advance(lex);
        }

        /* 'H' suffix → hex integer */
        if (lex->ch == 'H') {
            if (tlen < MAX_TOKEN_LEN - 1) text[tlen++] = 'H';
            text[tlen] = '\0';
            advance(lex);
            Token t   = make_tok(TOK_INTEGER, text, line, col);
            t.int_val = strtol(text, NULL, 16); /* strtol stops before 'H' */
            return t;
        }

        /* 'X' suffix → character literal (e.g. 0X = NUL, 0AX = LF) */
        if (lex->ch == 'X') {
            if (tlen < MAX_TOKEN_LEN - 1) text[tlen++] = 'X';
            text[tlen] = '\0';
            advance(lex);
            Token t   = make_tok(TOK_CHAR, text, line, col);
            t.int_val = strtol(text, NULL, 16); /* stops before 'X' */
            return t;
        }

        /* Hex digits seen but no H or X suffix → lexer error */
        if (is_hex) {
            text[tlen] = '\0';
            Token t = make_tok(TOK_ERROR, text, line, col);
            fprintf(stderr, "%d:%d: hex digits without H or X suffix: %s\n",
                    line, col, text);
            return t;
        }

        /* '.' after digits — could be real literal or start of '..' */
        if (lex->ch == '.') {
            /* Peek at the character after '.'.  Because lex->ch is already
             * the lookahead (read ahead), the *next* character is one more
             * fgetc away.  We use a raw fgetc/ungetc pair to peek without
             * disturbing lex->ch. */
            int peek = fgetc(lex->file);
            ungetc(peek, lex->file);

            if (peek == '.') {
                /* This is the '..' range operator, not a decimal point.
                 * Return the integer and leave lex->ch == '.' so the next
                 * call produces TOK_DOTDOT. */
                text[tlen] = '\0';
                Token t   = make_tok(TOK_INTEGER, text, line, col);
                t.int_val = atol(text);
                return t;
            }

            /* Consume the '.' and fractional digits → real literal */
            text[tlen++] = '.';
            advance(lex);
            while (lex->ch != EOF && isdigit(lex->ch)) {
                if (tlen < MAX_TOKEN_LEN - 1) text[tlen++] = (char)lex->ch;
                advance(lex);
            }
            /* Optional scale factor: E | D  followed by optional sign */
            if (lex->ch == 'E' || lex->ch == 'D') {
                if (tlen < MAX_TOKEN_LEN - 1) text[tlen++] = (char)lex->ch;
                advance(lex);
                if (lex->ch == '+' || lex->ch == '-') {
                    if (tlen < MAX_TOKEN_LEN - 1) text[tlen++] = (char)lex->ch;
                    advance(lex);
                }
                while (lex->ch != EOF && isdigit(lex->ch)) {
                    if (tlen < MAX_TOKEN_LEN - 1) text[tlen++] = (char)lex->ch;
                    advance(lex);
                }
            }
            text[tlen] = '\0';
            Token t    = make_tok(TOK_REAL, text, line, col);
            t.real_val = atof(text);
            return t;
        }

        /* Plain decimal integer */
        text[tlen] = '\0';
        Token t   = make_tok(TOK_INTEGER, text, line, col);
        t.int_val = atol(text);
        return t;
    }

    /* ----------------------------------------------------------------
     * String literal  "..."  or  '...'
     * The token text holds the content WITHOUT the surrounding quotes.
     * ---------------------------------------------------------------- */
    if (lex->ch == '"' || lex->ch == '\'') {
        char delim = (char)lex->ch;
        advance(lex);
        while (lex->ch != EOF && lex->ch != delim) {
            if (tlen < MAX_TOKEN_LEN - 1) text[tlen++] = (char)lex->ch;
            advance(lex);
        }
        if (lex->ch == delim) advance(lex); /* consume closing quote */
        text[tlen] = '\0';
        return make_tok(TOK_STRING, text, line, col);
    }

    /* ----------------------------------------------------------------
     * Operators and punctuation
     * ---------------------------------------------------------------- */
    int c = lex->ch;
    advance(lex);

    switch (c) {
    case '+': return make_tok(TOK_PLUS,     "+",  line, col);
    case '-': return make_tok(TOK_MINUS,    "-",  line, col);
    case '*': return make_tok(TOK_STAR,     "*",  line, col);
    case '/': return make_tok(TOK_SLASH,    "/",  line, col);
    case '&': return make_tok(TOK_AMP,      "&",  line, col);
    case '~': return make_tok(TOK_TILDE,    "~",  line, col);
    case '=': return make_tok(TOK_EQ,       "=",  line, col);
    case '#': return make_tok(TOK_NEQ,      "#",  line, col);
    case ')': return make_tok(TOK_RPAREN,   ")",  line, col);
    case '[': return make_tok(TOK_LBRACKET, "[",  line, col);
    case ']': return make_tok(TOK_RBRACKET, "]",  line, col);
    case '{': return make_tok(TOK_LBRACE,   "{",  line, col);
    case '}': return make_tok(TOK_RBRACE,   "}",  line, col);
    case ',': return make_tok(TOK_COMMA,    ",",  line, col);
    case ';': return make_tok(TOK_SEMI,     ";",  line, col);
    case '|': return make_tok(TOK_BAR,      "|",  line, col);
    case '^': return make_tok(TOK_CARET,    "^",  line, col);
    case '<':
        if (lex->ch == '=') { advance(lex); return make_tok(TOK_LE,     "<=", line, col); }
        return make_tok(TOK_LT, "<", line, col);
    case '>':
        if (lex->ch == '=') { advance(lex); return make_tok(TOK_GE,     ">=", line, col); }
        return make_tok(TOK_GT, ">", line, col);
    case ':':
        if (lex->ch == '=') { advance(lex); return make_tok(TOK_ASSIGN, ":=", line, col); }
        return make_tok(TOK_COLON, ":", line, col);
    case '.':
        if (lex->ch == '.') { advance(lex); return make_tok(TOK_DOTDOT, "..", line, col); }
        return make_tok(TOK_DOT, ".", line, col);
    default: {
        char msg[32];
        snprintf(msg, sizeof(msg), "unexpected '%c'", (char)c);
        Token t = make_tok(TOK_ERROR, msg, line, col);
        fprintf(stderr, "%d:%d: %s\n", line, col, msg);
        return t;
    }
    }
}

/* -----------------------------------------------------------------------
 * Diagnostics
 * ----------------------------------------------------------------------- */

const char *token_kind_name(TokenKind k) {
    switch (k) {
    case TOK_EOF:       return "EOF";
    case TOK_ERROR:     return "ERROR";
    case TOK_IDENT:     return "IDENT";
    case TOK_INTEGER:   return "INTEGER";
    case TOK_REAL:      return "REAL";
    case TOK_STRING:    return "STRING";
    case TOK_CHAR:      return "CHAR";
    case TOK_ARRAY:     return "ARRAY";
    case TOK_BEGIN:     return "BEGIN";
    case TOK_BY:        return "BY";
    case TOK_CASE:      return "CASE";
    case TOK_CONST:     return "CONST";
    case TOK_DIV:       return "DIV";
    case TOK_DO:        return "DO";
    case TOK_ELSE:      return "ELSE";
    case TOK_ELSIF:     return "ELSIF";
    case TOK_END:       return "END";
    case TOK_FALSE:     return "FALSE";
    case TOK_FOR:       return "FOR";
    case TOK_IF:        return "IF";
    case TOK_IMPORT:    return "IMPORT";
    case TOK_EXIT:      return "EXIT";
    case TOK_IN:        return "IN";
    case TOK_IS:        return "IS";
    case TOK_LOOP:      return "LOOP";
    case TOK_MOD:       return "MOD";
    case TOK_MODULE:    return "MODULE";
    case TOK_NIL:       return "NIL";
    case TOK_OF:        return "OF";
    case TOK_OR:        return "OR";
    case TOK_POINTER:   return "POINTER";
    case TOK_PROCEDURE: return "PROCEDURE";
    case TOK_RECORD:    return "RECORD";
    case TOK_REPEAT:    return "REPEAT";
    case TOK_RETURN:    return "RETURN";
    case TOK_THEN:      return "THEN";
    case TOK_TO:        return "TO";
    case TOK_TRUE:      return "TRUE";
    case TOK_TYPE:      return "TYPE";
    case TOK_UNTIL:     return "UNTIL";
    case TOK_VAR:       return "VAR";
    case TOK_WHILE:     return "WHILE";
    case TOK_WITH:      return "WITH";
    case TOK_PLUS:      return "PLUS";
    case TOK_MINUS:     return "MINUS";
    case TOK_STAR:      return "STAR";
    case TOK_SLASH:     return "SLASH";
    case TOK_AMP:       return "AMP";
    case TOK_TILDE:     return "TILDE";
    case TOK_EQ:        return "EQ";
    case TOK_NEQ:       return "NEQ";
    case TOK_LT:        return "LT";
    case TOK_LE:        return "LE";
    case TOK_GT:        return "GT";
    case TOK_GE:        return "GE";
    case TOK_ASSIGN:    return "ASSIGN";
    case TOK_LPAREN:    return "LPAREN";
    case TOK_RPAREN:    return "RPAREN";
    case TOK_LBRACKET:  return "LBRACKET";
    case TOK_RBRACKET:  return "RBRACKET";
    case TOK_LBRACE:    return "LBRACE";
    case TOK_RBRACE:    return "RBRACE";
    case TOK_DOT:       return "DOT";
    case TOK_DOTDOT:    return "DOTDOT";
    case TOK_COMMA:     return "COMMA";
    case TOK_SEMI:      return "SEMI";
    case TOK_COLON:     return "COLON";
    case TOK_BAR:       return "BAR";
    case TOK_CARET:     return "CARET";
    default:            return "?";
    }
}

void token_print(const Token *t) {
    printf("%d:%d  %-12s  \"%s\"", t->line, t->col,
           token_kind_name(t->kind), t->text);
    if (t->kind == TOK_INTEGER || t->kind == TOK_CHAR)
        printf("  (%ld)", t->int_val);
    else if (t->kind == TOK_REAL)
        printf("  (%g)", t->real_val);
    printf("\n");
}

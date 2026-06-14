#include "OBCRegex.h"
#include <sys/types.h>
#include <regex.h>
#include <string.h>

#define MAX_GROUPS 32
#define MAX_STR    65536

static regmatch_t g_matches[MAX_GROUPS];
static int        g_n_matches = 0;
static int        g_start_off = 0;
static char       g_str[MAX_STR];

/* Translate Perl-style shortcuts to POSIX ERE equivalents. */
static void translate_pattern(const char *src, char *dst, int dst_len) {
    int i = 0, j = 0;
    while (src[i] && j < dst_len - 1) {
        if (src[i] == '\\' && src[i+1]) {
            char c2 = src[i+1];
            if (c2 == 'd') {
                if (j + 5 < dst_len) { memcpy(dst+j, "[0-9]", 5); j += 5; }
            } else if (c2 == 'D') {
                if (j + 6 < dst_len) { memcpy(dst+j, "[^0-9]", 6); j += 6; }
            } else if (c2 == 'w') {
                if (j + 12 < dst_len) { memcpy(dst+j, "[a-zA-Z0-9_]", 12); j += 12; }
            } else if (c2 == 'W') {
                if (j + 13 < dst_len) { memcpy(dst+j, "[^a-zA-Z0-9_]", 13); j += 13; }
            } else if (c2 == 's') {
                if (j + 6 < dst_len) {
                    dst[j++]='['; dst[j++]=' '; dst[j++]='\t';
                    dst[j++]='\n'; dst[j++]='\r'; dst[j++]=']';
                }
            } else if (c2 == 'S') {
                if (j + 7 < dst_len) {
                    dst[j++]='['; dst[j++]='^'; dst[j++]=' '; dst[j++]='\t';
                    dst[j++]='\n'; dst[j++]='\r'; dst[j++]=']';
                }
            } else if (c2 == 'n') {
                dst[j++] = '\n';
            } else if (c2 == 't') {
                dst[j++] = '\t';
            } else if (c2 == 'r') {
                dst[j++] = '\r';
            } else {
                if (j + 1 < dst_len) dst[j++] = '\\';
                if (j + 1 < dst_len) dst[j++] = c2;
            }
            i += 2;
        } else {
            dst[j++] = src[i++];
        }
    }
    dst[j] = '\0';
}

int Regex_FindAt(char *pattern, char *str, int startPos) {
    char xlat[2048];
    regex_t re;
    int ret, nsub;
    if (!str || startPos < 0) return -1;
    translate_pattern(pattern, xlat, (int)sizeof(xlat));
    if (regcomp(&re, xlat, REG_EXTENDED) != 0) return -1;
    nsub = (int)re.re_nsub;
    strncpy(g_str, str, MAX_STR - 1);
    g_str[MAX_STR - 1] = '\0';
    g_start_off = startPos;
    memset(g_matches, 0xff, sizeof(g_matches));
    ret = regexec(&re, str + startPos, MAX_GROUPS, g_matches, 0);
    regfree(&re);
    if (ret != 0) { g_n_matches = 0; return -1; }
    g_n_matches = nsub + 1;
    return startPos + (int)g_matches[0].rm_so;
}

int Regex_MatchLen(void) {
    if (g_n_matches == 0 || g_matches[0].rm_so < 0) return 0;
    return (int)(g_matches[0].rm_eo - g_matches[0].rm_so);
}

int Regex_NumGroups(char *pattern) {
    char xlat[2048];
    regex_t re;
    int n = 0;
    translate_pattern(pattern, xlat, (int)sizeof(xlat));
    if (regcomp(&re, xlat, REG_EXTENDED) == 0) {
        n = (int)re.re_nsub;
        regfree(&re);
    }
    return n;
}

int Regex_GroupStart(int n) {
    if (n < 0 || n >= g_n_matches || g_matches[n].rm_so < 0) return -1;
    return g_start_off + (int)g_matches[n].rm_so;
}

int Regex_GroupLen(int n) {
    if (n < 0 || n >= g_n_matches || g_matches[n].rm_so < 0) return 0;
    return (int)(g_matches[n].rm_eo - g_matches[n].rm_so);
}

void Regex_GetGroup(int n, char *result) {
    int s, l;
    if (!result) return;
    if (n < 0 || n >= g_n_matches || g_matches[n].rm_so < 0) {
        result[0] = '\0';
        return;
    }
    s = g_start_off + (int)g_matches[n].rm_so;
    l = (int)(g_matches[n].rm_eo - g_matches[n].rm_so);
    if (l > 255) l = 255;
    strncpy(result, g_str + s, l);
    result[l] = '\0';
}

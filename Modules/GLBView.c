/* GLBView.c — GLB/glTF2 mesh viewer backend: parser + OpenGL 3.3 core renderer.
 *
 * Parses the first mesh primitive.  Handles EXT_meshopt_compression for all
 * bufferViews, KHR_mesh_quantization (INT16/INT8 normalized), and the
 * baseColorTexture (WebP image via libwebp).
 */

#ifdef __APPLE__
#  define GL_SILENCE_DEPRECATION
#  include <OpenGL/gl3.h>
#else
#  include <GL/gl.h>
#endif

#define SDL_MAIN_HANDLED
#include <SDL2/SDL.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <stdint.h>

#include "meshopt/meshoptimizer.h"
#include <webp/decode.h>

/* ── Error buffer ─────────────────────────────────────────────────────────── */

static char g_errbuf[512];

static void set_error(const char *msg) {
    strncpy(g_errbuf, msg, sizeof(g_errbuf) - 1);
    g_errbuf[sizeof(g_errbuf) - 1] = '\0';
}

/* ── Mesh state ───────────────────────────────────────────────────────────── */

static float        *g_pos     = NULL;   /* 3 floats per vertex */
static float        *g_norm    = NULL;   /* 3 floats per vertex */
static float        *g_uv      = NULL;   /* 2 floats per vertex */
static unsigned int *g_idx     = NULL;   /* triangle indices   */
static int           g_vtx_n   = 0;
static int           g_idx_n   = 0;
static int           g_tri_n   = 0;
static int           g_indexed = 0;

/* World-space centre and scale-to-unit-sphere factor */
static float g_cx = 0, g_cy = 0, g_cz = 0, g_scale = 1.0f;

/* ── GPU state ────────────────────────────────────────────────────────────── */

static GLuint g_vao      = 0;
static GLuint g_vbo_pos  = 0;
static GLuint g_vbo_norm = 0;
static GLuint g_vbo_uv   = 0;
static GLuint g_ebo      = 0;
static GLuint g_prog     = 0;
static GLuint g_tex      = 0;
static int    g_has_tex  = 0;

static GLint g_loc_mvp    = -1;
static GLint g_loc_norm   = -1;
static GLint g_loc_light  = -1;
static GLint g_loc_color  = -1;
static GLint g_loc_tex    = -1;
static GLint g_loc_hastex = -1;

/* ══════════════════════════════════════════════════════════════════════════
   Minimal JSON navigator
   ══════════════════════════════════════════════════════════════════════════ */

static const char *skip_ws(const char *p) {
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') p++;
    return p;
}

static const char *skip_str(const char *p) {
    while (*p) {
        if (*p == '\\') { if (p[1]) p += 2; else p++; continue; }
        if (*p == '"') return p + 1;
        p++;
    }
    return p;
}

static const char *skip_val(const char *p) {
    p = skip_ws(p);
    if (*p == '"') return skip_str(p + 1);
    if (*p == '{' || *p == '[') {
        char open = *p, close = (*p == '{') ? '}' : ']';
        p++; int depth = 1;
        while (*p && depth > 0) {
            if (*p == '"') { p = skip_str(p + 1); continue; }
            if (*p == open)  depth++;
            if (*p == close) depth--;
            p++;
        }
        return p;
    }
    while (*p && *p != ',' && *p != ']' && *p != '}') p++;
    return p;
}

static const char *obj_find(const char *p, const char *key) {
    if (!p || *p != '{') return NULL;
    size_t klen = strlen(key);
    p++;
    for (;;) {
        p = skip_ws(p);
        if (!*p || *p == '}') return NULL;
        if (*p == ',') { p++; continue; }
        if (*p != '"') return NULL;
        p++;
        const char *ks = p;
        p = skip_str(p);
        size_t kl = (size_t)(p - ks - 1);
        p = skip_ws(p);
        if (*p == ':') p++;
        p = skip_ws(p);
        if (kl == klen && memcmp(ks, key, klen) == 0) return p;
        p = skip_val(p);
    }
}

static const char *arr_get(const char *p, int n) {
    if (!p || *p != '[') return NULL;
    p++; int idx = 0;
    for (;;) {
        p = skip_ws(p);
        if (!*p || *p == ']') return NULL;
        if (*p == ',') { p++; continue; }
        if (idx == n) return p;
        p = skip_val(p);
        idx++;
    }
}

static int parse_int(const char *p, int *out) {
    if (!p) return 0;
    p = skip_ws(p);
    char *end;
    long v = strtol(p, &end, 10);
    if (end == p) return 0;
    *out = (int)v;
    return 1;
}

/* True if JSON value at p is the string literal str (e.g. "TRIANGLES"). */
static int json_str_eq(const char *p, const char *str) {
    if (!p) return 0;
    p = skip_ws(p);
    if (*p != '"') return 0;
    p++;
    size_t len = strlen(str);
    return memcmp(p, str, len) == 0 && p[len] == '"';
}

/* True if JSON value at p is the boolean true. */
static int json_bool_true(const char *p) {
    if (!p) return 0;
    p = skip_ws(p);
    return p[0]=='t' && p[1]=='r' && p[2]=='u' && p[3]=='e';
}

/* ══════════════════════════════════════════════════════════════════════════
   Matrix math (column-major, OpenGL convention)
   ══════════════════════════════════════════════════════════════════════════ */

static void mat4_identity(float *m) {
    memset(m, 0, 16 * sizeof(float));
    m[0] = m[5] = m[10] = m[15] = 1.0f;
}

static void mat4_mul(const float *a, const float *b, float *r) {
    float t[16] = {0};
    for (int col = 0; col < 4; col++)
        for (int row = 0; row < 4; row++)
            for (int k = 0; k < 4; k++)
                t[col*4+row] += a[k*4+row] * b[col*4+k];
    memcpy(r, t, 16 * sizeof(float));
}

static void mat4_rotX(float *m, float a) {
    float c = cosf(a), s = sinf(a);
    mat4_identity(m);
    m[5] = c; m[6] = s; m[9] = -s; m[10] = c;
}

static void mat4_rotY(float *m, float a) {
    float c = cosf(a), s = sinf(a);
    mat4_identity(m);
    m[0] = c; m[2] = -s; m[8] = s; m[10] = c;
}

static void mat4_perspective(float *m, float fovy, float aspect, float zn, float zf) {
    float f = 1.0f / tanf(fovy * 0.5f);
    memset(m, 0, 16 * sizeof(float));
    m[0]  = f / aspect;
    m[5]  = f;
    m[10] = (zf + zn) / (zn - zf);
    m[11] = -1.0f;
    m[14] = 2.0f * zf * zn / (zn - zf);
}

static void build_matrices(double rotX, double rotY, double zoom,
                            int winW, int winH,
                            float *mvp_out, float *norm3_out) {
    float trans[16], scl[16], rx[16], ry[16], view[16], proj[16];
    float t1[16], t2[16], model[16];

    mat4_identity(trans);
    trans[12] = -g_cx; trans[13] = -g_cy; trans[14] = -g_cz;

    mat4_identity(scl);
    scl[0] = scl[5] = scl[10] = g_scale;

    mat4_rotX(rx, (float)rotX);
    mat4_rotY(ry, (float)rotY);

    mat4_mul(scl, trans, t1);
    mat4_mul(rx, t1, t2);
    mat4_mul(ry, t2, model);

    float dist = 3.0f / (float)(zoom > 0.01 ? zoom : 0.01);
    mat4_identity(view);
    view[14] = -dist;

    float aspect = (winH > 0) ? (float)winW / (float)winH : 1.0f;
    mat4_perspective(proj, 0.7854f, aspect, 0.01f, 200.0f);

    mat4_mul(view, model, t1);
    mat4_mul(proj, t1, mvp_out);

    mat4_mul(ry, rx, t1);
    norm3_out[0]=t1[0]; norm3_out[1]=t1[1]; norm3_out[2]=t1[2];
    norm3_out[3]=t1[4]; norm3_out[4]=t1[5]; norm3_out[5]=t1[6];
    norm3_out[6]=t1[8]; norm3_out[7]=t1[9]; norm3_out[8]=t1[10];
}

/* ══════════════════════════════════════════════════════════════════════════
   Mesh helpers
   ══════════════════════════════════════════════════════════════════════════ */

static void compute_bounds(void) {
    float minx = g_pos[0], maxx = g_pos[0];
    float miny = g_pos[1], maxy = g_pos[1];
    float minz = g_pos[2], maxz = g_pos[2];
    for (int i = 1; i < g_vtx_n; i++) {
        float x=g_pos[i*3], y=g_pos[i*3+1], z=g_pos[i*3+2];
        if (x<minx)minx=x; if (x>maxx)maxx=x;
        if (y<miny)miny=y; if (y>maxy)maxy=y;
        if (z<minz)minz=z; if (z>maxz)maxz=z;
    }
    g_cx = (minx + maxx) * 0.5f;
    g_cy = (miny + maxy) * 0.5f;
    g_cz = (minz + maxz) * 0.5f;
    float span = maxx-minx;
    if (maxy-miny > span) span = maxy-miny;
    if (maxz-minz > span) span = maxz-minz;
    g_scale = (span > 1e-6f) ? 1.0f / span : 1.0f;
}

static float *gen_normals(void) {
    float *n = (float*)calloc(g_vtx_n * 3, sizeof(float));
    if (!n) return NULL;
    int ntri = g_indexed ? g_idx_n / 3 : g_vtx_n / 3;
    for (int t = 0; t < ntri; t++) {
        int i0, i1, i2;
        if (g_indexed) {
            i0=(int)g_idx[t*3]; i1=(int)g_idx[t*3+1]; i2=(int)g_idx[t*3+2];
        } else {
            i0=t*3; i1=t*3+1; i2=t*3+2;
        }
        float ax=g_pos[i1*3]-g_pos[i0*3], ay=g_pos[i1*3+1]-g_pos[i0*3+1], az=g_pos[i1*3+2]-g_pos[i0*3+2];
        float bx=g_pos[i2*3]-g_pos[i0*3], by=g_pos[i2*3+1]-g_pos[i0*3+1], bz=g_pos[i2*3+2]-g_pos[i0*3+2];
        float nx=ay*bz-az*by, ny=az*bx-ax*bz, nz=ax*by-ay*bx;
        n[i0*3]+=nx; n[i0*3+1]+=ny; n[i0*3+2]+=nz;
        n[i1*3]+=nx; n[i1*3+1]+=ny; n[i1*3+2]+=nz;
        n[i2*3]+=nx; n[i2*3+1]+=ny; n[i2*3+2]+=nz;
    }
    for (int i = 0; i < g_vtx_n; i++) {
        float len = sqrtf(n[i*3]*n[i*3]+n[i*3+1]*n[i*3+1]+n[i*3+2]*n[i*3+2]);
        if (len > 1e-6f) { n[i*3]/=len; n[i*3+1]/=len; n[i*3+2]/=len; }
    }
    return n;
}

static int gpu_upload(void) {
    glGenVertexArrays(1, &g_vao);
    glGenBuffers(1, &g_vbo_pos);
    glGenBuffers(1, &g_vbo_norm);
    if (g_uv)      glGenBuffers(1, &g_vbo_uv);
    if (g_indexed) glGenBuffers(1, &g_ebo);

    glBindVertexArray(g_vao);

    glBindBuffer(GL_ARRAY_BUFFER, g_vbo_pos);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(g_vtx_n*3*sizeof(float)), g_pos, GL_STATIC_DRAW);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, (void*)0);
    glEnableVertexAttribArray(0);

    if (g_norm) {
        glBindBuffer(GL_ARRAY_BUFFER, g_vbo_norm);
        glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(g_vtx_n*3*sizeof(float)), g_norm, GL_STATIC_DRAW);
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 0, (void*)0);
        glEnableVertexAttribArray(1);
    }

    if (g_uv) {
        glBindBuffer(GL_ARRAY_BUFFER, g_vbo_uv);
        glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(g_vtx_n*2*sizeof(float)), g_uv, GL_STATIC_DRAW);
        glVertexAttribPointer(2, 2, GL_FLOAT, GL_FALSE, 0, (void*)0);
        glEnableVertexAttribArray(2);
    }

    if (g_indexed) {
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, g_ebo);
        glBufferData(GL_ELEMENT_ARRAY_BUFFER, (GLsizeiptr)(g_idx_n*sizeof(unsigned int)), g_idx, GL_STATIC_DRAW);
    }

    glBindVertexArray(0);

    free(g_pos);  g_pos  = NULL;
    free(g_norm); g_norm = NULL;
    free(g_uv);   g_uv   = NULL;
    free(g_idx);  g_idx  = NULL;

    GLenum err = glGetError();
    if (err != GL_NO_ERROR) {
        set_error("OpenGL error during buffer upload");
        return 0;
    }
    return 1;
}

/* ══════════════════════════════════════════════════════════════════════════
   Shader source
   ══════════════════════════════════════════════════════════════════════════ */

static const char *VERT_SRC =
    "#version 330 core\n"
    "layout(location=0) in vec3 aPos;\n"
    "layout(location=1) in vec3 aNorm;\n"
    "layout(location=2) in vec2 aUV;\n"
    "uniform mat4 uMVP;\n"
    "uniform mat3 uNorm;\n"
    "out vec3 vN;\n"
    "out vec2 vUV;\n"
    "void main() {\n"
    "    vN  = normalize(uNorm * aNorm);\n"
    "    vUV = vec2(aUV.x, 1.0 - aUV.y);\n"   /* flip V: glTF top-left vs GL bottom-left */
    "    gl_Position = uMVP * vec4(aPos, 1.0);\n"
    "}\n";

static const char *FRAG_SRC =
    "#version 330 core\n"
    "in  vec3 vN;\n"
    "in  vec2 vUV;\n"
    "out vec4 fragColor;\n"
    "uniform vec3      uLight;\n"
    "uniform vec3      uColor;\n"
    "uniform sampler2D uTex;\n"
    "uniform int       uHasTex;\n"
    "void main() {\n"
    "    vec3 n  = normalize(vN);\n"
    "    float d = max(dot(n, uLight), 0.0);\n"
    "    float b = max(dot(-n, uLight), 0.0) * 0.25;\n"
    "    float l = 0.15 + 0.85 * d + b;\n"
    "    vec3 base = (uHasTex != 0) ? texture(uTex, vUV).rgb : uColor;\n"
    "    fragColor = vec4(base * l, 1.0);\n"
    "}\n";

static GLuint compile_shader(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[512]; glGetShaderInfoLog(s, sizeof(log), NULL, log);
        snprintf(g_errbuf, sizeof(g_errbuf), "Shader compile error: %s", log);
        glDeleteShader(s);
        return 0;
    }
    return s;
}

static GLuint link_program(GLuint vs, GLuint fs) {
    GLuint p = glCreateProgram();
    glAttachShader(p, vs); glAttachShader(p, fs);
    glLinkProgram(p);
    GLint ok; glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[512]; glGetProgramInfoLog(p, sizeof(log), NULL, log);
        snprintf(g_errbuf, sizeof(g_errbuf), "Shader link error: %s", log);
        glDeleteProgram(p);
        return 0;
    }
    return p;
}

/* ══════════════════════════════════════════════════════════════════════════
   Public API
   ══════════════════════════════════════════════════════════════════════════ */

void GLBView_SetAttribs(void) {
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MAJOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_MINOR_VERSION, 3);
    SDL_GL_SetAttribute(SDL_GL_CONTEXT_PROFILE_MASK, SDL_GL_CONTEXT_PROFILE_CORE);
    SDL_GL_SetAttribute(SDL_GL_DOUBLEBUFFER, 1);
    SDL_GL_SetAttribute(SDL_GL_DEPTH_SIZE, 24);
}

int GLBView_Init(void) {
    g_errbuf[0] = '\0';

    GLuint vs = compile_shader(GL_VERTEX_SHADER,   VERT_SRC); if (!vs) return 0;
    GLuint fs = compile_shader(GL_FRAGMENT_SHADER, FRAG_SRC);
    if (!fs) { glDeleteShader(vs); return 0; }

    g_prog = link_program(vs, fs);
    glDeleteShader(vs); glDeleteShader(fs);
    if (!g_prog) return 0;

    g_loc_mvp    = glGetUniformLocation(g_prog, "uMVP");
    g_loc_norm   = glGetUniformLocation(g_prog, "uNorm");
    g_loc_light  = glGetUniformLocation(g_prog, "uLight");
    g_loc_color  = glGetUniformLocation(g_prog, "uColor");
    g_loc_tex    = glGetUniformLocation(g_prog, "uTex");
    g_loc_hastex = glGetUniformLocation(g_prog, "uHasTex");

    glEnable(GL_DEPTH_TEST);
    glDisable(GL_CULL_FACE);

    return 1;
}

int GLBView_Load(char *path) {
    g_errbuf[0] = '\0';

    /* ── Read file ─────────────────────────────────────────────────────────── */
    FILE *f = fopen(path, "rb");
    if (!f) { snprintf(g_errbuf,sizeof(g_errbuf),"Cannot open: %s",path); return 0; }
    fseek(f, 0, SEEK_END); long fsize = ftell(f); rewind(f);
    unsigned char *data = (unsigned char*)malloc((size_t)fsize);
    if (!data) { fclose(f); set_error("Out of memory"); return 0; }
    fread(data, 1, (size_t)fsize, f); fclose(f);

    /* ── Validate GLB header ─────────────────────────────────────────────── */
    if (fsize < 12 || memcmp(data, "glTF", 4) != 0) {
        free(data); set_error("Not a GLB file"); return 0;
    }
    uint32_t ver; memcpy(&ver, data+4, 4);
    if (ver != 2) {
        free(data); snprintf(g_errbuf,sizeof(g_errbuf),"GLB version %u not supported",ver); return 0;
    }

    /* ── Locate JSON and BIN chunks ──────────────────────────────────────── */
    const char         *json_raw = NULL; int json_len = 0;
    const unsigned char *bin_raw = NULL; int bin_len  = 0;
    {
        int off = 12;
        while (off + 8 <= fsize) {
            uint32_t clen, ctype;
            memcpy(&clen,  data+off,   4);
            memcpy(&ctype, data+off+4, 4);
            off += 8;
            if (off + (int)clen > fsize) break;
            if (ctype == 0x4E4F534A && !json_raw) { json_raw=(const char*)(data+off); json_len=(int)clen; }
            if (ctype == 0x004E4942 && !bin_raw)  { bin_raw=data+off;                 bin_len =(int)clen; }
            off += (int)clen;
        }
    }
    if (!json_raw) { free(data); set_error("No JSON chunk in GLB"); return 0; }

    char *json = (char*)malloc((size_t)(json_len+1));
    if (!json) { free(data); set_error("Out of memory"); return 0; }
    memcpy(json, json_raw, (size_t)json_len);
    json[json_len] = '\0';

    /* ── Navigate JSON: meshes[0].primitives[0] ──────────────────────────── */
    const char *jmesh = arr_get(obj_find(json, "meshes"), 0);
    if (!jmesh) { free(json); free(data); set_error("No mesh in GLB"); return 0; }
    const char *jprim = arr_get(obj_find(jmesh, "primitives"), 0);
    if (!jprim) { free(json); free(data); set_error("No primitives in mesh"); return 0; }
    const char *jattr = obj_find(jprim, "attributes");
    if (!jattr) { free(json); free(data); set_error("No attributes"); return 0; }

    int pos_acc=-1, norm_acc=-1, uv_acc=-1, idx_acc=-1;
    if (!parse_int(obj_find(jattr, "POSITION"), &pos_acc) || pos_acc < 0) {
        free(json); free(data); set_error("No POSITION attribute"); return 0;
    }
    parse_int(obj_find(jattr, "NORMAL"),     &norm_acc);
    parse_int(obj_find(jattr, "TEXCOORD_0"), &uv_acc);
    parse_int(obj_find(jprim, "indices"),    &idx_acc);

    /* ── Locate accessors and bufferViews arrays ─────────────────────────── */
    const char *jaccs = obj_find(json, "accessors");
    const char *jbvs  = obj_find(json, "bufferViews");
    if (!jaccs || !jbvs) { free(json); free(data); set_error("Missing accessors/bufferViews"); return 0; }

    /* ── Count bufferViews ───────────────────────────────────────────────── */
    int n_bvs = 0;
    { const char *p = arr_get(jbvs, 0); while (p) { n_bvs++; p = arr_get(jbvs, n_bvs); } }

    /* ── Decompress any EXT_meshopt_compression bufferViews ──────────────── */
    unsigned char **decomp = (unsigned char**)calloc((size_t)n_bvs, sizeof(unsigned char*));
    if (!decomp) { free(json); free(data); set_error("Out of memory"); return 0; }

    for (int bvi = 0; bvi < n_bvs; bvi++) {
        const char *jbv   = arr_get(jbvs, bvi); if (!jbv) continue;
        const char *jext  = obj_find(jbv, "extensions"); if (!jext) continue;
        const char *jmopt = obj_find(jext, "EXT_meshopt_compression"); if (!jmopt) continue;

        int ext_off=0, ext_len_=0, count=0, stride=0;
        parse_int(obj_find(jmopt, "byteOffset"), &ext_off);
        parse_int(obj_find(jmopt, "byteLength"), &ext_len_);
        parse_int(obj_find(jmopt, "count"),      &count);
        parse_int(obj_find(jmopt, "byteStride"), &stride);

        const char *jmode   = obj_find(jmopt, "mode");
        const char *jfilter = obj_find(jmopt, "filter");

        if (count <= 0 || stride <= 0 || ext_len_ <= 0) continue;
        if (!bin_raw || ext_off + ext_len_ > bin_len) continue;

        size_t decomp_size = (size_t)count * (size_t)stride;
        decomp[bvi] = (unsigned char*)malloc(decomp_size);
        if (!decomp[bvi]) continue;

        const unsigned char *comp = bin_raw + ext_off;
        int rc;
        if (json_str_eq(jmode, "TRIANGLES") || json_str_eq(jmode, "INDICES")) {
            rc = meshopt_decodeIndexBuffer(decomp[bvi], (size_t)count, (size_t)stride,
                                           comp, (size_t)ext_len_);
        } else {
            rc = meshopt_decodeVertexBuffer(decomp[bvi], (size_t)count, (size_t)stride,
                                            comp, (size_t)ext_len_);
            if (rc == 0 && json_str_eq(jfilter, "OCTAHEDRAL")) {
                meshopt_decodeFilterOct(decomp[bvi], (size_t)count, (size_t)stride);
            }
        }
        if (rc != 0) { free(decomp[bvi]); decomp[bvi] = NULL; }
    }

    /* ── Build bv_data[]: base pointer for each bufferView's data ────────── */
    const unsigned char **bv_data = (const unsigned char**)calloc((size_t)n_bvs, sizeof(unsigned char*));
    int *bv_len = (int*)calloc((size_t)n_bvs, sizeof(int));
    if (!bv_data || !bv_len) {
        for (int i=0;i<n_bvs;i++) free(decomp[i]);
        free(decomp); free(bv_data); free(bv_len); free(json); free(data);
        set_error("Out of memory"); return 0;
    }
    for (int bvi = 0; bvi < n_bvs; bvi++) {
        const char *jbv = arr_get(jbvs, bvi);
        int bvo=0, bvl=0;
        parse_int(obj_find(jbv, "byteOffset"), &bvo);
        parse_int(obj_find(jbv, "byteLength"), &bvl);
        bv_len[bvi] = bvl;
        if (decomp[bvi]) {
            bv_data[bvi] = decomp[bvi];
        } else if (bin_raw) {
            bv_data[bvi] = bin_raw + bvo;
        }
    }

#define LOAD_FAIL(msg) do { \
    for (int _i=0;_i<n_bvs;_i++) free(decomp[_i]); \
    free(decomp); free((void*)bv_data); free(bv_len); free(json); free(data); \
    free(g_pos); g_pos=NULL; free(g_norm); g_norm=NULL; \
    free(g_uv);  g_uv=NULL;  free(g_idx);  g_idx=NULL; \
    set_error(msg); return 0; \
} while(0)

    /* ── Extract POSITION ────────────────────────────────────────────────── */
    {
        const char *ac = arr_get(jaccs, pos_acc);
        int bv=-1, ao=0, count=0, ctype=5126;
        parse_int(obj_find(ac, "bufferView"),    &bv);
        parse_int(obj_find(ac, "byteOffset"),    &ao);
        parse_int(obj_find(ac, "count"),         &count);
        parse_int(obj_find(ac, "componentType"), &ctype);
        int normalized = json_bool_true(obj_find(ac, "normalized"));

        if (bv < 0 || bv >= n_bvs || count <= 0 || !bv_data[bv])
            LOAD_FAIL("Invalid POSITION accessor");

        const char *jbv = arr_get(jbvs, bv);
        int st = 0;
        parse_int(obj_find(jbv, "byteStride"), &st);
        if (st == 0) st = (ctype == 5122 || ctype == 5123) ? 6 : 12;

        g_vtx_n = count;
        g_pos   = (float*)malloc((size_t)g_vtx_n * 3 * sizeof(float));
        if (!g_pos) LOAD_FAIL("Out of memory");

        const unsigned char *base = bv_data[bv] + ao;
        for (int i = 0; i < g_vtx_n; i++) {
            const unsigned char *v = base + i * st;
            if (ctype == 5122 && normalized) {
                int16_t x, y, z;
                memcpy(&x, v, 2); memcpy(&y, v+2, 2); memcpy(&z, v+4, 2);
                g_pos[i*3]   = x < 0 ? x/32768.0f : x/32767.0f;
                g_pos[i*3+1] = y < 0 ? y/32768.0f : y/32767.0f;
                g_pos[i*3+2] = z < 0 ? z/32768.0f : z/32767.0f;
            } else {
                memcpy(&g_pos[i*3], v, 12);
            }
        }
    }

    /* ── Extract NORMAL ──────────────────────────────────────────────────── */
    if (norm_acc >= 0) {
        const char *ac = arr_get(jaccs, norm_acc);
        int bv=-1, ao=0, count=0, ctype=5126;
        parse_int(obj_find(ac, "bufferView"),    &bv);
        parse_int(obj_find(ac, "byteOffset"),    &ao);
        parse_int(obj_find(ac, "count"),         &count);
        parse_int(obj_find(ac, "componentType"), &ctype);
        int normalized = json_bool_true(obj_find(ac, "normalized"));

        if (bv >= 0 && bv < n_bvs && count == g_vtx_n && bv_data[bv]) {
            const char *jbv = arr_get(jbvs, bv);
            int st = 0;
            parse_int(obj_find(jbv, "byteStride"), &st);
            if (st == 0) st = (ctype == 5120 || ctype == 5121) ? 3 : 12;

            g_norm = (float*)malloc((size_t)g_vtx_n * 3 * sizeof(float));
            if (g_norm) {
                const unsigned char *base = bv_data[bv] + ao;
                for (int i = 0; i < g_vtx_n; i++) {
                    const unsigned char *v = base + i * st;
                    if (ctype == 5120 && normalized) {
                        int8_t x, y, z;
                        memcpy(&x, v, 1); memcpy(&y, v+1, 1); memcpy(&z, v+2, 1);
                        g_norm[i*3]   = x < 0 ? x/128.0f : x/127.0f;
                        g_norm[i*3+1] = y < 0 ? y/128.0f : y/127.0f;
                        g_norm[i*3+2] = z < 0 ? z/128.0f : z/127.0f;
                    } else {
                        memcpy(&g_norm[i*3], v, 12);
                    }
                }
            }
        }
    }

    /* ── Extract TEXCOORD_0 (UV) ─────────────────────────────────────────── */
    if (uv_acc >= 0) {
        const char *ac = arr_get(jaccs, uv_acc);
        int bv=-1, ao=0, count=0, ctype=5126;
        parse_int(obj_find(ac, "bufferView"),    &bv);
        parse_int(obj_find(ac, "byteOffset"),    &ao);
        parse_int(obj_find(ac, "count"),         &count);
        parse_int(obj_find(ac, "componentType"), &ctype);
        int normalized = json_bool_true(obj_find(ac, "normalized"));

        if (bv >= 0 && bv < n_bvs && count == g_vtx_n && bv_data[bv]) {
            const char *jbv = arr_get(jbvs, bv);
            int st = 0;
            parse_int(obj_find(jbv, "byteStride"), &st);
            if (st == 0) st = (ctype == 5123) ? 4 : 8;  /* UINT16 vec2 = 4, FLOAT vec2 = 8 */

            g_uv = (float*)malloc((size_t)g_vtx_n * 2 * sizeof(float));
            if (g_uv) {
                const unsigned char *base = bv_data[bv] + ao;
                for (int i = 0; i < g_vtx_n; i++) {
                    const unsigned char *v = base + i * st;
                    if (ctype == 5123 && normalized) {
                        /* UINT16 normalized: divide by 65535 */
                        uint16_t u, w;
                        memcpy(&u, v, 2); memcpy(&w, v+2, 2);
                        g_uv[i*2]   = u / 65535.0f;
                        g_uv[i*2+1] = w / 65535.0f;
                    } else {
                        memcpy(&g_uv[i*2], v, 8);
                    }
                }
            }
        }
    }

    /* ── Extract INDICES ─────────────────────────────────────────────────── */
    if (idx_acc >= 0) {
        const char *ac = arr_get(jaccs, idx_acc);
        int bv=-1, ao=0, count=0, ctype=5123;
        parse_int(obj_find(ac, "bufferView"),    &bv);
        parse_int(obj_find(ac, "byteOffset"),    &ao);
        parse_int(obj_find(ac, "count"),         &count);
        parse_int(obj_find(ac, "componentType"), &ctype);

        if (bv >= 0 && bv < n_bvs && count > 0 && bv_data[bv]) {
            g_idx = (unsigned int*)malloc((size_t)count * sizeof(unsigned int));
            if (g_idx) {
                const unsigned char *src = bv_data[bv] + ao;
                for (int i = 0; i < count; i++) {
                    if      (ctype == 5125) { uint32_t w; memcpy(&w, src+i*4, 4); g_idx[i] = w; }
                    else if (ctype == 5123) { uint16_t w; memcpy(&w, src+i*2, 2); g_idx[i] = w; }
                    else                    { g_idx[i] = src[i]; }
                }
                g_idx_n   = count;
                g_tri_n   = count / 3;
                g_indexed = 1;
            }
        }
    }
    if (!g_indexed) g_tri_n = g_vtx_n / 3;

    /* ── Load base color texture (WebP) ──────────────────────────────────── */
    {
        int mat_idx = -1;
        parse_int(obj_find(jprim, "material"), &mat_idx);
        if (mat_idx >= 0) {
            const char *jmats = obj_find(json, "materials");
            const char *jmat  = arr_get(jmats, mat_idx);
            const char *jpbr  = obj_find(jmat, "pbrMetallicRoughness");
            const char *jbct  = obj_find(jpbr, "baseColorTexture");
            int tex_idx = -1;
            parse_int(obj_find(jbct, "index"), &tex_idx);
            if (tex_idx >= 0) {
                const char *jtex = arr_get(obj_find(json, "textures"), tex_idx);
                int img_idx = -1;
                parse_int(obj_find(jtex, "source"), &img_idx);
                if (img_idx >= 0) {
                    const char *jimg = arr_get(obj_find(json, "images"), img_idx);
                    int img_bv = -1;
                    parse_int(obj_find(jimg, "bufferView"), &img_bv);
                    if (img_bv >= 0 && img_bv < n_bvs && bv_data[img_bv] && bv_len[img_bv] > 0) {
                        int tw = 0, th = 0;
                        uint8_t *rgb = WebPDecodeRGB(bv_data[img_bv],
                                                     (size_t)bv_len[img_bv],
                                                     &tw, &th);
                        if (rgb && tw > 0 && th > 0) {
                            glGenTextures(1, &g_tex);
                            glBindTexture(GL_TEXTURE_2D, g_tex);
                            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
                            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
                            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
                            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_REPEAT);
                            glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, tw, th, 0,
                                         GL_RGB, GL_UNSIGNED_BYTE, rgb);
                            glGenerateMipmap(GL_TEXTURE_2D);
                            glBindTexture(GL_TEXTURE_2D, 0);
                            WebPFree(rgb);
                            g_has_tex = 1;
                        }
                    }
                }
            }
        }
    }

    /* ── Cleanup decompression buffers ───────────────────────────────────── */
    for (int i = 0; i < n_bvs; i++) free(decomp[i]);
    free(decomp); free((void*)bv_data); free(bv_len); free(json);

    /* ── Generate normals if absent ──────────────────────────────────────── */
    if (!g_norm) g_norm = gen_normals();

    /* ── Compute bounding box for auto-fit ───────────────────────────────── */
    compute_bounds();

    /* ── Upload to GPU ───────────────────────────────────────────────────── */
    if (!gpu_upload()) {
        free(data); return 0;
    }

    free(data);
    return 1;
}

void GLBView_Render(long winW, long winH, double rotX, double rotY, double zoom) {
    glViewport(0, 0, (GLsizei)winW, (GLsizei)winH);
    glClearColor(0.13f, 0.13f, 0.18f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);

    if (!g_prog || !g_vao) return;

    float mvp[16], norm3[9];
    build_matrices(rotX, rotY, zoom, (int)winW, (int)winH, mvp, norm3);

    glUseProgram(g_prog);
    glUniformMatrix4fv(g_loc_mvp,  1, GL_FALSE, mvp);
    glUniformMatrix3fv(g_loc_norm, 1, GL_FALSE, norm3);

    float lx=0.5f, ly=0.8f, lz=0.6f;
    float ll = sqrtf(lx*lx+ly*ly+lz*lz);
    glUniform3f(g_loc_light, lx/ll, ly/ll, lz/ll);
    glUniform3f(g_loc_color, 0.72f, 0.76f, 0.84f);

    glUniform1i(g_loc_hastex, g_has_tex);
    if (g_has_tex) {
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, g_tex);
        glUniform1i(g_loc_tex, 0);
    }

    glBindVertexArray(g_vao);
    if (g_indexed)
        glDrawElements(GL_TRIANGLES, g_idx_n, GL_UNSIGNED_INT, 0);
    else
        glDrawArrays(GL_TRIANGLES, 0, g_vtx_n);
    glBindVertexArray(0);
}

void GLBView_Done(void) {
    if (g_vao)      { glDeleteVertexArrays(1, &g_vao);  g_vao=0; }
    if (g_vbo_pos)  { glDeleteBuffers(1, &g_vbo_pos);   g_vbo_pos=0; }
    if (g_vbo_norm) { glDeleteBuffers(1, &g_vbo_norm);  g_vbo_norm=0; }
    if (g_vbo_uv)   { glDeleteBuffers(1, &g_vbo_uv);    g_vbo_uv=0; }
    if (g_ebo)      { glDeleteBuffers(1, &g_ebo);        g_ebo=0; }
    if (g_prog)     { glDeleteProgram(g_prog);           g_prog=0; }
    if (g_tex)      { glDeleteTextures(1, &g_tex);       g_tex=0; }
    free(g_pos);  g_pos  = NULL;
    free(g_norm); g_norm = NULL;
    free(g_uv);   g_uv   = NULL;
    free(g_idx);  g_idx  = NULL;
    g_vtx_n=0; g_idx_n=0; g_tri_n=0; g_indexed=0; g_has_tex=0;
}

void GLBView_GetLastError(char *buf) {
    strncpy(buf, g_errbuf, sizeof(g_errbuf) - 1);
    buf[sizeof(g_errbuf) - 1] = '\0';
}

long GLBView_VertexCount(void)   { return (long)g_vtx_n; }
long GLBView_TriangleCount(void) { return (long)g_tri_n; }

void GLBView_init(void) { }

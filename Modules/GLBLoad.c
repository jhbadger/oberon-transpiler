/* GLBLoad.c — GLB loader with KHR_mesh_quantization + EXT_meshopt_compression.
 *
 * Separated from Raylib.c so that the heavy dependencies (libwebp, meshopt)
 * are only pulled in by programs that actually load GLB files, not by every
 * program that uses Raylib for 2D graphics.
 */

#include "OBCGLBLoad.h"
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <webp/decode.h>

#ifdef __cplusplus
#include "meshopt/meshoptimizer.h"
#else
extern int meshopt_decodeIndexBuffer(void *destination, size_t index_count, size_t index_size,
                                     const unsigned char *buffer, size_t buffer_size);
extern int meshopt_decodeVertexBuffer(void *destination, size_t vertex_count, size_t vertex_size,
                                      const unsigned char *buffer, size_t buffer_size);
#endif

/* ── Minimal JSON helpers ────────────────────────────────────────────────── */

static const char *_gl_ws(const char *p) {
    while (*p==' '||*p=='\t'||*p=='\n'||*p=='\r') p++; return p;
}
static const char *_gl_skip_str(const char *p) {
    while (*p) {
        if (*p=='\\') { if(p[1]) p+=2; else p++; continue; }
        if (*p=='"') return p+1; p++;
    }
    return p;
}
static const char *_gl_skip_val(const char *p) {
    p = _gl_ws(p);
    if (*p=='"') return _gl_skip_str(p+1);
    if (*p=='{'||*p=='[') {
        char open=*p, close=(*p=='{')? '}':']'; p++; int d=1;
        while (*p&&d>0) {
            if (*p=='"'){p=_gl_skip_str(p+1);continue;}
            if(*p==open) d++; if(*p==close) d--; p++;
        }
        return p;
    }
    while(*p&&*p!=','&&*p!=']'&&*p!='}') p++;
    return p;
}
static const char *_gl_find(const char *p, const char *key) {
    if(!p||*p!='{') return NULL;
    size_t kl=strlen(key); p++;
    for(;;) {
        p=_gl_ws(p);
        if(!*p||*p=='}') return NULL;
        if(*p==','){p++;continue;}
        if(*p!='"') return NULL;
        p++;
        const char *ks=p; p=_gl_skip_str(p);
        size_t klen=(size_t)(p-ks-1);
        p=_gl_ws(p); if(*p==':') p++; p=_gl_ws(p);
        if(klen==kl&&memcmp(ks,key,kl)==0) return p;
        p=_gl_skip_val(p);
    }
}
static const char *_gl_arr(const char *p, int n) {
    if(!p||*p!='[') return NULL;
    p++; int idx=0;
    for(;;) {
        p=_gl_ws(p);
        if(!*p||*p==']') return NULL;
        if(*p==','){p++;continue;}
        if(idx==n) return p;
        p=_gl_skip_val(p); idx++;
    }
}
static int _gl_int(const char *p, int *out) {
    if(!p) return 0;
    p=_gl_ws(p); char *e; long v=strtol(p,&e,10);
    if(e==p) return 0; *out=(int)v; return 1;
}
static int _gl_true(const char *p) {
    if(!p) return 0; p=_gl_ws(p);
    return p[0]=='t'&&p[1]=='r'&&p[2]=='u'&&p[3]=='e';
}
static int _gl_str_eq(const char *p, const char *s) {
    if(!p) return 0; p=_gl_ws(p);
    if(*p!='"') return 0; p++;
    size_t n=strlen(s);
    return memcmp(p,s,n)==0 && p[n]=='"';
}

/* ── meshopt bufferView decompressor ─────────────────────────────────────── */

static unsigned char *_gl_meshopt_bv(const char *jbv,
                                      const unsigned char *bin, long bin_len,
                                      int *out_stride, int *out_count) {
    const char *jext=_gl_find(_gl_find(jbv,"extensions"),"EXT_meshopt_compression");
    if(!jext) return NULL;
    int mo_off=0,mo_len=0,mo_stride=0,mo_count=0;
    _gl_int(_gl_find(jext,"byteOffset"),&mo_off);
    _gl_int(_gl_find(jext,"byteLength"),&mo_len);
    _gl_int(_gl_find(jext,"byteStride"),&mo_stride);
    _gl_int(_gl_find(jext,"count"),     &mo_count);
    if(mo_stride<=0||mo_count<=0||mo_off+mo_len>(int)bin_len) return NULL;
    unsigned char *decoded=(unsigned char*)malloc((size_t)mo_count*(size_t)mo_stride);
    if(!decoded) return NULL;
    const char *mode_p=_gl_find(jext,"mode");
    int ret;
    if(_gl_str_eq(mode_p,"TRIANGLES"))
        ret=meshopt_decodeIndexBuffer(decoded,(size_t)mo_count,(size_t)mo_stride,
                                      bin+mo_off,(size_t)mo_len);
    else
        ret=meshopt_decodeVertexBuffer(decoded,(size_t)mo_count,(size_t)mo_stride,
                                       bin+mo_off,(size_t)mo_len);
    if(ret!=0){free(decoded);return NULL;}
    if(out_stride)*out_stride=mo_stride;
    if(out_count) *out_count =mo_count;
    return decoded;
}

/* ── Accessor decoders ───────────────────────────────────────────────────── */

static float *_gl_decode_vec3(const char *ac, const char *jbvs,
                               const unsigned char *bin, long bin_len,
                               int *count_out) {
    int bv=-1,ao=0,count=0,ctype=5126;
    _gl_int(_gl_find(ac,"bufferView"),&bv);
    _gl_int(_gl_find(ac,"byteOffset"),&ao);
    _gl_int(_gl_find(ac,"count"),     &count);
    _gl_int(_gl_find(ac,"componentType"),&ctype);
    int norm=_gl_true(_gl_find(ac,"normalized"));
    if(bv<0||count<=0||!bin) return NULL;

    const char *jbv=_gl_arr(jbvs,bv);
    int st=0;
    unsigned char *decoded=_gl_meshopt_bv(jbv,bin,bin_len,&st,NULL);
    const unsigned char *base;
    if(decoded) {
        base=decoded+ao;
    } else {
        int bvo=0;
        _gl_int(_gl_find(jbv,"byteOffset"),&bvo);
        _gl_int(_gl_find(jbv,"byteStride"),&st);
        if(st==0){
            if(ctype==5120||ctype==5121) st=3;
            else if(ctype==5122||ctype==5123) st=6;
            else st=12;
        }
        base=bin+bvo+ao;
    }
    float *out=(float*)malloc(count*3*sizeof(float));
    if(!out){free(decoded);return NULL;}
    for(int i=0;i<count;i++) {
        const unsigned char *v=base+i*st;
        if(ctype==5122&&norm) {
            int16_t x,y,z;
            memcpy(&x,v,2);memcpy(&y,v+2,2);memcpy(&z,v+4,2);
            out[i*3]  =x<0?x/32768.f:x/32767.f;
            out[i*3+1]=y<0?y/32768.f:y/32767.f;
            out[i*3+2]=z<0?z/32768.f:z/32767.f;
        } else if(ctype==5120&&norm) {
            int8_t x,y,z;
            memcpy(&x,v,1);memcpy(&y,v+1,1);memcpy(&z,v+2,1);
            out[i*3]  =x<0?x/128.f:x/127.f;
            out[i*3+1]=y<0?y/128.f:y/127.f;
            out[i*3+2]=z<0?z/128.f:z/127.f;
        } else {
            memcpy(&out[i*3],v,12);
        }
    }
    free(decoded);
    if(count_out)*count_out=count;
    return out;
}

static float *_gl_decode_vec2(const char *ac, const char *jbvs,
                               const unsigned char *bin, long bin_len) {
    int bv=-1,ao=0,count=0,ctype=5126;
    _gl_int(_gl_find(ac,"bufferView"),&bv);
    _gl_int(_gl_find(ac,"byteOffset"),&ao);
    _gl_int(_gl_find(ac,"count"),     &count);
    _gl_int(_gl_find(ac,"componentType"),&ctype);
    int norm=_gl_true(_gl_find(ac,"normalized"));
    if(bv<0||count<=0||!bin) return NULL;

    const char *jbv=_gl_arr(jbvs,bv);
    int st=0;
    unsigned char *decoded=_gl_meshopt_bv(jbv,bin,bin_len,&st,NULL);
    const unsigned char *base;
    if(decoded) {
        base=decoded+ao;
    } else {
        int bvo=0;
        _gl_int(_gl_find(jbv,"byteOffset"),&bvo);
        _gl_int(_gl_find(jbv,"byteStride"),&st);
        if(st==0) st=(ctype==5123)?4:8;
        base=bin+bvo+ao;
    }
    float *out=(float*)malloc(count*2*sizeof(float));
    if(!out){free(decoded);return NULL;}
    for(int i=0;i<count;i++) {
        const unsigned char *v=base+i*st;
        if(ctype==5123&&norm) {
            uint16_t u,w; memcpy(&u,v,2); memcpy(&w,v+2,2);
            out[i*2]=u/65535.f; out[i*2+1]=w/65535.f;
        } else {
            memcpy(&out[i*2],v,8);
        }
    }
    free(decoded);
    return out;
}

/* ── WebP image loader ───────────────────────────────────────────────────── */

static Image _gl_load_webp(const unsigned char *data, int len) {
    Image img={0};
    int w=0,h=0;
    uint8_t *rgba=WebPDecodeRGBA(data,(size_t)len,&w,&h);
    if(!rgba) return img;
    size_t sz=(size_t)w*(size_t)h*4;
    img.data=malloc(sz);
    if(img.data){
        memcpy(img.data,rgba,sz);
        img.width=w; img.height=h; img.mipmaps=1;
        img.format=PIXELFORMAT_UNCOMPRESSED_R8G8B8A8;
    }
    WebPFree(rgba);
    return img;
}

/* ── Public entry point ──────────────────────────────────────────────────── */

Raylib_Model GLBLoad_LoadModel(char *path) {
    Raylib_Model m=(Raylib_Model)calloc(1,sizeof(Raylib_ModelRec));
    if(!m) return NULL;
    m->_tag=_TAG_Raylib_ModelRec;

    FILE *f=fopen(path,"rb");
    if(!f){free(m);return NULL;}
    fseek(f,0,SEEK_END); long fsz=ftell(f); rewind(f);
    unsigned char *data=(unsigned char*)malloc((size_t)fsz);
    if(!data){fclose(f);free(m);return NULL;}
    fread(data,1,(size_t)fsz,f); fclose(f);

    if(fsz<12||memcmp(data,"glTF",4)!=0){free(data);free(m);return NULL;}
    uint32_t ver; memcpy(&ver,data+4,4);
    if(ver!=2){free(data);free(m);return NULL;}

    const char *json_raw=NULL; int json_len=0;
    const unsigned char *bin=NULL;
    int off=12;
    while(off+8<=(int)fsz) {
        uint32_t clen,ctype;
        memcpy(&clen,data+off,4); memcpy(&ctype,data+off+4,4); off+=8;
        if(off+(int)clen>(int)fsz) break;
        if(ctype==0x4E4F534A&&!json_raw){json_raw=(const char*)(data+off);json_len=(int)clen;}
        if(ctype==0x004E4942&&!bin)      bin=data+off;
        off+=(int)clen;
    }
    if(!json_raw){free(data);free(m);return NULL;}
    long bin_len=bin?(long)((data+fsz)-(unsigned char*)bin):0;

    char *json=(char*)malloc((size_t)(json_len+1));
    if(!json){free(data);free(m);return NULL;}
    memcpy(json,json_raw,(size_t)json_len); json[json_len]='\0';

    const char *jmesh=_gl_arr(_gl_find(json,"meshes"),0);
    if(!jmesh){free(json);free(data);free(m);return NULL;}
    const char *jprim=_gl_arr(_gl_find(jmesh,"primitives"),0);
    if(!jprim){free(json);free(data);free(m);return NULL;}
    const char *jattr=_gl_find(jprim,"attributes");
    if(!jattr){free(json);free(data);free(m);return NULL;}

    int pos_acc=-1,norm_acc=-1,uv_acc=-1,idx_acc=-1;
    _gl_int(_gl_find(jattr,"POSITION"),   &pos_acc);
    _gl_int(_gl_find(jattr,"NORMAL"),     &norm_acc);
    _gl_int(_gl_find(jattr,"TEXCOORD_0"), &uv_acc);
    _gl_int(_gl_find(jprim,"indices"),    &idx_acc);
    if(pos_acc<0){free(json);free(data);free(m);return NULL;}

    const char *jaccs=_gl_find(json,"accessors");
    const char *jbvs =_gl_find(json,"bufferViews");
    if(!jaccs||!jbvs){free(json);free(data);free(m);return NULL;}

    int vtx_n=0;
    float *positions=_gl_decode_vec3(_gl_arr(jaccs,pos_acc), jbvs,bin,bin_len,&vtx_n);
    float *normals  =(norm_acc>=0)?_gl_decode_vec3(_gl_arr(jaccs,norm_acc),jbvs,bin,bin_len,NULL):NULL;
    float *texcoords=(uv_acc>=0) ?_gl_decode_vec2(_gl_arr(jaccs,uv_acc),  jbvs,bin,bin_len)     :NULL;

    unsigned int *idx32=NULL;
    int idx_n=0;
    if(idx_acc>=0) {
        const char *ac=_gl_arr(jaccs,idx_acc);
        int bv=-1,ao=0,count=0,ctype=5123;
        _gl_int(_gl_find(ac,"bufferView"),&bv);
        _gl_int(_gl_find(ac,"byteOffset"),&ao);
        _gl_int(_gl_find(ac,"count"),&count);
        _gl_int(_gl_find(ac,"componentType"),&ctype);
        if(bv>=0&&count>0&&bin) {
            const char *jbv=_gl_arr(jbvs,bv);
            int mo_stride=0;
            unsigned char *decoded=_gl_meshopt_bv(jbv,bin,bin_len,&mo_stride,NULL);
            const unsigned char *src;
            if(decoded){
                src=decoded+ao;
                ctype=(mo_stride==4)?5125:(mo_stride==2)?5123:5121;
            } else {
                int bvo=0; _gl_int(_gl_find(jbv,"byteOffset"),&bvo);
                src=bin+bvo+ao;
            }
            idx32=(unsigned int*)malloc((size_t)count*sizeof(unsigned int));
            if(idx32){
                for(int i=0;i<count;i++){
                    if(ctype==5125){memcpy(&idx32[i],src+i*4,4);}
                    else if(ctype==5123){uint16_t w;memcpy(&w,src+i*2,2);idx32[i]=w;}
                    else{idx32[i]=src[i];}
                }
                idx_n=count;
            }
            free(decoded);
        }
    }

    if(!positions){free(normals);free(texcoords);free(idx32);free(json);free(data);free(m);return NULL;}

    Mesh mesh={0};
    if(vtx_n<=65535 && idx32 && idx_n>0) {
        mesh.vertexCount  = vtx_n;
        mesh.triangleCount= idx_n/3;
        mesh.vertices=positions; mesh.normals=normals; mesh.texcoords=texcoords;
        mesh.indices=(unsigned short*)malloc((size_t)idx_n*sizeof(unsigned short));
        if(mesh.indices) for(int i=0;i<idx_n;i++) mesh.indices[i]=(unsigned short)idx32[i];
        free(idx32);
    } else if(idx32 && idx_n>0) {
        float *ep=(float*)malloc((size_t)idx_n*3*sizeof(float));
        float *en=normals   ?(float*)malloc((size_t)idx_n*3*sizeof(float)):NULL;
        float *eu=texcoords ?(float*)malloc((size_t)idx_n*2*sizeof(float)):NULL;
        if(ep){
            for(int i=0;i<idx_n;i++){
                unsigned int vi=idx32[i];
                ep[i*3]=positions[vi*3]; ep[i*3+1]=positions[vi*3+1]; ep[i*3+2]=positions[vi*3+2];
                if(en){en[i*3]=normals[vi*3];en[i*3+1]=normals[vi*3+1];en[i*3+2]=normals[vi*3+2];}
                if(eu){eu[i*2]=texcoords[vi*2];eu[i*2+1]=texcoords[vi*2+1];}
            }
        }
        free(positions); free(normals); free(texcoords); free(idx32);
        positions=ep; normals=en; texcoords=eu; vtx_n=idx_n; idx_n=0;
        mesh.vertexCount=vtx_n; mesh.triangleCount=vtx_n/3;
        mesh.vertices=positions; mesh.normals=normals; mesh.texcoords=texcoords;
    } else {
        mesh.vertexCount=vtx_n; mesh.triangleCount=vtx_n/3;
        mesh.vertices=positions; mesh.normals=normals; mesh.texcoords=texcoords;
        free(idx32);
    }

    UploadMesh(&mesh,false);
    m->mdl=LoadModelFromMesh(mesh);

    /* ── Embedded textures (albedo + normal map) ─────────────────────────── */
    {
        const char *jmats=_gl_find(json,"materials");
        const char *jmat =_gl_arr(jmats,0);
        const char *jpbr =_gl_find(jmat,"pbrMetallicRoughness");

        #define _GL_LOAD_TEX(tex_idx_expr) do { \
            int _ti=-1; _gl_int((tex_idx_expr),&_ti); \
            if(_ti>=0) { \
                int _si=-1; \
                _gl_int(_gl_find(_gl_arr(_gl_find(json,"textures"),_ti),"source"),&_si); \
                if(_si>=0) { \
                    const char *_ji=_gl_arr(_gl_find(json,"images"),_si); \
                    int _bvi=-1; _gl_int(_gl_find(_ji,"bufferView"),&_bvi); \
                    if(_bvi>=0) { \
                        const char *_jbv=_gl_arr(jbvs,_bvi); \
                        int _bvo=0,_bvl=0; \
                        _gl_int(_gl_find(_jbv,"byteOffset"),&_bvo); \
                        _gl_int(_gl_find(_jbv,"byteLength"),&_bvl); \
                        const char *_mp=_gl_find(_ji,"mimeType"); \
                        if(_bvl>0 && _bvo+_bvl<=(int)bin_len) { \
                            if(_gl_str_eq(_mp,"image/webp")) \
                                _loaded_img=_gl_load_webp(bin+_bvo,_bvl); \
                            else { \
                                const char *_ext=_gl_str_eq(_mp,"image/jpeg")?".jpg":".png"; \
                                _loaded_img=LoadImageFromMemory(_ext,bin+_bvo,_bvl); \
                            } \
                        } \
                    } \
                } \
            } \
        } while(0)

        Image _loaded_img={0};

        _GL_LOAD_TEX(_gl_find(_gl_find(jpbr,"baseColorTexture"),"index"));
        if(_loaded_img.data){
            Texture2D _t=LoadTextureFromImage(_loaded_img);
            UnloadImage(_loaded_img); _loaded_img=(Image){0};
            if(_t.id>0) m->mdl.materials[0].maps[MATERIAL_MAP_ALBEDO].texture=_t;
        }

        _GL_LOAD_TEX(_gl_find(_gl_find(jmat,"normalTexture"),"index"));
        if(_loaded_img.data){
            Texture2D _t=LoadTextureFromImage(_loaded_img);
            UnloadImage(_loaded_img); _loaded_img=(Image){0};
            if(_t.id>0) m->mdl.materials[0].maps[MATERIAL_MAP_NORMAL].texture=_t;
        }

        #undef _GL_LOAD_TEX
    }

    free(json); free(data);
    return m;
}

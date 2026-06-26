#pragma once
#include "OBCRaylib.h"

/* Load a GLB file with full support for:
 *   KHR_mesh_quantization  (INT16/INT8 normalized vertex data)
 *   EXT_meshopt_compression (meshopt-compressed bufferViews)
 *   WebP embedded textures (base color + normal map)
 *
 * Requires libwebp and the pre-built meshopt static library.
 * To rebuild meshopt:
 *   cd Modules/meshopt && g++ -std=c++14 -O2 -c meshopt_all.cpp -o meshopt_decode.o \
 *       && ar rcs meshopt_decode.a meshopt_decode.o
 */
Raylib_Model GLBLoad_LoadModel(char *path);

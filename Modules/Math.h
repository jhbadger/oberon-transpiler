#ifndef OBC_MATH_H_
#define OBC_MATH_H_

/* Pull in the real system <math.h>.  We use #include_next so that on
 * case-insensitive filesystems (macOS) this file can safely shadow <math.h>
 * without causing infinite recursion: #include_next continues the header
 * search from the directory *after* the one that supplied this file. */
#include_next <math.h>

/* Constants */
#define Math_pi  M_PI
#define Math_e   M_E

/* One-argument functions */
#define Math_sqrt(x)    sqrt(x)
#define Math_exp(x)     exp(x)
#define Math_ln(x)      log(x)
#define Math_log(x)     log10(x)
#define Math_sin(x)     sin(x)
#define Math_cos(x)     cos(x)
#define Math_tan(x)     tan(x)
#define Math_arcsin(x)  asin(x)
#define Math_arccos(x)  acos(x)
#define Math_arctan(x)  atan(x)
#define Math_floor(x)   floor(x)
#define Math_ceil(x)    ceil(x)
#define Math_round(x)   round(x)
#define Math_entier(x)  ((int)floor(x))
#define Math_abs(x)     fabs(x)

/* Two-argument functions */
#define Math_arctan2(y,x)   atan2(y,x)
#define Math_power(x,y)     pow(x,y)
#define Math_min(x,y)       fmin(x,y)
#define Math_max(x,y)       fmax(x,y)
#define Math_clamp(x,lo,hi) fmin(fmax(x,lo),hi)

#endif /* OBC_MATH_H_ */

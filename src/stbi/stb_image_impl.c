// stb_image compiled as its own optimized C library (see build.zig). A Zig
// module dependency would be compiled at the root artifact's optimize level,
// which makes image decoding ~10x slower in a Debug build; a C artifact keeps
// its own ReleaseFast.
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

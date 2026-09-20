#ifndef SEGGS_YOGA_H
#define SEGGS_YOGA_H

// Flexbox layout boundary. Yoga's public API is C, so it crosses directly and
// the C++ it is implemented in stays behind this header: only this file names
// a Yoga path, and Zig sees the result through translate-c as the `yoga`
// module, the same way SDL is kept behind `native`.
#include <yoga/Yoga.h>

#endif

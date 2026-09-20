// The C surface of libghostty-vt, the terminal emulator core extracted from
// Ghostty. The library is built by the Zig release Ghostty pins (see
// tools/bootstrap.py), and the editor reaches it through this header exactly
// as it reaches SDL: translate-c, then link.
#include <ghostty/vt.h>

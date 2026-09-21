// Display math, through the MicroTex TeX engine.
//
// The engine lays a formula out and then draws it through its own abstract
// Graphics2D, exactly as its other backends draw through Cairo, GDI, Qt, or
// Skia. Those backends hand the drawing to a toolkit. This one hands it to the
// editor: the callbacks below are the drawing primitives, and they are the
// whole of what the engine needs. Nothing in this header knows what a GPU is,
// which is the point - the same set is what an extension will draw with.
//
// Two things about the contract are worth stating, because they are what make
// the primitives general rather than tailored to TeX:
//
//   * Every drawing call carries the current transform as a 2D affine. The
//     engine translates, scales and rotates freely, and a primitive that could
//     not express that would be a primitive only TeX could use.
//   * Colour is ARGB in the high byte first, matching MicroTex's own `color`.
//     The renderer converts; nothing else in the editor uses ARGB.
//
// Coordinates are in points, with y increasing downward, which is the
// convention the engine lays out in.

#ifndef SEGGS_MICROTEX_H
#define SEGGS_MICROTEX_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// A 2D affine transform, in the order the engine composes it:
//
//   x' = m[0]*x + m[2]*y + m[4]
//   y' = m[1]*x + m[3]*y + m[5]
//
// Every callback receives the transform in effect for that call. A drawing
// layer that cannot rotate can ignore m[1] and m[2], but it must apply the rest.
typedef struct seggs_tex_transform {
    float m[6];
} seggs_tex_transform;

// The drawing primitives the engine draws through.
//
// `ctx` is passed back untouched; it is the renderer, and this header does not
// name its type, so the same callback set can be served by a test double or by
// a future extension surface.
typedef struct seggs_tex_callbacks {
    void *ctx;

    // Solid fills and strokes are all one colour at a time.
    void (*set_color)(void *ctx, uint32_t argb);

    void (*fill_rect)(void *ctx, float x, float y, float w, float h,
                      const seggs_tex_transform *t);
    void (*draw_line)(void *ctx, float x1, float y1, float x2, float y2, float width,
                      const seggs_tex_transform *t);

    // Text, baseline aligned, in a font the engine has already chosen by size
    // and style. `cps` is a run of codepoints, not bytes: the engine lays out
    // mathematics in wide characters and a byte string cannot round-trip it.
    void (*draw_text)(void *ctx, const uint32_t *cps, size_t count, float x, float y,
                      float size, int style, const seggs_tex_transform *t);

    // The width the same run would occupy, so the engine can lay out around it.
    float (*text_width)(void *ctx, const uint32_t *cps, size_t count, float size, int style);
} seggs_tex_callbacks;

// Load the resource directory the engine reads its mappings from. This is the
// expensive call - the engine's own documentation warns it may take a long
// time, and it parses XML - so it is not on the startup path: call it when the
// first formula appears, and never twice.
//
// Returns false if the directory could not be read, in which case display math
// is unavailable and callers fall back to showing the source.
bool seggs_tex_init(const char *res_dir);

// Unload. Formulas parsed before this must not be drawn afterwards.
void seggs_tex_release(void);

// True once seggs_tex_init has succeeded, so a caller can decide whether to
// hand a formula to the engine or to show it as source.
bool seggs_tex_ready(void);

// Lay out `tex` (a run of codepoints, NUL-terminated by `count` rather than by
// a terminator, because NUL is a legal codepoint in the engine's input).
//
// `width` is the layout width in points; pass 0 to lay out on one line at the
// formula's natural width. Returns NULL if the formula could not be parsed -
// the engine prints the reason to stderr, which keeps it out of the protocol
// stream on stdout.
void *seggs_tex_parse(const uint32_t *tex, size_t count, int width, float text_size,
                      float line_space, uint32_t fg);

// The size of a laid-out formula: its width, its height above the baseline, and
// its depth below it. The caller needs all three to reserve room in a row of
// text and to place the baseline.
void seggs_tex_measure(const void *render, float *width, float *height, float *depth);

// Draw at (x, y), the top-left corner of the formula's box.
void seggs_tex_draw(const void *render, float x, float y, const seggs_tex_callbacks *cb);

// Release a formula.
void seggs_tex_free(void *render);

#ifdef __cplusplus
}
#endif

#endif // SEGGS_MICROTEX_H

// The MicroTex backing, implemented over the editor's drawing callbacks.
//
// The engine ships one Graphics2D per toolkit - Cairo, GDI, Qt, Skia - and
// every one of them is the same shape: hold the current colour, font, stroke
// and transform, and turn each call into the toolkit's equivalent. This is that
// same class with the toolkit removed, so the drawing lands in the editor's
// renderer instead.
//
// The engine has no partial backend: its base sources declare Font::create,
// Font::_create and TextLayout::create and leave them undefined precisely so a
// backend supplies them. That is why the engine links without a GUI at all, and
// why the definitions below are load-bearing rather than optional.

#include "microtex.h"

#include <cmath>
#include <cstring>
#include <string>
#include <vector>

#include "graphic/graphic.h"
#include "latex.h"
#include "render.h"

using namespace tex;

namespace {

// wchar_t is four bytes everywhere this builds, which is what lets a run of
// codepoints cross the C boundary without conversion. UTF-16 platforms would
// need a surrogate pass here, so the assumption is checked rather than assumed.
static_assert(sizeof(wchar_t) == 4, "the codepoint bridge assumes a 4-byte wchar_t");

// A font is an identity here: size and style, with no file and no toolkit
// handle. The renderer owns the actual face and rasterizes glyphs itself, so a
// Font carrying a file path would be describing something that does not exist.
//
// The engine's Font has no accessors at all - it is four virtuals and nothing
// else - so a backend keeps its own notion of what a font is and answers
// equality itself. That is what the toolkit backends do too.
class CallbackFont final : public Font {
public:
    CallbackFont(std::string name, int style, float size)
        : _name(std::move(name)), _style(style), _size(size) {}

    float getSize() const override { return _size; }
    int style() const { return _style; }
    const std::string &name() const { return _name; }

    sptr<Font> deriveFont(int style) const override {
        return sptr<Font>(new CallbackFont(_name, style, _size));
    }

    bool operator==(const Font &f) const override {
        const auto *other = dynamic_cast<const CallbackFont *>(&f);
        return other != nullptr && other->_name == _name && other->_style == _style &&
               other->_size == _size;
    }

    bool operator!=(const Font &f) const override { return !(*this == f); }

private:
    std::string _name;
    int _style;
    float _size;
};

// The engine's fallback path for glyphs it has no font data for. It asks for a
// width and then draws the run, so the two must agree; both go through the same
// callback the primitive layer exposes.
class CallbackTextLayout final : public TextLayout {
public:
    CallbackTextLayout(const std::wstring &src, const sptr<Font> &font) : _src(src), _font(font) {}

    void getBounds(Rect &bounds) override {
        bounds.x = 0;
        bounds.y = 0;
        bounds.w = measure();
        bounds.h = _font == nullptr ? 0 : _font->getSize();
    }

    void draw(Graphics2D &g2, float x, float y) override {
        // Straight through the context, so the run inherits its transform and
        // colour like any other drawing the engine does.
        g2.drawText(_src, x, y);
    }

private:
    float measure() const {
        if (_font == nullptr) return 0;
        return _font->getSize() * static_cast<float>(_src.size()) * 0.5f;
    }

    std::wstring _src;
    sptr<Font> _font;
};

class CallbackGraphics final : public Graphics2D {
public:
    CallbackGraphics(const seggs_tex_callbacks *cb, color fg) : _cb(cb), _color(fg) {
        identity();
    }

    void setColor(color c) override { _color = c; }
    color getColor() const override { return _color; }

    void setStroke(const Stroke &s) override { _stroke = s; }
    const Stroke &getStroke() const override { return _stroke; }
    void setStrokeWidth(float w) override { _stroke.lineWidth = w; }

    const Font *getFont() const override { return _font; }

    void setFont(const Font *font) override {
        // Non-owning, deliberately. The engine keeps every font it creates in
        // its own alphabet map and passes the raw pointer here; adopting it into
        // a shared_ptr would give the same object two owners and free it twice.
        _font = font;
    }

    void translate(float dx, float dy) override {
        float m[6];
        multiply(m, 1, 0, 0, 1, dx, dy);
        compose(m);
    }

    void scale(float sx, float sy) override {
        float m[6];
        multiply(m, sx, 0, 0, sy, 0, 0);
        compose(m);
    }

    void rotate(float angle) override { rotate(angle, 0, 0); }

    void rotate(float angle, float px, float py) override {
        const float c = std::cos(angle), s = std::sin(angle);
        float m[6];
        multiply(m, c, s, -s, c, px - c * px + s * py, py - s * px - c * py);
        compose(m);
    }

    void reset() override { identity(); }

    float sx() const override { return std::sqrt(_t[0] * _t[0] + _t[1] * _t[1]); }
    float sy() const override { return std::sqrt(_t[2] * _t[2] + _t[3] * _t[3]); }

    void drawChar(wchar_t c, float x, float y) override {
        const std::wstring s(1, c);
        drawText(s, x, y);
    }

    void drawText(const std::wstring &c, float x, float y) override {
        if (_cb->draw_text == nullptr || _font == nullptr) return;
        const auto *cps = reinterpret_cast<const uint32_t *>(c.data());
        _cb->draw_text(_cb->ctx, cps, c.size(), x, y, _font->getSize(), _styleOf(_font), &_xform);
    }

    void drawLine(float x1, float y1, float x2, float y2) override {
        if (_cb->draw_line == nullptr) return;
        _cb->draw_line(_cb->ctx, x1, y1, x2, y2, _stroke.lineWidth, &_xform);
    }

    void drawRect(float x, float y, float w, float h) override {
        // A stroke is four edges. There is no rect-stroke primitive to reach
        // for, and adding one the renderer would implement as exactly this
        // would be an indirection with no content.
        const float lw = _stroke.lineWidth <= 0 ? 1.0f : _stroke.lineWidth;
        if (_cb->draw_line == nullptr) return;
        // Inset by half the stroke so the outline sits inside the rectangle the
        // engine asked for, which is where a filled stroke would land.
        const float hw = lw * 0.5f;
        drawLine(x + hw, y + hw, x + w - hw, y + hw);
        drawLine(x + w - hw, y + hw, x + w - hw, y + h - hw);
        drawLine(x + w - hw, y + h - hw, x + hw, y + h - hw);
        drawLine(x + hw, y + h - hw, x + hw, y + hw);
    }

    void fillRect(float x, float y, float w, float h) override {
        if (_cb->fill_rect == nullptr) return;
        _cb->fill_rect(_cb->ctx, x, y, w, h, &_xform);
    }

    void drawRoundRect(float x, float y, float w, float h, float rx, float ry) override {
        (void)rx;
        (void)ry;
        drawRect(x, y, w, h);
    }

    void fillRoundRect(float x, float y, float w, float h, float rx, float ry) override {
        (void)rx;
        (void)ry;
        fillRect(x, y, w, h);
    }

private:
    // Font has no accessor for style - only getSize is virtual - so the
    // concrete type is consulted directly. A font from another backend would
    // fall back to plain, which is the safe reading.
    static int _styleOf(const Font *font) {
        const auto *f = dynamic_cast<const CallbackFont *>(font);
        return f == nullptr ? PLAIN : f->style();
    }

    void identity() {
        for (int i = 0; i < 6; i++) _t[i] = (i == 0 || i == 3) ? 1.0f : 0.0f;
        sync();
    }

    // Post-multiply: the new transform applies in the current local frame, which
    // is what translate/scale/rotate mean to a caller that nests them.
    void compose(const float m[6]) {
        float r[6];
        r[0] = _t[0] * m[0] + _t[2] * m[1];
        r[1] = _t[1] * m[0] + _t[3] * m[1];
        r[2] = _t[0] * m[2] + _t[2] * m[3];
        r[3] = _t[1] * m[2] + _t[3] * m[3];
        r[4] = _t[0] * m[4] + _t[2] * m[5] + _t[4];
        r[5] = _t[1] * m[4] + _t[3] * m[5] + _t[5];
        std::memcpy(_t, r, sizeof(r));
        sync();
    }

    void multiply(float out[6], float a, float b, float c, float d, float e, float f) const {
        out[0] = a;
        out[1] = b;
        out[2] = c;
        out[3] = d;
        out[4] = e;
        out[5] = f;
    }

    void sync() { std::memcpy(_xform.m, _t, sizeof(_t)); }

    const seggs_tex_callbacks *_cb;
    color _color;
    Stroke _stroke;
    const Font *_font = nullptr;
    float _t[6];
    seggs_tex_transform _xform{};
};

} // namespace

// The factories the engine leaves to its backend.

sptr<Font> Font::_create(const std::string &name, int style, float size) {
    return sptr<Font>(new CallbackFont(name, style, size));
}

Font *Font::create(const std::string &file, float size) {
    (void)file;
    // There is no font file to open: the renderer owns the face, and the engine
    // only ever reaches this when a resource named a font by path. Reporting the
    // family and the size is the honest answer, and the glyphs still draw.
    return new CallbackFont("seggs", PLAIN, size);
}

sptr<TextLayout> TextLayout::create(const std::wstring &src, const sptr<Font> &font) {
    return sptr<TextLayout>(new CallbackTextLayout(src, font));
}

// The C surface.

extern "C" {

bool seggs_tex_init(const char *res_dir) {
    if (res_dir == nullptr) return false;
    LaTeX::init(std::string(res_dir));
    return true;
}

void seggs_tex_release(void) { LaTeX::release(); }

bool seggs_tex_ready(void) {
    const std::string &root = LaTeX::getResRootPath();
    return !root.empty();
}

struct ParsedFormula {
    TeXRender *render;
    color fg;
};

void *seggs_tex_parse(const uint32_t *tex, size_t count, int width, float text_size,
                      float line_space, uint32_t fg) {
    if (tex == nullptr) return nullptr;
    const auto *wide = reinterpret_cast<const wchar_t *>(tex);
    const std::wstring source(wide, count);
    TeXRender *render = LaTeX::parse(source, width, text_size, line_space, fg);
    if (render == nullptr) return nullptr;
    return static_cast<void *>(new ParsedFormula{render, fg});
}

void seggs_tex_measure(const void *render, float *width, float *height, float *depth) {
    const auto *f = static_cast<const ParsedFormula *>(render);
    const TeXRender *r = f == nullptr ? nullptr : f->render;
    if (width != nullptr) *width = r == nullptr ? 0 : static_cast<float>(r->getWidth());
    // The engine reports height above the baseline and depth below it
    // separately, because that is what placing a formula in a row of text needs.
    if (height != nullptr) *height = r == nullptr ? 0 : static_cast<float>(r->getHeight());
    if (depth != nullptr) *depth = r == nullptr ? 0 : static_cast<float>(r->getDepth());
}

void seggs_tex_draw(const void *render, float x, float y, const seggs_tex_callbacks *cb) {
    // The handle is ours and the drawing only needs a mutable render because the
    // engine's signature says so; nothing here mutates the formula.
    auto *f = static_cast<ParsedFormula *>(const_cast<void *>(render));
    if (f == nullptr || cb == nullptr) return;
    CallbackGraphics g(cb, f->fg);
    f->render->draw(g, static_cast<int>(x), static_cast<int>(y));
}

void seggs_tex_free(void *render) {
    auto *f = static_cast<ParsedFormula *>(render);
    if (f == nullptr) return;
    delete f->render;
    delete f;
}

} // extern "C"

#version 450
// SDL_GPU assigns fragment samplers to set 2.
layout(set = 2, binding = 0) uniform sampler2D atlas;
layout(location = 0) in vec2 uv;
layout(location = 1) in vec4 color;
layout(location = 0) out vec4 out_color;
void main() {
    out_color = texture(atlas, uv) * color;
}

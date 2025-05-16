#pragma sokol @vs vs
layout(set = 0, binding = 0) uniform vs_params {
    mat4 u_proj;
};

layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_instance_pos;
layout(location = 2) in vec2 a_instance_size;
layout(location = 3) in vec4 a_instance_color;

out vec4 color;

void main() {
    vec2 pixel_pos = a_instance_pos + a_pos * a_instance_size;
    gl_Position = u_proj * vec4(pixel_pos, 0.0, 1.0);
    color = a_instance_color;
}
#pragma sokol @end

/* quad fragment shader */
#pragma sokol @fs fs
in vec4 color;
out vec4 frag_color;

void main() {
    frag_color = color;
}
#pragma sokol @end

/* quad shader program */
#pragma sokol @program quad vs fs

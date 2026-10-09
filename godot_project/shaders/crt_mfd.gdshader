shader_type spatial;
render_mode unshaded, fog_disabled, shadows_disabled;

uniform sampler2D screen_texture : source_color, filter_linear;
uniform float scanline_count = 120.0;
uniform float scanline_intensity = 0.25;
uniform float bloom_intensity = 0.4;
uniform float vignette_intensity = 0.2;
uniform float curvature = 1.0;

void fragment() {
    vec2 uv = UV;
    vec2 offset = uv - 0.5;
    float r = dot(offset, offset);
    uv = uv + offset * r * curvature * 0.05;

    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        ALBEDO = vec3(0.0);
        ALPHA = 1.0;
    } else {
        vec4 base_color = texture(screen_texture, uv);

        // Phosphor bleed
        vec2 texel = 1.0 / vec2(textureSize(screen_texture, 0));
        vec3 bloom = texture(screen_texture, uv + vec2(-texel.x, 0.0)).rgb
                   + texture(screen_texture, uv + vec2(texel.x, 0.0)).rgb
                   + texture(screen_texture, uv + vec2(0.0, -texel.y)).rgb
                   + texture(screen_texture, uv + vec2(0.0, texel.y)).rgb;
        bloom *= 0.25;

        vec3 color = base_color.rgb + bloom * bloom_intensity;

        // Scanlines
        float scanline = sin(uv.y * scanline_count * 3.14159) * 0.5 + 0.5;
        color *= mix(1.0, scanline, scanline_intensity);

        // Vignette
        float dist = distance(UV, vec2(0.5));
        float vignette = clamp(1.0 - dist * vignette_intensity, 0.0, 1.0);
        color *= vignette;

        ALBEDO = max(vec3(0.0), color);
        ALPHA = 1.0;
    }
}

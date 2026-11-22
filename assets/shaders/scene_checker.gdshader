shader_type canvas_item;
render_mode unshaded;

uniform vec4 checker_dark : source_color;
uniform vec4 checker_light : source_color;
uniform float cell_size = 20.0;

void fragment() {
	vec2 cell = floor(FRAGCOORD.xy / cell_size);
	COLOR = mix(checker_dark, checker_light, mod(cell.x + cell.y, 2.0));
}

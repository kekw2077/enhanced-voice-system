#version 460 core
#include <flutter/runtime_effect.glsl>

// Фон-аврора EVS. Порт WebGL-шейдера из прототипа один-в-один.
// Регистрация: pubspec.yaml → flutter: shaders: - shaders/aurora.frag
// Порядок uniform-ов важен: setFloat(0..12) идёт ровно в этом порядке.

precision highp float;

uniform vec2 uSize;   // 0,1  — размер холста в пикселях
uniform float uTime;  // 2    — время в секундах
uniform vec3 c1;      // 3,4,5
uniform vec3 c2;      // 6,7,8
uniform vec3 c3;      // 9,10,11

out vec4 fragColor;

float h(vec2 p){ return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }

float n(vec2 p){
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(h(i), h(i + vec2(1, 0)), f.x),
             mix(h(i + vec2(0, 1)), h(i + vec2(1, 1)), f.x), f.y);
}

float fbm(vec2 p){
  float s = 0.0, a = 0.5;
  for (int i = 0; i < 5; i++){ s += a * n(p); p *= 2.03; a *= 0.5; }
  return s;
}

void main(){
  float T = uTime * 1.05;
  vec2 frag = FlutterFragCoord().xy;
  vec2 uv = vec2(frag.x / uSize.x, 1.0 - frag.y / uSize.y);
  vec2 p = vec2(uv.x * uSize.x / uSize.y, uv.y);
  vec2 sp = p * vec2(0.85, 1.9);

  float f1 = fbm(sp + vec2(T * 0.34, -T * 0.12));
  float f2 = fbm(sp * 1.3 + vec2(4.7, 2.1) - vec2(T * 0.27, T * 0.09));
  vec2 wp = sp + vec2(f1, f2) * 2.4;

  float v  = fbm(wp * 0.72 + vec2(-T * 0.22, T * 0.07));
  float v2 = fbm(wp * 1.15 + vec2(T * 0.18, -T * 0.06));
  float lift = 0.38 + 0.34 * fbm(p * 1.4 + vec2(T * 0.18, 0.0));
  float mask = smoothstep(lift + 0.06, lift - 0.30, uv.y);
  float g = fbm(wp * 0.42 + vec2(T * 0.10, -T * 0.04) + f1 * 0.4);

  float m1 = smoothstep(0.38, 0.59, v);
  float m2 = smoothstep(0.46, 0.67, v2);
  float lum = max(max(m1, m2 * 0.85), smoothstep(0.34, 0.02, uv.y) * 0.62) * mask;

  vec3 col = mix(c1, c2, smoothstep(0.40, 0.74, g));
  float cy = smoothstep(0.50, 0.66, fbm(wp * 1.55 + vec2(-T * 0.17, T * 0.09)));
  col = mix(col, c3, cy * 0.80);

  float rim = m1 * (1.0 - m1) * 4.0;
  col = col * lum * 1.05 + mix(c2, c3, 0.5) * rim * mask * 0.40;
  col += (h(frag) - 0.5) * 0.006;

  fragColor = vec4(clamp(col, 0.0, 0.95), 1.0);
}

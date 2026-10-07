#include <metal_stdlib>
using namespace metal;

// Independently implemented small 2D flow. No upstream shaders are vendored.
struct FlowUniforms { float4 motion; float4 detail; float4 character; float4 paletteA; float4 paletteB; float4 surface; };
constant sampler smoothSampler(coord::normalized, address::clamp_to_edge, filter::linear);

float4 cell(texture2d<float, access::read> t, int2 p) {
    return t.read(uint2(clamp(p, int2(0), int2(t.get_width()-1, t.get_height()-1))));
}

kernel void flowAdvect(texture2d<float, access::sample> field [[texture(0)]],
                       texture2d<float, access::sample> velocity [[texture(1)]],
                       texture2d<float, access::write> output [[texture(2)]],
                       constant FlowUniforms &u [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    float2 size = float2(output.get_width(), output.get_height());
    float2 uv = (float2(p) + 0.5) / size;
    float2 v = velocity.sample(smoothSampler, uv).xy;
    float4 value = field.sample(smoothSampler, uv - u.motion.x * v / size);
    // Velocity decay and dye decay are selected by detail.w.
    value *= exp(-u.motion.x * u.detail.w);
    output.write(value, p);
}

kernel void flowForce(texture2d<float, access::read> velocity [[texture(0)]],
                      texture2d<float, access::read> dye [[texture(1)]],
                      texture2d<float, access::write> nextVelocity [[texture(2)]],
                      texture2d<float, access::write> nextDye [[texture(3)]],
                      constant FlowUniforms &u [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= velocity.get_width() || p.y >= velocity.get_height()) return;
    float2 uv = (float2(p) + 0.5) / float2(velocity.get_width(), velocity.get_height());
    float energy = u.motion.z * u.detail.z;
    float2 v = velocity.read(p).xy;
    float density = dye.read(p).x;
    for (int i=0; i<3; ++i) {
        float phase = u.motion.y * (0.42 + float(i)*0.12) + float(i)*2.094;
        float2 origin = float2(0.2 + float(i)*0.3 + 0.07*sin(phase*0.7),
                               0.5 + (0.16 + u.character.z*0.14)*sin(phase));
        float2 delta = uv-origin;
        float source = exp(-dot(delta,delta)*(70.0+u.character.z*40.0));
        float direction = i%2 == 0 ? 1.0 : -1.0;
        float punch = u.character.y;
        float2 twist = float2(-delta.y,delta.x) * direction * (400.0 + u.motion.w*220.0 + punch*650.0);
        float2 drift = float2(32.0*cos(phase), 36.0*sin(phase*0.7))*(0.5+u.detail.x*0.45);
        v += u.motion.x * source * energy * (twist + drift) * (1.0+punch*2.0);
        density += u.motion.x * source * energy * (2.5 + u.detail.x*0.7 + punch*6.0);
    }
    // Closed boundary; pressure projection follows.
    if (p.x == 0 || p.x+1 == velocity.get_width()) v.x=0;
    if (p.y == 0 || p.y+1 == velocity.get_height()) v.y=0;
    nextVelocity.write(float4(clamp(v, -80.0, 80.0), 0, 0), p);
    nextDye.write(float4(min(density, 1.6),0,0,0), p);
}

kernel void flowDivergence(texture2d<float, access::read> velocity [[texture(0)]],
                           texture2d<float, access::write> divergence [[texture(1)]],
                           uint2 p [[thread_position_in_grid]]) {
    if (p.x >= velocity.get_width() || p.y >= velocity.get_height()) return;
    int2 c=int2(p);
    float d=0.5*(cell(velocity,c+int2(1,0)).x-cell(velocity,c-int2(1,0)).x
                +cell(velocity,c+int2(0,1)).y-cell(velocity,c-int2(0,1)).y);
    divergence.write(float4(d,0,0,0),p);
}

kernel void flowPressure(texture2d<float, access::read> pressure [[texture(0)]],
                         texture2d<float, access::read> divergence [[texture(1)]],
                         texture2d<float, access::write> nextPressure [[texture(2)]],
                         uint2 p [[thread_position_in_grid]]) {
    if (p.x >= pressure.get_width() || p.y >= pressure.get_height()) return;
    int2 c=int2(p);
    float value=(cell(pressure,c+int2(1,0)).x+cell(pressure,c-int2(1,0)).x
                 +cell(pressure,c+int2(0,1)).x+cell(pressure,c-int2(0,1)).x
                 -divergence.read(p).x)*0.25;
    nextPressure.write(float4(value,0,0,0),p);
}

kernel void flowProject(texture2d<float, access::read> velocity [[texture(0)]],
                        texture2d<float, access::read> pressure [[texture(1)]],
                        texture2d<float, access::write> output [[texture(2)]],
                        uint2 p [[thread_position_in_grid]]) {
    if (p.x >= velocity.get_width() || p.y >= velocity.get_height()) return;
    int2 c=int2(p);
    float2 grad=0.5*float2(cell(pressure,c+int2(1,0)).x-cell(pressure,c-int2(1,0)).x,
                          cell(pressure,c+int2(0,1)).x-cell(pressure,c-int2(0,1)).x);
    float2 v=velocity.read(p).xy-grad;
    if (p.x==0 || p.x+1==velocity.get_width()) v.x=0;
    if (p.y==0 || p.y+1==velocity.get_height()) v.y=0;
    output.write(float4(v,0,0),p);
}

struct FlowVertex { float4 position [[position]]; float2 uv; };
vertex FlowVertex flowVertex(uint id [[vertex_id]]) {
    float2 xy = id==0 ? float2(-1,-1) : (id==1 ? float2(3,-1) : float2(-1,3));
    return {float4(xy,0,1), float2((xy.x+1)*0.5, (1-xy.y)*0.5)};
}

float surfaceLuminance(float3 rgb) {
    float3 linear = select(rgb/12.92, pow((rgb+0.055)/1.055, float3(2.4)), rgb > 0.04045);
    return dot(linear, float3(0.2126, 0.7152, 0.0722));
}

float surfaceContrast(float3 first, float3 second) {
    float a = surfaceLuminance(first), b = surfaceLuminance(second);
    return (max(a,b)+0.05)/(min(a,b)+0.05);
}

float3 readableFlowAnchor(float3 preferred, float3 background, float polarity) {
    if (surfaceContrast(preferred,background) >= 4.5) return preferred;
    float3 target=float3(polarity);
    float light=surfaceLuminance(background);
    float threshold=polarity > 0.5 ? 4.5*(light+0.05)-0.05 : (light+0.05)/4.5-0.05;
    float low=0, high=1;
    for (int i=0; i<12; i++) {
        float mid=(low+high)*0.5;
        float candidate=surfaceLuminance(mix(preferred,target,mid));
        if (polarity > 0.5 ? candidate >= threshold : candidate <= threshold) high=mid;
        else low=mid;
    }
    return mix(preferred,target,high);
}

fragment float4 flowASCII(FlowVertex in [[stage_in]],
                         texture2d<float> dye [[texture(0)]], texture2d<float> atlas [[texture(1)]],
                         constant FlowUniforms &u [[buffer(0)]]) {
    float2 grid=float2(26,16);
    float2 tile=floor(in.uv*grid);
    // Immediate, small outward pulse makes the detected attack visible without
    // waiting for dye advection. It settles with the audio onset envelope.
    float2 sampleUV=((tile+0.5)/grid-0.5)/(1.0+u.character.y*0.18)+0.5;
    float density=dye.sample(smoothSampler,sampleUV).x;
    float weight=saturate(density*1.7);
    float glyph=floor(weight*9.0);
    float2 local=fract(in.uv*grid);
    float shape=saturate(u.character.z)*2.0;
    float bank=floor(shape), nextBank=min(bank+1.0,2.0);
    float inkA=atlas.sample(smoothSampler,float2((bank*10.0+glyph+local.x)/30.0,1-local.y)).a;
    float inkB=atlas.sample(smoothSampler,float2((nextBank*10.0+glyph+local.x)/30.0,1-local.y)).a;
    float ink=mix(inkA,inkB,fract(shape));
    float edge=smoothstep(0.0,0.12,in.uv.x)*smoothstep(0.0,0.12,1-in.uv.x)
              *smoothstep(0.0,0.12,in.uv.y)*smoothstep(0.0,0.12,1-in.uv.y);
    // Spectrum selects the palette; spatial phase gives a gradient within it.
    float hue=u.character.x + in.uv.x*(0.1+u.character.z*0.2) + in.uv.y*0.09 + weight*0.08;
    float3 rgb=clamp(abs(fract(hue+float3(0,2.0/3.0,1.0/3.0))*6.0-3.0)-1.0,0.0,1.0);
    float3 color=mix(float3(1.0),rgb,0.5+u.character.z*0.25);
    if (u.paletteA.w > 0.5) {
        // Cover anchors one end; spectral color adds a changing second end.
        float3 second=mix(u.paletteB.rgb,color,0.45);
        float blend=saturate(in.uv.x*0.6+in.uv.y*0.2+weight*0.2);
        color=mix(u.paletteA.rgb,second,blend);
    }
    float glow=0.5+weight*0.5+u.character.y*0.16;
    if (u.paletteA.w > 0.5) glow=0.85+weight*0.15+u.character.y*0.1;
    float3 background = u.surface.rgb;
    // Preserve the accepted black visual exactly. Decorative glyphs keep their
    // cover/spectrum colour; only a third gradient anchor uses surface contrast.
    bool transparent = u.character.w > 0.5;
    if (!transparent && all(background == float3(0))) return float4(color*ink*glow*edge,1);
    float coverage = ink*edge;
    if (coverage == 0) return transparent ? float4(0) : float4(background,1);
    color = saturate(color*glow);
    // The accent follows audio hue, preserving colour even when it must darken.
    // A local smooth stop leaves the cover end intact instead of recolouring all glyphs.
    float3 accentRGB=clamp(abs(fract(u.character.x+float3(0,2.0/3.0,1.0/3.0))*6.0-3.0)-1.0,0.0,1.0);
    float3 anchor=readableFlowAnchor(mix(float3(1),accentRGB,0.75),background,u.surface.w);
    float anchorWeight=1-smoothstep(0.0,0.3,abs(in.uv.x-0.65));
    color=mix(color,anchor,anchorWeight);
    if (transparent) return float4(color*coverage,coverage);
    return float4(mix(background,color,coverage),1);
}

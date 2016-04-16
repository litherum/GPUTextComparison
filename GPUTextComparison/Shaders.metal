//
//  Shaders.metal
//  GPUTextComparison
//
//  Created by Litherum on 4/10/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

#include <metal_stdlib>
using namespace metal;

constexpr sampler s = sampler(coord::normalized, 
                              address::clamp_to_zero,
                              filter::linear);

struct VertexInOut
{
    float4  position [[position]];
    float2  textureCoordinate;
};

vertex VertexInOut passThroughVertex(uint vid [[ vertex_id ]],
                                     constant float3* position [[ buffer(0) ]],
                                     constant float2* textureCoordinate [[ buffer(1) ]])
{
    VertexInOut outVertex;
    
    outVertex.position = float4(position[vid], 1);
    outVertex.textureCoordinate = textureCoordinate[vid];
    
    return outVertex;
};

fragment half4 passThroughFragment(VertexInOut inFrag [[stage_in]],
                                   texture2d<float> texture [[ texture(0) ]])
{
    return half4(texture.sample(s, inFrag.textureCoordinate));
};

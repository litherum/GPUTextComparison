//
//  Shaders.metal
//  GPUTextComparison
//
//  Created by Litherum on 4/10/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

#include <metal_stdlib>
using namespace metal;

constexpr sampler s = sampler(coord::pixel,
                              address::clamp_to_zero,
                              filter::linear);

struct TextureVertexIn {
    float2 position [[ attribute(0) ]];
    float2 textureCoordinate [[ attribute(1) ]];
};

struct TextureVertexInOut
{
    float4 position [[ position ]];
    float2 textureCoordinate;
};

vertex TextureVertexInOut textureVertex(TextureVertexIn vertexIn [[ stage_in ]])
{
    TextureVertexInOut outVertex;
    
    outVertex.position = float4x4(float4(2.0 / 800.0, 0, 0, 0), float4(0, 2.0 / 600.0, 0, 0), float4(0, 0, 1, 0), float4(-1, -1, 0, 1)) * float4(vertexIn.position, 0, 1);
    outVertex.textureCoordinate = vertexIn.textureCoordinate;
    
    return outVertex;
};

fragment half4 textureFragment(TextureVertexInOut inFrag [[stage_in]],
                               texture2d<float> texture [[ texture(0) ]])
{
    return half4(half3(texture.sample(s, inFrag.textureCoordinate).x), 1);
};

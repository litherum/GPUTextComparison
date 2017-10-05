//
//  NaiveStencilShaders.metal
//  GPUTextComparison
//
//  Created by Litherum on 5/7/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

#include <metal_stdlib>
using namespace metal;

struct StencilVertexIn {
    float2 position [[ attribute(0) ]];
};

struct StencilVertexInOut
{
    float4 position [[ position ]];
};

vertex StencilVertexInOut stencilVertex(StencilVertexIn vertexIn [[ stage_in ]])
{
    StencilVertexInOut outVertex;

    outVertex.position = float4x4(float4(2.0 / 800.0, 0, 0, 0), float4(0, 2.0 / 600.0, 0, 0), float4(0, 0, 1, 0), float4(-1, -1, 0, 1)) * float4(vertexIn.position, 0, 1);

    return outVertex;
};

fragment half4 stencilFragment(StencilVertexInOut inFrag [[ stage_in ]])
{
    return half4(1, 1, 1, 1);
};


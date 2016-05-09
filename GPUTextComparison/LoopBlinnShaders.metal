//
//  LoopBlinnShaders.metal
//  GPUTextComparison
//
//  Created by Litherum on 5/7/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

#include <metal_stdlib>
using namespace metal;

struct LoopBlinnVertexIn {
    float2 position [[ attribute(0) ]];
    float2 coefficient [[ attribute(1) ]];
};

struct LoopBlinnVertexInOut
{
    float4 position [[ position ]];
    float2 coefficient;
};

vertex LoopBlinnVertexInOut loopBlinnVertex(LoopBlinnVertexIn vertexIn [[ stage_in ]])
{
    LoopBlinnVertexInOut outVertex;
    
    outVertex.position = float4x4(float4(2.0 / 800.0, 0, 0, 0), float4(0, 2.0 / 600.0, 0, 0), float4(0, 0, 1, 0), float4(-1, -1, 0, 1)) * float4(vertexIn.position, 0, 1);
    outVertex.coefficient = vertexIn.coefficient;
    
    return outVertex;
};

fragment half4 loopBlinnFragment(LoopBlinnVertexInOut inFrag [[ stage_in ]])
{
    /*float u = inFrag.coefficient.x;
    float v = inFrag.coefficient.y;
    float result = u * u - v;
    float gradient = length(float2(dfdx(result), dfdy(result)));
    float dist = -result / gradient;
    return half4(dist, dist, dist, 1);*/
    return half4(1, 1, 1, 1);
};

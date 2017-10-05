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
    float4 coefficient [[ attribute(1) ]];
};

struct LoopBlinnVertexInOut
{
    float4 position [[ position ]];
    float4 coefficient;
};

vertex LoopBlinnVertexInOut loopBlinnVertex(LoopBlinnVertexIn vertexIn [[ stage_in ]])
{
    LoopBlinnVertexInOut outVertex;

    outVertex.position = float4x4(float4(2.0 / 800.0, 0, 0, 0), float4(0, 2.0 / 600.0, 0, 0), float4(0, 0, 1, 0), float4(-1, -1, 0, 1)) * float4(vertexIn.position, 0, 1);
    outVertex.coefficient = vertexIn.coefficient;

    return outVertex;
};

fragment float4 loopBlinnFragment(LoopBlinnVertexInOut inFrag [[ stage_in ]])
{
    /*float offsetU = inFrag.coefficient.x;
     float offsetV = inFrag.coefficient.y;
     float flag = offsetU < 0;
     flag = flag * 2 - 1;

     float u = abs(offsetU) - 1;
     float v = abs(offsetV) - 1;

     float result = flag * (u * u - v);
     float dist = result <= 0;
     return half4(dist, dist, dist, 1);
     //return half4(1, 1, 1, 1);*/

    float k = inFrag.coefficient.x;
    float l = inFrag.coefficient.y;
    float m = inFrag.coefficient.z;

    float result = k * k * k - l * m;
    float dist = result <= 0;
    return float4(dist, dist, dist, 1);
};


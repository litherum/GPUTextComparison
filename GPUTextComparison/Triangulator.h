//
//  Triangulator.h
//  GPUTextComparison
//
//  Created by Litherum on 5/8/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

#ifndef Triangulator_h
#define Triangulator_h

#include <CoreGraphics/CoreGraphics.h>
#include <simd/simd.h>

#include "CubicBeziers.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CubicTriangleVertex {
    CGPoint point;
    vector_float3 coefficient;
} CubicTriangleVertex;

typedef void (^CubicTriangleFaceReceiver)(CubicTriangleVertex, CubicTriangleVertex, CubicTriangleVertex);
void triangulate(CGPathRef, CubicTriangleFaceReceiver);

#ifdef __cplusplus
}
#endif

#endif /* Triangulator_h */

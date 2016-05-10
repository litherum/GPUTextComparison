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

#ifdef __cplusplus
extern "C" {
#endif

struct Vertex {
    CGPoint position;
    vector_float3 coefficient;
};

typedef void (^TriangleReceiver)(struct Vertex, struct Vertex, struct Vertex);
void triangulate(CGPathRef, TriangleReceiver);

#ifdef __cplusplus
}
#endif

#endif /* Triangulator_h */

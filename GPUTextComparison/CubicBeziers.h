//
//  CubicBeziers.h
//  GPUTextComparison
//
//  Created by Litherum on 5/9/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

#ifndef CubicBeziers_h
#define CubicBeziers_h

#include <CoreGraphics/CoreGraphics.h>
#include <simd/simd.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct CubicVertex {
    CGPoint point;
    vector_float3 coefficient;
    int order;
} CubicVertex;

typedef void (^CubicFaceReceiver)(CubicVertex, CubicVertex, CubicVertex);
bool cubic(CGPoint, CGPoint, CGPoint, CGPoint, CubicFaceReceiver);

#ifdef __cplusplus
}
#endif

#endif /* CubicBeziers_h */

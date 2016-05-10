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

typedef struct CubicCoefficients {
    vector_float3 c0;
    vector_float3 c1;
    vector_float3 c2;
    vector_float3 c3;
    bool include1;
    bool include2;
} CubicCoefficients;

CubicCoefficients cubic(CGPoint, CGPoint, CGPoint, CGPoint);

#ifdef __cplusplus
}
#endif

#endif /* CubicBeziers_h */

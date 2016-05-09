//
//  CGPathIterator.h
//  GPUTextComparison
//
//  Created by Litherum on 4/30/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

#ifndef CGPathIterator_h
#define CGPathIterator_h

#import <CoreGraphics/CoreGraphics.h>

#ifdef __cplusplus
#import <functional>
extern "C" {
#endif

typedef void (^CGPathIterator)(CGPathElement);
void iterateCGPath(CGPathRef, CGPathIterator);

#ifdef __cplusplus
}
void iterateCGPath(CGPathRef, std::function<void(CGPathElement)>);
#endif

#endif /* CGPathIterator_h */

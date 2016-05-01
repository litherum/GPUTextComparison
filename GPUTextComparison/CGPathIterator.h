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

typedef void (^CGPathIterator)(CGPathElement);
void iterateCGPath(CGPathRef, CGPathIterator);

#endif /* CGPathIterator_h */

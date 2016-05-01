//
//  CGPathIterator.c
//  GPUTextComparison
//
//  Created by Litherum on 4/30/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

#include "CGPathIterator.h"

static void applyCallback(void *info, const CGPathElement *element) {
    CGPathIterator iterator = (CGPathIterator)info;
    iterator(*element);
}

void iterateCGPath(CGPathRef path, CGPathIterator iterator) {
    CGPathApply(path, iterator, &applyCallback);
}

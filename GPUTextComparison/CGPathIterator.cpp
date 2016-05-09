//
//  CGPathIterator.c
//  GPUTextComparison
//
//  Created by Litherum on 4/30/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

#include "CGPathIterator.h"

template <typename T>
static void applyCallback(void *info, const CGPathElement *element) {
    T& iterator = *reinterpret_cast<T*>(info);
    iterator(*element);
}

void iterateCGPath(CGPathRef path, CGPathIterator iterator) {
    CGPathApply(path, &iterator, &applyCallback<CGPathIterator>);
}

void iterateCGPath(CGPathRef path, std::function<void(CGPathElement)> function) {
    CGPathApply(path, &function, &applyCallback<std::function<void(CGPathElement)>>);
}

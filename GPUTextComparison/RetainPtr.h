//
//  RetainPtr.h
//  GPUTextComparison
//
//  Created by Litherum on 5/8/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

#ifndef RetainPtr_h
#define RetainPtr_h

enum class AdoptFlag {
    adoptFlag
};

template <typename T>
class RetainPtr {
public:
    RetainPtr(T t) : t(t) {
        CFRetain(t);
    }

    RetainPtr(T t, AdoptFlag) : t(t) {
    }

    ~RetainPtr() {
        CFRelease(t);
    }

    operator T() const {
        return t;
    }

private:
    T t;
};

template <typename T>
RetainPtr<T> adopt(T t) {
    return RetainPtr<T>(t, AdoptFlag::adoptFlag);
}

#endif /* RetainPtr_h */

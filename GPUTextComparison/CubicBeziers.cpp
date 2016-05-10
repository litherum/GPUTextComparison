//
//  CubicBeziers.cpp
//  GPUTextComparison
//
//  Created by Litherum on 5/9/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

#include "CubicBeziers.h"
#include <array>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wconditional-uninitialized"
#pragma clang diagnostic ignored "-Wshift-negative-value"
#pragma clang diagnostic ignored "-Wshorten-64-to-32"
#include <CGAL/Exact_predicates_inexact_constructions_kernel.h>
#pragma clang diagnostic pop

typedef CGAL::Exact_predicates_inexact_constructions_kernel K;

struct Coefficients {
    std::array<CGFloat, 3> v0;
    std::array<CGFloat, 3> v1;
    std::array<CGFloat, 3> v2;
    std::array<CGFloat, 3> v3;
    bool flip;
};

Coefficients lineOrPoint(CGFloat d1, CGFloat d2, CGFloat d3) {
    return {
        { 0, 0, 0 },
        { 0, 0, 0 },
        { 0, 0, 0 },
        { 0, 0, 0 },
        false
    };
}

Coefficients quadratic(CGFloat d1, CGFloat d2, CGFloat d3) {
    return {
        { 0, 0, 0 },
        { CGFloat(1) / 3, 0, CGFloat(1) / 3 },
        { CGFloat(2) / 3, CGFloat(1) / 3, CGFloat(2) / 3 },
        { 1, 1, 1 },
        d3 < 0
    };
}

Coefficients serpentine(CGFloat d1, CGFloat d2, CGFloat d3) {
    CGFloat ls = 3 * d2 - std::sqrt(9 * d2 * d2 - 12 * d1 * d3);
    CGFloat lt = 6 * d1;
    CGFloat ms = 3 * d2 + std::sqrt(9 * d2 * d2 - 12 * d1 * d3);
    CGFloat mt = 6 * d1;
    return {
        { ls * ms, ls * ls * ls, ms * ms * ms },
        { (3 * ls * ms - ls * mt - lt * ms) / 3, ls * ls * (ls - lt), ms * ms * (ms - mt) },
        { (lt * (mt - 2 * ms) + ls * (3 * ms - 2 * mt)) / 3, (lt - ls) * (lt - ls) * ls, (mt - ms) * (mt - ms) * ms },
        { (lt - ls) * (mt - ms), -(lt - ls) * (lt - ls) * (lt - ls), -(mt - ms) * (mt - ms) * (mt - ms) },
        d1 < 0
    };
}

Coefficients loop(CGFloat d1, CGFloat d2, CGFloat d3) {
    CGFloat ls = d2 - std::sqrt(4 * d1 * d3 - 3 * d2 * d2);
    CGFloat lt = 2 * d1;
    CGFloat ms = d2 + std::sqrt(4 * d1 * d3 - 3 * d2 * d2);
    CGFloat mt = 2 * d1;
    return {
        { ls * ms, ls * ls * ms, ls * ms * ms },
        { (-ls * mt - lt * ms + 3 * ls * ms) / 3, ls * (ls * (mt - 3 * ms) + 2 * lt * ms) / -3, ms * (ls * (2 * mt - 3 * ms) + lt * ms) / -3 },
        { (lt * (mt - 2 * ms) + ls * (3 * ms - 2 * mt)) / 3, (lt - ls) * (ls * (2 * mt - 3 * ms) + lt * ms) / 3, (mt - ms) * (ls * (mt - 3 * ms) + 2 * lt * ms) / 3 },
        { (lt - ls) * (mt - ms), -(lt - ls) * (lt - ls) * (mt - ms), -(lt - ls) * (mt - ms) * (mt - ms) },
        false
    }; // FIXME: might need to subdivide and update orientation
}

Coefficients cusp(CGFloat d1, CGFloat d2, CGFloat d3) {
    CGFloat ls = d3;
    CGFloat lt = 3 * d2;
    return {
        { ls, ls * ls * ls, 1 },
        { ls - lt / 3, ls * ls * (ls - lt), 1 },
        { ls - 2 * lt / 3, (ls - lt) * (ls - lt) * ls, 1 },
        { ls - lt, (ls - lt) * (ls - lt) * (ls - lt), 1 },
        false
    };
}

CubicCoefficients cubic(CGPoint p0, CGPoint p1, CGPoint p2, CGPoint p3) {
    CGAL::Vector_3<K> b0(p0.x, p0.y, 1);
    CGAL::Vector_3<K> b1(p1.x, p1.y, 1);
    CGAL::Vector_3<K> b2(p2.x, p2.y, 1);
    CGAL::Vector_3<K> b3(p3.x, p3.y, 1);
    CGFloat a1 = b0 * CGAL::cross_product(b3, b2);
    CGFloat a2 = b1 * CGAL::cross_product(b0, b3);
    CGFloat a3 = b2 * CGAL::cross_product(b1, b0);
    CGFloat d1 = a1 - 2 * a2 + 3 * a3;
    CGFloat d2 = -a2 + 3 * a3;
    CGFloat d3 = 3 * a3;
    CGAL::Vector_3<K> u(d1, d2, d3);
    u = u / std::sqrt(u.squared_length());
    d1 = u.x();
    d2 = u.y();
    d3 = u.z();

    Coefficients result;
    CGFloat discr = d1 * d1 * (3 * d2 * d2 - 4 * d1 * d3);

    if (b0 == b1 && b0 == b2 && b0 == b3)
        result = lineOrPoint(d1, d2, d3);
    else if (d1 == 0 && d2 == 0 && d3 == 0)
        result = lineOrPoint(d1, d2, d3);
    else if (d1 == 0 && d2 == 0)
        result = quadratic(d1, d2, d3);
    else if (discr > 0)
        result = serpentine(d1, d2, d3);
    else if (discr < 0)
        result = loop(d1, d2, d3);
    else
        result = cusp(d1, d2, d3);

    if (result.flip) {
        for (size_t i = 0; i < 2; ++i)
            result.v0[i] *= -1;
        for (size_t i = 0; i < 2; ++i)
            result.v1[i] *= -1;
        for (size_t i = 0; i < 2; ++i)
            result.v2[i] *= -1;
        for (size_t i = 0; i < 2; ++i)
            result.v3[i] *= -1;
    }

    return {
        { static_cast<float>(result.v0[0]), static_cast<float>(result.v0[1]), static_cast<float>(result.v0[2]) },
        { static_cast<float>(result.v1[0]), static_cast<float>(result.v1[1]), static_cast<float>(result.v1[2]) },
        { static_cast<float>(result.v2[0]), static_cast<float>(result.v2[1]), static_cast<float>(result.v2[2]) },
        { static_cast<float>(result.v3[0]), static_cast<float>(result.v3[1]), static_cast<float>(result.v3[2]) },
        CGAL::orientation(CGAL::Point_2<K>(p0.x, p0.y), CGAL::Point_2<K>(p3.x, p3.y), CGAL::Point_2<K>(p1.x, p1.y)) == CGAL::RIGHT_TURN,
        CGAL::orientation(CGAL::Point_2<K>(p0.x, p0.y), CGAL::Point_2<K>(p3.x, p3.y), CGAL::Point_2<K>(p2.x, p2.y)) == CGAL::RIGHT_TURN
    };
}

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
#include <CGAL/Triangulation_vertex_base_with_info_2.h>
#include <CGAL/Delaunay_triangulation_2.h>
#pragma clang diagnostic pop

struct CoefficientTriple {
    CGFloat k;
    CGFloat l;
    CGFloat m;
};

typedef CGAL::Exact_predicates_inexact_constructions_kernel K;
typedef CGAL::Triangulation_vertex_base_with_info_2<CoefficientTriple, K> Vb;
typedef CGAL::Triangulation_face_base_2<K> Fb;
typedef CGAL::Triangulation_data_structure_2<Vb, Fb> TDS;
typedef CGAL::Delaunay_triangulation_2<K, TDS> Triangulation;

struct Coefficients {
    CoefficientTriple c0;
    CoefficientTriple c1;
    CoefficientTriple c2;
    CoefficientTriple c3;
    bool flip;
};

struct CubicCurve {
    CGPoint p0;
    CGPoint p1;
    CGPoint p2;
    CGPoint p3;
    Coefficients c;
};

static Coefficients lineOrPoint(CGFloat d1, CGFloat d2, CGFloat d3) {
    return {
        { 0, 0, 0 },
        { 0, 0, 0 },
        { 0, 0, 0 },
        { 0, 0, 0 },
        false
    };
}

static Coefficients quadratic(CGFloat d1, CGFloat d2, CGFloat d3) {
    return {
        { 0, 0, 0 },
        { CGFloat(1) / 3, 0, CGFloat(1) / 3 },
        { CGFloat(2) / 3, CGFloat(1) / 3, CGFloat(2) / 3 },
        { 1, 1, 1 },
        d3 > 0
    };
}

static Coefficients serpentine(CGFloat d1, CGFloat d2, CGFloat d3) {
    CGFloat ls = 3 * d2 - std::sqrt(9 * d2 * d2 - 12 * d1 * d3);
    CGFloat lt = 6 * d1;
    CGFloat ms = 3 * d2 + std::sqrt(9 * d2 * d2 - 12 * d1 * d3);
    CGFloat mt = 6 * d1;
    return {
        { ls * ms, ls * ls * ls, ms * ms * ms },
        { (3 * ls * ms - ls * mt - lt * ms) / 3, ls * ls * (ls - lt), ms * ms * (ms - mt) },
        { (lt * (mt - 2 * ms) + ls * (3 * ms - 2 * mt)) / 3, (lt - ls) * (lt - ls) * ls, (mt - ms) * (mt - ms) * ms },
        { (lt - ls) * (mt - ms), -(lt - ls) * (lt - ls) * (lt - ls), -(mt - ms) * (mt - ms) * (mt - ms) },
        d1 > 0
    };
}

static inline CGFloat roundToZero(CGFloat x) {
    const CGFloat epsilon = 0.0001;
    if (std::abs(x) < epsilon)
        return 0;
    return x;
}

static inline std::array<CGFloat, 3> computeDs(CGPoint p0, CGPoint p1, CGPoint p2, CGPoint p3) {
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

    d1 = roundToZero(d1);
    d2 = roundToZero(d2);
    d3 = roundToZero(d3);

    return { d1, d2, d3 };
}

static inline CGPoint subdivide(CGFloat t, CGPoint a, CGPoint b) {
    return CGPointMake((1 - t) * a.x + t * b.x, (1 - t) * a.y + t * b.y);
}

static inline std::array<std::array<CGPoint, 4>, 2> subdivide(CGFloat t, CGPoint p0, CGPoint p1, CGPoint p2, CGPoint p3) {
    auto ab = subdivide(t, p0, p1);
    auto bc = subdivide(t, p1, p2);
    auto cd = subdivide(t, p2, p3);
    auto abc = subdivide(t, ab, bc);
    auto bcd = subdivide(t, bc, cd);
    auto abcd = subdivide(t, abc, bcd);

    return {{ { p0, ab, abc, abcd }, { abcd, bcd, cd, p3 } }};
}

static inline std::array<CGFloat, 4> loopParameters(CGFloat d1, CGFloat d2, CGFloat d3) {
    CGFloat ls = d2 - std::sqrt(4 * d1 * d3 - 3 * d2 * d2);
    CGFloat lt = 2 * d1;
    CGFloat ms = d2 + std::sqrt(4 * d1 * d3 - 3 * d2 * d2);
    CGFloat mt = 2 * d1;

    return { ls, lt, ms, mt };
}

template <typename T>
static inline T sign(T x) {
    return x > 0 ? 1 : (x < 0 ? -1 : 0);
}

static inline Coefficients loopCoefficients(CGFloat d1, CGFloat ls, CGFloat lt, CGFloat ms, CGFloat mt) {
    Coefficients result = {
        { ls * ms, ls * ls * ms, ls * ms * ms },
        { (-ls * mt - lt * ms + 3 * ls * ms) / 3, ls * (ls * (mt - 3 * ms) + 2 * lt * ms) / -3, ms * (ls * (2 * mt - 3 * ms) + lt * ms) / -3 },
        { (lt * (mt - 2 * ms) + ls * (3 * ms - 2 * mt)) / 3, (lt - ls) * (ls * (2 * mt - 3 * ms) + lt * ms) / 3, (mt - ms) * (ls * (mt - 3 * ms) + 2 * lt * ms) / 3 },
        { (lt - ls) * (mt - ms), -(lt - ls) * (lt - ls) * (mt - ms), -(lt - ls) * (mt - ms) * (mt - ms) },
        false
    };
    result.flip = (d1 > 0 && sign(result.c1.k) > 0) || (d1 < 0 && sign(result.c1.k) < 0);
    return result;
}

static std::vector<CubicCurve> loop(CGFloat d1, CGFloat d2, CGFloat d3, CGPoint p0, CGPoint p1, CGPoint p2, CGPoint p3, CubicFaceReceiver receiver) {
    CGFloat ls, lt, ms, mt;
    std::tie(ls, lt, ms, mt) = loopParameters(d1, d2, d3);

    CGFloat t0 = ms / mt;
    CGFloat t1 = ls / lt;
    bool c0 = t0 > 0 && t0 < 1;
    bool c1 = t1 > 0 && t1 < 1;
    if (c0 || c1) {
        // We need to subdivide.
        // This is a huge layering violation, but I think it's better than recursion. Maybe we should pass a signal up instead?
        auto t = c0 ? t0 : t1;
        auto subdivided = subdivide(t, p0, p1, p2, p3);
        std::tie(d1, d2, d3) = computeDs(subdivided[0][0], subdivided[0][1], subdivided[0][2], subdivided[0][3]);
        std::tie(ls, lt, ms, mt) = loopParameters(d1, d2, d3);
        auto coefficients1 = loopCoefficients(d1, ls, lt, ms, mt);
        std::tie(d1, d2, d3) = computeDs(subdivided[1][0], subdivided[1][1], subdivided[1][2], subdivided[1][3]);
        std::tie(ls, lt, ms, mt) = loopParameters(d1, d2, d3);
        auto coefficients2 = loopCoefficients(d1, ls, lt, ms, mt);

        return { { subdivided[0][0], subdivided[0][1], subdivided[0][2], subdivided[0][3], coefficients1 },
            { subdivided[1][0], subdivided[1][1], subdivided[1][2], subdivided[1][3], coefficients2 } };
    }

    return { { p0, p1, p2, p3, loopCoefficients(d1, ls, lt, ms, mt) } };
}

static Coefficients cusp(CGFloat d1, CGFloat d2, CGFloat d3) {
    CGFloat ls = d3;
    CGFloat lt = 3 * d2;
    return {
        { ls, ls * ls * ls, 1 },
        { ls - lt / 3, ls * ls * (ls - lt), 1 },
        { ls - 2 * lt / 3, (ls - lt) * (ls - lt) * ls, 1 },
        { ls - lt, (ls - lt) * (ls - lt) * (ls - lt), 1 },
        true
    };
}

static inline CubicVertex convertTriangulatedVertex(Triangulation::Vertex& v) {
    auto& point = v.point();
    auto& info = v.info();
    return { CGPointMake(point.x(), point.y()),
        { static_cast<float>(info.k), static_cast<float>(info.l), static_cast<float>(info.m) },
        -1 };
}

// FIXME: This might not work if some points are duplicated.
static inline Triangulation::Vertex_handle toInside(Triangulation::Vertex_handle initial, Triangulation::Vertex_handle v1, Triangulation::Vertex_handle v2, Triangulation::Vertex_handle v3) {
    auto circulatorBase = initial->incident_edges();
    auto circulator = circulatorBase;
    do {
        auto neighbor = circulator->first->vertex((circulator->second + 1) % 3);
        assert(neighbor != initial);
        auto k = neighbor->info().k;
        auto l = neighbor->info().l;
        auto m = neighbor->info().m;
        if (k * k * k - l * m > 0) {
            ++circulator;
            continue;
        }
        if (neighbor == v1 || neighbor == v2)
            return neighbor;
        ++circulator;
    } while (circulator != circulatorBase);
    return v3;
}

static inline int index(std::vector<Triangulation::Vertex_handle>& order, Triangulation::Vertex_handle test) {
    for (int i = 0; i < order.size(); ++i) {
        if (order[i] == test)
            return i;
    }
    return -1;
}

static inline std::vector<std::array<CubicVertex, 3>> triangulate(CubicCurve s) {
    assert(!s.c.flip);

    Triangulation t;
    auto v0 = t.insert(Triangulation::Point(s.p0.x, s.p0.y));
    v0->info() = { s.c.c0.k, s.c.c0.l, s.c.c0.m };
    auto v1 = t.insert(Triangulation::Point(s.p1.x, s.p1.y));
    v1->info() = { s.c.c1.k, s.c.c1.l, s.c.c1.m };
    auto v2 = t.insert(Triangulation::Point(s.p2.x, s.p2.y));
    v2->info() = { s.c.c2.k, s.c.c2.l, s.c.c2.m };
    auto v3 = t.insert(Triangulation::Point(s.p3.x, s.p3.y));
    v3->info() = { s.c.c3.k, s.c.c3.l, s.c.c3.m };

    std::vector<Triangulation::Vertex_handle> insideBorder = { v0 };
    auto nextInside = toInside(v0, v1, v2, v3);
    insideBorder.push_back(nextInside);
    if (nextInside != v3) {
        nextInside = toInside(nextInside, v1, v2, v3);
        insideBorder.push_back(nextInside);
        if (nextInside != v3)
            insideBorder.push_back(v3);
    }

    std::vector<std::array<CubicVertex, 3>> result;
    for (auto i = t.finite_faces_begin(); i != t.finite_faces_end(); ++i) {
        auto resultV0 = convertTriangulatedVertex(*i->vertex(0));
        auto resultV1 = convertTriangulatedVertex(*i->vertex(1));
        auto resultV2 = convertTriangulatedVertex(*i->vertex(2));
        resultV0.order = index(insideBorder, i->vertex(0));
        resultV1.order = index(insideBorder, i->vertex(1));
        resultV2.order = index(insideBorder, i->vertex(2));
        result.push_back({ resultV0, resultV1, resultV2 });
    }
    return result;
}

static inline void flipCoefficients(Coefficients& coefficients) {
    if (!coefficients.flip)
        return;

    coefficients.c0.k *= -1;
    coefficients.c0.l *= -1;
    coefficients.c1.k *= -1;
    coefficients.c1.l *= -1;
    coefficients.c2.k *= -1;
    coefficients.c2.l *= -1;
    coefficients.c3.k *= -1;
    coefficients.c3.l *= -1;
    coefficients.flip = false;
}

void cubic(CGPoint p0, CGPoint p1, CGPoint p2, CGPoint p3, CubicFaceReceiver receiver) {
    CGFloat d1, d2, d3;
    std::tie(d1, d2, d3) = computeDs(p0, p1, p2, p3);

    Coefficients result;
    CGFloat discr = d1 * d1 * (3 * d2 * d2 - 4 * d1 * d3);

    if (CGPointEqualToPoint(p0, p1) && CGPointEqualToPoint(p0, p2) && CGPointEqualToPoint(p0, p3))
        result = lineOrPoint(d1, d2, d3);
    else if (d1 == 0 && d2 == 0 && d3 == 0)
        result = lineOrPoint(d1, d2, d3);
    else if (d1 == 0 && d2 == 0)
        result = quadratic(d1, d2, d3);
    else if (discr > 0)
        result = serpentine(d1, d2, d3);
    else if (discr < 0) {
        auto maxIndex = 0;
        for (auto subdivision : loop(d1, d2, d3, p0, p1, p2, p3, receiver)) {
            flipCoefficients(subdivision.c);
            auto localMaxIndex = 0;
            for (auto triangle : triangulate(subdivision)) {
                localMaxIndex = std::max(localMaxIndex, triangle[0].order);
                localMaxIndex = std::max(localMaxIndex, triangle[1].order);
                localMaxIndex = std::max(localMaxIndex, triangle[2].order);
                triangle[0].order += maxIndex;
                triangle[1].order += maxIndex;
                triangle[2].order += maxIndex;
                receiver(triangle[0], triangle[1], triangle[2]);
            }
            maxIndex += localMaxIndex + 1;
        }
        return;
    } else
        result = cusp(d1, d2, d3);

    flipCoefficients(result);

    for (auto triangle : triangulate({ p0, p1, p2, p3, result }))
        receiver(triangle[0], triangle[1], triangle[2]);
}

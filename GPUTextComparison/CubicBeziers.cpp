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

struct VertexInfo {
    CGFloat k;
    CGFloat l;
    CGFloat m;
};

typedef CGAL::Exact_predicates_inexact_constructions_kernel K;
typedef CGAL::Triangulation_vertex_base_with_info_2<VertexInfo, K> Vb;
typedef CGAL::Triangulation_face_base_2<K> Fb;
typedef CGAL::Triangulation_data_structure_2<Vb, Fb> TDS;
typedef CGAL::Delaunay_triangulation_2<K, TDS> Triangulation;

struct Coefficients {
    std::array<CGFloat, 3> v0;
    std::array<CGFloat, 3> v1;
    std::array<CGFloat, 3> v2;
    std::array<CGFloat, 3> v3;
    bool flip;
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
        d3 < 0
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
        d1 < 0
    };
}

static Coefficients loop(CGFloat d1, CGFloat d2, CGFloat d3) {
    CGFloat ls = d2 - std::sqrt(4 * d1 * d3 - 3 * d2 * d2);
    CGFloat lt = 2 * d1;
    CGFloat ms = d2 + std::sqrt(4 * d1 * d3 - 3 * d2 * d2);
    CGFloat mt = 2 * d1;
    return {
        { ls * ms, ls * ls * ms, ls * ms * ms },
        { (-ls * mt - lt * ms + 3 * ls * ms) / 3, ls * (ls * (mt - 3 * ms) + 2 * lt * ms) / -3, ms * (ls * (2 * mt - 3 * ms) + lt * ms) / -3 },
        { (lt * (mt - 2 * ms) + ls * (3 * ms - 2 * mt)) / 3, (lt - ls) * (ls * (2 * mt - 3 * ms) + lt * ms) / 3, (mt - ms) * (ls * (mt - 3 * ms) + 2 * lt * ms) / 3 },
        { (lt - ls) * (mt - ms), -(lt - ls) * (lt - ls) * (mt - ms), -(lt - ls) * (mt - ms) * (mt - ms) },
        true
    }; // FIXME: might need to subdivide and update orientation
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

static inline CGFloat roundToZero(CGFloat x) {
    const CGFloat epsilon = 0.001;
    if (std::abs(x) < epsilon)
        return 0;
    return x;
}

static inline CubicVertex convertTriangulatedVertex(Triangulation::Vertex& v) {
    auto& point = v.point();
    auto& info = v.info();
    return { CGPointMake(point.x(), point.y()),
        { static_cast<float>(info.k), static_cast<float>(info.l), static_cast<float>(info.m) } };
}

static inline std::vector<std::array<CubicVertex, 3>> triangulate(CGPoint p0, std::array<CGFloat, 3> c0, CGPoint p1, std::array<CGFloat, 3> c1, CGPoint p2, std::array<CGFloat, 3> c2, CGPoint p3, std::array<CGFloat, 3> c3) {
    Triangulation t;
    auto v0 = t.insert(Triangulation::Point(p0.x, p0.y));
    v0->info() = { c0[0], c0[1], c0[2] };
    auto v1 = t.insert(Triangulation::Point(p1.x, p1.y));
    v1->info() = { c1[0], c1[1], c1[2] };
    auto v2 = t.insert(Triangulation::Point(p2.x, p2.y));
    v2->info() = { c2[0], c2[1], c2[2] };
    auto v3 = t.insert(Triangulation::Point(p3.x, p3.y));
    v3->info() = { c3[0], c3[1], c3[2] };

    std::vector<std::array<CubicVertex, 3>> result;
    for (auto i = t.finite_faces_begin(); i != t.finite_faces_end(); ++i)
        result.push_back({ convertTriangulatedVertex(*i->vertex(0)), convertTriangulatedVertex(*i->vertex(1)), convertTriangulatedVertex(*i->vertex(2)) });
    return result;
}

void cubic(CGPoint p0, CGPoint p1, CGPoint p2, CGPoint p3, CubicFaceReceiver receiver) {
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
        result.v0[0] *= -1;
        result.v0[1] *= -1;
        result.v1[0] *= -1;
        result.v1[1] *= -1;
        result.v2[0] *= -1;
        result.v2[1] *= -1;
        result.v3[0] *= -1;
        result.v3[1] *= -1;
    }

    for (auto triangle : triangulate(p0, result.v0, p1, result.v1, p2, result.v2, p3, result.v3))
        receiver(triangle[0], triangle[1], triangle[2]);

    //CGAL::orientation(CGAL::Point_2<K>(p0.x, p0.y), CGAL::Point_2<K>(p3.x, p3.y), CGAL::Point_2<K>(p1.x, p1.y)) == CGAL::RIGHT_TURN,
    //CGAL::orientation(CGAL::Point_2<K>(p0.x, p0.y), CGAL::Point_2<K>(p3.x, p3.y), CGAL::Point_2<K>(p2.x, p2.y)) == CGAL::RIGHT_TURN
}

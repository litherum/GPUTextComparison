//
//  Triangulator.cpp
//  GPUTextComparison
//
//  Created by Litherum on 5/8/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

#include "Triangulator.h"
#include "CGPathIterator.h"
#include "RetainPtr.h"

#include <queue>
#include <boost/optional.hpp>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wconditional-uninitialized"
#pragma clang diagnostic ignored "-Wshift-negative-value"
#pragma clang diagnostic ignored "-Wshorten-64-to-32"
#include <CGAL/Exact_predicates_inexact_constructions_kernel.h>
#include <CGAL/Constrained_Delaunay_triangulation_2.h>
#include <CGAL/Triangulation_face_base_with_info_2.h>
#pragma clang diagnostic pop

class FaceInfo {
public:
    boost::optional<unsigned> getDepth() const {
        return depth;
    }

    void setDepth(unsigned newDepth) {
        depth = newDepth;
    }

    bool inside() const {
        return depth.value() % 2 == 1;
    }

private:
    boost::optional<unsigned> depth;
};

typedef CGAL::Exact_predicates_inexact_constructions_kernel      K;
typedef CGAL::Triangulation_vertex_base_2<K>                     Vb;
typedef CGAL::Triangulation_face_base_with_info_2<FaceInfo, K>  Fbb;
typedef CGAL::Constrained_triangulation_face_base_2<K,Fbb>       Fb;
typedef CGAL::Triangulation_data_structure_2<Vb,Fb>              TDS;
typedef CGAL::Exact_predicates_tag                               Itag;
typedef CGAL::Constrained_Delaunay_triangulation_2<K, TDS, Itag> CDT;

class Triangulator {
public:
    Triangulator(CGPathRef path) : path(path) {
        insert();
        mark();
    }

    void triangulate(TriangleReceiver receiver) {
        for (auto facesIterator = cdt.finite_faces_begin(); facesIterator != cdt.finite_faces_end(); ++facesIterator) {
            if (facesIterator->info().inside()) {
                auto p0 = facesIterator->vertex(0)->point();
                auto p1 = facesIterator->vertex(1)->point();
                auto p2 = facesIterator->vertex(2)->point();
                receiver({ CGPointMake(p0.x(), p0.y()), { 0, 0 } },
                         { CGPointMake(p1.x(), p1.y()), { 0, 0 } },
                         { CGPointMake(p2.x(), p2.y()), { 0, 0 } });
            }
        }
        
        for (auto& quadraticCurve : quadraticCurves)
            receiver(quadraticCurve[0], quadraticCurve[1], quadraticCurve[2]);
        
        for (auto& cubicCurve : cubicCurves) {
            receiver(cubicCurve[0],
                     cubicCurve[1],
                     cubicCurve[2]);
            receiver(cubicCurve[2],
                     cubicCurve[3],
                     cubicCurve[0]);
        }
    }

private:
    void insertQuadraticCurve(CDT::Vertex_handle& currentVertex, const CGPathElement& element) {
        auto p0 = CGPointMake(currentVertex->point().x(), currentVertex->point().y());
        auto p1 = element.points[0];
        auto p2 = element.points[1];
        Vertex a = { p0, { 1, 1, 0, 0 } };
        Vertex b = { p1, { 1.5, 1, 0, 0 } };
        Vertex c = { p2, { 2, 2, 0, 0 } };
        auto newVertex = cdt.insert(CDT::Point(p2.x, p2.y));
        switch (CGAL::orientation(CDT::Point(p0.x, p0.y), CDT::Point(p2.x, p2.y), CDT::Point(p1.x, p1.y))) {
        case CGAL::LEFT_TURN: {
            insertConstraint(currentVertex, newVertex);
            quadraticCurves.push_back({ a, b, c });
            break;
        }
        case CGAL::RIGHT_TURN: {
            auto middleVertex = cdt.insert(CDT::Point(p1.x, p1.y));
            insertConstraint(currentVertex, middleVertex);
            insertConstraint(currentVertex, newVertex);
            a.coefficient *= -1;
            b.coefficient *= -1;
            c.coefficient *= -1;
            quadraticCurves.push_back({ a, b, c });
            break;
        }
        case CGAL::COLLINEAR: {
            insertConstraint(currentVertex, newVertex);
            break;
        }
        }
        currentVertex = newVertex;
    }

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
            { ls - lt / 3, ls * ls * (ls - lt), 1 },
            { ls - lt, (ls - lt) * (ls - lt) * (ls - lt), 1 },
            false
        };
    }

    std::array<Vertex, 4> cubicVertices(CGPoint p0, CGPoint p1, CGPoint p2, CGPoint p3) {
        CGAL::Vector_3<K> b0(p0.x, p0.y, 1);
        CGAL::Vector_3<K> b1(p1.x, p1.y, 1);
        CGAL::Vector_3<K> b2(p3.x, p2.y, 1);
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

        Vertex a = { p0, { static_cast<float>(result.v0[0]), static_cast<float>(result.v0[1]), static_cast<float>(result.v0[2]), 0 } };
        Vertex b = { p1, { static_cast<float>(result.v1[0]), static_cast<float>(result.v1[1]), static_cast<float>(result.v1[2]), 0 } };
        Vertex c = { p2, { static_cast<float>(result.v2[0]), static_cast<float>(result.v2[1]), static_cast<float>(result.v2[2]), 0 } };
        Vertex d = { p3, { static_cast<float>(result.v3[0]), static_cast<float>(result.v3[1]), static_cast<float>(result.v3[2]), 0 } };
        return { a, b, c, d };
    }

    void insertCubicCurve(CDT::Vertex_handle& currentVertex, const CGPathElement& element) {
        auto p0 = CGPointMake(currentVertex->point().x(), currentVertex->point().y());
        auto p1 = element.points[0];
        auto p2 = element.points[1];
        auto p3 = element.points[2];
        auto newVertex = cdt.insert(CDT::Point(p3.x, p3.y));
        insertConstraint(currentVertex, newVertex);
        cubicCurves.push_back(cubicVertices(p0, p1, p2, p3));
    }

    void insert() {
        CDT::Vertex_handle currentVertex;
        CDT::Vertex_handle subpathBegin;
        iterateCGPath(path, [&](CGPathElement element) {
            switch (element.type) {
            case kCGPathElementMoveToPoint:
                currentVertex = cdt.insert(CDT::Point(element.points[0].x, element.points[0].y));
                subpathBegin = currentVertex;
                break;
            case kCGPathElementAddLineToPoint: {
                auto newVertex = cdt.insert(CDT::Point(element.points[0].x, element.points[0].y));
                insertConstraint(currentVertex, newVertex);
                currentVertex = newVertex;
                break;
            }
            case kCGPathElementAddQuadCurveToPoint: {
                insertQuadraticCurve(currentVertex, element);
                break;
            }
            case kCGPathElementAddCurveToPoint: {
                insertCubicCurve(currentVertex, element);
                break;
            }
            case kCGPathElementCloseSubpath:
                insertConstraint(currentVertex, subpathBegin);
                currentVertex = subpathBegin;
            }
        });
    }

    std::list<CDT::Edge> flood(CDT::Face_handle seed, unsigned depth) {
        std::list<CDT::Edge> result;
        std::queue<CDT::Face_handle> queue;
        queue.push(seed);
        while (!queue.empty()) {
            auto handle = queue.front();
            queue.pop();
            if (handle->info().getDepth())
                continue;
            handle->info().setDepth(depth);
            for (unsigned i = 0; i < 3; ++i) {
                CDT::Edge edge(handle, i);
                auto neighbor = handle->neighbor(i);
                if (neighbor->info().getDepth())
                    continue;
                if (cdt.is_constrained(edge))
                    result.push_back(edge);
                else
                    queue.push(neighbor);
            }
        }
        return result;
    }

    void mark() {
        auto border = flood(cdt.infinite_face(), 0);
        while (!border.empty()) {
            auto edge = border.front();
            border.pop_front();
            auto face = edge.first->neighbor(edge.second);
            if (!face->info().getDepth()) {
                auto next = flood(face, edge.first->info().getDepth().value() + 1);
                border.insert(border.end(), next.begin(), next.end());
            }
        }
    }

    void insertConstraint(CDT::Vertex_handle a, CDT::Vertex_handle b) {
        if (a != b)
            cdt.insert_constraint(a, b);
    }

    CDT cdt;
    std::vector<std::array<Vertex, 3>> quadraticCurves;
    std::vector<std::array<Vertex, 4>> cubicCurves;
    RetainPtr<CGPathRef> path;
};

void triangulate(CGPathRef path, TriangleReceiver triangleReceiver) {
    Triangulator(path).triangulate(triangleReceiver);
}

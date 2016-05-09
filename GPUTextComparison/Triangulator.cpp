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
            receiver({ cubicCurve[0], { 0, 0 } },
                     { cubicCurve[1], { 0, 0 } },
                     { cubicCurve[2], { 0, 0 } });
            receiver({ cubicCurve[2], { 0, 0 } },
                     { cubicCurve[3], { 0, 0 } },
                     { cubicCurve[0], { 0, 0 } });
        }
    }

private:
    void insertQuadraticCurve(CDT::Vertex_handle& currentVertex, const CGPathElement& element) {
        auto p0 = CGPointMake(currentVertex->point().x(), currentVertex->point().y());
        auto p1 = element.points[0];
        auto p2 = element.points[1];
        Vertex a = { p0, { 1, 1 } };
        Vertex b = { p1, { 1.5, 1 } };
        Vertex c = { p2, { 2, 2 } };
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
                auto p0 = CGPointMake(currentVertex->point().x(), currentVertex->point().y());
                auto p1 = element.points[0];
                auto p2 = element.points[1];
                auto p3 = element.points[2];
                auto newVertex = cdt.insert(CDT::Point(p3.x, p3.y));
                insertConstraint(currentVertex, newVertex);
                cubicCurves.push_back({ p0, p1, p2, p3 });
                currentVertex = newVertex;
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
    std::vector<std::array<CGPoint, 4>> cubicCurves;
    RetainPtr<CGPathRef> path;
};

void triangulate(CGPathRef path, TriangleReceiver triangleReceiver) {
    Triangulator(path).triangulate(triangleReceiver);
}

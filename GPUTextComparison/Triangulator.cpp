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
#include "CubicBeziers.h"

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

        return depth.get() % 2 == 1;
    }

private:
    boost::optional<unsigned> depth;
};

typedef CGAL::Exact_predicates_inexact_constructions_kernel      K;
typedef CGAL::Triangulation_vertex_base_2<K>                     Vb;
typedef CGAL::Triangulation_face_base_with_info_2<FaceInfo, K>  Fbb;
typedef CGAL::Constrained_triangulation_face_base_2<K, Fbb>      Fb;
typedef CGAL::Triangulation_data_structure_2<Vb, Fb>             TDS;
typedef CGAL::Exact_predicates_tag                               Itag;
typedef CGAL::Constrained_Delaunay_triangulation_2<K, TDS, Itag> CDT;

class Triangulator {
public:
    Triangulator(CGPathRef path) : path(path) {
        insert();
        mark();
    }

    void triangulate(CubicTriangleFaceReceiver receiver) {
        for (auto facesIterator = cdt.finite_faces_begin(); facesIterator != cdt.finite_faces_end(); ++facesIterator) {
            if (facesIterator->info().inside()) {
                auto p0 = facesIterator->vertex(0)->point();
                auto p1 = facesIterator->vertex(1)->point();
                auto p2 = facesIterator->vertex(2)->point();
                receiver({ CGPointMake(p0.x(), p0.y()), { 0, 1, 1 } },
                         { CGPointMake(p1.x(), p1.y()), { 0, 1, 1 } },
                         { CGPointMake(p2.x(), p2.y()), { 0, 1, 1 } });
            }
        }

        for (auto& cubicCurve : cubicFaces)
            receiver(cubicCurve[0], cubicCurve[1], cubicCurve[2]);
    }

private:
    void insertCubicCurve(CDT::Vertex_handle& currentVertex, CGPoint p1, CGPoint p2, CGPoint p3) {
        auto p0 = CGPointMake(currentVertex->point().x(), currentVertex->point().y());
        __block std::vector<boost::optional<CubicVertex>> insideBorder(8);
        __block std::vector<std::array<CubicTriangleVertex, 3>> localCubicFaces;
        bool degenerate = cubic(p0, p1, p2, p3, ^(CubicVertex v0, CubicVertex v1, CubicVertex v2) {
            if (v0.order >= 0)
                insideBorder[v0.order] = v0;
            if (v1.order >= 0)
                insideBorder[v1.order] = v1;
            if (v2.order >= 0)
                insideBorder[v2.order] = v2;
            localCubicFaces.push_back({{ { v0.point, v0.coefficient }, { v1.point, v1.coefficient }, { v2.point, v2.coefficient } }});
        });

        if (degenerate) {
            auto newVertex = cdt.insert(CDT::Point(p3.x, p3.y));
            insertConstraint(currentVertex, newVertex);
            currentVertex = newVertex;
            return;
        }

        for (auto v : localCubicFaces)
            cubicFaces.push_back(v);

        assert(insideBorder[0]);
        CDT::Vertex_handle newVertex;
        for (size_t i = 1; i < insideBorder.size(); ++i) {
            if (!insideBorder[i])
                break;
            newVertex = cdt.insert(CDT::Point(insideBorder[i].get().point.x, insideBorder[i].get().point.y));
            insertConstraint(currentVertex, newVertex);
            currentVertex = newVertex;
        }
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
                auto source = currentVertex->point();
                auto control = element.points[0];
                auto destination = element.points[1];
                auto cp1 = CGPointMake(source.x() + 2 * (control.x - source.x()) / 3, source.y() + 2 * (control.y - source.y()) / 3);
                auto cp2 = CGPointMake(destination.x + 2 * (control.x - destination.x) / 3, destination.y + 2 * (control.y - destination.y) / 3);
                insertCubicCurve(currentVertex, cp1, cp2, destination);
                break;
            }
            case kCGPathElementAddCurveToPoint: {
                insertCubicCurve(currentVertex, element.points[0], element.points[1], element.points[2]);
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
                auto next = flood(face, edge.first->info().getDepth().get() + 1);
                border.insert(border.end(), next.begin(), next.end());
            }
        }
    }

    void insertConstraint(CDT::Vertex_handle a, CDT::Vertex_handle b) {
        if (a != b)
            cdt.insert_constraint(a, b);
    }

    CDT cdt;
    std::vector<std::array<CubicTriangleVertex, 3>> cubicFaces;
    RetainPtr<CGPathRef> path;
};

void triangulate(CGPathRef path, CubicTriangleFaceReceiver receiver) {
    Triangulator(path).triangulate(receiver);
}

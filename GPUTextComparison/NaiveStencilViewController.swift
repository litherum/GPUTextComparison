//
//  DisplayViewController.swift
//  GPUTextComparison
//
//  Created by Litherum on 4/10/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

import Cocoa
import MetalKit

extension NaiveStencilViewController.GlyphCacheKey: Hashable {
    var hashValue: Int {
        let a = glyphID.hashValue
        let b = Int(CFHash(CTFontDescriptorCopyAttributes(CTFontCopyFontDescriptor(font))))
        //let b = Int(CFHash(font))
        return a ^ b
    }

    static func ==(lhs: NaiveStencilViewController.GlyphCacheKey, rhs: NaiveStencilViewController.GlyphCacheKey) -> Bool {
        return lhs.glyphID == rhs.glyphID && CFEqual(lhs.font, rhs.font)
    }

}


class NaiveStencilViewController: TextViewController, MTKViewDelegate {

    var device: MTLDevice! = nil

    var commandQueue: MTLCommandQueue! = nil
    var pipelineState: MTLRenderPipelineState! = nil
    var countDepthStencilState: MTLDepthStencilState! = nil
    var fillDepthStencilState: MTLDepthStencilState! = nil
    var vertexBuffers: [MTLBuffer] = []
    var fillVertexBuffer: MTLBuffer! = nil

    let inflightSemaphore = DispatchSemaphore(value : MaxBuffers)
    var bufferIndex = 0

    var frameCounter = 0

    struct GlyphCacheKey {
        let glyphID: CGGlyph
        let font: CTFont
    }

    struct GlyphCacheValue {
        var geometry: [Float]
    }

    var cache: [GlyphCacheKey : GlyphCacheValue] = [:]

    override func viewDidLoad() {

        super.viewDidLoad()

        device = MTLCreateSystemDefaultDevice()
        guard device != nil else {
            fatalError()
        }

        // setup view properties
        let view = self.view as! MTKView
        view.delegate = self
        view.device = device
        view.sampleCount = 1
        // .Depth32Float_Stencil8
        view.depthStencilPixelFormat = .depth32Float_stencil8
        view.clearStencil = 0
        loadAssets()
    }

    private func loadAssets() {
        // load any resources required for rendering
        let view = self.view as! MTKView
        commandQueue = device.makeCommandQueue()
        commandQueue.label = "main command queue"

        let defaultLibrary = device.makeDefaultLibrary()!
        let fragmentProgram = defaultLibrary.makeFunction(name:"stencilFragment")!
        let vertexProgram = defaultLibrary.makeFunction(name:"stencilVertex")!

        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.size * 2
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0

        let pipelineStateDescriptor = MTLRenderPipelineDescriptor()
        pipelineStateDescriptor.vertexFunction = vertexProgram
        pipelineStateDescriptor.fragmentFunction = fragmentProgram
        pipelineStateDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineStateDescriptor.sampleCount = view.sampleCount
        pipelineStateDescriptor.depthAttachmentPixelFormat = .depth32Float_stencil8
        pipelineStateDescriptor.stencilAttachmentPixelFormat = .depth32Float_stencil8
        pipelineStateDescriptor.vertexDescriptor = vertexDescriptor

        do {
            try pipelineState = device.makeRenderPipelineState(descriptor: pipelineStateDescriptor)
        } catch let error {
            fatalError("Failed to create pipeline state, error \(error)")
        }

        let countFrontFaceStencil = MTLStencilDescriptor()
        countFrontFaceStencil.stencilCompareFunction = .never
        countFrontFaceStencil.stencilFailureOperation = .incrementWrap

        let countBackFaceStencil = MTLStencilDescriptor()
        countBackFaceStencil.stencilCompareFunction = .never
        countBackFaceStencil.stencilFailureOperation = .decrementWrap

        let countDepthStencilDescriptor = MTLDepthStencilDescriptor()
        countDepthStencilDescriptor.frontFaceStencil = countFrontFaceStencil
        countDepthStencilDescriptor.backFaceStencil = countBackFaceStencil
        countDepthStencilState = device.makeDepthStencilState(descriptor: countDepthStencilDescriptor)

        let fillStencil = MTLStencilDescriptor()
        fillStencil.stencilCompareFunction = .notEqual

        let fillDepthStencilDescriptor = MTLDepthStencilDescriptor()
        fillDepthStencilDescriptor.frontFaceStencil = fillStencil
        fillDepthStencilDescriptor.backFaceStencil = fillStencil
        fillDepthStencilState = device.makeDepthStencilState(descriptor: fillDepthStencilDescriptor)

        let fillVertexData : [Float] = [
            0, 0,
            0, Float(view.bounds.height),
            Float(view.bounds.width), Float(view.bounds.height),

            Float(view.bounds.width), Float(view.bounds.height),
            Float(view.bounds.width), 0,
            0, 0
        ]
        fillVertexBuffer = device.makeBuffer(bytes: fillVertexData, length: MemoryLayout.size(ofValue: fillVertexData[0]) * fillVertexData.count, options: .storageModeManaged)
    }

    private func acquireVertexBuffer(usedBuffers: inout [MTLBuffer]) -> MTLBuffer {
        if vertexBuffers.isEmpty {
            let newBuffer = device.makeBuffer(length: VertexBufferSize, options: [])!
            usedBuffers.append(newBuffer)
            return newBuffer
        } else {
            let buffer = vertexBuffers.removeLast()
            usedBuffers.append(buffer)
            return buffer
        }
    }

    private func canAppendVertices(vertices: [Float], vertexBuffer: MTLBuffer, vertexBufferUtilization: Int) -> Bool {
        if vertexBufferUtilization + MemoryLayout<Float>.size * vertices.count > vertexBuffer.length {
            return false
        }
        return true
    }

    private func issueDraw(renderEncoder: MTLRenderCommandEncoder, vertexBuffer: inout MTLBuffer, vertexBufferUtilization: inout Int, usedVertexBuffers: inout [MTLBuffer], vertexCount: Int) {
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: 1)

        vertexBuffer = acquireVertexBuffer(&usedVertexBuffers)
        vertexBufferUtilization = 0
    }

    private class func interpolate(t: CGFloat, p0: CGPoint, p1: CGPoint) -> CGPoint {
        return CGPointMake(t * p1.x + (1 - t) * p0.x, t * p1.y + (1 - t) * p0.y)
    }

    private class func interpolateQuadraticBezier(t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint) -> CGPoint {
        let ab = NaiveStencilViewController.interpolate(t: t, p0: p0, p1: p1)
        let bc = NaiveStencilViewController.interpolate(t: t, p0: p1, p1: p2)
        return NaiveStencilViewController.interpolate(t: t, p0: ab, p1: bc)
    }

    private class func interpolateCubicBezier(t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) -> CGPoint {
        let ab = NaiveStencilViewController.interpolate(t: t, p0: p0, p1: p1)
        let bc = NaiveStencilViewController.interpolate(t: t, p0: p1, p1: p2)
        let cd = NaiveStencilViewController.interpolate(t: t, p0: p2, p1: p3)
        let abc = NaiveStencilViewController.interpolate(t: t, p0: ab, p1: bc)
        let bcd = NaiveStencilViewController.interpolate(t: t, p0: bc, p1: cd)
        return NaiveStencilViewController.interpolate(t: t, p0: abc, p1: bcd)
    }

    private class func approximatePath(path: CGPath) -> CGPath
    {
        let result = CGMutablePath()
        var currentPoint = CGPoint.zero
        var subpathBegin = CGPoint.zero
        let definition = 10
        iterateCGPath(path) {(element : CGPathElement) in
            switch element.type {
            case .moveToPoint:
//                result.move(to: element.points[0])
                CGPathMoveToPoint(result, nil, element.points[0].x, element.points[0].y)
                currentPoint = element.points[0]
                subpathBegin = currentPoint
            case .addLineToPoint:
                CGPathAddLineToPoint(result, nil, element.points[0].x, element.points[0].y)
                currentPoint = element.points[0]
            case .addQuadCurveToPoint:
                for i in 1 ... definition {
                    let intermediate = NaiveStencilViewController.interpolateQuadraticBezier(CGFloat(i) / CGFloat(definition), p0: currentPoint, p1: element.points[0], p2: element.points[1])
                    CGPathAddLineToPoint(result, nil, intermediate.x, intermediate.y)
                }
                currentPoint = element.points[1]
            case .addCurveToPoint:
                for i in 1 ... definition {
                    let intermediate = NaiveStencilViewController.interpolateCubicBezier(CGFloat(i) / CGFloat(definition), p0: currentPoint, p1: element.points[0], p2: element.points[1], p3: element.points[2])
                    CGPathAddLineToPoint(result, nil, intermediate.x, intermediate.y)
                }
                currentPoint = element.points[2]
            case .closeSubpath:
                CGPathAddLineToPoint(result, nil, subpathBegin.x, subpathBegin.y)
                currentPoint = subpathBegin
            }
        }
        return result
    }

    private class func generateGeometry(path: CGPath) -> [Float] {
        var result: [Float] = []
        var previousPoint : CGPoint?
        var subpathBegin = CGPoint.zero
        iterateCGPath(path) {(element : CGPathElement) in
            switch element.type {
            case .moveToPoint:
                subpathBegin = element.points[0]
                previousPoint = subpathBegin
            case .addLineToPoint:
                if let p = previousPoint {
                    result.append(0)
                    result.append(0)

                    result.append(Float(p.x))
                    result.append(Float(p.y))

                    result.append(Float(element.points[0].x))
                    result.append(Float(element.points[0].y))
                }
                previousPoint = element.points[0]
            case .addQuadCurveToPoint:
                fatalError()
            case .addCurveToPoint:
                fatalError()
            case .closeSubpath:
                if let p = previousPoint {
                    result.append(0)
                    result.append(0)

                    result.append(Float(p.x))
                    result.append(Float(p.y))

                    result.append(Float(subpathBegin.x))
                    result.append(Float(subpathBegin.y))
                }
                previousPoint = subpathBegin
            }
        }
        return result
    }

    func drawInMTKView(view: MTKView) {
        if frames.count == 0 {
            return
        }
        let slowness = 1
        if frameCounter >= frames.count * slowness {
            frameCounter = 0
        }
        let frame = frames[frameCounter / slowness]

        var usedVertexBuffers: [MTLBuffer] = []

        let commandBuffer = commandQueue.makeCommandBuffer()!

        guard let renderPassDescriptor = view.currentRenderPassDescriptor, let currentDrawable = view.currentDrawable else {
            return
        }

        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(countDepthStencilState)

        var vertexBuffer = acquireVertexBuffer(&usedVertexBuffers)
        var vertexBufferUtilization = 0

        for glyph in frame {
            // FIXME: Gracefully handle full geometry buffers

            let key = GlyphCacheKey(glyphID: glyph.glyphID, font: glyph.font)
            var geometry : [Float] = []
            if let cacheLookup = cache[key] {
                geometry = cacheLookup.geometry
            } else {
                if let glyphPath = CTFontCreatePathForGlyph(glyph.font, glyph.glyphID, nil) {
                    let approximatedPath = NaiveStencilViewController.approximatePath(glyphPath)
                    geometry = NaiveStencilViewController.generateGeometry(approximatedPath)
                }
                cache[key] = GlyphCacheValue(geometry: geometry)
            }

            if geometry.isEmpty {
                continue
            }

            assert(canAppendVertices(geometry, vertexBuffer: vertexBuffer, vertexBufferUtilization: vertexBufferUtilization))

            let pVertexData = vertexBuffer.contents()
            let vVertexData = UnsafeMutablePointer<Float>(pVertexData + vertexBufferUtilization)

            assert(geometry.count % 2 == 0)
            for i in 0 ..< geometry.count / 2 {
                vVertexData[i * 2] = geometry[i * 2] + Float(glyph.position.x)
                vVertexData[i * 2 + 1] = geometry[i * 2 + 1] + Float(glyph.position.y)
            }
            vertexBufferUtilization = vertexBufferUtilization + MemoryLayout.size(ofValue: geometry[0]) * geometry.count
        }

        issueDraw(renderEncoder, vertexBuffer: &vertexBuffer, vertexBufferUtilization: &vertexBufferUtilization, usedVertexBuffers: &usedVertexBuffers, vertexCount: vertexBufferUtilization / (MemoryLayout<Float>.size * 2))

        renderEncoder.setDepthStencilState(fillDepthStencilState)
        renderEncoder.setVertexBuffer(fillVertexBuffer, offset: 0, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)

        renderEncoder.endEncoding()
        commandBuffer.present(currentDrawable)

        commandBuffer.addCompletedHandler{ [weak self] commandBuffer in
            dispatch_async(dispatch_get_main_queue(), { [weak self] in
                if let strongSelf = self {
                    strongSelf.vertexBuffers.append(contentsOf:usedVertexBuffers)
                }
            })
        }

        commandBuffer.commit()

        frameCounter = frameCounter + 1
    }


    func mtkView(view: MTKView, drawableSizeWillChange size: CGSize) {

    }
}


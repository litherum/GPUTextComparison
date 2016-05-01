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
}

func ==(lhs: NaiveStencilViewController.GlyphCacheKey, rhs: NaiveStencilViewController.GlyphCacheKey) -> Bool {
    return lhs.glyphID == rhs.glyphID && CFEqual(lhs.font, rhs.font)
}

class NaiveStencilViewController: NSViewController, MTKViewDelegate {
    
    var device: MTLDevice! = nil
    
    var commandQueue: MTLCommandQueue! = nil
    var pipelineState: MTLRenderPipelineState! = nil
    var countDepthStencilState: MTLDepthStencilState! = nil
    var fillDepthStencilState: MTLDepthStencilState! = nil
    var vertexBuffers: [MTLBuffer] = []
    var stencilTextures: [MTLTexture] = []

    let inflightSemaphore = dispatch_semaphore_create(MaxBuffers)
    var bufferIndex = 0

    var frameCounter = 0

    struct GlyphCacheKey {
        let glyphID: CGGlyph
        let font: CTFont
    }

    struct GlyphCacheValue {
        var approximation: CGPath
    }

    var frames : [Frame] = []

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
        
        loadAssets()
    }

    private func createStencilTexture() -> MTLTexture {
        let textureWidth = Int(view.bounds.width)
        let textureHeight = Int(view.bounds.height)
        let textureDescriptor = MTLTextureDescriptor()
        textureDescriptor.pixelFormat = .Stencil8
        textureDescriptor.width = textureWidth
        textureDescriptor.height = textureHeight
        textureDescriptor.resourceOptions = .StorageModePrivate
        textureDescriptor.usage = .RenderTarget
        return device.newTextureWithDescriptor(textureDescriptor)
    }
    
    private func loadAssets() {
        // load any resources required for rendering
        let view = self.view as! MTKView
        commandQueue = device.newCommandQueue()
        commandQueue.label = "main command queue"
        
        let defaultLibrary = device.newDefaultLibrary()!
        let fragmentProgram = defaultLibrary.newFunctionWithName("stencilFragment")!
        let vertexProgram = defaultLibrary.newFunctionWithName("stencilVertex")!

        
        let pipelineStateDescriptor = MTLRenderPipelineDescriptor()
        pipelineStateDescriptor.vertexFunction = vertexProgram
        pipelineStateDescriptor.fragmentFunction = fragmentProgram
        pipelineStateDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineStateDescriptor.sampleCount = view.sampleCount
        pipelineStateDescriptor.stencilAttachmentPixelFormat = .Stencil8
        
        do {
            try pipelineState = device.newRenderPipelineStateWithDescriptor(pipelineStateDescriptor)
        } catch let error {
            fatalError("Failed to create pipeline state, error \(error)")
        }

        let countFrontFaceStencil = MTLStencilDescriptor()
        countFrontFaceStencil.stencilCompareFunction = .Never
        countFrontFaceStencil.stencilFailureOperation = .IncrementClamp

        let countBackFaceStencil = MTLStencilDescriptor()
        countBackFaceStencil.stencilCompareFunction = .Never
        countBackFaceStencil.depthStencilPassOperation = .DecrementClamp

        let countDepthStencilDescriptor = MTLDepthStencilDescriptor()
        countDepthStencilDescriptor.frontFaceStencil = countFrontFaceStencil
        countDepthStencilDescriptor.backFaceStencil = countBackFaceStencil
        countDepthStencilState = device.newDepthStencilStateWithDescriptor(countDepthStencilDescriptor)

        let fillFrontFaceStencil = MTLStencilDescriptor()
        fillFrontFaceStencil.stencilCompareFunction = .Equal

        let fillBackFaceStencil = MTLStencilDescriptor()
        fillBackFaceStencil.stencilCompareFunction = .Equal

        let fillDepthStencilDescriptor = MTLDepthStencilDescriptor()
        fillDepthStencilDescriptor.frontFaceStencil = fillFrontFaceStencil
        fillDepthStencilDescriptor.backFaceStencil = fillBackFaceStencil
        fillDepthStencilState = device.newDepthStencilStateWithDescriptor(fillDepthStencilDescriptor)
    }

    private func acquireVertexBuffer(inout usedBuffers: [MTLBuffer]) -> MTLBuffer {
        if vertexBuffers.isEmpty {
            let newBuffer = device.newBufferWithLength(VertexBufferSize, options: [])
            usedBuffers.append(newBuffer)
            return newBuffer
        } else {
            let buffer = vertexBuffers.removeLast()
            usedBuffers.append(buffer)
            return buffer
        }
    }

    private func acquireStencilBuffer() -> MTLTexture {
        if stencilTextures.isEmpty {
            return createStencilTexture()
        } else {
            return stencilTextures.removeLast()
        }
    }

    private func canAppendVertices(vertices: [Float], vertexBuffer: MTLBuffer, vertexBufferUtilization: Int) -> Bool {
        if vertexBufferUtilization + sizeof(Float) * vertices.count > vertexBuffer.length {
            return false
        }
        return true
    }

    private func appendSimplifiedPath(path: CGPath, position: CGPoint, vertexBuffer: MTLBuffer, inout vertexBufferUtilization: Int) {
        var newVertices: [Float] = []
        var previousPoint : CGPoint?
        var subpathBegin = CGPointZero
        iterateCGPath(path) {(element : CGPathElement) in
            switch element.type {
            case .MoveToPoint:
                subpathBegin = element.points[0]
                previousPoint = subpathBegin
            case .AddLineToPoint:
                if let p = previousPoint {
                    newVertices.append(Float(0 + position.x))
                    newVertices.append(Float(0 + position.y))

                    newVertices.append(Float(p.x + position.x))
                    newVertices.append(Float(p.y + position.y))

                    newVertices.append(Float(element.points[0].x + position.x))
                    newVertices.append(Float(element.points[0].y + position.y))
                }
                previousPoint = element.points[0]
            case .AddQuadCurveToPoint:
                fatalError()
            case .AddCurveToPoint:
                fatalError()
            case .CloseSubpath:
                if let p = previousPoint {
                    newVertices.append(Float(0 + position.x))
                    newVertices.append(Float(0 + position.y))

                    newVertices.append(Float(p.x + position.x))
                    newVertices.append(Float(p.y + position.y))

                    newVertices.append(Float(subpathBegin.x + position.x))
                    newVertices.append(Float(subpathBegin.y + position.y))
                }
                previousPoint = subpathBegin
            }
        }
        
        assert(canAppendVertices(newVertices, vertexBuffer: vertexBuffer, vertexBufferUtilization: vertexBufferUtilization))

        let pVertexData = vertexBuffer.contents()
        let vVertexData = UnsafeMutablePointer<Float>(pVertexData + vertexBufferUtilization)
        
        vVertexData.initializeFrom(newVertices)
        vertexBufferUtilization = vertexBufferUtilization + sizeofValue(newVertices[0]) * newVertices.count
    }

    private func issueDraw(renderEncoder: MTLRenderCommandEncoder, inout vertexBuffer: MTLBuffer, inout vertexBufferUtilization: Int, inout usedVertexBuffers: [MTLBuffer], vertexCount: Int) {
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, atIndex: 0)
        renderEncoder.drawPrimitives(.Triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: 1)

        vertexBuffer = acquireVertexBuffer(&usedVertexBuffers)
        vertexBufferUtilization = 0
    }

    private class func interpolate(t: CGFloat, p0: CGPoint, p1: CGPoint) -> CGPoint {
        return CGPointMake(t * p1.x + (1 - t) * p0.x, t * p1.y + (1 - t) * p0.y)
    }

    private class func interpolateQuadraticBezier(t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint) -> CGPoint {
        let ab = NaiveStencilViewController.interpolate(t, p0: p0, p1: p1)
        let bc = NaiveStencilViewController.interpolate(t, p0: p1, p1: p2)
        return NaiveStencilViewController.interpolate(t, p0: ab, p1: bc)
    }

    private class func interpolateCubicBezier(t: CGFloat, p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) -> CGPoint {
        let ab = NaiveStencilViewController.interpolate(t, p0: p0, p1: p1)
        let bc = NaiveStencilViewController.interpolate(t, p0: p1, p1: p2)
        let cd = NaiveStencilViewController.interpolate(t, p0: p2, p1: p3)
        let abc = NaiveStencilViewController.interpolate(t, p0: ab, p1: bc)
        let bcd = NaiveStencilViewController.interpolate(t, p0: bc, p1: cd)
        return NaiveStencilViewController.interpolate(t, p0: abc, p1: bcd)
    }

    private class func approximatePath(path: CGPath) -> CGPath
    {
        let result = CGPathCreateMutable()
        var currentPoint = CGPointZero
        var subpathBegin = CGPointZero
        let definition = 10
        iterateCGPath(path) {(element : CGPathElement) in
            switch element.type {
            case .MoveToPoint:
                CGPathMoveToPoint(result, nil, element.points[0].x, element.points[0].y)
                currentPoint = element.points[0]
                subpathBegin = currentPoint
            case .AddLineToPoint:
                CGPathAddLineToPoint(result, nil, element.points[0].x, element.points[0].y)
                currentPoint = element.points[0]
            case .AddQuadCurveToPoint:
                for i in 1 ... definition {
                    let intermediate = NaiveStencilViewController.interpolateQuadraticBezier(CGFloat(i) / CGFloat(definition), p0: currentPoint, p1: element.points[0], p2: element.points[1])
                    CGPathAddLineToPoint(result, nil, intermediate.x, intermediate.y)
                }
                currentPoint = element.points[1]
            case .AddCurveToPoint:
                for i in 1 ... definition {
                    let intermediate = NaiveStencilViewController.interpolateCubicBezier(CGFloat(i) / CGFloat(definition), p0: currentPoint, p1: element.points[0], p2: element.points[1], p3: element.points[2])
                    CGPathAddLineToPoint(result, nil, intermediate.x, intermediate.y)
                }
                currentPoint = element.points[2]
            case .CloseSubpath:
                CGPathAddLineToPoint(result, nil, subpathBegin.x, subpathBegin.y)
                currentPoint = subpathBegin
            }
        }
        return result
    }
    
    func drawInMTKView(view: MTKView) {
        if frames.count == 0 {
            return
        }
        let slowness = 10000000
        if frameCounter >= frames.count * slowness {
            frameCounter = 0
        }
        let frame = frames[frameCounter / slowness]

        var usedVertexBuffers: [MTLBuffer] = []

        let commandBuffer = commandQueue.commandBuffer()

        guard let renderPassDescriptor = view.currentRenderPassDescriptor, currentDrawable = view.currentDrawable else {
            return
        }

        let usedStencilBuffer = acquireStencilBuffer()
        renderPassDescriptor.stencilAttachment.texture = usedStencilBuffer
        renderPassDescriptor.stencilAttachment.loadAction = .Clear
        let renderEncoder = commandBuffer.renderCommandEncoderWithDescriptor(renderPassDescriptor)
        renderEncoder.setRenderPipelineState(pipelineState)
        renderEncoder.setDepthStencilState(fillDepthStencilState)

        var vertexBuffer = acquireVertexBuffer(&usedVertexBuffers)
        var vertexBufferUtilization = 0

        for glyph in frame {
            // FIXME: Gracefully handle full geometry buffers

            let key = GlyphCacheKey(glyphID: glyph.glyphID, font: glyph.font)
            var approximatedPath : CGPath!
            if let cacheLookup = cache[key] {
                approximatedPath = cacheLookup.approximation
            } else {
                if let glyphPath = CTFontCreatePathForGlyph(glyph.font, glyph.glyphID, nil) {
                    approximatedPath = NaiveStencilViewController.approximatePath(glyphPath)
                    cache[key] = GlyphCacheValue(approximation: approximatedPath)
                }
            }

            if approximatedPath == nil || CGPathGetBoundingBox(approximatedPath) == CGRectZero {
                continue
            }

            appendSimplifiedPath(approximatedPath, position: glyph.position, vertexBuffer: vertexBuffer, vertexBufferUtilization: &vertexBufferUtilization)
        }
        issueDraw(renderEncoder, vertexBuffer: &vertexBuffer, vertexBufferUtilization: &vertexBufferUtilization, usedVertexBuffers: &usedVertexBuffers, vertexCount: vertexBufferUtilization / (sizeof(Float) * 2))

        renderEncoder.endEncoding()
        commandBuffer.presentDrawable(currentDrawable)

        commandBuffer.addCompletedHandler{ [weak self] commandBuffer in
            dispatch_async(dispatch_get_main_queue(), { [weak self] in
                if let strongSelf = self {
                    strongSelf.vertexBuffers.appendContentsOf(usedVertexBuffers)
                    strongSelf.stencilTextures.append(usedStencilBuffer)
                }
            })
        }

        commandBuffer.commit()

        frameCounter = frameCounter + 1
    }
    
    
    func mtkView(view: MTKView, drawableSizeWillChange size: CGSize) {
        
    }
}


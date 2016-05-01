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
    var vertexBuffers: [MTLBuffer] = []

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
        
        do {
            try pipelineState = device.newRenderPipelineStateWithDescriptor(pipelineStateDescriptor)
        } catch let error {
            fatalError("Failed to create pipeline state, error \(error)")
        }
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

    private class func approximatePath(path: CGPath) -> CGPath
    {
        let result = CGPathCreateMutable()
        var currentPoint = CGPointZero
        var subpathBegin = CGPointZero
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
                CGPathAddLineToPoint(result, nil, element.points[1].x, element.points[1].y)
                currentPoint = element.points[1]
            case .AddCurveToPoint:
                CGPathAddLineToPoint(result, nil, element.points[2].x, element.points[2].y)
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
        let renderEncoder = commandBuffer.renderCommandEncoderWithDescriptor(renderPassDescriptor)
        renderEncoder.setRenderPipelineState(pipelineState)

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
                }
            })
        }

        commandBuffer.commit()

        frameCounter = frameCounter + 1
    }
    
    
    func mtkView(view: MTKView, drawableSizeWillChange size: CGSize) {
        
    }
}


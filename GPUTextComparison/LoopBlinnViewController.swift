//
//  LoopBlinnViewController.swift
//  GPUTextComparison
//
//  Created by Litherum on 5/7/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

import Cocoa
import MetalKit

let CoefficientBufferSize = 1024*1024

extension LoopBlinnViewController.GlyphCacheKey: Hashable {
    var hashValue: Int {
        let a = glyphID.hashValue
        let b = Int(CFHash(CTFontDescriptorCopyAttributes(CTFontCopyFontDescriptor(font))))
        //let b = Int(CFHash(font))
        return a ^ b
    }
}

func ==(lhs: LoopBlinnViewController.GlyphCacheKey, rhs: LoopBlinnViewController.GlyphCacheKey) -> Bool {
    return lhs.glyphID == rhs.glyphID && CFEqual(lhs.font, rhs.font)
}

class LoopBlinnViewController: TextViewController, MTKViewDelegate {
    
    var device: MTLDevice! = nil
    
    var commandQueue: MTLCommandQueue! = nil
    var pipelineState: MTLRenderPipelineState! = nil
    var vertexBuffers: [MTLBuffer] = []
    var coefficientBuffers: [MTLBuffer] = []
    
    let inflightSemaphore = dispatch_semaphore_create(MaxBuffers)
    var bufferIndex = 0
    
    var frameCounter = 0
    
    struct GlyphCacheKey {
        let glyphID: CGGlyph
        let font: CTFont
    }
    
    struct GlyphCacheValue {
        var positions: [Float]
        var coefficients: [Float]
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
        loadAssets()
    }
    
    private func loadAssets() {
        // load any resources required for rendering
        let view = self.view as! MTKView
        commandQueue = device.newCommandQueue()
        commandQueue.label = "main command queue"
        
        let defaultLibrary = device.newDefaultLibrary()!
        let fragmentProgram = defaultLibrary.newFunctionWithName("loopBlinnFragment")!
        let vertexProgram = defaultLibrary.newFunctionWithName("loopBlinnVertex")!
        
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.layouts[0].stride = sizeof(Float) * 2
        vertexDescriptor.layouts[1].stride = sizeof(Float) * 4
        vertexDescriptor.attributes[0].format = .Float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .Float4
        vertexDescriptor.attributes[1].offset = 0
        vertexDescriptor.attributes[1].bufferIndex = 1
        
        let pipelineStateDescriptor = MTLRenderPipelineDescriptor()
        pipelineStateDescriptor.vertexFunction = vertexProgram
        pipelineStateDescriptor.fragmentFunction = fragmentProgram
        pipelineStateDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineStateDescriptor.sampleCount = view.sampleCount
        pipelineStateDescriptor.vertexDescriptor = vertexDescriptor
        
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
    
    private func acquireCoefficientBuffer(inout usedBuffers: [MTLBuffer]) -> MTLBuffer {
        if coefficientBuffers.isEmpty {
            let newBuffer = device.newBufferWithLength(CoefficientBufferSize, options: [])
            usedBuffers.append(newBuffer)
            return newBuffer
        } else {
            let buffer = coefficientBuffers.removeLast()
            usedBuffers.append(buffer)
            return buffer
        }
    }
    
    private func canAppendVertices(verticesCount: Int, coefficientsCount: Int, vertexBuffer: MTLBuffer, vertexBufferUtilization: Int, coefficientBuffer: MTLBuffer, coefficientBufferUtilization: Int) -> Bool {
        if vertexBufferUtilization + sizeof(Float) * verticesCount > vertexBuffer.length {
            return false
        }
        if coefficientBufferUtilization + sizeof(Float) * coefficientsCount > coefficientBuffer.length {
            return false
        }
        return true
    }

    private func appendVertices(glyph: Glyph, positions: [Float], coefficients: [Float], vertexBuffer: MTLBuffer, inout vertexBufferUtilization: Int, coefficientBuffer: MTLBuffer, inout coefficientBufferUtilization: Int) {
        assert(canAppendVertices(positions.count, coefficientsCount: coefficients.count, vertexBuffer: vertexBuffer, vertexBufferUtilization: vertexBufferUtilization, coefficientBuffer: coefficientBuffer, coefficientBufferUtilization: coefficientBufferUtilization))
        
        let pVertexData = vertexBuffer.contents()
        let vVertexData = UnsafeMutablePointer<Float>(pVertexData + vertexBufferUtilization)
        
        assert(positions.count % 2 == 0)
        for i in 0 ..< positions.count / 2 {
            vVertexData[i * 2] = positions[i * 2] + Float(glyph.position.x)
            vVertexData[i * 2 + 1] = positions[i * 2 + 1] + Float(glyph.position.y)
        }
        vertexBufferUtilization = vertexBufferUtilization + sizeofValue(positions[0]) * positions.count
        
        let pCoefficientData = coefficientBuffer.contents()
        let vCoefficientData = UnsafeMutablePointer<Float>(pCoefficientData + coefficientBufferUtilization)
        
        assert(coefficients.count % 2 == 0)
        for i in 0 ..< coefficients.count {
            vCoefficientData[i] = coefficients[i]
        }
        coefficientBufferUtilization = coefficientBufferUtilization + sizeofValue(coefficients[0]) * coefficients.count
    }
    
    private func issueDraw(renderEncoder: MTLRenderCommandEncoder, inout vertexBuffer: MTLBuffer, inout vertexBufferUtilization: Int, inout usedVertexBuffers: [MTLBuffer], inout coefficientBuffer: MTLBuffer, inout coefficientBufferUtilization: Int, inout usedCoefficientBuffers: [MTLBuffer], vertexCount: Int) {
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, atIndex: 0)
        renderEncoder.setVertexBuffer(coefficientBuffer, offset:0, atIndex: 1)
        renderEncoder.drawPrimitives(.Triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: 1)
        
        vertexBuffer = acquireVertexBuffer(&usedVertexBuffers)
        vertexBufferUtilization = 0
        coefficientBuffer = acquireCoefficientBuffer(&usedCoefficientBuffers)
        coefficientBufferUtilization = 0
    }

    func drawInMTKView(view: MTKView) {
        if frames.count == 0 {
            return
        }
        let slowness = 100000000000
        if frameCounter >= frames.count * slowness {
            frameCounter = 0
        }
        let frame = frames[frameCounter / slowness]
        
        var usedVertexBuffers: [MTLBuffer] = []
        var usedCoefficientBuffers: [MTLBuffer] = []
        
        let commandBuffer = commandQueue.commandBuffer()
        
        guard let renderPassDescriptor = view.currentRenderPassDescriptor, currentDrawable = view.currentDrawable else {
            return
        }
        
        let renderEncoder = commandBuffer.renderCommandEncoderWithDescriptor(renderPassDescriptor)
        renderEncoder.setRenderPipelineState(pipelineState)
        
        var vertexBuffer = acquireVertexBuffer(&usedVertexBuffers)
        var vertexBufferUtilization = 0
        var coefficientBuffer = acquireCoefficientBuffer(&usedCoefficientBuffers)
        var coefficientBufferUtilization = 0
        
        for glyph in frame {
            // FIXME: Gracefully handle full geometry buffers

            let key = GlyphCacheKey(glyphID: glyph.glyphID, font: glyph.font)
            var positions : [Float] = []
            var coefficients : [Float] = []
            if let cacheLookup = cache[key] {
                positions = cacheLookup.positions
                coefficients = cacheLookup.coefficients
            } else {
                if let path = CTFontCreatePathForGlyph(glyph.font, glyph.glyphID, nil) {
                    triangulate(path) { (vertex0, vertex1, vertex2) in
                        positions.append(Float(vertex0.position.x))
                        positions.append(Float(vertex0.position.y))
                        positions.append(Float(vertex1.position.x))
                        positions.append(Float(vertex1.position.y))
                        positions.append(Float(vertex2.position.x))
                        positions.append(Float(vertex2.position.y))
                        coefficients.append(Float(vertex0.coefficient.x))
                        coefficients.append(Float(vertex0.coefficient.y))
                        coefficients.append(Float(vertex0.coefficient.z))
                        coefficients.append(Float(vertex0.coefficient.w))
                        coefficients.append(Float(vertex1.coefficient.x))
                        coefficients.append(Float(vertex1.coefficient.y))
                        coefficients.append(Float(vertex1.coefficient.z))
                        coefficients.append(Float(vertex1.coefficient.w))
                        coefficients.append(Float(vertex2.coefficient.x))
                        coefficients.append(Float(vertex2.coefficient.y))
                        coefficients.append(Float(vertex2.coefficient.z))
                        coefficients.append(Float(vertex2.coefficient.w))
                    }
                }
                cache[key] = GlyphCacheValue(positions: positions, coefficients: coefficients)
            }
            
            if positions.isEmpty || coefficients.isEmpty {
                continue
            }

            appendVertices(glyph, positions: positions, coefficients: coefficients, vertexBuffer: vertexBuffer, vertexBufferUtilization: &vertexBufferUtilization, coefficientBuffer: coefficientBuffer, coefficientBufferUtilization: &coefficientBufferUtilization)
        }
        
        issueDraw(renderEncoder, vertexBuffer: &vertexBuffer, vertexBufferUtilization: &vertexBufferUtilization, usedVertexBuffers: &usedVertexBuffers, coefficientBuffer: &coefficientBuffer, coefficientBufferUtilization: &coefficientBufferUtilization, usedCoefficientBuffers: &usedCoefficientBuffers, vertexCount: vertexBufferUtilization / (sizeof(Float) * 2))
        
        renderEncoder.endEncoding()
        commandBuffer.presentDrawable(currentDrawable)
        
        commandBuffer.addCompletedHandler{ [weak self] commandBuffer in
            dispatch_async(dispatch_get_main_queue(), { [weak self] in
                if let strongSelf = self {
                    strongSelf.vertexBuffers.appendContentsOf(usedVertexBuffers)
                    strongSelf.coefficientBuffers.appendContentsOf(usedCoefficientBuffers)
                }
            })
        }
        
        commandBuffer.commit()
        
        frameCounter = frameCounter + 1
    }

    func mtkView(view: MTKView, drawableSizeWillChange size: CGSize) {
        
    }
}


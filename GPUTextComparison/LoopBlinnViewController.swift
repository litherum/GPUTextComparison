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

    static func ==(lhs: LoopBlinnViewController.GlyphCacheKey, rhs: LoopBlinnViewController.GlyphCacheKey) -> Bool {
        return lhs.glyphID == rhs.glyphID && CFEqual(lhs.font, rhs.font)
    }
}


class LoopBlinnViewController: TextViewController, MTKViewDelegate {

    var device: MTLDevice! = nil

    var commandQueue: MTLCommandQueue! = nil
    var pipelineState: MTLRenderPipelineState! = nil
    var vertexBuffers: [MTLBuffer] = []
    var coefficientBuffers: [MTLBuffer] = []

    let inflightSemaphore = DispatchSemaphore(value: MaxBuffers)
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
        commandQueue = device.makeCommandQueue()
        commandQueue.label = "main command queue"

        let defaultLibrary = device.makeDefaultLibrary()!
        let fragmentProgram = defaultLibrary.makeFunction(name: "loopBlinnFragment")!
        let vertexProgram = defaultLibrary.makeFunction(name: "loopBlinnVertex")!

        let vertexDescriptor = MTLVertexDescriptor()

        vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.size * 2
        vertexDescriptor.layouts[1].stride = MemoryLayout<Float>.size * 4
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float4
        vertexDescriptor.attributes[1].offset = 0
        vertexDescriptor.attributes[1].bufferIndex = 1

        let pipelineStateDescriptor = MTLRenderPipelineDescriptor()
        pipelineStateDescriptor.vertexFunction = vertexProgram
        pipelineStateDescriptor.fragmentFunction = fragmentProgram
        pipelineStateDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineStateDescriptor.sampleCount = view.sampleCount
        pipelineStateDescriptor.vertexDescriptor = vertexDescriptor

        do {
            try pipelineState = device.makeRenderPipelineState(descriptor: pipelineStateDescriptor)
        } catch let error {
            fatalError("Failed to create pipeline state, error \(error)")
        }
    }

    private func acquireVertexBuffer( usedBuffers: inout [MTLBuffer]) -> MTLBuffer {
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

    private func acquireCoefficientBuffer(usedBuffers: inout [MTLBuffer]) -> MTLBuffer {
        if coefficientBuffers.isEmpty {
            let newBuffer = device.makeBuffer(length: CoefficientBufferSize, options: [])!
            usedBuffers.append(newBuffer)
            return newBuffer
        } else {
            let buffer = coefficientBuffers.removeLast()
            usedBuffers.append(buffer)
            return buffer
        }
    }

    private func canAppendVertices(verticesCount: Int, coefficientsCount: Int, vertexBuffer: MTLBuffer, vertexBufferUtilization: Int, coefficientBuffer: MTLBuffer, coefficientBufferUtilization: Int) -> Bool {
        if vertexBufferUtilization + MemoryLayout<Float>.size * verticesCount > vertexBuffer.length {
            return false
        }
        if coefficientBufferUtilization + MemoryLayout<Float>.size * coefficientsCount > coefficientBuffer.length {
            return false
        }
        return true
    }

    private func appendVertices(glyph: Glyph,
                                positions: [Float],
                                coefficients: [Float],
                                vertexBuffer: MTLBuffer,
                                vertexBufferUtilization: inout Int,
                                coefficientBuffer: MTLBuffer,
                                coefficientBufferUtilization: inout Int) {
        assert(canAppendVertices(verticesCount: positions.count, coefficientsCount: coefficients.count, vertexBuffer: vertexBuffer, vertexBufferUtilization: vertexBufferUtilization, coefficientBuffer: coefficientBuffer, coefficientBufferUtilization: coefficientBufferUtilization))

        let pVertexData = vertexBuffer.contents()

        let vVertexData = pVertexData.assumingMemoryBound(to: Float.self).advanced(by: vertexBufferUtilization)

        assert(positions.count % 2 == 0)
        for i in 0 ..< positions.count / 2 {
            vVertexData[i * 2] = positions[i * 2] + Float(glyph.position.x)
            vVertexData[i * 2 + 1] = positions[i * 2 + 1] + Float(glyph.position.y)
        }
        vertexBufferUtilization = vertexBufferUtilization + MemoryLayout.size(ofValue: positions[0]) * positions.count

        let pCoefficientData = coefficientBuffer.contents()
        let vCoefficientData = pCoefficientData.assumingMemoryBound(to: Float.self).advanced(by: vertexBufferUtilization)

        assert(coefficients.count % 2 == 0)
        for i in 0 ..< coefficients.count {
            vCoefficientData[i] = coefficients[i]
        }
        coefficientBufferUtilization = coefficientBufferUtilization + MemoryLayout.size(ofValue: coefficients[0]) * coefficients.count
    }

    private func issueDraw(renderEncoder: MTLRenderCommandEncoder,
                           vertexBuffer: inout MTLBuffer,
                           vertexBufferUtilization: inout Int,
                           usedVertexBuffers: inout [MTLBuffer],
                           coefficientBuffer: inout MTLBuffer,
                           coefficientBufferUtilization: inout Int,
                           usedCoefficientBuffers: inout [MTLBuffer],
                           vertexCount: Int) {
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(coefficientBuffer, offset:0, index: 1)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: 1)

        vertexBuffer = acquireVertexBuffer(usedBuffers: &usedVertexBuffers)
        vertexBufferUtilization = 0
        coefficientBuffer = acquireCoefficientBuffer(usedBuffers: &usedCoefficientBuffers)
        coefficientBufferUtilization = 0
    }
    var t = 0

    func draw(in view: MTKView) {
        if frames.count == 0 {
            return
        }
        let slowness = 1
        if frameCounter >= frames.count * slowness {
            frameCounter = 0
        }
        let frame = frames[frameCounter / slowness]

        var usedVertexBuffers: [MTLBuffer] = []
        var usedCoefficientBuffers: [MTLBuffer] = []

        let commandBuffer = commandQueue.makeCommandBuffer()!

        guard let renderPassDescriptor = view.currentRenderPassDescriptor, let currentDrawable = view.currentDrawable else {
            return
        }

        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
        renderEncoder.setRenderPipelineState(pipelineState)

        var vertexBuffer = acquireVertexBuffer(usedBuffers: &usedVertexBuffers)
        var vertexBufferUtilization = 0
        var coefficientBuffer = acquireCoefficientBuffer(usedBuffers: &usedCoefficientBuffers)
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
                        positions.append(Float(vertex0.point.x))
                        positions.append(Float(vertex0.point.y))
                        positions.append(Float(vertex1.point.x))
                        positions.append(Float(vertex1.point.y))
                        positions.append(Float(vertex2.point.x))
                        positions.append(Float(vertex2.point.y))
                        coefficients.append(vertex0.coefficient.x)
                        coefficients.append(vertex0.coefficient.y)
                        coefficients.append(vertex0.coefficient.z)
                        coefficients.append(0)
                        coefficients.append(vertex1.coefficient.x)
                        coefficients.append(vertex1.coefficient.y)
                        coefficients.append(vertex1.coefficient.z)
                        coefficients.append(0)
                        coefficients.append(vertex2.coefficient.x)
                        coefficients.append(vertex2.coefficient.y)
                        coefficients.append(vertex2.coefficient.z)
                        coefficients.append(0)
                    }
                }
                cache[key] = GlyphCacheValue(positions: positions, coefficients: coefficients)
            }

            if positions.isEmpty || coefficients.isEmpty {
                continue
            }

            appendVertices(glyph: glyph, positions: positions, coefficients: coefficients, vertexBuffer: vertexBuffer, vertexBufferUtilization: &vertexBufferUtilization, coefficientBuffer: coefficientBuffer, coefficientBufferUtilization: &coefficientBufferUtilization)
        }

        issueDraw(renderEncoder: renderEncoder, vertexBuffer: &vertexBuffer, vertexBufferUtilization: &vertexBufferUtilization, usedVertexBuffers: &usedVertexBuffers, coefficientBuffer: &coefficientBuffer, coefficientBufferUtilization: &coefficientBufferUtilization, usedCoefficientBuffers: &usedCoefficientBuffers, vertexCount: vertexBufferUtilization / (MemoryLayout<Float>.size * 2))

        renderEncoder.endEncoding()
        commandBuffer.present(currentDrawable)

        commandBuffer.addCompletedHandler{ [weak self] commandBuffer in
            DispatchQueue.main.async {
                [weak self] in
                if let strongSelf = self {
                    strongSelf.vertexBuffers.append(contentsOf:usedVertexBuffers)
                    strongSelf.coefficientBuffers.append(contentsOf:usedCoefficientBuffers)
                }
            }
        }

        commandBuffer.commit()

        frameCounter = frameCounter + 1
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {

    }
}


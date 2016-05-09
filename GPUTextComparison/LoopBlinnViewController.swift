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

class LoopBlinnViewController: TextViewController, MTKViewDelegate {
    
    var device: MTLDevice! = nil
    
    var commandQueue: MTLCommandQueue! = nil
    var pipelineState: MTLRenderPipelineState! = nil
    var vertexBuffers: [MTLBuffer] = []
    var coefficientBuffers: [MTLBuffer] = []
    
    let inflightSemaphore = dispatch_semaphore_create(MaxBuffers)
    var bufferIndex = 0
    
    var frameCounter = 0
    
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
        vertexDescriptor.layouts[1].stride = sizeof(Float) * 2
        vertexDescriptor.attributes[0].format = .Float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .Float2
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
    
    /*private func canAppendVertices(vertexBuffer: MTLBuffer, vertexBufferUtilization: Int, coefficientBuffer: MTLBuffer, coefficientBufferUtilization: Int) -> Bool {
     if vertexBufferUtilization + sizeof(Float) * 2 * 3 * 2 > vertexBuffer.length {
     return false
     }
     if coefficientBufferUtilization + sizeof(Float) * 2 * 3 * 2 > coefficientBuffer.length {
     return false
     }
     return true
     }*/
    
    private func appendQuad(positionRect: CGRect, textureRect: CGRect, vertexBuffer: MTLBuffer, inout vertexBufferUtilization: Int, textureCoordinateBuffer: MTLBuffer, inout textureCoordinateBufferUtilization: Int) {
        //assert(canAppendQuad(vertexBuffer, vertexBufferUtilization: vertexBufferUtilization, textureCoordinateBuffer: textureCoordinateBuffer, textureCoordinateBufferUtilization: textureCoordinateBufferUtilization))
        
        let pVertexData = vertexBuffer.contents()
        let vVertexData = UnsafeMutablePointer<Float>(pVertexData + vertexBufferUtilization)
        let newVertices: [Float] =
            [
                Float(positionRect.origin.x), Float(positionRect.origin.y),
                Float(positionRect.origin.x), Float(positionRect.maxY),
                Float(positionRect.maxX), Float(positionRect.maxY),
                
                Float(positionRect.maxX), Float(positionRect.maxY),
                Float(positionRect.maxX), Float(positionRect.origin.y),
                Float(positionRect.origin.x), Float(positionRect.origin.y),
                ]
        
        vVertexData.initializeFrom(newVertices)
        vertexBufferUtilization = vertexBufferUtilization + sizeofValue(newVertices[0]) * 2 * 3 * 2
        
        let pTextureCoordinateData = textureCoordinateBuffer.contents()
        let vTextureCoordinateData = UnsafeMutablePointer<Float>(pTextureCoordinateData + textureCoordinateBufferUtilization)
        let newTextureCoordinates: [Float] =
            [
                Float(textureRect.origin.x), Float(textureRect.maxY),
                Float(textureRect.origin.x), Float(textureRect.origin.y),
                Float(textureRect.maxX), Float(textureRect.origin.y),
                
                Float(textureRect.maxX), Float(textureRect.origin.y),
                Float(textureRect.maxX), Float(textureRect.maxY),
                Float(textureRect.origin.x), Float(textureRect.maxY),
                ]
        
        vTextureCoordinateData.initializeFrom(newTextureCoordinates)
        textureCoordinateBufferUtilization = textureCoordinateBufferUtilization + sizeofValue(newTextureCoordinates[0]) * 2 * 3 * 2
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
        let slowness = 10000000000
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

            guard let path = CTFontCreatePathForGlyph(glyph.font, glyph.glyphID, nil) else {
                continue
            }

            triangulate(path) { (vertex0, vertex1, vertex2) in
                let pVertexData = vertexBuffer.contents()
                let vVertexData = UnsafeMutablePointer<Float>(pVertexData + vertexBufferUtilization)

                let initialVertexData: [Float] = [
                    Float(glyph.position.x + vertex0.position.x), Float(glyph.position.y + vertex0.position.y),
                    Float(glyph.position.x + vertex1.position.x), Float(glyph.position.y + vertex1.position.y),
                    Float(glyph.position.x + vertex2.position.x), Float(glyph.position.y + vertex2.position.y)
                ]
                vVertexData.initializeFrom(initialVertexData)
                vertexBufferUtilization = vertexBufferUtilization + sizeof(Float) * 2 * 3
            
                let pCoefficientData = coefficientBuffer.contents()
                let vCoefficientData = UnsafeMutablePointer<Float>(pCoefficientData + coefficientBufferUtilization)
            
                let initialCoefficientData: [Float] = [
                    Float(vertex0.coefficient.x), Float(vertex0.coefficient.y),
                    Float(vertex1.coefficient.x), Float(vertex1.coefficient.y),
                    Float(vertex2.coefficient.x), Float(vertex2.coefficient.y)
                ]
                vCoefficientData.initializeFrom(initialCoefficientData)
                coefficientBufferUtilization = coefficientBufferUtilization + sizeof(Float) * 2 * 3
            }
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


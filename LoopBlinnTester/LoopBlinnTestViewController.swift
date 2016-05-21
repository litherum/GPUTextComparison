//
//  LoopBlinnTestViewController
//  GPUTextComparison
//
//  Created by Litherum on 5/7/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

import Cocoa
import MetalKit

let MaxBuffers = 3
let VertexBufferSize = 1024*1024
let CoefficientBufferSize = 1024*1024

class LoopBlinnViewController: NSViewController, MTKViewDelegate {
    
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
    
    private func issueDraw(renderEncoder: MTLRenderCommandEncoder, inout vertexBuffer: MTLBuffer, inout vertexBufferUtilization: Int, inout usedVertexBuffers: [MTLBuffer], inout coefficientBuffer: MTLBuffer, inout coefficientBufferUtilization: Int, inout usedCoefficientBuffers: [MTLBuffer], vertexCount: Int) {
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, atIndex: 0)
        renderEncoder.setVertexBuffer(coefficientBuffer, offset:0, atIndex: 1)
        renderEncoder.drawPrimitives(.Triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: 1)
        
        vertexBuffer = acquireVertexBuffer(&usedVertexBuffers)
        vertexBufferUtilization = 0
        coefficientBuffer = acquireCoefficientBuffer(&usedCoefficientBuffers)
        coefficientBufferUtilization = 0
    }

    var t = 20
    func drawInMTKView(view: MTKView) {
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

        t = t + 1
        let p0 = CGPointMake(100, 300)
        let p1 = CGPointMake(700, 100)
        let p2 = CGPointMake(700, 500)
        let p3 = CGPointMake(700, 300)
        cubic(p0, p1, p2, p3) { (v0, v1, v2) in
            let newVertices: [Float] = [
                Float(v0.point.x), Float(v0.point.y),
                Float(v1.point.x), Float(v1.point.y),
                Float(v2.point.x), Float(v2.point.y)
            ]

            let pVertexData = vertexBuffer.contents()
            let vVertexData = UnsafeMutablePointer<Float>(pVertexData + vertexBufferUtilization)

            vVertexData.initializeFrom(newVertices)

            vertexBufferUtilization = vertexBufferUtilization + sizeof(Float) * 6

            let newCoefficients: [Float] = [
                v0.coefficient.x, v0.coefficient.y, v0.coefficient.z, 0,
                v1.coefficient.x, v1.coefficient.y, v1.coefficient.z, 0,
                v2.coefficient.x, v2.coefficient.y, v2.coefficient.z, 0
            ]

            let pCoefficientData = coefficientBuffer.contents()
            let vCoefficientData = UnsafeMutablePointer<Float>(pCoefficientData + coefficientBufferUtilization)

            vCoefficientData.initializeFrom(newCoefficients)

            coefficientBufferUtilization = coefficientBufferUtilization + sizeof(Float) * 12
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


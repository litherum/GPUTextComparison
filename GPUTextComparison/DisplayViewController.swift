//
//  DisplayViewController.swift
//  GPUTextComparison
//
//  Created by Litherum on 4/10/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

import Cocoa
import MetalKit

let MaxBuffers = 3
let VertexBufferSize = 1024*1024
let TextureCoordinateBufferSize = 1024*1024

let vertexData:[Float] =
[
    -1.0, -1.0, 0.0, 0.0,
    -1.0, 1.0, 0.0, 0.0,
    1.0, 1.0, 0.0, 0.0,

    1.0, 1.0, 0.0, 0.0,
    1.0, -1.0, 0.0, 0.0,
    -1.0, -1.0, 0.0, 0.0,
]

let textureCoordinateData:[Float] =
[
    0.0, 0.0,
    0.0, 1.0,
    1.0, 1.0,

    1.0, 1.0,
    1.0, 0.0,
    0.0, 0.0
]

struct GlyphIdentity {
    let glyphID: CGGlyph
    let font: CTFont
}

extension GlyphIdentity: Hashable {
    var hashValue: Int {
        return glyphID.hashValue ^ Int(CFHash(font))
    }
}

func ==(lhs: GlyphIdentity, rhs: GlyphIdentity) -> Bool {
    return lhs.glyphID == rhs.glyphID && CFEqual(lhs.font, rhs.font)
}

struct Glyph {
    let identity : GlyphIdentity
    let position : CGPoint
}

typealias Frame = [Glyph]

class DisplayViewController: NSViewController, MTKViewDelegate {
    
    var device: MTLDevice! = nil
    
    var commandQueue: MTLCommandQueue! = nil
    var pipelineState: MTLRenderPipelineState! = nil
    var vertexBuffers: [MTLBuffer] = []
    var textureCoordinateBuffers: [MTLBuffer] = []
    var texture: MTLTexture! = nil

    let inflightSemaphore = dispatch_semaphore_create(MaxBuffers)
    var bufferIndex = 0

    var frameCounter = 0

    struct GlyphOccupation {
        var texture: MTLTexture
        var space: CGRect
    }

    var frames : [Frame] = []

    var glyphUtilizations: [GlyphIdentity : GlyphOccupation] = [:]

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
    
    func loadAssets() {
        
        // load any resources required for rendering
        let view = self.view as! MTKView
        commandQueue = device.newCommandQueue()
        commandQueue.label = "main command queue"
        
        let defaultLibrary = device.newDefaultLibrary()!
        let fragmentProgram = defaultLibrary.newFunctionWithName("passThroughFragment")!
        let vertexProgram = defaultLibrary.newFunctionWithName("passThroughVertex")!
        
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

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptorWithPixelFormat(.RGBA8Unorm, width: 800, height: 600, mipmapped: false)
        texture = device.newTextureWithDescriptor(textureDescriptor)
        let newData = Array<UInt8>(count: 800 * 600 * 4, repeatedValue: UInt8(255))
        texture.replaceRegion(MTLRegionMake2D(0, 0, 800, 600), mipmapLevel: 0, withBytes: newData, bytesPerRow: 800 * 4)
    }

    /*func runBenchmark(frames: [Frame]) {
        for frame in frames {
            for glyph in frame {
                var occupation = glyphUtilizations[glyph.identity]
                while occupation == nil {
                }
                guard let usedOccupation = occupation else {
                    fatalError()
                }
                
            }
        }
    }*/

    func acquireVertexBuffer(inout usedBuffers: [MTLBuffer]) -> MTLBuffer {
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

    func acquireTextureCoordinateBuffer(inout usedBuffers: [MTLBuffer]) -> MTLBuffer {
        if textureCoordinateBuffers.isEmpty {
            let newBuffer = device.newBufferWithLength(TextureCoordinateBufferSize, options: [])
            usedBuffers.append(newBuffer)
            return newBuffer
        } else {
            let buffer = textureCoordinateBuffers.removeLast()
            usedBuffers.append(buffer)
            return buffer
        }
    }

    func canAppendQuad(vertexBuffer: MTLBuffer, vertexBufferUtilization: Int, textureCoordinateBuffer: MTLBuffer, textureCoordinateBufferUtilization: Int) -> Bool {
        if vertexBufferUtilization + sizeof(Float) * 2 * 3 * 2 > vertexBuffer.length {
            return false
        }
        if textureCoordinateBufferUtilization + sizeof(Float) * 2 * 3 * 2 > textureCoordinateBuffer.length {
            return false
        }
        return true
    }

    func appendQuad(position: CGPoint, vertexBuffer: MTLBuffer, inout vertexBufferUtilization: Int, textureCoordinateBuffer: MTLBuffer, inout textureCoordinateBufferUtilization: Int) {
        assert(canAppendQuad(vertexBuffer, vertexBufferUtilization: vertexBufferUtilization, textureCoordinateBuffer: textureCoordinateBuffer, textureCoordinateBufferUtilization: textureCoordinateBufferUtilization))
        
        let pVertexData = vertexBuffer.contents()
        let vVertexData = UnsafeMutablePointer<Float>(pVertexData + vertexBufferUtilization)
        let x = Float(position.x)
        let y = Float(position.y)
        let newVertices: [Float] =
        [
            x    , y    ,
            x    , y + 3,
            x + 3, y + 3,

            x + 3, y + 3,
            x + 3, y    ,
            x    , y    ,
        ]
        
        vVertexData.initializeFrom(newVertices)
        vertexBufferUtilization = vertexBufferUtilization + sizeofValue(newVertices[0]) * 2 * 3 * 2
        
        let pTextureCoordinateData = textureCoordinateBuffer.contents()
        let vTextureCoordinateData = UnsafeMutablePointer<Float>(pTextureCoordinateData + textureCoordinateBufferUtilization)
        let newTextureCoordinates: [Float] =
        [
            0.0, 0.0,
            0.0, 1.0,
            1.0, 1.0,

            1.0, 1.0,
            1.0, 0.0,
            0.0, 0.0
        ]
        
        vTextureCoordinateData.initializeFrom(newTextureCoordinates)
        textureCoordinateBufferUtilization = textureCoordinateBufferUtilization + sizeofValue(newTextureCoordinates[0]) * 2 * 3 * 2
    }

    func issueDraw(renderEncoder: MTLRenderCommandEncoder, vertexBuffer: MTLBuffer, textureCoordinateBuffer: MTLBuffer, vertexCount: Int) {
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, atIndex: 0)
        renderEncoder.setVertexBuffer(textureCoordinateBuffer, offset:0, atIndex: 1)
        renderEncoder.setFragmentTexture(texture, atIndex: 0)
        renderEncoder.drawPrimitives(.Triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: 1)
    }
    
    func drawInMTKView(view: MTKView) {
        if frameCounter >= frames.count {
            frameCounter = 0
            if frames.count == 0 {
                return
            }
        }
        let frame = frames[frameCounter]

        var usedVertexBuffers: [MTLBuffer] = []
        var usedTextureCoordinateBuffers: [MTLBuffer] = []

        let commandBuffer = commandQueue.commandBuffer()

        guard let renderPassDescriptor = view.currentRenderPassDescriptor, currentDrawable = view.currentDrawable else {
            return
        }
        let renderEncoder = commandBuffer.renderCommandEncoderWithDescriptor(renderPassDescriptor)
        renderEncoder.setRenderPipelineState(pipelineState)

        var vertexBuffer = acquireVertexBuffer(&usedVertexBuffers)
        var vertexBufferUtilization = 0
        var textureCoordinateBuffer = acquireTextureCoordinateBuffer(&usedTextureCoordinateBuffers)
        var textureCoordinateBufferUtilization = 0

        for glyph in frame {
            if !canAppendQuad(vertexBuffer, vertexBufferUtilization: vertexBufferUtilization, textureCoordinateBuffer: textureCoordinateBuffer, textureCoordinateBufferUtilization: textureCoordinateBufferUtilization) {
                issueDraw(renderEncoder, vertexBuffer: vertexBuffer, textureCoordinateBuffer: textureCoordinateBuffer, vertexCount: vertexBufferUtilization / (sizeof(Float) * 2))
                vertexBuffer = acquireVertexBuffer(&usedVertexBuffers)
                vertexBufferUtilization = 0
                textureCoordinateBuffer = acquireTextureCoordinateBuffer(&usedTextureCoordinateBuffers)
                textureCoordinateBufferUtilization = 0
            }
            appendQuad(glyph.position, vertexBuffer: vertexBuffer, vertexBufferUtilization: &vertexBufferUtilization, textureCoordinateBuffer: textureCoordinateBuffer, textureCoordinateBufferUtilization: &textureCoordinateBufferUtilization)
        }
        issueDraw(renderEncoder, vertexBuffer: vertexBuffer, textureCoordinateBuffer: textureCoordinateBuffer, vertexCount: vertexBufferUtilization / (sizeof(Float) * 2))

        renderEncoder.endEncoding()
        commandBuffer.presentDrawable(currentDrawable)

        commandBuffer.addCompletedHandler{ [weak self] commandBuffer in
            dispatch_async(dispatch_get_main_queue(), { [weak self] in
                if let strongSelf = self {
                    strongSelf.vertexBuffers.appendContentsOf(usedVertexBuffers)
                    strongSelf.textureCoordinateBuffers.appendContentsOf(usedTextureCoordinateBuffers)
                }
            })
        }

        commandBuffer.commit()

        frameCounter = frameCounter + 1
    }
    
    
    func mtkView(view: MTKView, drawableSizeWillChange size: CGSize) {
        
    }
}


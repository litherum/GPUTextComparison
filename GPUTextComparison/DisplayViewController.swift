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

struct GlyphCacheKey {
    let glyphID: CGGlyph
    let font: CTFont
    let subpixelPosition: CGPoint
}

extension GlyphCacheKey: Hashable {
    var hashValue: Int {
        let a = glyphID.hashValue
        let b = subpixelPosition.x.hashValue
        let c = subpixelPosition.y.hashValue
        let d = Int(CFHash(CTFontDescriptorCopyAttributes(CTFontCopyFontDescriptor(font))))
        //let d = Int(CFHash(font))
        return a ^ b ^ c ^ d
    }
}

func ==(lhs: GlyphCacheKey, rhs: GlyphCacheKey) -> Bool {
    return lhs.glyphID == rhs.glyphID && CFEqual(lhs.font, rhs.font) && lhs.subpixelPosition == rhs.subpixelPosition
}

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

    var glyphAtlas: GlyphAtlas! = nil

    struct GlyphCacheValue {
        var texture: MTLTexture
        var space: CGRect
    }

    struct Glyph {
        let glyphID: CGGlyph
        let font: CTFont
        let position : CGPoint
    }

    typealias Frame = [Glyph]

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

        let textureWidth = 4096
        let textureHeight = 4096
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptorWithPixelFormat(.R8Unorm, width: textureWidth, height: textureHeight, mipmapped: false)
        texture = device.newTextureWithDescriptor(textureDescriptor)
        let newData = Array<UInt8>(count: textureWidth * textureHeight, repeatedValue: UInt8(255))
        texture.replaceRegion(MTLRegionMake2D(0, 0, textureWidth, textureHeight), mipmapLevel: 0, withBytes: newData, bytesPerRow: 4096)

        glyphAtlas = GlyphAtlas(texture: texture)
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

    func appendQuad(positionRect: CGRect, textureRect: CGRect, vertexBuffer: MTLBuffer, inout vertexBufferUtilization: Int, textureCoordinateBuffer: MTLBuffer, inout textureCoordinateBufferUtilization: Int) {
        assert(canAppendQuad(vertexBuffer, vertexBufferUtilization: vertexBufferUtilization, textureCoordinateBuffer: textureCoordinateBuffer, textureCoordinateBufferUtilization: textureCoordinateBufferUtilization))
        
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

    func issueDraw(renderEncoder: MTLRenderCommandEncoder, inout vertexBuffer: MTLBuffer, inout vertexBufferUtilization: Int, inout usedVertexBuffers: [MTLBuffer], inout textureCoordinateBuffer: MTLBuffer, inout textureCoordinateBufferUtilization: Int, inout usedTextureCoordinateBuffers: [MTLBuffer], vertexCount: Int) {
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, atIndex: 0)
        renderEncoder.setVertexBuffer(textureCoordinateBuffer, offset:0, atIndex: 1)
        renderEncoder.setFragmentTexture(texture, atIndex: 0)
        renderEncoder.drawPrimitives(.Triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: 1)

        vertexBuffer = acquireVertexBuffer(&usedVertexBuffers)
        vertexBufferUtilization = 0
        textureCoordinateBuffer = acquireTextureCoordinateBuffer(&usedTextureCoordinateBuffers)
        textureCoordinateBufferUtilization = 0
    }
    
    func drawInMTKView(view: MTKView) {
        if frames.count == 0 {
            return
        }
        let slowness = 10
        if frameCounter >= frames.count * slowness {
            frameCounter = 0
        }
        let frame = frames[frameCounter / slowness]

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
            // FIXME: Gracefully handle full geometry buffers

            let subpixelRoundFactor = CGFloat(4)
            var subpixelPosition = CGSizeMake(modf(glyph.position.x).1, modf(glyph.position.y).1)
            subpixelPosition = CGSizeMake(subpixelPosition.width * subpixelRoundFactor, subpixelPosition.height * subpixelRoundFactor)
            subpixelPosition = CGSizeMake(floor(subpixelPosition.width), floor(subpixelPosition.height))
            subpixelPosition = CGSizeMake(subpixelPosition.width / subpixelRoundFactor, subpixelPosition.height / subpixelRoundFactor)
            let key = GlyphCacheKey(glyphID: glyph.glyphID, font: glyph.font, subpixelPosition: CGPointMake(subpixelPosition.width, subpixelPosition.height))
            var box = CGRectZero
            if let cacheLookup = cache[key] {
                box = cacheLookup.space
            } else {
                guard let rect = glyphAtlas.put(key.font, glyph: key.glyphID, subpixelPosition: key.subpixelPosition) else {
                    fatalError()
                }
                box = rect
                cache[key] = GlyphCacheValue(texture: texture, space: rect)
            }

            var localGlyph = glyph.glyphID
            var boundingRect = CGRectZero;
            CTFontGetBoundingRectsForGlyphs(glyph.font, .Default, &localGlyph, &boundingRect, 1)

            if boundingRect == CGRectZero {
                continue
            }

            appendQuad(boundingRect.offsetBy(dx: glyph.position.x, dy: glyph.position.y), textureRect: box, vertexBuffer: vertexBuffer, vertexBufferUtilization: &vertexBufferUtilization, textureCoordinateBuffer: textureCoordinateBuffer, textureCoordinateBufferUtilization: &textureCoordinateBufferUtilization)
        }
        issueDraw(renderEncoder, vertexBuffer: &vertexBuffer, vertexBufferUtilization: &vertexBufferUtilization, usedVertexBuffers: &usedVertexBuffers, textureCoordinateBuffer: &textureCoordinateBuffer, textureCoordinateBufferUtilization: &textureCoordinateBufferUtilization, usedTextureCoordinateBuffers: &usedTextureCoordinateBuffers, vertexCount: vertexBufferUtilization / (sizeof(Float) * 2))

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


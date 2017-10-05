//
//  DisplayViewController.swift
//  GPUTextComparison
//
//  Created by Litherum on 4/10/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

import Cocoa
import MetalKit

extension CGSize {
    init(_ w : CGFloat, _ h : CGFloat) {
        self.init(width: w, height: h)
    }
}

extension CGPoint {
    init(_ x: CGFloat, _ y: CGFloat) {
        self.init(x: x, y: y)
    }
}

let MaxBuffers = 3
let VertexBufferSize = 1024*1024
let TextureCoordinateBufferSize = 1024*1024

extension DisplayViewController.GlyphCacheKey: Hashable {
    var hashValue: Int {
        let a = glyphID.hashValue
        let b = subpixelPosition.x.hashValue
        let c = subpixelPosition.y.hashValue
        let d = Int(CFHash(CTFontDescriptorCopyAttributes(CTFontCopyFontDescriptor(font))))
        //let d = Int(CFHash(font))
        return a ^ b ^ c ^ d
    }

    static func ==(lhs: DisplayViewController.GlyphCacheKey, rhs: DisplayViewController.GlyphCacheKey) -> Bool {
        return lhs.glyphID == rhs.glyphID && CFEqual(lhs.font, rhs.font) && lhs.subpixelPosition == rhs.subpixelPosition
    }
}



class DisplayViewController: TextViewController, MTKViewDelegate {

    
    var device: MTLDevice! = nil
    
    var commandQueue: MTLCommandQueue! = nil
    var pipelineState: MTLRenderPipelineState! = nil
    var vertexBuffers: [MTLBuffer] = []
    var textureCoordinateBuffers: [MTLBuffer] = []
    var texture: MTLTexture! = nil

    let inflightSemaphore = DispatchSemaphore(value: MaxBuffers)
    var bufferIndex = 0

    var frameCounter = 0

    struct GlyphCacheKey {
        let glyphID: CGGlyph
        let font: CTFont
        let subpixelPosition: CGPoint
    }

    var glyphAtlas: GlyphAtlas! = nil

    struct GlyphCacheValue {
        var texture: MTLTexture
        var space: CGRect
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
        let fragmentProgram = defaultLibrary.makeFunction(name:"textureFragment")!
        let vertexProgram = defaultLibrary.makeFunction(name:"textureVertex")!
        
        let vertexDescriptor = MTLVertexDescriptor()
        vertexDescriptor.layouts[0].stride = MemoryLayout<Float>.size * 2
        vertexDescriptor.layouts[1].stride = MemoryLayout<Float>.size * 2
        vertexDescriptor.attributes[0].format = .float2
        vertexDescriptor.attributes[0].offset = 0
        vertexDescriptor.attributes[0].bufferIndex = 0
        vertexDescriptor.attributes[1].format = .float2
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

        let textureWidth = 4096
        let textureHeight = 4096
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: textureWidth, height: textureHeight, mipmapped: false)
        texture = device.makeTexture(descriptor: textureDescriptor)
        let newData = Array<UInt8>(repeating: UInt8(255), count: textureWidth * textureHeight)
        texture.replace(region: MTLRegionMake2D(0, 0, textureWidth, textureHeight), mipmapLevel: 0, withBytes: newData, bytesPerRow: 4096)

        glyphAtlas = GlyphAtlas(texture: texture)
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

    private func acquireTextureCoordinateBuffer(usedBuffers: inout [MTLBuffer]) -> MTLBuffer {
        if textureCoordinateBuffers.isEmpty {
            let newBuffer = device.makeBuffer(length: TextureCoordinateBufferSize, options: [])!
            usedBuffers.append(newBuffer)
            return newBuffer
        } else {
            let buffer = textureCoordinateBuffers.removeLast()
            usedBuffers.append(buffer)
            return buffer
        }
    }

    private func canAppendQuad(vertexBuffer: MTLBuffer, vertexBufferUtilization: Int, textureCoordinateBuffer: MTLBuffer, textureCoordinateBufferUtilization: Int) -> Bool {
        if vertexBufferUtilization + MemoryLayout<Float>.size * 2 * 3 * 2 > vertexBuffer.length {
            return false
        }
        if textureCoordinateBufferUtilization + MemoryLayout<Float>.size * 2 * 3 * 2 > textureCoordinateBuffer.length {
            return false
        }
        return true
    }

    private func appendQuad(positionRect: CGRect,
                            textureRect: CGRect,
                            vertexBuffer: MTLBuffer,
                            vertexBufferUtilization: inout Int,
                            textureCoordinateBuffer: MTLBuffer,
                            textureCoordinateBufferUtilization: inout Int) {
        assert(canAppendQuad(vertexBuffer: vertexBuffer, vertexBufferUtilization: vertexBufferUtilization, textureCoordinateBuffer: textureCoordinateBuffer, textureCoordinateBufferUtilization: textureCoordinateBufferUtilization))
        
        let pVertexData = vertexBuffer.contents()
        let vVertexData = pVertexData.assumingMemoryBound(to: Float.self).advanced(by: vertexBufferUtilization)
        let newVertices: [Float] =
        [
            Float(positionRect.origin.x), Float(positionRect.origin.y),
            Float(positionRect.origin.x), Float(positionRect.maxY),
            Float(positionRect.maxX), Float(positionRect.maxY),

            Float(positionRect.maxX), Float(positionRect.maxY),
            Float(positionRect.maxX), Float(positionRect.origin.y),
            Float(positionRect.origin.x), Float(positionRect.origin.y),
        ]


        vVertexData.initialize(from: newVertices, count: newVertices.count)
        vertexBufferUtilization = vertexBufferUtilization + MemoryLayout.size(ofValue: newVertices[0]) * 2 * 3 * 2


        let pTextureCoordinateData = textureCoordinateBuffer.contents()

        let vTextureCoordinateData = pTextureCoordinateData.assumingMemoryBound(to: Float.self).advanced(by: textureCoordinateBufferUtilization)
        let newTextureCoordinates: [Float] =
        [
            Float(textureRect.origin.x), Float(textureRect.maxY),
            Float(textureRect.origin.x), Float(textureRect.origin.y),
            Float(textureRect.maxX), Float(textureRect.origin.y),

            Float(textureRect.maxX), Float(textureRect.origin.y),
            Float(textureRect.maxX), Float(textureRect.maxY),
            Float(textureRect.origin.x), Float(textureRect.maxY),
        ]
        
        vVertexData.initialize(from: newVertices, count: newVertices.count)
        textureCoordinateBufferUtilization = textureCoordinateBufferUtilization + MemoryLayout.size(ofValue: newTextureCoordinates[0]) * 2 * 3 * 2
    }

    private func issueDraw(renderEncoder: MTLRenderCommandEncoder,
                           vertexBuffer: inout MTLBuffer,
                           vertexBufferUtilization: inout Int,
                           usedVertexBuffers: inout [MTLBuffer],
                           textureCoordinateBuffer: inout MTLBuffer,
                           textureCoordinateBufferUtilization: inout Int,
                           usedTextureCoordinateBuffers: inout [MTLBuffer],
                           vertexCount: Int) {
        renderEncoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBuffer(textureCoordinateBuffer, offset:0, index: 1)
        renderEncoder.setFragmentTexture(texture, index: 0)
        renderEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount, instanceCount: 1)

        vertexBuffer = acquireVertexBuffer(usedBuffers: &usedVertexBuffers)
        vertexBufferUtilization = 0
        textureCoordinateBuffer = acquireTextureCoordinateBuffer(usedBuffers: &usedTextureCoordinateBuffers)
        textureCoordinateBufferUtilization = 0
    }
    
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
        var usedTextureCoordinateBuffers: [MTLBuffer] = []

        let commandBuffer = commandQueue.makeCommandBuffer()!

        guard let renderPassDescriptor = view.currentRenderPassDescriptor, let currentDrawable = view.currentDrawable else {
            return
        }
        let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
        renderEncoder.setRenderPipelineState(pipelineState)

        var vertexBuffer = acquireVertexBuffer(usedBuffers: &usedVertexBuffers)
        var vertexBufferUtilization = 0
        var textureCoordinateBuffer = acquireTextureCoordinateBuffer(usedBuffers: &usedTextureCoordinateBuffers)
        var textureCoordinateBufferUtilization = 0

        for glyph in frame {
            // FIXME: Gracefully handle full geometry buffers

            let subpixelRoundFactor = CGFloat(4)

            var subpixelPosition = CGSize(modf(glyph.position.x).1, modf(glyph.position.y).1)
            subpixelPosition = CGSize(subpixelPosition.width * subpixelRoundFactor, subpixelPosition.height * subpixelRoundFactor)
            subpixelPosition = CGSize(floor(subpixelPosition.width), floor(subpixelPosition.height))
            subpixelPosition = CGSize(subpixelPosition.width / subpixelRoundFactor, subpixelPosition.height / subpixelRoundFactor)
            let key = GlyphCacheKey(glyphID: glyph.glyphID, font: glyph.font, subpixelPosition: CGPoint(subpixelPosition.width, subpixelPosition.height))
            var box = CGRect.zero
            if let cacheLookup = cache[key] {
                box = cacheLookup.space
            } else {
                guard let rect = glyphAtlas.put(font: key.font, glyph: key.glyphID, subpixelPosition: key.subpixelPosition) else {
                    fatalError()
                }
                box = rect
                cache[key] = GlyphCacheValue(texture: texture, space: rect)
            }

            var localGlyph = glyph.glyphID
            var boundingRect = CGRect.zero;
            CTFontGetBoundingRectsForGlyphs(glyph.font, .default, &localGlyph, &boundingRect, 1)

            if boundingRect == CGRect.zero {
                continue
            }

            appendQuad(positionRect: boundingRect.offsetBy(dx: glyph.position.x, dy: glyph.position.y), textureRect: box, vertexBuffer: vertexBuffer, vertexBufferUtilization: &vertexBufferUtilization, textureCoordinateBuffer: textureCoordinateBuffer, textureCoordinateBufferUtilization: &textureCoordinateBufferUtilization)
        }
        issueDraw(renderEncoder: renderEncoder,
                  vertexBuffer: &vertexBuffer,
                  vertexBufferUtilization: &vertexBufferUtilization,
                  usedVertexBuffers: &usedVertexBuffers,
                  textureCoordinateBuffer: &textureCoordinateBuffer,
                  textureCoordinateBufferUtilization: &textureCoordinateBufferUtilization,
                  usedTextureCoordinateBuffers: &usedTextureCoordinateBuffers, vertexCount: vertexBufferUtilization / (MemoryLayout<Float>.size * 2))

        renderEncoder.endEncoding()
        commandBuffer.present(currentDrawable)

        commandBuffer.addCompletedHandler{ [weak self] commandBuffer in
            DispatchQueue.main.async { [weak self] in
                if let strongSelf = self {
                    strongSelf.vertexBuffers.append(contentsOf: usedVertexBuffers)
                    strongSelf.textureCoordinateBuffers.append(contentsOf:usedTextureCoordinateBuffers)
                }

            }
        }

        commandBuffer.commit()

        frameCounter = frameCounter + 1
    }
    
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        
    }
}


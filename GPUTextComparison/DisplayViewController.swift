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
let ConstantBufferSize = 1024*1024

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

class DisplayViewController: NSViewController, MTKViewDelegate {
    
    var device: MTLDevice! = nil
    
    var commandQueue: MTLCommandQueue! = nil
    var pipelineState: MTLRenderPipelineState! = nil
    var vertexBuffer: MTLBuffer! = nil
    var textureCoordinateBuffer: MTLBuffer! = nil
    var texture: MTLTexture! = nil

    let inflightSemaphore = dispatch_semaphore_create(MaxBuffers)
    var bufferIndex = 0

    var cache = NSCache()

    struct Glyph {
        var glyphID : CGGlyph
        var position : CGPoint
        var font : CTFont
    }

    typealias Frame = [Glyph]

    var frames : [Frame] = []

    override func viewDidLoad() {
        
        super.viewDidLoad()
        
        device = MTLCreateSystemDefaultDevice()
        guard device != nil else { // Fallback to a blank NSView, an application could also fallback to OpenGL here.
            print("Metal is not supported on this device")
            self.view = NSView(frame: self.view.frame)
            return
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
            print("Failed to create pipeline state, error \(error)")
        }
        
        // generate a large enough buffer to allow streaming vertices for 3 semaphore controlled frames
        vertexBuffer = device.newBufferWithLength(ConstantBufferSize, options: [])
        vertexBuffer.label = "vertices"
        
        let textureCoordinateSize = textureCoordinateData.count * sizeofValue(textureCoordinateData[0])
        textureCoordinateBuffer = device.newBufferWithBytes(textureCoordinateData, length: textureCoordinateSize, options: [])
        textureCoordinateBuffer.label = "texture coordinates"

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptorWithPixelFormat(.RGBA8Unorm, width: 800, height: 600, mipmapped: false)
        texture = device.newTextureWithDescriptor(textureDescriptor)
        let newData = Array<UInt8>(count: 800 * 600 * 4, repeatedValue: UInt8(255))
        texture.replaceRegion(MTLRegionMake2D(0, 0, 800, 600), mipmapLevel: 0, withBytes: newData, bytesPerRow: 800 * 4)
    }
    
    func update() {
        
        // vData is pointer to the MTLBuffer's Float data contents
        let pData = vertexBuffer.contents()
        let vData = UnsafeMutablePointer<Float>(pData + 256*bufferIndex)
        
        // reset the vertices to default before adding animated offsets
        vData.initializeFrom(vertexData)
    }

    func layout() -> [Frame] {
        let path = NSBundle.mainBundle().pathForResource("shakespeare", ofType: "txt")!
        var encoding = UInt(0)
        var string = ""
        do {
            string = try NSString(contentsOfFile: path, usedEncoding: &encoding) as String
        } catch {
            fatalError()
        }

        /*var endIndex = string.startIndex
        for _ in 0 ..< 2000 {
            endIndex = endIndex.successor()
        }
        string = string.substringToIndex(endIndex)*/
        let font = CTFontCreateWithName("American Typewriter", 6, nil)
        let attributedString = CFAttributedStringCreate(kCFAllocatorDefault, string, [kCTFontAttributeName as String : font])
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        var frameStart = CFIndex(0)
        var result : [Frame] = []
        while true {
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(frameStart, 0), CGPathCreateWithRect(CGRectMake(0, 0, 800, 600), nil), nil)
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            if visibleRange.length == 0 {
                break
            }
            let lines = CTFrameGetLines(frame) as NSArray
            var lineOrigins = Array<CGPoint>(count: lines.count, repeatedValue: CGPointZero)
            CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &lineOrigins)

            var resultFrame = Frame()

            for i in 0 ..< lines.count {
                let line = lines[i] as! CTLine
                let lineOrigin = lineOrigins[i]

                let runs = CTLineGetGlyphRuns(line) as NSArray
                for run in runs {
                    let run = run as! CTRun
                    let glyphCount = CTRunGetGlyphCount(run)
                    var glyphs = Array<CGGlyph>(count: glyphCount, repeatedValue: CGGlyph(0))
                    CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), &glyphs)
                    var positions = Array<CGPoint>(count: glyphCount, repeatedValue: CGPointZero)
                    CTRunGetPositions(run, CFRangeMake(0, glyphCount), &positions)
                    let attributes = CTRunGetAttributes(run) as NSDictionary
                    let usedFont = attributes[kCTFontAttributeName as String] as! CTFont
                    for j in 0 ..< glyphCount {
                        resultFrame.append(Glyph(glyphID: glyphs[j], position: CGPointMake(positions[j].x + lineOrigin.x, positions[j].y + lineOrigin.y), font: usedFont))
                    }
                }
            }
            result.append(resultFrame)
            frameStart = visibleRange.location + visibleRange.length
        }
        return result
    }
    
    func drawInMTKView(view: MTKView) {
        
        // use semaphore to encode 3 frames ahead
        dispatch_semaphore_wait(inflightSemaphore, DISPATCH_TIME_FOREVER)
        
        self.update()
        
        let commandBuffer = commandQueue.commandBuffer()
        commandBuffer.label = "Frame command buffer"
        
        // use completion handler to signal the semaphore when this frame is completed allowing the encoding of the next frame to proceed
        // use capture list to avoid any retain cycles if the command buffer gets retained anywhere besides this stack frame
        commandBuffer.addCompletedHandler{ [weak self] commandBuffer in
            if let strongSelf = self {
                dispatch_semaphore_signal(strongSelf.inflightSemaphore)
            }
            return
        }
        
        if let renderPassDescriptor = view.currentRenderPassDescriptor, currentDrawable = view.currentDrawable
        {
            let renderEncoder = commandBuffer.renderCommandEncoderWithDescriptor(renderPassDescriptor)
            renderEncoder.label = "render encoder"
            
            renderEncoder.pushDebugGroup("draw morphing triangle")
            renderEncoder.setRenderPipelineState(pipelineState)
            renderEncoder.setVertexBuffer(vertexBuffer, offset: 256*bufferIndex, atIndex: 0)
            renderEncoder.setVertexBuffer(textureCoordinateBuffer, offset:0 , atIndex: 1)
            renderEncoder.setFragmentTexture(texture, atIndex: 0)
            renderEncoder.drawPrimitives(.Triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
            
            renderEncoder.popDebugGroup()
            renderEncoder.endEncoding()
                
            commandBuffer.presentDrawable(currentDrawable)
        }
        
        // bufferIndex matches the current semaphore controled frame index to ensure writing occurs at the correct region in the vertex buffer
        bufferIndex = (bufferIndex + 1) % MaxBuffers
        
        commandBuffer.commit()
    }
    
    
    func mtkView(view: MTKView, drawableSizeWillChange size: CGSize) {
        
    }
}


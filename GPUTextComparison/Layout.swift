//
//  Layout.swift
//  GPUTextComparison
//
//  Created by Litherum on 4/16/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

import Cocoa

struct Glyph {
    let glyphID: CGGlyph
    let font: CTFont
    let position : CGPoint
}

extension CGRect {
    init(_ a : CGFloat, _ b : CGFloat, _ c : CGFloat, _ d : CGFloat) {
        self.init(origin : CGPoint(x: a, y: b), size : CGSize(c, d))
    }
}

typealias Frame = [Glyph]

func layout() -> [Frame] {
    let path = Bundle.main.path(forResource: "shakespeare", ofType: "txt")!
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
    guard let font = CTFontCreateUIFontForLanguage(.system, 50, nil) else {
        fatalError()
    }
    let attributedString = CFAttributedStringCreate(kCFAllocatorDefault, string as CFString, [kCTFontAttributeName as String : font] as CFDictionary)!
    let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
    var frameStart = CFIndex(0)
    var result : [Frame] = []
    while true {
        let path = CGPath(rect: CGRect(0, 0, 800, 600), transform: nil)

        let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(frameStart, 0), path, nil)
        let visibleRange = CTFrameGetVisibleStringRange(frame)
        if visibleRange.length == 0 {
            break
        }
        let lines = CTFrameGetLines(frame) as NSArray
        var lineOrigins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &lineOrigins)

        var resultFrame = Frame()

        for i in 0 ..< lines.count {
            let line = lines[i] as! CTLine
            let lineOrigin = lineOrigins[i]

            let runs = CTLineGetGlyphRuns(line) as NSArray
            for run in runs {
                let run = run as! CTRun
                let glyphCount = CTRunGetGlyphCount(run)
                var glyphs = Array<CGGlyph>(repeating: CGGlyph(0), count: glyphCount)
                CTRunGetGlyphs(run, CFRangeMake(0, glyphCount), &glyphs)
                var positions = Array<CGPoint>(repeating: .zero, count: glyphCount)
                CTRunGetPositions(run, CFRangeMake(0, glyphCount), &positions)
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let usedFont = attributes[kCTFontAttributeName as String] as! CTFont
                for j in 0 ..< glyphCount {
                    resultFrame.append(Glyph(glyphID: glyphs[j], font: usedFont, position: CGPoint(positions[j].x + lineOrigin.x, positions[j].y + lineOrigin.y)))
                }
            }
        }
        result.append(resultFrame)
        frameStart = visibleRange.location + visibleRange.length
    }
    return result
}

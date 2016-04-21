//
//  Layout.swift
//  GPUTextComparison
//
//  Created by Litherum on 4/16/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

import Cocoa

    func layout() -> [DisplayViewController.Frame] {
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
        var result : [DisplayViewController.Frame] = []
        while true {
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(frameStart, 0), CGPathCreateWithRect(CGRectMake(0, 0, 800, 600), nil), nil)
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            if visibleRange.length == 0 {
                break
            }
            let lines = CTFrameGetLines(frame) as NSArray
            var lineOrigins = Array<CGPoint>(count: lines.count, repeatedValue: CGPointZero)
            CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), &lineOrigins)

            var resultFrame = DisplayViewController.Frame()

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
                        resultFrame.append(DisplayViewController.Glyph(glyphID: glyphs[j], font: usedFont, position: CGPointMake(positions[j].x + lineOrigin.x, positions[j].y + lineOrigin.y)))
                    }
                }
            }
            result.append(resultFrame)
            frameStart = visibleRange.location + visibleRange.length
        }
        return result
    }
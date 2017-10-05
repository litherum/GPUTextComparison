//
//  GlyphAtlas.swift
//  GPUTextComparison
//
//  Created by Litherum on 4/20/16.
//  Copyright © 2016 Litherum. All rights reserved.
//

import CoreGraphics
import Metal

class GlyphAtlas {
    // FIXME: Let the atlas grow larger than a single texture
    // FIXME: Evict stuff we don't need
    private let texture: MTLTexture
    private let bitmapContext: CGContext
    private let backgroundColor: CGColor
    private let foregroundColor: CGColor

    private var minRow = 0
    private var maxRow = 0
    private var column = 0

    init(texture: MTLTexture) {
        self.texture = texture
        guard let bitmapContext = CGContext(data: nil, width: texture.width, height: texture.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            fatalError()
        }
        backgroundColor = CGColor(gray: 0.0, alpha: 1.0)
        foregroundColor = CGColor(gray: 1.0, alpha: 1.0)
        bitmapContext.setFillColor(backgroundColor)
        bitmapContext.fill(CGRect(0, 0, CGFloat(texture.width), CGFloat(texture.height)))
        self.bitmapContext = bitmapContext
    }

    private func findLocation(width: Int, height: Int) -> MTLRegion? {
        if column + width < texture.width {
            let result = MTLRegionMake2D(column, minRow, width, height)
            column = column + width
            maxRow = max(maxRow, minRow + height)
            return result
        } else if maxRow + height < texture.height {
            let result = MTLRegionMake2D(0, maxRow, width, height)
            column = width
            minRow = maxRow
            maxRow = minRow + height
            return result
        }
        return nil
    }

    // Returns the rect of the bounding box of the glyph in texture coordinates
    // Returns nil iff the atlas is full
    func put(font: CTFont, glyph: CGGlyph, subpixelPosition: CGPoint) -> CGRect? {
        var localGlyph = glyph
        var boundingRect : CGRect = .zero

        CTFontGetBoundingRectsForGlyphs(font, .default, &localGlyph, &boundingRect, 1)

        if boundingRect == .zero {
            return .zero
        }

        let boundingRectOffset = CGSize((CGFloat(texture.width) - boundingRect.width) / 2, (CGFloat(texture.height) - boundingRect.height) / 2)
        let origin = CGPoint(floor(boundingRectOffset.width - boundingRect.origin.x), floor(boundingRectOffset.height - boundingRect.origin.y))
        var adjustedOrigin = CGPoint(origin.x + subpixelPosition.x, origin.y + subpixelPosition.y)

        let adjustedBoundingRect = boundingRect.offsetBy(dx: adjustedOrigin.x, dy: adjustedOrigin.y)
        let affectedPixelsMinCorner = CGPoint(floor(adjustedBoundingRect.origin.x), floor(adjustedBoundingRect.origin.y))
        let affectedPixelsMaxCorner = CGPoint(ceil(adjustedBoundingRect.maxX), ceil(adjustedBoundingRect.maxY))
        let affectedPixelsSize = CGSize(affectedPixelsMaxCorner.x - affectedPixelsMinCorner.x, affectedPixelsMaxCorner.y - affectedPixelsMinCorner.y)
        guard let textureLocation = findLocation(width: Int(affectedPixelsSize.width), height: Int(affectedPixelsSize.height)) else {
            return nil
        }

        bitmapContext.setFillColor(foregroundColor)
        CTFontDrawGlyphs(font, &localGlyph, &adjustedOrigin, 1, bitmapContext)

        let bitmapData = UnsafeMutablePointer<UInt8>(CGBitmapContextGetData(bitmapContext))
        let localBitmapData = bitmapData + Int(affectedPixelsMinCorner.y) * CGBitmapContextGetBytesPerRow(bitmapContext) + Int(affectedPixelsMinCorner.x)
        texture.replaceRegion(textureLocation, mipmapLevel: 0, withBytes: localBitmapData, bytesPerRow: CGBitmapContextGetBytesPerRow(bitmapContext))

        bitmapContext.setFillColor(backgroundColor)
        bitmapContext.fill(CGRect(affectedPixelsMinCorner.x, affectedPixelsMinCorner.y, affectedPixelsSize.width, affectedPixelsSize.height))

        let pixelSnappingAmount = adjustedBoundingRect.offsetBy(dx: -affectedPixelsMinCorner.x, dy: -affectedPixelsMinCorner.y)
        return pixelSnappingAmount.offsetBy(dx: CGFloat(textureLocation.origin.x), dy: CGFloat(textureLocation.origin.y))

    }
}


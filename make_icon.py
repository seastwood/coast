"""
Generate Coast.icns from the same SF Symbol used in the menu bar
(cursorarrow.motionlines), rendered white on a dark rounded tile.

Renders a 1024px master with AppKit, downscales the iconset sizes with `sips`,
and packs them with `iconutil`.
"""
import os
import subprocess

from AppKit import (
    NSImage,
    NSBitmapImageRep,
    NSColor,
    NSBezierPath,
    NSGradient,
    NSGraphicsContext,
    NSImageSymbolConfiguration,
    NSRectFillUsingOperation,
    NSCompositingOperationSourceOver,
    NSCompositingOperationSourceAtop,
    NSDeviceRGBColorSpace,
    NSBitmapImageFileTypePNG,
)

ICON_SYMBOL = "cursorarrow.motionlines"
HERE = os.path.dirname(os.path.abspath(__file__))


def _tinted_white(symbol):
    """Return a white-filled copy of a (template) SF Symbol image."""
    size = symbol.size()
    rect = ((0, 0), (size.width, size.height))
    out = NSImage.alloc().initWithSize_(size)
    out.lockFocus()
    symbol.drawInRect_fromRect_operation_fraction_(
        rect, rect, NSCompositingOperationSourceOver, 1.0)
    NSColor.whiteColor().set()
    NSRectFillUsingOperation(rect, NSCompositingOperationSourceAtop)
    out.unlockFocus()
    return out


def render_master(px=1024):
    rep = NSBitmapImageRep.alloc().initWithBitmapDataPlanes_pixelsWide_pixelsHigh_bitsPerSample_samplesPerPixel_hasAlpha_isPlanar_colorSpaceName_bytesPerRow_bitsPerPixel_(
        None, px, px, 8, 4, True, False, NSDeviceRGBColorSpace, 0, 0)
    ctx = NSGraphicsContext.graphicsContextWithBitmapImageRep_(rep)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.setCurrentContext_(ctx)

    # Rounded tile with a ~10% margin (matches the visual weight of other icons).
    margin = px * 0.10
    tile = px - 2 * margin
    radius = tile * 0.2237
    tile_rect = ((margin, margin), (tile, tile))
    path = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(tile_rect, radius, radius)
    grad = NSGradient.alloc().initWithStartingColor_endingColor_(
        NSColor.colorWithSRGBRed_green_blue_alpha_(0.27, 0.27, 0.30, 1.0),
        NSColor.colorWithSRGBRed_green_blue_alpha_(0.12, 0.12, 0.14, 1.0))
    grad.drawInBezierPath_angle_(path, -90.0)

    # White motion-cursor glyph, centered, ~52% of the canvas.
    sym = NSImage.imageWithSystemSymbolName_accessibilityDescription_(ICON_SYMBOL, None)
    cfg = NSImageSymbolConfiguration.configurationWithPointSize_weight_(px * 0.40, 0.0)
    sym = sym.imageWithSymbolConfiguration_(cfg)
    sym = _tinted_white(sym)
    gs = sym.size()
    scale = (px * 0.52) / max(gs.width, gs.height)
    gw, gh = gs.width * scale, gs.height * scale
    glyph_rect = (((px - gw) / 2.0, (px - gh) / 2.0), (gw, gh))
    sym.drawInRect_fromRect_operation_fraction_(
        glyph_rect, ((0, 0), (gs.width, gs.height)), NSCompositingOperationSourceOver, 1.0)

    NSGraphicsContext.restoreGraphicsState()
    png = rep.representationUsingType_properties_(NSBitmapImageFileTypePNG, {})
    master = os.path.join(HERE, "Coast_master.png")
    png.writeToFile_atomically_(master, True)
    return master


def build_icns():
    master = render_master(1024)
    iconset = os.path.join(HERE, "Coast.iconset")
    subprocess.run(["rm", "-rf", iconset], check=True)
    os.makedirs(iconset)
    specs = [
        (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
    ]
    for size, name in specs:
        subprocess.run(["sips", "-z", str(size), str(size), master,
                        "--out", os.path.join(iconset, name)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    icns = os.path.join(HERE, "Coast.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)
    print("wrote", icns)
    return icns


if __name__ == "__main__":
    build_icns()

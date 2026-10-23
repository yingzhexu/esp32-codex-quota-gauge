// Draws the 1024 px app icon: the vertical gauge itself - white plate,
// tick scale, red arrow pointing at the scale.
import AppKit
let s: CGFloat = 1024
let img = NSImage(size: NSSize(width: s, height: s))
img.lockFocus()
// Plate with a soft shadow and a hairline edge.
let plate = NSRect(x: 100, y: 100, width: s-200, height: s-200)
let sh = NSShadow(); sh.shadowBlurRadius = 30; sh.shadowOffset = NSSize(width: 0, height: -12)
sh.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.28)
NSGraphicsContext.saveGraphicsState(); sh.set()
NSColor.white.setFill(); NSBezierPath(roundedRect: plate, xRadius: 180, yRadius: 180).fill()
NSGraphicsContext.restoreGraphicsState()
NSColor(calibratedWhite: 0.85, alpha: 1).setStroke()
let edge = NSBezierPath(roundedRect: plate.insetBy(dx: 2, dy: 2), xRadius: 178, yRadius: 178); edge.lineWidth = 4; edge.stroke()
// Vertical scale: baseline on the right, ticks to the left (25% long, 10% mid, 5% short).
let ink = NSColor(calibratedWhite: 0.16, alpha: 1)
let base: CGFloat = 560, y0: CGFloat = 230, y1: CGFloat = 794
ink.setFill(); NSBezierPath(rect: NSRect(x: base-10, y: y0-8, width: 14, height: y1-y0+16)).fill()
for q in stride(from: 0, through: 100, by: 5) {
    let y = y0 + (y1-y0) * CGFloat(q) / 100
    let len: CGFloat = q % 25 == 0 ? 230 : (q % 10 == 0 ? 150 : 95)
    let w: CGFloat = q % 25 == 0 ? 16 : 10
    NSBezierPath(rect: NSRect(x: base-len, y: y-w/2, width: len, height: w)).fill()
}
// Red arrow pointing left at about 70%.
let ay = y0 + (y1-y0) * 0.70
let red = NSColor(calibratedRed: 0.89, green: 0.20, blue: 0.18, alpha: 1)
let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: base+20, y: ay))
arrow.line(to: NSPoint(x: base+150, y: ay+72)); arrow.line(to: NSPoint(x: base+150, y: ay+34))
arrow.line(to: NSPoint(x: 840, y: ay+34)); arrow.line(to: NSPoint(x: 840, y: ay-34))
arrow.line(to: NSPoint(x: base+150, y: ay-34)); arrow.line(to: NSPoint(x: base+150, y: ay-72))
arrow.close(); red.setFill(); arrow.fill()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

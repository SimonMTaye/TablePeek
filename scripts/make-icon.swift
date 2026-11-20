// Draws the app icon (1024x1024 PNG). Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Rounded square background
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185, yRadius: 185)
NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.33, blue: 0.62, alpha: 1),
           ending: NSColor(calibratedRed: 0.09, green: 0.18, blue: 0.40, alpha: 1))!.draw(in: bg, angle: -90)

// Paper sheet
let paper = CGRect(x: 230, y: 200, width: 564, height: 640)
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: NSColor.black.withAlphaComponent(0.35).cgColor)
NSColor.white.setFill()
NSBezierPath(roundedRect: paper, xRadius: 22, yRadius: 22).fill()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// Booktabs-style table: thick top/bottom rules, thin mid rule, rows of "numbers"
NSColor(calibratedWhite: 0.1, alpha: 1).setFill()
func rule(_ y: CGFloat, _ h: CGFloat) { NSBezierPath(rect: CGRect(x: 290, y: y, width: 444, height: h)).fill() }
rule(740, 12)
rule(655, 6)
rule(275, 12)
NSColor(calibratedWhite: 0.35, alpha: 1).setFill()
for (i, y) in [700, 600, 545, 470, 415, 340].enumerated() {
    let cy = CGFloat(y)
    NSBezierPath(roundedRect: CGRect(x: 300, y: cy, width: 120, height: 22), xRadius: 11, yRadius: 11).fill()
    for col in 0..<2 {
        let w: CGFloat = i % 2 == 1 && y < 650 ? 90 : 110
        let x = 500 + CGFloat(col) * 130 + (110 - w) / 2
        NSBezierPath(roundedRect: CGRect(x: x, y: cy, width: w, height: 22), xRadius: 11, yRadius: 11).fill()
    }
}

// Magnifier
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor.black.withAlphaComponent(0.3).cgColor)
let lens = NSBezierPath(ovalIn: CGRect(x: 560, y: 150, width: 260, height: 260))
lens.lineWidth = 44
NSColor(calibratedRed: 0.98, green: 0.62, blue: 0.16, alpha: 1).setStroke()
NSColor(calibratedRed: 1, green: 0.85, blue: 0.55, alpha: 0.35).setFill()
lens.fill()
lens.stroke()
let handle = NSBezierPath()
handle.move(to: CGPoint(x: 780, y: 185))
handle.line(to: CGPoint(x: 880, y: 85))
handle.lineWidth = 64
handle.lineCapStyle = .round
handle.stroke()

img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

#!/usr/bin/env swift
// WHAT: Render Pelican's app icon: an original gold pelican, drawn with paths, on a cream plate.
// OUT:  Support/AppIcon/icon_1024.png (the .icns fallback, via make-iconset.sh) and
//       Support/AppIcon/AppIcon.icon/Assets/icon_1024.png (the layer macOS 26+ draws).
// PIN:  Left square and opaque, like Craft's and Ambient's: the system masks the icon to its
//       own rounded shape, and a pre-rounded PNG would show two sets of corners.
// PIN:  Not the SF Symbol the app uses in its sidebar — Apple's SF Symbols terms don't allow
//       symbols in app icons. This mark is drawn here, from nothing but these paths.
//
//   swift scripts/gen-app-icon.swift
//
import AppKit

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let outputs = [
    root.appendingPathComponent("Support/AppIcon/icon_1024.png"),
    root.appendingPathComponent("Support/AppIcon/AppIcon.icon/Assets/icon_1024.png"),
]
let size = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}
let cream = color(0xFAF9F6), creamShade = color(0xEFE9DC)
let gold = color(0xAE9060), goldDeep = color(0x8E7446), ink = color(0x2D3142)

guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { fatalError("no context") }
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)

// Plate: cream with a soft light from the top.
NSGradient(starting: cream, ending: creamShade)!.draw(in: NSRect(x: 0, y: 0, width: size, height: size), angle: -90)

// The drawing lives in a 1000-unit box, centred at 70% of the canvas; icon.json draws the
// layer at 1.242, and the bird itself fills about half the box.
let art: CGFloat = 0.70
let scale = CGFloat(size) * art / 1000
let inset = CGFloat(size) * (1 - art) / 2
context.translateBy(x: inset, y: inset)
context.scaleBy(x: scale, y: scale)

func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x, y: y) }

// Body: a full, forward-leaning teardrop resting on the water.
let body = NSBezierPath()
body.move(to: p(120, 330))
body.curve(to: p(470, 250), controlPoint1: p(190, 250), controlPoint2: p(340, 225))
body.curve(to: p(660, 380), controlPoint1: p(580, 270), controlPoint2: p(650, 320))
body.curve(to: p(560, 520), controlPoint1: p(670, 450), controlPoint2: p(620, 505))
body.curve(to: p(250, 470), controlPoint1: p(450, 545), controlPoint2: p(330, 520))
body.curve(to: p(120, 330), controlPoint1: p(180, 430), controlPoint2: p(120, 380))
body.close()
gold.setFill()
body.fill()

// Wing: a darker sweep over the body.
let wing = NSBezierPath()
wing.move(to: p(200, 380))
wing.curve(to: p(520, 330), controlPoint1: p(300, 330), controlPoint2: p(430, 300))
wing.curve(to: p(600, 420), controlPoint1: p(575, 345), controlPoint2: p(600, 385))
wing.curve(to: p(300, 440), controlPoint1: p(520, 470), controlPoint2: p(390, 470))
wing.curve(to: p(200, 380), controlPoint1: p(250, 425), controlPoint2: p(215, 400))
wing.close()
goldDeep.setFill()
wing.fill()

// Neck: an S rising from the chest to the head.
let neck = NSBezierPath()
neck.lineWidth = 74
neck.lineCapStyle = .round
neck.move(to: p(575, 470))
neck.curve(to: p(600, 700), controlPoint1: p(520, 560), controlPoint2: p(520, 650))
gold.setStroke()
neck.stroke()

// Head.
let head = NSBezierPath(ovalIn: NSRect(x: 548, y: 650, width: 118, height: 108))
gold.setFill()
head.fill()

// Beak: the long upper mandible, and the pouch hanging beneath it.
let beak = NSBezierPath()
beak.move(to: p(640, 735))
beak.curve(to: p(905, 640), controlPoint1: p(740, 720), controlPoint2: p(840, 675))
beak.line(to: p(910, 628))
beak.curve(to: p(645, 690), controlPoint1: p(830, 650), controlPoint2: p(730, 675))
beak.close()
goldDeep.setFill()
beak.fill()

let pouch = NSBezierPath()
pouch.move(to: p(650, 690))
pouch.curve(to: p(905, 630), controlPoint1: p(740, 670), controlPoint2: p(840, 645))
pouch.curve(to: p(700, 585), controlPoint1: p(860, 600), controlPoint2: p(760, 570))
pouch.curve(to: p(620, 660), controlPoint1: p(655, 595), controlPoint2: p(625, 625))
pouch.close()
gold.withAlphaComponent(0.85).setFill()
pouch.fill()

// Eye.
ink.setFill()
NSBezierPath(ovalIn: NSRect(x: 612, y: 708, width: 20, height: 20)).fill()

// Water: two quiet lines under the bird.
for (index, y) in [CGFloat(215), 165].enumerated() {
    let wave = NSBezierPath()
    wave.lineWidth = index == 0 ? 16 : 12
    wave.lineCapStyle = .round
    let start: CGFloat = index == 0 ? 90 : 190, end: CGFloat = index == 0 ? 760 : 660
    wave.move(to: p(start, y))
    let segments = max(1, Int(((end - start) / 112).rounded()))
    let step = (end - start) / CGFloat(segments)
    for segment in 0..<segments {
        let x = start + CGFloat(segment) * step, next = x + step
        let lift: CGFloat = segment.isMultiple(of: 2) ? 18 : -18
        wave.curve(to: p(next, y), controlPoint1: p(x + step / 3, y + lift), controlPoint2: p(next - step / 3, y + lift))
    }
    gold.withAlphaComponent(index == 0 ? 0.55 : 0.32).setStroke()
    wave.stroke()
}

NSGraphicsContext.current = nil
guard let image = context.makeImage() else { fatalError("no image") }
for url in outputs {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(url.path)") }
    print("wrote \(url.path)")
}

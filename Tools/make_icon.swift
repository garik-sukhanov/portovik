#!/usr/bin/env swift
import AppKit

// Иконка: тёмно-синий скруглённый квадрат, слева три «клиента», справа «сервер» с гнездом-портом,
// между ними — связи. Метафора: кто к кому подключён.
func renderIcon(size: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: Int(size), pixelsHigh: Int(size),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        NSGraphicsContext.restoreGraphicsState(); return nil
    }

    let inset = size * 0.055
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: size * 0.225, yRadius: size * 0.225)

    ctx.saveGState()
    shape.addClip()
    let colors = [NSColor(calibratedRed: 0.17, green: 0.24, blue: 0.62, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.04, green: 0.55, blue: 0.68, alpha: 1).cgColor]
    if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])
    }
    // Лёгкая сетка точек — «схема».
    NSColor.white.withAlphaComponent(0.08).setFill()
    let step = size / 11
    var y = step
    while y < size {
        var x = step
        while x < size {
            NSBezierPath(ovalIn: CGRect(x: x - size * 0.006, y: y - size * 0.006, width: size * 0.012, height: size * 0.012)).fill()
            x += step
        }
        y += step
    }
    ctx.restoreGState()

    let server = CGRect(x: size * 0.60, y: size * 0.30, width: size * 0.22, height: size * 0.40)
    let socketY = server.midY
    let clients = [CGPoint(x: size * 0.25, y: size * 0.72),
                   CGPoint(x: size * 0.21, y: size * 0.50),
                   CGPoint(x: size * 0.25, y: size * 0.28)]

    // Связи.
    let teal = NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.85, alpha: 1)
    for (i, c) in clients.enumerated() {
        let p = NSBezierPath()
        p.lineWidth = size * 0.032
        p.lineCapStyle = .round
        p.move(to: c)
        let end = CGPoint(x: server.minX - size * 0.035, y: socketY + CGFloat(1 - i) * size * 0.07)
        p.curve(to: end,
                controlPoint1: CGPoint(x: c.x + size * 0.18, y: c.y),
                controlPoint2: CGPoint(x: end.x - size * 0.16, y: end.y))
        (i == 1 ? teal : NSColor.white.withAlphaComponent(0.85)).setStroke()
        p.stroke()
    }

    // Сервер.
    NSColor.white.setFill()
    NSBezierPath(roundedRect: server, xRadius: size * 0.045, yRadius: size * 0.045).fill()
    NSColor(calibratedRed: 0.10, green: 0.36, blue: 0.66, alpha: 1).setFill()
    for k in 0..<3 {
        let ly = server.minY + server.height * (0.25 + CGFloat(k) * 0.25)
        NSBezierPath(roundedRect: CGRect(x: server.minX + server.width * 0.22, y: ly - size * 0.013,
                                         width: server.width * 0.56, height: size * 0.026),
                     xRadius: size * 0.013, yRadius: size * 0.013).fill()
    }
    // Гнёзда-порты на левой стороне сервера.
    for i in 0..<3 {
        let cy = socketY + CGFloat(1 - i) * size * 0.07
        let r = CGRect(x: server.minX - size * 0.05, y: cy - size * 0.022, width: size * 0.06, height: size * 0.044)
        (i == 1 ? teal : NSColor.white).setFill()
        NSBezierPath(roundedRect: r, xRadius: size * 0.018, yRadius: size * 0.018).fill()
    }
    // Клиенты.
    for (i, c) in clients.enumerated() {
        let r = size * 0.062
        (i == 1 ? teal : NSColor.white).setFill()
        NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for size in [16, 32, 64, 128, 256, 512, 1024] {
    guard let data = renderIcon(size: CGFloat(size)) else { continue }
    try? data.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("icon_\(size)x\(size).png"))
}
print("icons → \(outDir)")

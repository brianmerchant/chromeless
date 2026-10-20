// Contact sheet of real window captures: crops the top band of each PNG
// (top-left origin) and stacks them with a caption.
//   swift sheet.swift <out.png> <topPoints> <file.png>...
import AppKit

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 3, let topPt = Double(args[1]) else {
    print("usage: sheet.swift <out.png> <topPoints> <png>..."); exit(1)
}
let files = Array(args.dropFirst(2))
let width = 1800, caption = 26, scale = 0.5          // output in points * 0.5 ... keeps sheets small
var rows: [(String, CGImage)] = []
for f in files {
    guard let src = NSImage(contentsOfFile: f)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    let px = Double(src.width) / 1800.0               // pixels per point
    guard let crop = src.cropping(to: CGRect(x: 0, y: 0, width: Double(src.width), height: topPt * px)) else { continue }
    rows.append(((f as NSString).lastPathComponent, crop))
}
let rowH = Int(topPt * 2 * scale)
let outW = Int(Double(width) * 2 * scale)
let outH = rows.count * (rowH + caption)
guard let ctx = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(2) }
ctx.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
for (i, (name, img)) in rows.enumerated() {
    let top = outH - i * (rowH + caption)
    ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
    ctx.fill(CGRect(x: 0, y: top - caption, width: outW, height: caption))
    (name as NSString).draw(at: NSPoint(x: 8, y: top - caption + 5),
                            withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .medium),
                                             .foregroundColor: NSColor.white])
    ctx.draw(img, in: CGRect(x: 0, y: top - caption - rowH, width: outW, height: rowH))
}
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[0]))
print("wrote \(args[0]) (\(rows.count) rows)")

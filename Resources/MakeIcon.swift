import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let icon = NSImage(size: NSSize(width: pixels, height: pixels), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
            context.saveGState()
            context.setShadow(offset: CGSize(width: 0, height: -14), blur: 24,
                              color: NSColor.black.withAlphaComponent(0.33).cgColor)
            let shape = NSBezierPath(roundedRect: CGRect(x: 72, y: 72, width: 880, height: 880),
                                     xRadius: 200, yRadius: 200)
            NSColor(srgbRed: 0.08, green: 0.24, blue: 0.37, alpha: 1).setFill()
            shape.fill()
            context.restoreGState()
            NSGradient(starting: NSColor(srgbRed: 0.08, green: 0.43, blue: 0.52, alpha: 1),
                       ending: NSColor(srgbRed: 0.06, green: 0.17, blue: 0.29, alpha: 1))?
                .draw(in: shape, angle: -65)
            let config = NSImage.SymbolConfiguration(pointSize: 490, weight: .medium)
                .applying(.init(paletteColors: [.white]))
            guard let symbol = NSImage(systemSymbolName: "archivebox.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return false }
            let rect = CGRect(x: (1024 - symbol.size.width) / 2, y: (1024 - symbol.size.height) / 2,
                              width: symbol.size.width, height: symbol.size.height)
            symbol.draw(in: rect)
            return true
        }
        guard let tiff = icon.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not render the application icon.")
        }
        let suffix = scale == 1 ? "" : "@2x"
        try png.write(to: folder.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}

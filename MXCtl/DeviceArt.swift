import AppKit

/// The device picture with its buttons marked, as in Logi Options+. The pictures are our own pencil
/// drawings (`scripts/make-device-art.py` → `Resources/Devices/<model>.png` and `-dark.png`): the
/// mouse from the side, the keyboard from the front. Button positions are in the drawings' own
/// coordinates, kept here.
struct DeviceArt {
    struct Marker: Identifiable {
        enum Target: Hashable {
            case control(UInt16)
            case thumbWheel
        }

        let target: Target
        /// Centre of the button's frame in the picture, 0…1 from the top left.
        let x: Double
        let y: Double
        /// Frame size, 0…1 of the picture.
        let width: Double
        let height: Double

        var id: Target { target }
    }

    let image: NSImage
    let darkImage: NSImage
    let markers: [Marker]

    /// "2b034" for MX Master 3S (product 0xB034): the model ID Logitech names its devices by.
    static func model(productID: Int) -> String { "2" + String(format: "%x", productID) }

    static func load(productID: Int) -> DeviceArt? {
        let model = model(productID: productID)
        guard let markers = markers[model],
              let dir = Bundle.main.resourceURL?.appendingPathComponent("Devices", isDirectory: true),
              let image = NSImage(contentsOf: dir.appendingPathComponent("\(model).png")) else { return nil }
        let darkImage = NSImage(contentsOf: dir.appendingPathComponent("\(model)-dark.png")) ?? image
        return DeviceArt(image: image, darkImage: darkImage, markers: markers)
    }

    /// Pixels of the drawing → a marker.
    private static func marker(_ target: Marker.Target, _ x: Double, _ y: Double, _ width: Double, _ height: Double,
                               picture: (width: Double, height: Double)) -> Marker {
        Marker(target: target, x: x / picture.width, y: y / picture.height,
               width: width / picture.width, height: height / picture.height)
    }

    private static let markers: [String: [Marker]] = {
        // MX Master 3S from the side, 636 × 1024.
        let mouse = (width: 636.0, height: 1024.0)
        let mouseMarkers = [
            marker(.control(0x0052), 436, 200, 64, 154, picture: mouse),  // wheel
            marker(.control(0x00C4), 504, 382, 45, 61, picture: mouse),   // mode shift
            marker(.control(0x0056), 236, 460, 38, 82, picture: mouse),   // forward
            marker(.control(0x0053), 263, 569, 45, 82, picture: mouse),   // back
            marker(.control(0x00C3), 45, 616, 51, 102, picture: mouse),   // gesture
            marker(.thumbWheel, 314, 478, 83, 102, picture: mouse),
        ]
        // MX Keys Mini from the front, 1382 × 616: the top row, 77 px keys every 88.6 px from x 34.
        let keyboard = (width: 1382.0, height: 616.0)
        let topRow: [(index: Int, cid: UInt16)] = [
            (4, 0x00E2), (5, 0x00E3), (6, 0x0103), (7, 0x0108), (8, 0x010A), (9, 0x011C),  // F4–F9
            (10, 0x00E5), (11, 0x00E7), (12, 0x00E8), (13, 0x00E9), (14, 0x0117),         // F10–F12, ins, del/lock
        ]
        let keyMarkers = topRow.map { key in
            marker(.control(key.cid), 34 + Double(key.index) * 88.6 + 38.5, 118, 80, 57, picture: keyboard)
        }
        return ["2b034": mouseMarkers, "2b369": keyMarkers]
    }()
}

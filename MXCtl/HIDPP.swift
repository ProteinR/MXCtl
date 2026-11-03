import Foundation

/// Logitech HID++ 2.0 packets, without I/O (tested in LogicTests).
///
/// A long report is 20 bytes: report ID 0x11, device index, feature index, function << 4 | software
/// ID, 16 parameter bytes. Over Bluetooth the device index is 0xFF. Answers carry our software ID;
/// notifications (pressed diverted buttons, raw XY) carry 0. An error answer has feature index 0xFF.
enum HIDPP {
    static let longReportID: UInt8 = 0x11
    static let longReportLength = 20
    static let bleDeviceIndex: UInt8 = 0xFF
    /// Ours, so answers to Logi Options+ (if it still runs) are not taken for ours.
    static let softwareID: UInt8 = 0x0B

    enum Feature: UInt16 {
        case root = 0x0000
        case featureSet = 0x0001
        case deviceInfo = 0x0003 // DEVICE_INFORMATION: extended model ID = the colour
        case deviceName = 0x0005
        case battery = 0x1004 // UNIFIED_BATTERY
        case reprogControls = 0x1B04 // REPROG_CONTROLS_V4
        case smartShift = 0x2110
        case smartShiftEnhanced = 0x2111
    }

    struct Message: Equatable {
        var deviceIndex: UInt8
        var featureIndex: UInt8
        var function: UInt8
        var softwareID: UInt8
        var params: [UInt8]

        var isError: Bool { featureIndex == 0xFF }
        /// For an error: the feature index and function of the failed request, and the error code.
        var errorCode: UInt8? { isError && params.count >= 2 ? params[1] : nil }
    }

    static func request(featureIndex: UInt8, function: UInt8, params: [UInt8] = [],
                        deviceIndex: UInt8 = bleDeviceIndex) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: longReportLength)
        report[0] = longReportID
        report[1] = deviceIndex
        report[2] = featureIndex
        report[3] = (function << 4) | softwareID
        for (i, byte) in params.prefix(16).enumerated() { report[4 + i] = byte }
        return report
    }

    /// Parses an input report; nil when it is not a long HID++ report.
    static func parse(_ report: [UInt8]) -> Message? {
        guard report.count >= 4, report[0] == longReportID else { return nil }
        if report[2] == 0xFF {
            // 11 FF FF <feature index> <function|sw> <error code>
            return Message(deviceIndex: report[1], featureIndex: 0xFF, function: report[4] >> 4,
                           softwareID: report[4] & 0x0F, params: [report[3], report.count > 5 ? report[5] : 0])
        }
        return Message(deviceIndex: report[1], featureIndex: report[2], function: report[3] >> 4,
                       softwareID: report[3] & 0x0F, params: Array(report.dropFirst(4)))
    }

    static func uint16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        guard bytes.count > offset + 1 else { return 0 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    static func int16(_ bytes: [UInt8], at offset: Int) -> Int {
        Int(Int16(bitPattern: uint16(bytes, at: offset)))
    }

    static func bytes(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
}

/// REPROG_CONTROLS_V4 (0x1B04): the keys and buttons a device lets software take over.
enum ReprogControls {
    /// getCidInfo flags (first byte | second byte << 8).
    struct Flags: OptionSet {
        let rawValue: UInt16
        static let mouse = Flags(rawValue: 0x01)
        static let fnKey = Flags(rawValue: 0x02)
        static let reprogrammable = Flags(rawValue: 0x10)
        static let divertable = Flags(rawValue: 0x20)
        static let persistentlyDivertable = Flags(rawValue: 0x40)
        static let virtual = Flags(rawValue: 0x80)
        static let rawXY = Flags(rawValue: 0x100)
    }

    struct Control: Equatable, Codable, Hashable {
        var cid: UInt16
        var taskID: UInt16
        var flags: UInt16

        var isDivertable: Bool { Flags(rawValue: flags).contains(.divertable) }
        var hasRawXY: Bool { Flags(rawValue: flags).contains(.rawXY) }
        var isVirtual: Bool { Flags(rawValue: flags).contains(.virtual) }
    }

    static let getCount: UInt8 = 0
    static let getCidInfo: UInt8 = 1
    static let getCidReporting: UInt8 = 2
    static let setCidReporting: UInt8 = 3

    /// Events: function 0 lists the diverted controls held now (up to 4), function 1 is raw XY.
    static let buttonsEvent: UInt8 = 0
    static let rawXYEvent: UInt8 = 1

    static func control(from params: [UInt8]) -> Control {
        let flags = UInt16(params.count > 4 ? params[4] : 0) | UInt16(params.count > 8 ? params[8] : 0) << 8
        return Control(cid: HIDPP.uint16(params, at: 0), taskID: HIDPP.uint16(params, at: 2), flags: flags)
    }

    /// setCidReporting parameters. Each flag has a "valid" bit next to it (divert 0x01/0x02,
    /// raw XY 0x10/0x20); a cleared value with its valid bit set turns the flag off.
    static func reportingParams(cid: UInt16, divert: Bool, rawXY: Bool) -> [UInt8] {
        var flags: UInt8 = 0x02 | (divert ? 0x01 : 0)
        if rawXY || !divert { flags |= 0x20 | (rawXY ? 0x10 : 0) }
        return HIDPP.bytes(cid) + [flags, 0x00, 0x00]
    }

    static func pressedControls(from params: [UInt8]) -> Set<UInt16> {
        var result = Set<UInt16>()
        for offset in stride(from: 0, to: 8, by: 2) {
            let cid = HIDPP.uint16(params, at: offset)
            if cid != 0 { result.insert(cid) }
        }
        return result
    }

    static func rawXY(from params: [UInt8]) -> (dx: Int, dy: Int) {
        (HIDPP.int16(params, at: 0), HIDPP.int16(params, at: 2))
    }
}

/// SMART_SHIFT (0x2110) and SMART_SHIFT_ENHANCED (0x2111): the wheel switches from ratchet to free
/// spin when turned faster than a threshold.
enum SmartShift {
    /// Wheel mode byte: 0 = keep, 1 = free spin, 2 = ratchet.
    enum Mode: UInt8, Codable {
        case keep = 0, freeSpin = 1, ratchet = 2
    }

    /// The ratchet control mode: mode, threshold (1…254; 255 = always ratchet).
    struct State: Equatable {
        var mode: Mode
        var threshold: UInt8
    }

    static func readFunction(enhanced: Bool) -> UInt8 { enhanced ? 1 : 0 }
    static func writeFunction(enhanced: Bool) -> UInt8 { enhanced ? 2 : 1 }

    static func state(from params: [UInt8]) -> State {
        State(mode: Mode(rawValue: params.first ?? 0) ?? .keep, threshold: params.count > 1 ? params[1] : 0)
    }

    static func params(_ state: State) -> [UInt8] { [state.mode.rawValue, state.threshold] }
}

/// BACKLIGHT2 (0x1982), the keyboard backlight. Read with function 0:
/// enabled, options (mode in bits 3–4: 1 = automatic by the light sensor, 3 = manual), supported
/// options, effects (2), level, and how long it stays lit — hands out, hands in, on power — in
/// 5-second units (2 bytes each, little-endian). Written with function 1:
/// enabled, options, 0xFF, level (manual mode only), the three durations.
struct BacklightConfig: Equatable {
    var enabled: Bool
    var options: UInt8
    var level: Int
    var handsOut: Int
    var handsIn: Int
    var powered: Int

    static let readFunction: UInt8 = 0
    static let writeFunction: UInt8 = 1

    var mode: Int { Int(options >> 3) & 0x03 }
    var isAutomatic: Bool { mode == 1 }

    init?(params: [UInt8]) {
        guard params.count >= 12 else { return nil }
        func le(_ offset: Int) -> Int { Int(params[offset]) | Int(params[offset + 1]) << 8 }
        enabled = params[0] != 0
        options = params[1]
        level = Int(params[5])
        handsOut = le(6)
        handsIn = le(8)
        powered = le(10)
    }

    var writeParams: [UInt8] {
        func le(_ value: Int) -> [UInt8] { [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)] }
        return [enabled ? 1 : 0, options, 0xFF, mode == 3 ? UInt8(level) : 0] + le(handsOut) + le(handsIn) + le(powered)
    }

    /// "вкл, авто, уровень 4, гаснет через 30 с".
    var summary: String {
        guard enabled else { return String(localized: "выключена") }
        let mode = isAutomatic ? String(localized: "авто по датчику света")
            : self.mode == 3 ? String(localized: "ручной режим") : String(localized: "режим \(self.mode)")
        return String(localized: "включена, \(mode), уровень \(level), гаснет через \(handsOut * 5) с")
    }
}

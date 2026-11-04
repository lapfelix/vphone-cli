import CoreFoundation
import Foundation
import IcliKit
import IcliPrivate
import VphonedNative

// MARK: - Buttons, Text, Gestures

extension GuestAPI {
    /// Gesture coordinates are screen points, as `device.screen` reports them.
    static func executeInput(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        switch method {
        case "input.button":
            return try pressButton(string(params, "name"))
        case "input.key":
            return try pressKey(string(params, "name"))
        case "input.type":
            return try typeText(string(params, "text"), delayMS: number(params, "delay_ms", default: 30))
        case "input.paste":
            return try pasteText(string(params, "text"))
        case "input.tap":
            let x = try requiredNumber(params, "x")
            let y = try requiredNumber(params, "y")
            if vp_research_touch_mode() {
                try researchTouchSequence([
                    TouchEvent(phase: .down, x: x, y: y, delayMS: 50),
                    TouchEvent(phase: .up, x: x, y: y),
                ], normalized: false)
                return ["x": x, "y": y]
            }
            return try tap(x: x, y: y)
        case "input.double_tap":
            let x = try requiredNumber(params, "x")
            let y = try requiredNumber(params, "y")
            let interval = number(params, "interval", default: 0.1)
            if vp_research_touch_mode() {
                try researchDuration(interval, name: "interval", maximum: 1)
                try researchTouchSequence([
                    TouchEvent(phase: .down, x: x, y: y, delayMS: 50),
                    TouchEvent(phase: .up, x: x, y: y, delayMS: interval * 1000),
                    TouchEvent(phase: .down, x: x, y: y, delayMS: 50),
                    TouchEvent(phase: .up, x: x, y: y),
                ], normalized: false)
                return ["x": x, "y": y]
            }
            return try doubleTap(x: x, y: y, interval: interval)
        case "input.long_press":
            let x = try requiredNumber(params, "x")
            let y = try requiredNumber(params, "y")
            let seconds = number(params, "seconds", default: 1)
            if vp_research_touch_mode() {
                try researchDuration(seconds, name: "seconds")
                try researchTouchSequence([
                    TouchEvent(phase: .down, x: x, y: y, delayMS: seconds * 1000),
                    TouchEvent(phase: .up, x: x, y: y),
                ], normalized: false)
                return ["x": x, "y": y, "seconds": seconds]
            }
            return try longPress(x: x, y: y, seconds: seconds)
        case "input.swipe":
            let x1 = try requiredNumber(params, "x1")
            let y1 = try requiredNumber(params, "y1")
            let x2 = try requiredNumber(params, "x2")
            let y2 = try requiredNumber(params, "y2")
            let seconds = number(params, "seconds", default: 0.3)
            let steps = (params["steps"] as? NSNumber)?.intValue ?? 20
            if vp_research_touch_mode() {
                try researchDrag(points: [(x1, y1), (x2, y2)], seconds: seconds, hold: 0, steps: steps)
                return ["from": [x1, y1], "to": [x2, y2]]
            }
            return try swipe(x1: x1, y1: y1, x2: x2, y2: y2, seconds: seconds, steps: steps)
        case "input.drag":
            guard let rows = params["points"] as? [[NSNumber]], rows.count >= 2,
                  rows.allSatisfy({ $0.count == 2 })
            else {
                throw GuestAPIError.invalidRequest("points must be at least two [x, y] pairs")
            }
            let points = rows.map { ($0[0].doubleValue, $0[1].doubleValue) }
            let seconds = number(params, "seconds", default: 0.5)
            let hold = number(params, "hold", default: 0.5)
            let steps = (params["steps"] as? NSNumber)?.intValue ?? 20
            if vp_research_touch_mode() {
                try researchDrag(points: points, seconds: seconds, hold: hold, steps: steps)
                return ["points": points.count]
            }
            return try drag(points: points, seconds: seconds, hold: hold, steps: steps)
        case "input.touch_sequence":
            guard let events = params["events"] as? [[String: Any]] else {
                throw GuestAPIError.invalidRequest("events must be an array of {phase, x, y, delay_ms}")
            }
            let json = try String(decoding: JSONSerialization.data(withJSONObject: events), as: UTF8.self)
            let parsed = try TouchEvent.list(fromJSON: json)
            let normalized = bool(params, "normalized", default: true)
            if vp_research_touch_mode() {
                return try researchTouchSequence(parsed, normalized: normalized)
            }
            return try touchSequence(parsed, normalized: normalized)
        default:
            return nil
        }
    }

    // MARK: - Research Guests touchscreen

    /// IcliKit's high-level gestures use an event sender that Apple's VRE
    /// host has no matching digitizer service for. Send the same gesture path
    /// through the virtual HID touchscreen registered by vphoned instead.
    private static func researchTouchSequence(_ events: [TouchEvent], normalized: Bool) throws -> [String: Any] {
        guard (1 ... 10000).contains(events.count) else {
            throw GuestAPIError.invalidRequest("a sequence needs 1–10000 events")
        }
        guard events.allSatisfy({ $0.delayMS.isFinite && (0 ... 60000).contains($0.delayMS) }),
              events.reduce(0, { $0 + $1.delayMS }) <= 300_000
        else {
            throw GuestAPIError.invalidRequest("delay_ms must be 0–60000 per event and at most 300000 in total")
        }
        let points = try events.map { try researchDigitizerPoint($0.x, $0.y, normalized: normalized) }
        let start = ProcessInfo.processInfo.systemUptime
        var down = false
        for (event, point) in zip(events, points) {
            let status = vp_research_touch_report(touchPhaseCode(event.phase), point.0, point.1)
            guard status == 0 else {
                if down { _ = vp_research_touch_report(touchPhaseCode(.up), point.0, point.1) }
                throw GuestAPIError.operationFailed("Research Guest virtual touchscreen report failed (IOReturn \(status))")
            }
            down = event.phase != .up
            if event.delayMS > 0 { Thread.sleep(forTimeInterval: event.delayMS / 1000) }
        }
        return ["events": events.count, "normalized": normalized, "finger_down": down,
                "duration_ms": Int((ProcessInfo.processInfo.systemUptime - start) * 1000)]
    }

    private static func researchDigitizerPoint(_ x: Double, _ y: Double, normalized: Bool) throws -> (Double, Double) {
        if normalized {
            guard x.isFinite, y.isFinite, (0 ... 1).contains(x), (0 ... 1).contains(y) else {
                throw GuestAPIError.invalidRequest("normalized coordinates must be between 0 and 1")
            }
            return (x, y)
        }
        let metrics = icli_screen_metrics()
        guard x.isFinite, y.isFinite, x >= 0, y >= 0, x < metrics.width, y < metrics.height else {
            throw GuestAPIError.invalidRequest("coordinates must be finite points inside the screen")
        }
        var nx = 0.0
        var ny = 0.0
        icli_screen_point_to_digitizer(x, y, &nx, &ny)
        return (nx, ny)
    }

    private static func researchDrag(points: [(Double, Double)], seconds: Double, hold: Double, steps: Int) throws {
        guard (2 ... 1000).contains(points.count), (points.count - 1 ... 2000).contains(steps) else {
            throw GuestAPIError.invalidRequest("drag needs 2–1000 points and steps >= segments, up to 2000")
        }
        try researchDuration(seconds, name: "seconds")
        try researchDuration(hold, name: "hold", allowZero: true)
        var events = [TouchEvent(phase: .down, x: points[0].0, y: points[0].1, delayMS: hold * 1000)]
        for segment in 0 ..< points.count - 1 {
            let samples = steps / (points.count - 1) + (segment < steps % (points.count - 1) ? 1 : 0)
            for step in 1 ... samples {
                let fraction = Double(step) / Double(samples)
                let x = points[segment].0 + (points[segment + 1].0 - points[segment].0) * fraction
                let y = points[segment].1 + (points[segment + 1].1 - points[segment].1) * fraction
                events.append(TouchEvent(phase: .move, x: x, y: y, delayMS: seconds * 1000 / Double(steps)))
            }
        }
        let last = points[points.count - 1]
        events.append(TouchEvent(phase: .up, x: last.0, y: last.1))
        _ = try researchTouchSequence(events, normalized: false)
    }

    private static func researchDuration(_ value: Double, name: String, maximum: Double = 60, allowZero: Bool = false) throws {
        guard value.isFinite, value <= maximum, allowZero ? value >= 0 : value > 0 else {
            throw GuestAPIError.invalidRequest("\(name) must be \(allowZero ? "nonnegative" : "positive") and at most \(maximum) seconds")
        }
    }

    // MARK: - Accessibility and OCR

    static func executeInterface(_ method: String, _ params: [String: Any]) throws -> [String: Any]? {
        interfaceLock.lock()
        defer { interfaceLock.unlock() }
        switch method {
        case "ui.tree", "accessibility.tree":
            if let value = params["nested"] {
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw GuestAPIError.invalidRequest("nested must be a boolean")
                }
            }
            if bool(params, "nested") {
                return try nestedHierarchy(params)
            }
            return try uiElements(
                maxElements: (params["max_elements"] as? NSNumber)?.intValue ?? 500,
                visibleOnly: bool(params, "visible_only", default: true),
                clickableOnly: bool(params, "clickable_only"),
                limit: (params["limit"] as? NSNumber)?.intValue,
            )
        case "ui.element_at":
            return try elementAt(x: requiredNumber(params, "x"), y: requiredNumber(params, "y"))
        case "ui.tap_element":
            return try tapElement(selector(params))
        case "ui.wait", "ui.wait_gone":
            return try waitForElement(
                selector(params),
                appear: method == "ui.wait",
                timeout: number(params, "timeout", default: 10),
            )
        case "ui.ocr":
            try requireTextRecognition()
            return try recognizeScreen(
                languages: params["languages"] as? [String] ?? ["en-US"],
                minConfidence: Float(number(params, "min_confidence", default: 0.3)),
            )
        case "ui.describe":
            try requireTextRecognition()
            return try describeScreen()
        default:
            return nil
        }
    }

    /// IcliKit's OCR is Vision's, which watchOS does not ship: vphoned links
    /// it weakly, so its classes are nil on a watch.
    private static func requireTextRecognition() throws {
        guard NSClassFromString("VNRecognizeTextRequest") != nil else {
            throw GuestAPIError.operationFailed("Text recognition needs Vision, which this guest does not have")
        }
    }

    private static func selector(_ params: [String: Any]) throws -> ElementSelector {
        try ElementSelector(
            text: optionalString(params, "text"),
            identifier: optionalString(params, "identifier"),
            role: optionalString(params, "role"),
            match: optionalString(params, "match") ?? "contains",
            index: (params["index"] as? NSNumber)?.intValue ?? 0,
        )
    }
}

import AppKit
import Foundation

// MARK: - Research Guest viewer

/// A small viewer for Apple's separate Research Guests host. It uses only the
/// guest's authenticated HTTP API; this process does not own a VZVirtualMachine.
@MainActor
final class VPhoneResearchGuestViewer: NSObject, NSWindowDelegate {
    private let endpoint: URL
    private let token: String
    private let session: URLSession
    private let window: NSWindow
    private let screen: VPhoneResearchGuestScreenView
    private var screenshotTask: Task<Void, Never>?
    private var inputTail: Task<Void, Never>?
    private var lastStatus = ""

    static func run(host: String, token: String) throws {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = 1339
        components.path = "/v1/rpc"
        guard let endpoint = components.url, !token.isEmpty else {
            throw VPhoneResearchViewerError.invalidConnection
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let viewer = VPhoneResearchGuestViewer(endpoint: endpoint, token: token)
        viewer.show()
        withExtendedLifetime(viewer) { app.run() }
    }

    private init(endpoint: URL, token: String) {
        self.endpoint = endpoint
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        session = URLSession(configuration: configuration)

        screen = VPhoneResearchGuestScreenView(frame: NSRect(x: 0, y: 0, width: 390, height: 780))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
        )
        super.init()

        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 260, height: 400)
        window.title = "vphone Research Guest — connecting"
        window.center()
        window.contentView = screen
        window.delegate = self
        screen.onTouch = { [weak self] phase, x, y, edge in
            self?.enqueueTouch(phase: phase, x: x, y: y, edge: edge)
        }
    }

    private func show() {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        screenshotTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.refreshScreenshot()
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        screenshotTask?.cancel()
        inputTail?.cancel()
        session.invalidateAndCancel()
        NSApplication.shared.stop(nil)
    }

    private func refreshScreenshot() async {
        do {
            let result = try await call("screen.screenshot")
            guard let encoded = result["data"] as? String,
                  let data = Data(base64Encoded: encoded),
                  let image = NSImage(data: data)
            else {
                throw VPhoneResearchViewerError.invalidScreenshot
            }
            let width = (result["width"] as? NSNumber)?.doubleValue ?? image.size.width
            let height = (result["height"] as? NSNumber)?.doubleValue ?? image.size.height
            guard width > 0, height > 0 else { throw VPhoneResearchViewerError.invalidScreenshot }
            screen.setImage(image, pixelSize: NSSize(width: width, height: height))
            setStatus("connected")
        } catch {
            setStatus("connection error: \(error.localizedDescription)")
        }
    }

    private func enqueueTouch(phase: String, x: Double, y: Double, edge: Int) {
        let previous = inputTail
        inputTail = Task { [weak self] in
            _ = await previous?.value
            guard let self, !Task.isCancelled else { return }
            do {
                _ = try await self.call("input.touch", params: [
                    "phase": phase, "x": x, "y": y, "normalized": true, "edge": edge,
                ])
            } catch {
                self.setStatus("input error: \(error.localizedDescription)")
            }
        }
    }

    private func setStatus(_ status: String) {
        guard status != lastStatus else { return }
        lastStatus = status
        window.title = "vphone Research Guest — \(status)"
        if status != "connected" {
            FileHandle.standardError.write(Data("[research viewer] \(status)\n".utf8))
        }
    }

    private func call(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: [
            "method": method, "params": params, "id": UUID().uuidString,
        ])
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let wire = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw VPhoneResearchViewerError.invalidResponse }
        if let error = wire["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "The guest rejected the request."
            throw VPhoneResearchViewerError.guest(message)
        }
        guard (200 ..< 300).contains(http.statusCode),
              let result = wire["result"] as? [String: Any]
        else { throw VPhoneResearchViewerError.invalidResponse }
        return result
    }
}

private enum VPhoneResearchViewerError: LocalizedError {
    case invalidConnection
    case invalidScreenshot
    case invalidResponse
    case guest(String)

    var errorDescription: String? {
        switch self {
        case .invalidConnection: "A guest host and API token are required."
        case .invalidScreenshot: "The guest returned an invalid screenshot."
        case .invalidResponse: "The guest returned an invalid API response."
        case .guest(let message): message
        }
    }
}

// MARK: - Screen and touch mapping

@MainActor
private final class VPhoneResearchGuestScreenView: NSView {
    var onTouch: ((String, Double, Double, Int) -> Void)?
    private var image: NSImage?
    private var pixelSize = NSSize(width: 1, height: 1)
    private var touching = false
    private var touchEdge = 0
    private var lastTouchPoint: (x: Double, y: Double)?

    override var acceptsFirstResponder: Bool { true }

    func setImage(_ image: NSImage, pixelSize: NSSize) {
        self.image = image
        self.pixelSize = pixelSize
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let image else { return }
        image.draw(in: imageRect, from: .zero, operation: .copy, fraction: 1)
    }

    override func mouseDown(with event: NSEvent) {
        guard let point = touchPoint(for: event, clamp: false) else { return }
        touching = true
        // SpringBoard's home and system-edge gestures require the digitizer's
        // edge metadata and an exact edge start. Keep ordinary controls near
        // the bottom corners available for taps.
        touchEdge = point.y >= 0.95 && (0.2 ... 0.8).contains(point.x)
            ? 2 : (point.y <= 0.02 ? 1 : 0)
        let start = (x: point.x, y: touchEdge == 2 ? 1.0 : (touchEdge == 1 ? 0.01 : point.y))
        lastTouchPoint = start
        onTouch?("down", start.x, start.y, touchEdge)
    }

    override func mouseDragged(with event: NSEvent) {
        guard touching, let point = touchPoint(for: event, clamp: true) else { return }
        sendMoves(to: point)
    }

    override func mouseUp(with event: NSEvent) {
        guard touching else { return }
        touching = false
        if let point = touchPoint(for: event, clamp: true) {
            sendMoves(to: point)
            onTouch?("up", point.x, point.y, touchEdge)
        }
        touchEdge = 0
        lastTouchPoint = nil
    }

    private func sendMoves(to point: (x: Double, y: Double)) {
        guard let lastTouchPoint else { return }
        let distance = hypot(point.x - lastTouchPoint.x, point.y - lastTouchPoint.y)
        guard distance > 0.001 else { return }
        // A fast mouse drag can contain very few events. Give the guest's
        // gesture recognizer a continuous path before the finger lifts.
        let steps = max(1, Int(ceil(distance / 0.06)))
        for step in 1 ... steps {
            let fraction = Double(step) / Double(steps)
            onTouch?(
                "move",
                lastTouchPoint.x + (point.x - lastTouchPoint.x) * fraction,
                lastTouchPoint.y + (point.y - lastTouchPoint.y) * fraction,
                touchEdge,
            )
        }
        self.lastTouchPoint = point
    }

    private var imageRect: NSRect {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return .zero }
        let scale = min(bounds.width / pixelSize.width, bounds.height / pixelSize.height)
        let size = NSSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
        return NSRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height,
        )
    }

    private func touchPoint(for event: NSEvent, clamp: Bool) -> (x: Double, y: Double)? {
        guard image != nil else { return nil }
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        if !clamp && !rect.contains(point) { return nil }
        let x = min(1, max(0, (point.x - rect.minX) / rect.width))
        // AppKit uses a lower-left origin; the guest digitizer uses upper-left.
        let y = min(1, max(0, 1 - (point.y - rect.minY) / rect.height))
        return (x, y)
    }
}

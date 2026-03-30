import FlutterMacOS
import Foundation

/// Flutter plugin that creates GhosttyTerminalView instances as PlatformViews.
///
/// Channels:
///   MethodChannel "dev.tether/ghostty_input":
///     sendText({viewId, text})
///     sendKey({viewId, key, modifiers})
///     setActive({viewId, active})
///   EventChannel "dev.tether/ghostty_events/{viewId}":
///     {type: "title", value: "..."} | {type: "exited"}
class GhosttyPlugin: NSObject, FlutterPlugin, FlutterPlatformViewFactory {
    private var registrar: FlutterPluginRegistrar!
    private var views: [Int64: GhosttyTerminalView] = [:]
    private var inputChannel: FlutterMethodChannel?

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = GhosttyPlugin()
        plugin.registrar = registrar

        // Register as platform view factory
        registrar.register(plugin, withId: "dev.tether/ghostty_surface")

        // Input method channel
        let inputCh = FlutterMethodChannel(
            name: "dev.tether/ghostty_input",
            binaryMessenger: registrar.messenger
        )
        plugin.inputChannel = inputCh
        registrar.addMethodCallDelegate(plugin, channel: inputCh)
    }

    // MARK: - FlutterPlatformViewFactory

    func create(
        withViewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> NSView {
        let params = args as? [String: Any] ?? [:]
        let sessionId = params["sessionId"] as? String ?? ""
        let command = params["command"] as? String
        let cwd = params["cwd"] as? String

        // Create the event channel for this view
        let eventChannel = FlutterEventChannel(
            name: "dev.tether/ghostty_events/\(viewId)",
            binaryMessenger: registrar.messenger
        )

        let view = GhosttyTerminalView(
            sessionId: sessionId,
            command: command,
            cwd: cwd,
            eventSink: { _ in } // placeholder, overwritten by stream handler below
        )

        let handler = GhosttyEventHandler(view: view)
        eventChannel.setStreamHandler(handler)

        views[viewId] = view
        return view
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }

    // MARK: - FlutterPlugin (MethodChannel handler)

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        guard let viewId = args["viewId"] as? Int64,
              let view = views[viewId]
        else {
            result(FlutterError(code: "NO_VIEW", message: "View not found", details: nil))
            return
        }

        switch call.method {
        case "sendText":
            if let text = args["text"] as? String {
                view.sendText(text)
            }
            result(nil)

        case "sendKey":
            // Keys are now handled at the AppKit level (NSView.keyDown:)
            result(nil)

        case "setActive":
            if let active = args["active"] as? Bool {
                view.setActive(active)
            }
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

/// FlutterStreamHandler that connects the EventChannel to a GhosttyTerminalView.
class GhosttyEventHandler: NSObject, FlutterStreamHandler {
    private weak var view: GhosttyTerminalView?
    private var sink: FlutterEventSink?

    init(view: GhosttyTerminalView) {
        self.view = view
    }

    func onListen(
        withArguments arguments: Any?,
        eventSink events: @escaping FlutterEventSink
    ) -> FlutterError? {
        sink = events
        // Patch the view's eventSink now that the stream is active
        view?.setEventSink(events)
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        sink = nil
        view?.setEventSink(nil)
        return nil
    }
}

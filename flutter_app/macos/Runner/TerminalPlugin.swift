import FlutterMacOS
import Foundation

/// Flutter plugin that creates TerminalView instances as PlatformViews.
///
/// Channels:
///   MethodChannel "dev.tether/terminal_input":
///     sendText({viewId, text})
///     setActive({viewId, active})
///     setImagePasteBridgeEnabled({viewId, enabled})
///     performAction({viewId, action})
///   EventChannel "dev.tether/terminal_events/{viewId}":
///     {type: "title", value: "..."} | {type: "exited"} | search events
class TerminalPlugin: NSObject, FlutterPlugin, FlutterPlatformViewFactory {
    private var registrar: FlutterPluginRegistrar!
    private var views: [Int64: TerminalView] = [:]
    private var inputChannel: FlutterMethodChannel?

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = TerminalPlugin()
        plugin.registrar = registrar

        // Register as platform view factory
        registrar.register(plugin, withId: "dev.tether/terminal_surface")

        // Input method channel
        let inputCh = FlutterMethodChannel(
            name: "dev.tether/terminal_input",
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
        let serverBaseUrl = params["serverBaseUrl"] as? String
        let authToken = params["authToken"] as? String

        // Create the event channel for this view
        let eventChannel = FlutterEventChannel(
            name: "dev.tether/terminal_events/\(viewId)",
            binaryMessenger: registrar.messenger
        )

        let view = TerminalView(
            sessionId: sessionId,
            serverBaseUrl: serverBaseUrl,
            authToken: authToken,
            eventSink: { _ in } // placeholder, overwritten by stream handler below
        )

        let handler = TerminalEventHandler(view: view)
        eventChannel.setStreamHandler(handler)

        views[viewId] = view
        return view
    }

    func createArgsCodec() -> (any FlutterMessageCodec & NSObjectProtocol)? {
        return FlutterStandardMessageCodec.sharedInstance()
    }

    // MARK: - FlutterPlugin (MethodChannel handler)

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any] ?? [:]
        guard let viewId = args["viewId"] as? Int64 else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing viewId", details: nil))
            return
        }

        // destroyView is handled before the view-existence guard so it can clean up
        // even if the view is in a partially initialized state.
        if call.method == "destroyView" {
            views.removeValue(forKey: viewId)
            result(nil)
            return
        }

        guard let view = views[viewId] else {
            result(FlutterError(code: "NO_VIEW", message: "View not found", details: nil))
            return
        }

        switch call.method {
        case "sendText":
            if let text = args["text"] as? String {
                view.sendText(text)
            }
            result(nil)

        case "setActive":
            if let active = args["active"] as? Bool {
                view.setActive(active)
            }
            result(nil)

        case "setImagePasteBridgeEnabled":
            if let enabled = args["enabled"] as? Bool {
                view.setImagePasteBridgeEnabled(enabled)
            }
            result(nil)

        case "performAction":
            if let action = args["action"] as? String {
                view.performAction(action)
            }
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}

/// FlutterStreamHandler that connects the EventChannel to a TerminalView.
class TerminalEventHandler: NSObject, FlutterStreamHandler {
    private weak var view: TerminalView?
    private var sink: FlutterEventSink?

    init(view: TerminalView) {
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

import FlutterMacOS
import AppKit

/// Demo 4: minimal FlutterPlatformViewFactory returning a red NSView.
/// Validates the PlatformView infrastructure before adding libghostty.
class DemoPlugin: NSObject, FlutterPlugin, FlutterPlatformViewFactory {

    static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = DemoPlugin()
        registrar.register(plugin, withId: "demo/colored_view")
    }

    func create(
        withViewIdentifier viewId: Int64,
        arguments args: Any?
    ) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.red.cgColor
        return view
    }

    func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }

    // FlutterPlugin stub
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        result(FlutterMethodNotImplemented)
    }
}

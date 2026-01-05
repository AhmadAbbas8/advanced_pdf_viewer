import Flutter
import UIKit

public class AdvancedPdfViewerPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "advanced_pdf_viewer", binaryMessenger: registrar.messenger())
    let instance = AdvancedPdfViewerPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
    
    let factory = IOSPdfViewFactory(messenger: registrar.messenger())
    registrar.register(factory, withId: "advanced_pdf_viewer_view")
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    default:
      result(FlutterMethodNotImplemented)
    }
  }
}

import Flutter
import AuthenticationServices
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    configureAutofillChannel()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  private func configureAutofillChannel() {
    guard let controller = window?.rootViewController as? FlutterViewController else {
      return
    }

    let channel = FlutterMethodChannel(
      name: "app.keytitan/autofill",
      binaryMessenger: controller.binaryMessenger
    )

    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "configure":
        guard
          let args = call.arguments as? [String: Any],
          let enabled = args["enabled"] as? Bool
        else {
          result(nil)
          return
        }
        if enabled {
          result(nil)
        } else {
          self.clearCredentialIdentities(result: result)
        }
      case "updateEntries":
        guard
          let args = call.arguments as? [String: Any],
          let entries = args["entries"] as? [[String: Any]]
        else {
          result(nil)
          return
        }
        self.saveCredentialIdentities(entries: entries, result: result)
      case "clearEntries":
        self.clearCredentialIdentities(result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func saveCredentialIdentities(
    entries: [[String: Any]],
    result: @escaping FlutterResult
  ) {
    let identities = entries.flatMap { entry -> [ASPasswordCredentialIdentity] in
      let title = entry["title"] as? String ?? ""
      let site = entry["site"] as? String ?? ""
      let username = entry["username"] as? String ?? ""
      let uris = entry["uris"] as? [String] ?? []
      let candidates = uris.isEmpty ? [site] : uris

      return candidates.compactMap { rawIdentifier in
        guard let serviceIdentifier = credentialServiceIdentifier(rawIdentifier) else {
          return nil
        }
        return ASPasswordCredentialIdentity(
          serviceIdentifier: serviceIdentifier,
          user: username,
          recordIdentifier: [title, site, username].joined(separator: "|")
        )
      }
    }

    if identities.isEmpty {
      clearCredentialIdentities(result: result)
      return
    }

    ASCredentialIdentityStore.shared.saveCredentialIdentities(identities) {
      success,
      error in
      if let error = error {
        result(FlutterError(code: "ios_autofill_identity_save_failed", message: error.localizedDescription, details: nil))
      } else {
        result(success)
      }
    }
  }

  private func clearCredentialIdentities(result: @escaping FlutterResult) {
    ASCredentialIdentityStore.shared.removeAllCredentialIdentities {
      success,
      error in
      if let error = error {
        result(FlutterError(code: "ios_autofill_identity_clear_failed", message: error.localizedDescription, details: nil))
      } else {
        result(success)
      }
    }
  }

  private func credentialServiceIdentifier(
    _ rawIdentifier: String
  ) -> ASCredentialServiceIdentifier? {
    let trimmed = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty ||
      trimmed.hasPrefix("androidapp://") ||
      trimmed.hasPrefix("app://") {
      return nil
    }

    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
      return ASCredentialServiceIdentifier(identifier: trimmed, type: .URL)
    }

    return ASCredentialServiceIdentifier(identifier: trimmed, type: .domain)
  }
}

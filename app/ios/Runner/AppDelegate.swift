import Flutter
import UIKit
import AVFoundation

@main
@objc class AppDelegate: FlutterAppDelegate {
  private var audioBroker: IosAudioHostBroker?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    if let controller = window?.rootViewController as? FlutterViewController {
      audioBroker = IosAudioHostBroker(messenger: controller.binaryMessenger)
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}

class IosAudioHostBroker: NSObject {
  private let channel: FlutterMethodChannel
  private let channelName = "com.bitdrop/audio_device"

  init(messenger: FlutterBinaryMessenger) {
    self.channel = FlutterMethodChannel(name: channelName, binaryMessenger: messenger)
    super.init()

    setupAudioSession()
    setupMethodCallHandler()
    setupNotifications()
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  private func setupAudioSession() {
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .default, options: [.defaultToSpeaker, .allowBluetooth, .allowAirPlay])
      try session.setActive(true)
    } catch {
      print("[bitdrop-ios] Failed to activate audio session: \(error)")
    }
  }

  private func setupMethodCallHandler() {
    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      guard let self = self else {
        result(nil)
        return
      }

      switch call.method {
      case "currentOutput":
        result(self.currentOutput())

      case "setPreferredSampleRate", "setPreferredMixerAttributes":
        let requestedRate: Double
        if let args = call.arguments as? [String: Any] {
          if let rateDouble = args["sampleRate"] as? Double {
            requestedRate = rateDouble
          } else if let rateInt = args["sampleRate"] as? Int {
            requestedRate = Double(rateInt)
          } else {
            requestedRate = 48000.0
          }
        } else {
          requestedRate = 48000.0
        }
        self.setPreferredSampleRate(requestedRate, result: result)

      case "clearPreferredSampleRate", "clearPreferredMixerAttributes":
        self.clearPreferredSampleRate(result: result)

      case "getAudioSessionState":
        result(self.getAudioSessionState())

      case "listUsbAudioDevices":
        result([])

      case "requestUsbPermission":
        result(true)

      case "openUsbDevice":
        result(nil)

      case "closeUsbDevice":
        result(true)

      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func setupNotifications() {
    let center = NotificationCenter.default
    let session = AVAudioSession.sharedInstance()

    center.addObserver(
      self,
      selector: #selector(handleRouteChange),
      name: AVAudioSession.routeChangeNotification,
      object: session
    )

    center.addObserver(
      self,
      selector: #selector(handleInterruption),
      name: AVAudioSession.interruptionNotification,
      object: session
    )

    center.addObserver(
      self,
      selector: #selector(handleMediaServicesWereReset),
      name: AVAudioSession.mediaServicesWereResetNotification,
      object: nil
    )
  }

  @objc private func handleRouteChange(notification: Notification) {
    guard let userInfo = notification.userInfo,
          let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
      DispatchQueue.main.async { [weak self] in
        self?.channel.invokeMethod("onDeviceChanged", nil)
      }
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      self.channel.invokeMethod("onDeviceChanged", nil)

      if reason == .oldDeviceUnavailable {
        print("[bitdrop-ios] audio route changed: oldDeviceUnavailable (becoming noisy)")
        self.channel.invokeMethod("onBecomingNoisy", nil)
      }
    }
  }

  @objc private func handleInterruption(notification: Notification) {
    guard let userInfo = notification.userInfo,
          let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      switch type {
      case .began:
        print("[bitdrop-ios] audio interruption began")
        self.channel.invokeMethod("onInterruptionBegan", nil)
      case .ended:
        let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
        let shouldResume = options.contains(.shouldResume)
        print("[bitdrop-ios] audio interruption ended (shouldResume: \(shouldResume))")
        self.channel.invokeMethod("onInterruptionEnded", ["shouldResume": shouldResume])
      @unknown default:
        break
      }
    }
  }

  @objc private func handleMediaServicesWereReset(notification: Notification) {
    print("[bitdrop-ios] media services reset notification received, reconfiguring audio session")
    setupAudioSession()
    DispatchQueue.main.async { [weak self] in
      self?.channel.invokeMethod("onDeviceChanged", nil)
    }
  }

  private func setPreferredSampleRate(_ rate: Double, result: @escaping FlutterResult) {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setPreferredSampleRate(rate)
      try session.setActive(true)
      let activeRate = session.sampleRate
      print("[bitdrop-ios] setPreferredSampleRate success: requested=\(rate), active=\(activeRate)")
      result(true)
    } catch {
      print("[bitdrop-ios] setPreferredSampleRate failed: \(error)")
      result(false)
    }
  }

  private func clearPreferredSampleRate(result: @escaping FlutterResult) {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setPreferredSampleRate(0.0)
      try session.setActive(true)
      result(true)
    } catch {
      result(false)
    }
  }

  private func getAudioSessionState() -> [String: Any] {
    let session = AVAudioSession.sharedInstance()
    return [
      "sampleRate": session.sampleRate,
      "ioBufferDuration": session.ioBufferDuration,
      "category": session.category.rawValue,
      "outputNumberOfChannels": session.outputNumberOfChannels
    ]
  }

  private func currentOutput() -> [String: Any]? {
    let session = AVAudioSession.sharedInstance()
    guard let output = session.currentRoute.outputs.first else {
      return ["available": false]
    }

    let portType = output.portType
    let deviceName = output.portName

    let typeStr: String
    let maxTier: String
    let supportsBitPerfect: Bool
    let explanation: String

    switch portType {
    case .usbAudio:
      typeStr = "usb"
      maxTier = "bitPerfect"
      supportsBitPerfect = true
      explanation = "iOS CoreAudio hardware sample rate switching via AVAudioSession (Tier A Bit-Perfect)"

    case .headphones, .lineOut:
      typeStr = "wired"
      maxTier = "nativeRate"
      supportsBitPerfect = false
      explanation = "iOS 3.5mm analog output via CoreAudio native clock"

    case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
      typeStr = "bluetooth"
      maxTier = "resampled"
      supportsBitPerfect = false
      explanation = "Bluetooth A2DP/HFP re-encoded with wireless codec (AAC/SBC)"

    case .builtInSpeaker, .builtInReceiver:
      typeStr = "speaker"
      maxTier = "resampled"
      supportsBitPerfect = false
      explanation = "iPhone built-in speakers operating at system mixed sample rate"

    case .airPlay:
      typeStr = "airplay"
      maxTier = "nativeRate"
      supportsBitPerfect = false
      explanation = "Apple AirPlay lossless network audio transport"

    case .hdmi:
      typeStr = "usb"
      maxTier = "nativeRate"
      supportsBitPerfect = false
      explanation = "HDMI digital multichannel audio"

    default:
      typeStr = "unknown"
      maxTier = "resampled"
      supportsBitPerfect = false
      explanation = "Unknown iOS audio route"
    }

    let activeRate = Int(session.sampleRate)
    var supportedRates: [Int] = [44100, 48000, 88200, 96000, 176400, 192000]
    if !supportedRates.contains(activeRate) && activeRate > 0 {
      supportedRates.append(activeRate)
      supportedRates.sort()
    }

    let encodings: [Int] = [4, 2, 21, 22]

    return [
      "available": true,
      "type": typeStr,
      "name": deviceName,
      "id": output.uid,
      "sampleRates": supportedRates,
      "encodings": encodings,
      "systemSampleRate": activeRate,
      "supportsBitPerfect": supportsBitPerfect,
      "maxTier": maxTier,
      "tierExplanation": explanation
    ]
  }
}

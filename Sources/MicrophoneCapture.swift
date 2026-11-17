import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct MicrophoneChoice {
    let id: AudioDeviceID
    let name: String

    static func preferred() -> MicrophoneChoice? {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &size, &ids) == noErr else { return nil }

        for id in ids {
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }

            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }

            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
                  let name else { continue }
            return MicrophoneChoice(id: id, name: name.takeRetainedValue() as String)
        }
        return nil
    }

    static func systemDefaultID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }
}

final class MicrophoneCapture {
    var onLevel: ((Float) -> Void)?
    var onAudioActivity: ((Double, Float) -> Void)?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get {
            bufferHandlerLock.lock()
            defer { bufferHandlerLock.unlock() }
            return bufferHandler
        }
        set {
            bufferHandlerLock.lock()
            bufferHandler = newValue
            bufferHandlerLock.unlock()
        }
    }
    var onInterruption: (() -> Void)?

    private let bufferHandlerLock = NSLock()
    private var bufferHandler: ((AVAudioPCMBuffer) -> Void)?
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var lastLevelUpdate = 0.0
    private var capturedFrames: Int64 = 0

    var isRunning: Bool { engine?.isRunning ?? false }
    var inputFormat: AVAudioFormat? { engine?.inputNode.outputFormat(forBus: 0) }

    func start(preferredDevice: MicrophoneChoice?) throws {
        stop()
        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        // The system's default input already routes to the built-in microphone
        // on this Mac. Avoid resetting that device on a live audio unit.
        if let preferredDevice, preferredDevice.id != MicrophoneChoice.systemDefaultID() {
            guard let unit = input.audioUnit else { throw CaptureError.deviceUnavailable }
            var id = preferredDevice.id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &id,
                                              UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw CaptureError.deviceUnavailable }
        }

        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { throw CaptureError.invalidFormat }
        capturedFrames = 0
        lastLevelUpdate = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.onBuffer?(buffer)
            self.capturedFrames += Int64(buffer.frameLength)
            let now = ProcessInfo.processInfo.systemUptime
            guard now - self.lastLevelUpdate >= 0.12 else { return }
            self.lastLevelUpdate = now
            guard buffer.frameLength > 0 else { return }
            let duration = Double(self.capturedFrames) / format.sampleRate
            guard let channels = buffer.floatChannelData else {
                DispatchQueue.main.async { [weak self] in
                    self?.onLevel?(0)
                    self?.onAudioActivity?(duration, -1)
                }
                return
            }
            let samples = channels[0]
            let count = Int(buffer.frameLength)
            var sum: Float = 0
            for index in 0..<count { sum += samples[index] * samples[index] }
            let rms = sqrt(sum / Float(count))
            let decibels = 20 * log10(max(rms, 0.000001))
            let level = min(1, max(0, (decibels + 60) / 60))
            DispatchQueue.main.async { [weak self] in
                self?.onLevel?(level)
                self?.onAudioActivity?(duration, rms)
            }
        }

        do {
            newEngine.prepare()
            try newEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            newEngine.stop()
            throw error
        }
        engine = newEngine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: newEngine, queue: .main
        ) { [weak self] _ in self?.onInterruption?() }
    }

    /// 暂停收声：停止麦克风硬件采集，但保留引擎、音频格式和已收声时长，便于继续。
    func pause() {
        guard let engine, engine.isRunning else { return }
        engine.pause()
        lastLevelUpdate = 0
        onLevel?(0)
    }

    /// 继续收声：在原有引擎上恢复采集，识别会接着之前的文本继续。
    func resume() throws {
        guard let engine else { throw CaptureError.deviceUnavailable }
        guard !engine.isRunning else { return }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        onBuffer = nil
        onLevel?(0)
    }
}

enum CaptureError: LocalizedError {
    case deviceUnavailable
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable: return "无法使用 Mac 内置麦克风，请检查系统的输入设备。"
        case .invalidFormat: return "麦克风没有提供可用的音频格式。"
        }
    }
}

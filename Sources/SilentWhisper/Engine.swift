import AVFoundation
import AppKit
import SwiftUI
import WhisperKit

enum PillState: Equatable {
    case idle
    case recording
    case transcribing
    case done
    case failed(String)
}

/// Model readiness is deliberately *not* a pill state: warming up happens silently in the
/// background, the blob stays usable, and progress shows up in Settings instead.
enum ModelStatus: Equatable {
    case downloading(Double)   // 0…1
    case warming               // CoreML compile + prewarm, which has no progress to report
    case ready
    case failed(String)

    var isReady: Bool { self == .ready }

    var label: String {
        switch self {
        case .downloading(let f): "Downloading… \(Int(f * 100))%"
        case .warming: "Compiling for the Neural Engine…"
        case .ready: "Ready"
        case .failed(let why): "Failed — \(why)"
        }
    }

    /// Compilation is a one-time, multi-minute, 100%-CPU affair the first time a model is
    /// used on a machine. Without saying so it reads as a hang.
    var detail: String? {
        switch self {
        case .downloading: "Already-downloaded models are reused — this only fetches what's missing."
        case .warming: "One-time per model, and it can take a few minutes. Cached from then on."
        default: nil
        }
    }
}

@MainActor
final class Engine: ObservableObject {
    @Published var state: PillState = .idle
    @Published var amp: Double = 0          // smoothed mic level, 0…1
    @Published var core: Double = 20        // smoothed core diameter, pt
    @Published var sat: Double = 0          // smoothed satellite diameter, pt
    @Published var theme: Theme = Theme(rawValue: UserDefaults.standard.string(forKey: "theme") ?? "") ?? .obsidian {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }

    @Published var model: ModelStatus = .warming

    private var whisper: WhisperKit?
    private var modelTask: Task<Void, Never>?
    private let engine = AVAudioEngine()
    private let mic = Mic()
    private var levelTimer: Timer?
    private var idleTimer: Timer?

    /// Multilingual by default — the `.en` models cannot transcribe anything but English.
    static var modelName: String { UserDefaults.standard.string(forKey: "model") ?? "small" }

    /// nil means "let Whisper detect it".
    static var language: String? {
        let code = UserDefaults.standard.string(forKey: "language") ?? "auto"
        return code == "auto" ? nil : code
    }

    init() {
        // 60 Hz smoothing so the blob moves like speech, not like a meter
        levelTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        modelTask = Task { await loadModel() }
    }

    private func tick() {
        let raw = mic.level
        let target: Double
        switch state {
        case .recording: target = raw
        case .transcribing: target = 0.28 + 0.22 * sin(Date().timeIntervalSinceReferenceDate * 7)
        case .done: target = 0.2
        default: target = 0.08
        }
        amp += (target - amp) * 0.18

        // same easing the CSS mock used for its .5s size transitions
        core += (state.coreDiameter - core) * 0.18
        sat += (state.satelliteDiameter - sat) * 0.18
    }

    // MARK: - model

    /// Swap models without a relaunch. Drops any in-flight take first.
    func reloadModel() {
        if state == .recording { stopRecording() }
        modelTask?.cancel()
        whisper = nil
        modelTask = Task { await loadModel() }
    }

    /// Downloads (reporting progress) then compiles and prewarms. Never touches `state`,
    /// so you can hold the hotkey and talk while this is still running.
    private func loadModel() async {
        let name = Engine.modelName
        model = .downloading(0)
        do {
            let folder = try await WhisperKit.download(variant: name) { progress in
                Task { @MainActor [weak self] in
                    guard let self, !self.model.isReady else { return }
                    self.model = .downloading(progress.fractionCompleted)
                }
            }
            guard !Task.isCancelled else { return }

            model = .warming
            whisper = try await WhisperKit(WhisperKitConfig(
                modelFolder: folder.path,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                download: false
            ))
            guard !Task.isCancelled else { return }
            model = .ready
        } catch {
            guard !Task.isCancelled else { return }
            model = .failed(error.localizedDescription)
        }
    }

    // MARK: - recording

    func toggle() {
        state == .recording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard state != .recording, state != .transcribing else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] ok in
            Task { @MainActor in ok ? self?.beginTap() : self?.fail("microphone denied") }
        }
    }

    private func beginTap() {
        guard state != .recording, state != .transcribing else { return }
        let input = engine.inputNode
        let inFormat = input.inputFormat(forBus: 0)
        guard inFormat.sampleRate > 0,
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 16_000, channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: inFormat, to: outFormat)
        else { fail("no input device"); return }

        mic.begin(conv)
        let mic = self.mic
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { buf, _ in
            mic.consume(buf, into: outFormat)
        }
        do {
            try engine.start()
            state = .recording
        } catch {
            input.removeTap(onBus: 0)
            fail("audio engine: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard state == .recording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        let audio = mic.finish()

        guard audio.count > 16_000 / 4 else { state = .idle; return }   // < 0.25 s, ignore
        state = .transcribing
        Task { await transcribe(audio) }
    }

    private func transcribe(_ audio: [Float]) async {
        // The take is already captured — if the model is still warming up, wait for it
        // rather than throwing away what was just said.
        await modelTask?.value

        guard let whisper else {
            fail(model.isReady ? "model unavailable" : model.label)
            return
        }
        do {
            let language = Engine.language
            let results = try await whisper.transcribe(audioArray: audio, decodeOptions: DecodingOptions(
                task: .transcribe,
                language: language,
                detectLanguage: language == nil,
                skipSpecialTokens: true,
                withoutTimestamps: true
            ))
            let text = results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { state = .idle; return }
            Paster.deliver(text)
            state = .done
            resetSoon(after: 1.1)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func fail(_ msg: String) {
        NSLog("SilentWhisper: %@", msg)
        state = .failed(msg)
        resetSoon(after: 2)
    }

    private func resetSoon(after t: TimeInterval) {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.state = .idle }
        }
    }
}

// MARK: - mic buffer

/// Written by the realtime audio tap, read by the main actor — so it lives outside
/// the actor behind its own lock rather than hopping threads per buffer.
private final class Mic: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []       // 16 kHz mono
    private var rawLevel: Double = 0
    private var converter: AVAudioConverter?

    var level: Double { lock.lock(); defer { lock.unlock() }; return rawLevel }

    func begin(_ conv: AVAudioConverter) {
        lock.lock()
        converter = conv
        rawLevel = 0
        samples.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Hands back everything captured and resets for the next take.
    func finish() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        let audio = samples
        samples = []
        rawLevel = 0
        converter = nil
        return audio
    }

    func consume(_ buf: AVAudioPCMBuffer, into outFormat: AVAudioFormat) {
        guard let conv = { lock.lock(); defer { lock.unlock() }; return converter }() else { return }
        let capacity = AVAudioFrameCount(Double(buf.frameLength) * outFormat.sampleRate / buf.format.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }

        var supplied = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buf
        }
        guard err == nil, out.frameLength > 0, let ch = out.floatChannelData?[0] else { return }

        let n = Int(out.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += ch[i] * ch[i] }
        let rms = sqrt(sum / Float(n))
        // ~ -50 dB floor → 0, -10 dB → 1
        let db = 20 * log10(max(rms, 1e-7))
        let level = min(1, max(0, (Double(db) + 50) / 40))

        lock.lock()
        rawLevel = level
        samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: n))
        lock.unlock()
    }
}

// MARK: - clipboard + auto-paste

enum Paster {
    /// Always copies, then pastes into whatever has focus.
    ///
    /// It deliberately does not check that the focused element looks like a text field:
    /// Electron apps, browsers and Slack all report roles that fail that test, which is
    /// exactly where dictation gets used. Worst case ⌘V goes somewhere harmless and the
    /// text is still on the clipboard.
    static func deliver(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)

        let autoPaste = UserDefaults.standard.object(forKey: "autoPaste") as? Bool ?? true
        guard autoPaste, AXIsProcessTrusted() else { return }
        // Let the hotkey's own modifiers clear first, or ⌘V lands as ⌥⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { pressCommandV() }
    }

    private static func pressCommandV() {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let v: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

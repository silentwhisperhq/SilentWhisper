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
    case downloading(Double)          // 0…1
    case warming                      // CoreML compile + prewarm, no progress to report
    case ready(String)                // the model actually loaded
    case substituting(using: String, want: String, progress: Double)
    case failed(String)

    /// True whenever *something* can transcribe right now, substitute included.
    var isUsable: Bool {
        switch self {
        case .ready, .substituting: true
        default: false
        }
    }

    var label: String {
        switch self {
        case .downloading(let f): "Downloading… \(Int(f * 100))%"
        case .warming: "Compiling for the Neural Engine…"
        case .ready(let name): "Ready — \(name)"
        case .substituting(let using, let want, let p):
            "Using \(using) · fetching \(want)… \(Int(p * 100))%"
        case .failed(let why): "Failed — \(why)"
        }
    }

    /// Compilation is a one-time, multi-minute, 100%-CPU affair the first time a model is
    /// used on a machine. Without saying so it reads as a hang.
    var detail: String? {
        switch self {
        case .downloading: "Nothing else is downloaded yet, so this one has to finish first."
        case .warming: "One-time per model, and it can take a few minutes. Cached from then on."
        case .substituting: "Dictation works now on the model you already have; it swaps over when the download finishes."
        default: nil
        }
    }

    /// Whether there is an in-flight download worth offering to cancel.
    var isCancellable: Bool {
        switch self {
        case .downloading, .substituting: true
        default: false
        }
    }
}

/// Quality order, worst first. Used to pick a stand-in when the chosen model is missing.
private let modelOrder = ["tiny.en", "tiny", "base.en", "base", "small.en", "small", "medium.en", "medium", "large-v3_turbo"]

/// The best already-downloaded model to stand in for `wanted`: the closest one at or below
/// its quality, else the smallest one above.
func fallbackModel(for wanted: String, from onDisk: Set<String>) -> String? {
    guard !onDisk.contains(wanted) else { return wanted }
    let rank = modelOrder.firstIndex(of: wanted) ?? modelOrder.count
    let ranked = onDisk.compactMap { name in modelOrder.firstIndex(of: name).map { ($0, name) } }
        .sorted { $0.0 < $1.0 }
    return ranked.last(where: { $0.0 <= rank })?.1 ?? ranked.first?.1
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

    /// Cached so the 60 Hz tick and every frame of the view are not hitting UserDefaults.
    @Published var calmMotion: Bool = Engine.reducedMotion

    func refreshMotionPreference() { calmMotion = Engine.reducedMotion }

    private var whisper: WhisperKit?
    private var modelTask: Task<Void, Never>?
    private let engine = AVAudioEngine()
    private let mic = Mic()
    private var levelTimer: Timer?
    private var idleTimer: Timer?
    private var transcribeTask: Task<Void, Never>?

    /// Set when a take was started by clicking rather than by holding the key.
    private var handsFree = false
    private var spoke = false          // has the level ever cleared the speech threshold?
    private var quietFrames = 0

    /// Multilingual by default — the `.en` models cannot transcribe anything but English.
    static var modelName: String { UserDefaults.standard.string(forKey: "model") ?? "small" }

    /// Honours the system Reduce Motion setting unless explicitly overridden.
    static var reducedMotion: Bool {
        switch UserDefaults.standard.string(forKey: "reducedMotion") ?? "system" {
        case "on": true
        case "off": false
        default: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }
    }

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
        var target: Double
        switch state {
        case .recording: target = raw
        case .transcribing: target = 0.28 + 0.22 * sin(Date().timeIntervalSinceReferenceDate * 7)
        case .done: target = 0.2
        default: target = 0.08
        }
        // Calm motion keeps the level readout but flattens the idle drift and the
        // transcribing pulse into something steady.
        if calmMotion, state != .recording { target = state == .idle ? 0.1 : 0.3 }
        amp += (target - amp) * (calmMotion ? 0.1 : 0.18)

        // same easing the CSS mock used for its .5s size transitions
        core += (state.coreDiameter - core) * 0.18
        sat += (state.satelliteDiameter - sat) * 0.18

        // ponytail: level threshold, not a real VAD. Ends a hands-free take after ~1.6 s of
        // quiet, but only once you have actually said something.
        guard handsFree, state == .recording else { return }
        if raw > 0.22 { spoke = true; quietFrames = 0 } else { quietFrames += 1 }
        if spoke, quietFrames > 96 { stopRecording() }
    }

    // MARK: - model

    /// Swap models without a relaunch. Drops any in-flight take first.
    func reloadModel() {
        if state == .recording { stopRecording() }
        modelTask?.cancel()
        whisper = nil
        modelTask = Task { await loadModel() }
    }

    /// Abandons an in-flight download and settles on whatever is already loaded.
    func cancelModelDownload() {
        modelTask?.cancel()
        modelTask = nil
        if case .substituting(let using, _, _) = model {
            model = .ready(using)
        } else if whisper == nil {
            model = .failed("cancelled")
        }
    }

    /// Never touches `state`, so you can talk while this runs. If the chosen model is not on
    /// disk but another one is, that one is loaded first and the download continues behind it —
    /// waiting is only unavoidable when nothing at all has been downloaded.
    private func loadModel() async {
        let wanted = Engine.modelName
        let onDisk = downloadedModels

        if !onDisk.contains(wanted), let stand = fallbackModel(for: wanted, from: onDisk) {
            model = .substituting(using: stand, want: wanted, progress: 0)
            await activate(stand, reportingAs: nil)
            guard !Task.isCancelled else { return }
            await fetchAndActivate(wanted, standingIn: stand)
        } else if onDisk.contains(wanted) {
            model = .warming
            await activate(wanted, reportingAs: wanted)
        } else {
            await fetchAndActivate(wanted, standingIn: nil)
        }
    }

    private func fetchAndActivate(_ name: String, standingIn stand: String?) async {
        model = stand.map { .substituting(using: $0, want: name, progress: 0) } ?? .downloading(0)
        do {
            let folder = try await WhisperKit.download(variant: name) { progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let f = progress.fractionCompleted
                    self.model = stand.map { .substituting(using: $0, want: name, progress: f) } ?? .downloading(f)
                }
            }
            guard !Task.isCancelled else { return }
            model = .warming
            await activate(name, reportingAs: name, folder: folder)
        } catch {
            guard !Task.isCancelled else { return }
            // A failed download is survivable when a stand-in is already carrying the load.
            model = stand.map { .ready($0) } ?? .failed(error.localizedDescription)
        }
    }

    /// Compiles and prewarms, then swaps it in as the live model.
    private func activate(_ name: String, reportingAs report: String?, folder: URL? = nil) async {
        do {
            let dir = folder ?? localModelFolder(name)
            let config = dir.map {
                WhisperKitConfig(modelFolder: $0.path, verbose: false, logLevel: .error, prewarm: true, download: false)
            } ?? WhisperKitConfig(model: name, verbose: false, logLevel: .error, prewarm: true, download: true)
            let loaded = try await WhisperKit(config)
            guard !Task.isCancelled else { return }
            whisper = loaded
            if let report { model = .ready(report) }
        } catch {
            guard !Task.isCancelled else { return }
            if report != nil { model = .failed(error.localizedDescription) }
        }
    }

    // MARK: - recording

    /// Clicking always ends whatever is happening: stop a recording, abandon a transcription,
    /// otherwise start a new take.
    func toggle() {
        switch state {
        case .recording: stopRecording()
        case .transcribing: cancel()
        default: startRecording(handsFree: true)
        }
    }

    /// Throws away the current take without pasting anything.
    func cancel() {
        if state == .recording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            _ = mic.finish()
        }
        transcribeTask?.cancel()
        transcribeTask = nil
        handsFree = false
        state = .idle
    }

    /// `handsFree` takes started by clicking have no key to release, so they end themselves
    /// once you stop talking.
    func startRecording(handsFree: Bool = false) {
        guard state != .recording, state != .transcribing else { return }
        self.handsFree = handsFree
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
            spoke = false
            quietFrames = 0
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

        handsFree = false
        guard audio.count > 16_000 / 4 else { state = .idle; return }   // < 0.25 s, ignore
        state = .transcribing
        transcribeTask = Task { await transcribe(audio) }
    }

    private func transcribe(_ audio: [Float]) async {
        // The take is already captured. If a substitute is already loaded, use it now; only
        // an empty slot is worth waiting on.
        if whisper == nil { await modelTask?.value }
        guard !Task.isCancelled else { return }

        guard let whisper else {
            fail(model.isUsable ? "model unavailable" : model.label)
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

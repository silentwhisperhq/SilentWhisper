import ServiceManagement
import SwiftUI

/// Models WhisperKit can pull down on demand. Bigger is slower but sharper.
/// The `.en` variants are English-only — they will happily return nonsense for other languages.
let availableModels = ["tiny", "base", "small", "medium", "large-v3_turbo", "base.en", "small.en"]

/// Which models are already on disk, so the picker can mark them and you know which
/// choices are instant and which mean a download plus a long first compile.
var downloadedModels: Set<String> {
    let folders = (try? FileManager.default.contentsOfDirectory(atPath: modelCache.path)) ?? []
    return Set(folders.compactMap { folder -> String? in
        guard folder.hasPrefix("openai_whisper-"),
              isModelComplete(modelCache.appendingPathComponent(folder))
        else { return nil }
        return String(folder.dropFirst("openai_whisper-".count))
    })
}

/// An interrupted download leaves the folder in place with its weights missing, and CoreML
/// only notices at load time. A model counts as present only when every weight file is there.
func isModelComplete(_ folder: URL) -> Bool {
    ["AudioEncoder", "MelSpectrogram", "TextDecoder"].allSatisfy { part in
        FileManager.default.fileExists(
            atPath: folder.appendingPathComponent("\(part).mlmodelc/weights/weight.bin").path)
    }
}

private var modelCache: URL {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml")
}

/// WhisperKit cannot find an already-downloaded model from its name alone — it needs the
/// folder, or it tries to fetch and fails when downloads are off.
func localModelFolder(_ name: String) -> URL? {
    let url = modelCache.appendingPathComponent("openai_whisper-\(name)")
    return isModelComplete(url) ? url : nil
}

/// A short list rather than all 99 Whisper languages — auto-detect covers the rest.
let languages: [(code: String, name: String)] = [
    ("auto", "Detect automatically"),
    ("tr", "Türkçe"), ("en", "English"), ("de", "Deutsch"), ("fr", "Français"),
    ("es", "Español"), ("it", "Italiano"), ("nl", "Nederlands"), ("pt", "Português"),
    ("ru", "Русский"), ("ar", "العربية"), ("ja", "日本語"), ("zh", "中文"), ("ko", "한국어"),
]

struct SettingsView: View {
    @EnvironmentObject var engine: Engine
    @EnvironmentObject var updater: Updater
    @AppStorage("model") private var model = "small"
    @AppStorage("inputDevice") private var inputDevice = ""   // "" follows the system default
    @AppStorage("spokenLanguages") private var spokenLanguages = ""   // codes, comma separated
    @AppStorage("autoPaste") private var autoPaste = true
    @AppStorage("reducedMotion") private var reducedMotion = "system"
    @AppStorage("aiEnabled") private var aiEnabled = false
    @AppStorage("aiProvider") private var aiProvider = AIProvider.apple.rawValue
    @AppStorage("aiStyle") private var aiStyle = AIStyle.tidy.rawValue
    @AppStorage("aiCustomInstruction") private var customInstruction = ""
    @AppStorage("vocabulary") private var vocabulary = ""

    @EnvironmentObject private var aiPass: AIPass

    /// Held in memory only; the Keychain is the store of record.
    @State private var apiKey = ""

    private var provider: AIProvider { AIProvider(rawValue: aiProvider) ?? .apple }

    /// Each provider keeps its own model choice, so switching back and forth doesn't lose it.
    private var aiModel: Binding<String> {
        Binding(
            get: { UserDefaults.standard.string(forKey: "aiModel-\(aiProvider)") ?? "" },
            set: { UserDefaults.standard.set($0, forKey: "aiModel-\(aiProvider)") }
        )
    }
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var trusted = AXIsProcessTrusted()

    /// Scanning the model cache touches the disk, so it happens on appear and when a
    /// download finishes — never inside `body`, which SwiftUI may run at any rate.
    @State private var onDisk: Set<String> = []
    @State private var mics: [AudioDevices.Device] = []

    private var spoken: [String] {
        spokenLanguages.split(separator: ",").map(String.init).filter { !$0.isEmpty }
    }

    private var spokenSummary: String {
        let names = spoken.compactMap { code in languages.first { $0.code == code }?.name }
        return names.isEmpty ? "Detect automatically" : names.joined(separator: ", ")
    }

    /// The set means three different things by size, so say which one is in force.
    private var languageHint: String {
        switch spoken.count {
        case 0:  "Whisper picks from all 99 languages — that is where a stray one comes from."
        case 1:  "Pinned. No detection runs, so it can never land on another language."
        default: "Detection is limited to these. One recording is still one language: Whisper labels each 30-second window once, so switching mid-sentence does not work."
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Language") {
                    Menu(spokenSummary) {
                        ForEach(languages.dropFirst(), id: \.code) { lang in
                            Toggle(lang.name, isOn: Binding(
                                get: { spoken.contains(lang.code) },
                                set: { on in
                                    var codes = spoken
                                    if on { codes.append(lang.code) }
                                    else { codes.removeAll { $0 == lang.code } }
                                    spokenLanguages = codes.joined(separator: ",")
                                }))
                        }
                        if !spoken.isEmpty {
                            Divider()
                            Button("Detect automatically") { spokenLanguages = "" }
                        }
                    }
                }

                Text(languageHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Microphone", selection: $inputDevice) {
                    Text("Follow system setting").tag("")
                    ForEach(mics) { Text($0.name).tag($0.id) }
                }
                // The list is read when the pane appears, not in `body` — CoreAudio should not
                // be polled at SwiftUI's redraw rate.
                .onAppear { mics = AudioDevices.inputs() }

                Picker("Model", selection: $model) {
                    ForEach(availableModels, id: \.self) { name in
                        Text(onDisk.contains(name) ? "\(name) ✓" : name).tag(name)
                    }
                }
                .onChange(of: model) { engine.reloadModel() }

                Text(modelHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                switch engine.model {
                case .downloading(let fraction), .substituting(_, _, let fraction):
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            ProgressView(value: fraction)
                            Button {
                                engine.cancelModelDownload()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .help("Stop downloading")
                        }
                        Text(engine.model.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .warming:
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(engine.model.label).foregroundStyle(.secondary)
                        }
                    }
                case .ready(let name):
                    LabeledContent("Status") { Text("Ready — \(name)").foregroundStyle(.green) }
                case .failed(let why):
                    LabeledContent("Status") { Text(why).foregroundStyle(.red) }
                }

                if let detail = engine.model.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Toggle("AI pass", isOn: $aiEnabled)
                Text("Sends the transcription to an AI to fix punctuation and misheard words. If it fails, the plain transcription is pasted anyway and you get a notification.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if aiEnabled {
                    Picker("Provider", selection: $aiProvider) {
                        ForEach(AIProvider.allCases) { Text($0.label).tag($0.rawValue) }
                    }

                    Picker("Style", selection: $aiStyle) {
                        ForEach(AIStyle.allCases) { Text($0.label).tag($0.rawValue) }
                    }

                    if aiStyle == AIStyle.custom.rawValue {
                        TextField("Instruction", text: $customInstruction, axis: .vertical)
                            .lineLimit(2...4)
                    }

                    if provider.needsKey {
                        SecureField("API key", text: $apiKey)
                            .onSubmit { Keychain.set(apiKey, for: provider) }
                        LabeledContent("Model") {
                            TextField(provider.defaultModel, text: aiModel)
                                .multilineTextAlignment(.trailing)
                        }
                        Text("Key is stored in your Keychain. Get one at \(provider.keyHint).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Runs entirely on this Mac — no key, no network, nothing leaves the machine. Needs Apple Intelligence enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("The on-device model is small: it cleans English well, but is unreliable on Türkçe and other languages. For those, a cloud provider is much better.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    if let error = aiPass.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                TextField("Names and jargon", text: $vocabulary, axis: .vertical)
                    .lineLimit(1...3)
                Text("Comma-separated. Nudges both Whisper and the AI pass toward spellings it keeps getting wrong — names, product names, acronyms.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Look", selection: $engine.theme) {
                    ForEach(Theme.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Motion", selection: $reducedMotion) {
                    Text("Match system").tag("system")
                    Text("Reduced").tag("on")
                    Text("Full").tag("off")
                }
                .onChange(of: reducedMotion) { engine.refreshMotionPreference() }

                Text(engine.calmMotion
                     ? "The blob still responds to your voice, but stops orbiting and pulsing."
                     : "The satellites orbit and the blob breathes while it works.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Paste automatically", isOn: $autoPaste)
                Text("Always copies to the clipboard. When on, it also presses ⌘V for you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !trusted {
                    LabeledContent("Accessibility") {
                        Button("Grant…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                    Text("Without it, both the hotkey and auto-paste stay dead. macOS revokes this every time the app is rebuilt — re-add it, or remove the old entry first if the toggle looks stuck on.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        // Throws when the app runs from a location macOS won't register (e.g. a DMG).
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }

            Section {
                LabeledContent("Push to talk", value: "Hold right ⌥")
                LabeledContent("Or", value: "Click the blob")
            }

            Section {
                LabeledContent("Version") {
                    switch updater.status {
                    case .checking:
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(updater.currentVersion).foregroundStyle(.secondary)
                        }
                    case .available(let version, _):
                        HStack(spacing: 8) {
                            Text("\(updater.currentVersion) → \(version)")
                            Button("Update") { Task { await updater.download() } }
                        }
                    case .downloading(let fraction):
                        HStack(spacing: 8) {
                            ProgressView(value: fraction).frame(width: 90)
                            Text("Downloading…").foregroundStyle(.secondary)
                        }
                    case .readyToRelaunch:
                        Button("Relaunch to finish") { updater.relaunch() }
                    case .failed(let why):
                        HStack(spacing: 8) {
                            Text(why).foregroundStyle(.red).lineLimit(1)
                            Button("Retry") { Task { await updater.check() } }
                        }
                    case .upToDate, .idle:
                        HStack(spacing: 8) {
                            Text(updater.currentVersion).foregroundStyle(.secondary)
                            Button("Check") { Task { await updater.check() } }
                        }
                    }
                }

                if updater.justChecked, case .upToDate = updater.status {
                    Label("You're on the latest version", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                } else if Updater.isDevBuild {
                    HStack(spacing: 6) {
                        Text("BETA")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.orange.opacity(0.22), in: Capsule())
                            .foregroundStyle(.orange)
                        Text("built by Claude")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)   // let the window's blur show through
        // Capped rather than sized-to-fit: the form has outgrown any screen it would have to
        // sit on, so the overflow scrolls instead of stretching the window.
        .frame(width: 400, height: 620)
        .onAppear {
            onDisk = downloadedModels
            apiKey = Keychain.get(provider) ?? ""
        }
        // Load the key for whichever provider is now selected, and persist edits as they happen.
        .onChange(of: aiProvider) { apiKey = Keychain.get(provider) ?? "" }
        .onChange(of: apiKey) { Keychain.set(apiKey, for: provider) }
        .onChange(of: engine.model) { onDisk = downloadedModels }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) {
            _ in trusted = AXIsProcessTrusted()   // no notification for this; poll while the window is open
        }
    }

    private var modelHint: String {
        if model.hasSuffix(".en") {
            return "English only — anything else comes back as garbage. Pick a model without “.en” for Türkçe."
        }
        switch model {
        case "tiny":  return "Fastest, roughest. Weak outside English."
        case "base":  return "Quick, but shaky on Turkish names and endings."
        case "small": return "The default — the smallest model that handles Türkçe properly."
        case "medium": return "Better again, noticeably slower on long takes."
        default:      return "Most accurate. First run downloads about 1.5 GB."
        }
    }
}

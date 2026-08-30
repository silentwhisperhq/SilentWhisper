import AppKit
import Foundation

/// Checks GitHub releases and installs the newer build in place.
///
/// Deliberately not Sparkle: no appcast to host, no signing keys to manage, and the whole
/// contract is one public JSON endpoint plus a zip.
@MainActor
final class Updater: ObservableObject {
    static let repo = "silentwhisperhq/SilentWhisper"

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, url: URL)
        case downloading(Double)
        case readyToRelaunch
        case failed(String)
    }

    @Published var status: Status = .idle

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// True only for a build installed directly rather than downloaded from a release.
    static var isDevBuild: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SWDevBuild") as? Bool ?? false
    }

    @Published var lastChecked: Date?

    /// Set only by a check the user asked for, and cleared a few seconds later — the
    /// confirmation is feedback for that click, not a permanent status line.
    @Published var justChecked = false

    private var checkTimer: Timer?
    private var noteTask: Task<Void, Never>?

    /// Check shortly after launch and every four hours after that, so the Settings pane is
    /// already current whenever it is opened.
    func startPeriodicChecks() {
        Task { await check(quietly: true) }
        checkTimer = Timer.scheduledTimer(withTimeInterval: 4 * 3_600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check(quietly: true) }
        }
    }

    private func flashCheckedNote() {
        justChecked = true
        noteTask?.cancel()
        noteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.justChecked = false
        }
    }

    /// "just now" / "2h ago" — enough to show the checking is really happening.
    var lastCheckedDescription: String? {
        guard let lastChecked else { return nil }
        let seconds = Date().timeIntervalSince(lastChecked)
        if seconds < 90 { return "checked just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "checked \(formatter.localizedString(for: lastChecked, relativeTo: Date()))"
    }

    func check(quietly: Bool = false) async {
        if !quietly {
            status = .checking
            justChecked = false
        }
        defer {
            if !quietly { flashCheckedNote() }
        }
        do {
            let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!
            var request = URLRequest(url: url)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)

            // A repo with no releases yet 404s — that is not an error worth showing.
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                status = .upToDate
                lastChecked = Date()
                return
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "v"))

            guard latest.compare(currentVersion, options: .numeric) == .orderedDescending,
                  let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }),
                  let assetURL = URL(string: asset.browser_download_url)
            else { status = .upToDate; lastChecked = Date(); return }

            status = .available(version: latest, url: assetURL)
            lastChecked = Date()
        } catch {
            status = quietly ? .idle : .failed(error.localizedDescription)
        }
    }

    func download() async {
        guard case .available(_, let url) = status else { return }
        status = .downloading(0)
        do {
            let (tmp, _) = try await URLSession.shared.download(from: url)
            status = .downloading(1)
            try install(from: tmp)
            status = .readyToRelaunch
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Unzips beside the running app and swaps the bundle. The running process keeps its
    /// open file handles, so replacing the bundle underneath it is safe until relaunch.
    private func install(from zip: URL) throws {
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL
        let staging = fm.temporaryDirectory.appendingPathComponent("SilentWhisperUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, staging.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw Failure("could not unpack the download") }

        guard let newApp = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else { throw Failure("the download did not contain an app") }

        _ = try fm.replaceItemAt(appURL, withItemAt: newApp)
    }

    /// Launches the new copy and exits, so the user lands on the updated build.
    func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    private struct Release: Decodable {
        let tag_name: String
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

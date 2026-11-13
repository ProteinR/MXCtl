import AppKit
import CryptoKit
import Security
import SwiftUI

/// Updates from GitHub Releases (the same scheme as MeetRec's `Updater`, with the usual choices of
/// a Mac updater such as Sparkle):
///
/// - Checks `releases/latest` a minute after launch and then every 6 hours, when "Проверять
///   обновления" is on (Общие → Обновления); "Проверить сейчас" there or in the menu bar icon's
///   menu checks at once. Nothing but that request leaves the Mac.
/// - A newer release shows "Доступна версия X" in the panel (and one notification per version):
///   "Обновить", "Позже" (hidden for a day), "Пропустить" (this version never again, a newer one
///   is shown). A check by hand shows a skipped or postponed version again.
/// - "Устанавливать автоматически" (off by default) installs a found version by itself once the
///   Mac has been idle for 2 minutes, so a held button or a gesture is never cut.
/// - "Обновить" downloads the `.zip` next to the app (same volume) and installs it only if it is
///   MXCtl, of the announced version, newer, matches the SHA-256 GitHub lists for the file, and is
///   **signed with the same certificate as the running copy** (its designated requirement): a
///   replaced download is refused, and macOS keeps the Accessibility / Input Monitoring
///   permissions, which are tied to that certificate. The bundle is swapped in place and MXCtl
///   quits as usual (keys go back to the device) and is reopened by a small shell.
/// - Only a copy signed with the release certificate replaces itself; one built with
///   `scripts/install.sh` (the local certificate) is told to update the way it was built.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    static let repository = "ProteinR/MXCtl"
    /// The certificate `.github/workflows/release.yml` signs releases with.
    static let releaseCertificate = "MXCtl Release Signing"
    static let checkInterval: TimeInterval = 6 * 3600
    static let snoozeInterval: TimeInterval = 24 * 3600
    /// Automatic installs wait for this much keyboard and mouse silence.
    static let idleBeforeInstall: TimeInterval = 120

    struct Release: Equatable {
        var version: String
        var page: URL
        var archive: URL
        /// "sha256:…" from the asset, when GitHub lists one.
        var digest: String?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release)
        case installing(Release)
        case failed(String)
    }

    /// Why this copy cannot replace itself; nil when it can.
    enum Blocker: Equatable {
        /// Signed with another certificate (built from source) or ad-hoc.
        case notReleaseBuild
        /// Run from the disk image, a translocated copy or a folder MXCtl cannot write to.
        case location

        var message: String {
            switch self {
            case .notReleaseBuild:
                String(localized: "Эта копия собрана не из релиза — обновите её так же, как собирали (scripts/install.sh).")
            case .location:
                String(localized: "Переместите MXCtl в «Программы» и откройте оттуда — тогда он сможет обновляться.")
            }
        }
    }

    @AppStorage("checkForUpdates") var automatic = true {
        didSet {
            Log.info("Updates: automatic check \(automatic ? "on" : "off")", "update")
            scheduleChecks()
        }
    }
    @AppStorage("installUpdatesAutomatically") var autoInstall = false {
        didSet {
            Log.info("Updates: automatic install \(autoInstall ? "on" : "off")", "update")
            if autoInstall { installAutomaticallyIfDue() }
        }
    }
    /// "Пропустить": this version is not offered again; a newer one is.
    @AppStorage("skippedUpdateVersion") var skippedVersion = ""
    /// "Позже": the banner of `snoozedVersion` stays hidden until `snoozedUntil`.
    @AppStorage("snoozedUpdateVersion") private var snoozedVersion = ""
    @AppStorage("snoozedUpdateUntil") private var snoozedUntil: Double = 0
    /// The version a notification was posted for (one per version).
    @AppStorage("notifiedUpdateVersion") private var notifiedVersion = ""
    @AppStorage("lastUpdateCheck") private var lastCheckTime: Double = 0

    @Published private(set) var state: State = .idle
    /// The newest release seen, kept while downloading or after a failed install.
    @Published private(set) var latest: Release?
    let blocker: Blocker?
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    /// Opens the menu bar panel (set by AppDelegate); a click on the notification calls it.
    var showPanel: (() -> Void)?

    private var timer: Timer?
    private var idleTimer: Timer?

    var lastCheck: Date? { lastCheckTime > 0 ? Date(timeIntervalSince1970: lastCheckTime) : nil }

    private init() {
        blocker = Self.findBlocker()
    }

    /// Call once at launch.
    func start() {
        Log.info("Updates: version \(currentVersion), automatic check \(automatic ? "on" : "off"), install "
            + "\(autoInstall ? "automatic" : "by hand"), "
            + (blocker.map { "can't self-update (\($0))" } ?? "can self-update"), "update")
        scheduleChecks()
    }

    private func scheduleChecks() {
        timer?.invalidate()
        timer = nil
        guard automatic else { return }
        // Not right at launch: after boot or wake the network may not be up yet.
        let first = lastCheck.map { max(60, Self.checkInterval - Date().timeIntervalSince($0)) } ?? 60
        timer = Timer.scheduledTimer(withTimeInterval: first, repeats: false) { [weak self] _ in
            Task { @MainActor in
                await self?.check()
                self?.scheduleChecks()
            }
        }
    }

    // MARK: - What to show

    /// The release the panel offers: newer, not skipped, not postponed (always while installing).
    var bannerRelease: Release? {
        switch state {
        case .downloading(let release), .installing(let release): return release
        case .available(let release): return isOffered(release) ? release : nil
        case .failed: return latest.flatMap { Self.isNewer($0.version, than: currentVersion) && isOffered($0) ? $0 : nil }
        default: return nil
        }
    }

    /// A newer release the user has not skipped or postponed.
    private func isOffered(_ release: Release) -> Bool {
        Self.isOffered(release.version, skipped: skippedVersion, snoozed: snoozedVersion,
                       snoozedUntil: Date(timeIntervalSince1970: snoozedUntil), now: Date())
    }

    nonisolated static func isOffered(_ version: String, skipped: String, snoozed: String, snoozedUntil: Date, now: Date) -> Bool {
        if version == skipped { return false }
        if version == snoozed && now < snoozedUntil { return false }
        return true
    }

    var isInstalling: Bool {
        switch state {
        case .downloading, .installing: true
        default: false
        }
    }

    /// "Позже": hide this version's banner for a day.
    func snooze(_ release: Release) {
        snoozedVersion = release.version
        snoozedUntil = Date().addingTimeInterval(Self.snoozeInterval).timeIntervalSince1970
        Log.info("Updates: \(release.version) postponed for a day", "update")
        objectWillChange.send()
    }

    /// "Пропустить эту версию".
    func skip(_ release: Release) {
        skippedVersion = release.version
        Log.info("Updates: \(release.version) skipped", "update")
        objectWillChange.send()
    }

    /// "Показать снова" for a skipped version.
    func unskip() {
        Log.info("Updates: \(skippedVersion) no longer skipped", "update")
        skippedVersion = ""
        snoozedVersion = ""
    }

    // MARK: - Checking

    func check(userInitiated: Bool = false) async {
        guard !isInstalling, state != .checking else { return }
        let previous = state
        state = .checking
        do {
            let release = try await Self.fetchLatest()
            lastCheckTime = Date().timeIntervalSince1970
            latest = release
            guard Self.isNewer(release.version, than: currentVersion) else {
                state = .upToDate
                Log.info("Updates: \(currentVersion) is the latest (GitHub has \(release.version))", "update")
                return
            }
            if case .available(let shown) = previous, shown == release {} else {
                Log.info("Updates: \(release.version) is available (this is \(currentVersion))", "update")
            }
            state = .available(release)
            if userInitiated {
                // Asked by hand: show it even if it was skipped or postponed.
                if skippedVersion == release.version { skippedVersion = "" }
                snoozedVersion = ""
            } else if isOffered(release) {
                if autoInstall && blocker == nil {
                    installAutomaticallyIfDue()
                } else {
                    notifyOnce(release)
                }
            }
        } catch {
            Log.warning("Updates: check failed: \(Log.describe(error))", "update")
            // A failed background check is not worth a red line in settings.
            state = userInitiated ? .failed(Self.message(error))
                : (latest.map { Self.isNewer($0.version, than: currentVersion) ? .available($0) : .upToDate } ?? .idle)
        }
    }

    private func notifyOnce(_ release: Release) {
        guard notifiedVersion != release.version else { return }
        notifiedVersion = release.version
        BatteryAlerts.notify(title: String(localized: "Доступна версия MXCtl \(release.version)"),
                             body: blocker?.message ?? String(localized: "Обновить можно в панели MXCtl."),
                             level: nil, identifier: Self.notificationID)
    }

    nonisolated static let notificationID = "mxctl-update"

    // MARK: - Installing

    /// Automatic install: waits until nobody has touched the keyboard or mouse for 2 minutes.
    private func installAutomaticallyIfDue() {
        idleTimer?.invalidate()
        idleTimer = nil
        guard autoInstall, blocker == nil, !isInstalling,
              case .available(let release) = state, isOffered(release) else { return }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        if idle >= Self.idleBeforeInstall {
            Log.info("Updates: installing \(release.version) automatically (idle \(Int(idle)) s)", "update")
            install()
        } else {
            idleTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.installAutomaticallyIfDue() }
            }
        }
    }

    func install() {
        guard let release = latest, blocker == nil, !isInstalling else { return }
        idleTimer?.invalidate()
        state = .downloading(release)
        Task {
            do {
                let (app, work) = try await Self.download(release)
                defer { try? FileManager.default.removeItem(at: work) }
                state = .installing(release)
                try Self.replaceRunningApp(with: app, backupIn: work)
                Log.info("Updates: installed \(release.version) over \(currentVersion), relaunching", "update")
                Self.relaunch()
            } catch {
                Log.error("Updates: installing \(release.version) failed: \(Log.describe(error))", "update")
                state = .failed(Self.message(error))
            }
        }
    }

    // MARK: - GitHub

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static func message(_ error: Error) -> String {
        (error as? UpdateError)?.message ?? error.localizedDescription
    }

    private static func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MXCtl", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw UpdateError(message: String(localized: "На GitHub ещё нет релизов")) }
        guard status == 200 else { throw UpdateError(message: String(localized: "GitHub ответил \(status)")) }
        guard let release = parseRelease(data) else {
            throw UpdateError(message: String(localized: "В последнем релизе нет архива MXCtl"))
        }
        return release
    }

    /// The `releases/latest` answer: tag `vX.Y.Z` and the `MXCtl-X.Y.Z.zip` asset.
    nonisolated static func parseRelease(_ data: Data) -> Release? {
        struct Answer: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
                let digest: String?
            }
            let tag_name: String
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data),
              answer.draft != true, answer.prerelease != true else { return nil }
        let version = answer.tag_name.hasPrefix("v") ? String(answer.tag_name.dropFirst()) : answer.tag_name
        guard let zip = answer.assets.first(where: { $0.name == "MXCtl-\(version).zip" })
                ?? answer.assets.first(where: { $0.name.lowercased().hasSuffix(".zip") }) else { return nil }
        return Release(version: version, page: answer.html_url, archive: zip.browser_download_url, digest: zip.digest)
    }

    /// Compares "0.10.1" with "0.11.0" part by part; missing parts are 0.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let parts = { (version: String) in
            version.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// True when `digest` ("sha256:<hex>") is missing (older releases) or matches `data`.
    nonisolated static func digestMatches(_ digest: String?, _ data: Data) -> Bool {
        guard let digest, digest.lowercased().hasPrefix("sha256:") else { return digest == nil }
        let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest.dropFirst("sha256:".count).lowercased() == hex
    }

    // MARK: - Download and swap

    /// Downloads and unpacks the release next to the running app, then checks it. Returns the new
    /// app and the temporary folder it is in.
    private static func download(_ release: Release) async throws -> (app: URL, work: URL) {
        let installed = Bundle.main.bundleURL
        // Same volume as the app, so the swap is a rename; removed after the install or a failure.
        let work = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                               appropriateFor: installed, create: true)
        Log.info("Updates: downloading \(release.archive.absoluteString)", "update")
        var request = URLRequest(url: release.archive)
        request.setValue("MXCtl", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120
        do {
            return (try await unpack(request, release: release, into: work), work)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    private static func unpack(_ request: URLRequest, release: Release, into work: URL) async throws -> URL {
        let installed = Bundle.main.bundleURL
        let (file, response) = try await URLSession.shared.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw UpdateError(message: String(localized: "Не удалось скачать обновление: GitHub ответил \(status)"))
        }
        let zip = work.appendingPathComponent("MXCtl.zip")
        try FileManager.default.moveItem(at: file, to: zip)
        guard digestMatches(release.digest, try Data(contentsOf: zip, options: .mappedIfSafe)) else {
            throw UpdateError(message: String(localized: "Скачанный архив не совпадает с контрольной суммой на GitHub"))
        }
        let unpacked = work.appendingPathComponent("unpacked")
        let unzip = try await run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard unzip.status == 0 else {
            throw UpdateError(message: String(localized: "Архив обновления не распаковался: \(unzip.output)"))
        }
        let app = unpacked.appendingPathComponent(installed.lastPathComponent)
        let fallback = unpacked.appendingPathComponent("MXCtl.app")
        let candidate = FileManager.default.fileExists(atPath: app.path) ? app : fallback
        try verify(candidate, release: release)
        // Downloaded by MXCtl itself, so normally not quarantined; never let a stray flag stop the relaunch.
        _ = try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", candidate.path])
        return candidate
    }

    /// The new app must be MXCtl, of the release's version, newer, and signed like this copy.
    private static func verify(_ app: URL, release: Release) throws {
        guard let bundle = Bundle(url: app), let info = bundle.infoDictionary else {
            throw UpdateError(message: String(localized: "В архиве обновления нет MXCtl.app"))
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError(message: String(localized: "В архиве обновления другое приложение"))
        }
        let version = info["CFBundleShortVersionString"] as? String ?? ""
        guard version == release.version else {
            throw UpdateError(message: String(localized: "В архиве версия \(version), а не \(release.version)"))
        }
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard isNewer(version, than: current) else {
            throw UpdateError(message: String(localized: "Версия \(version) не новее установленной"))
        }
        var own: SecCode?
        var ownStatic: SecStaticCode?
        var requirement: SecRequirement?
        var newCode: SecStaticCode?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &ownStatic) == errSecSuccess, let ownStatic,
              SecCodeCopyDesignatedRequirement(ownStatic, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError(message: String(localized: "Не удалось проверить подпись обновления"))
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let result = SecStaticCodeCheckValidity(newCode, flags, requirement)
        guard result == errSecSuccess else {
            Log.error("Updates: signature check of \(app.path) failed (\(result))", "update")
            throw UpdateError(message: String(localized: "Обновление подписано не тем сертификатом — не устанавливаю"))
        }
        Log.info("Updates: \(version) verified (bundle id, version, checksum, signature)", "update")
    }

    /// Swaps the app on disk; the running process keeps working from the files it has open.
    private static func replaceRunningApp(with app: URL, backupIn work: URL) throws {
        let installed = Bundle.main.bundleURL
        let backup = work.appendingPathComponent("previous.app")
        try FileManager.default.moveItem(at: installed, to: backup)
        do {
            try FileManager.default.moveItem(at: app, to: installed)
        } catch {
            try? FileManager.default.moveItem(at: backup, to: installed)
            throw UpdateError(message: String(localized: "Не удалось заменить приложение: \(error.localizedDescription)"))
        }
        // So Finder and `open` see the new version at once.
        let lsregister = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregister)
        process.arguments = ["-f", installed.path]
        try? process.run()
    }

    /// Quits as usual (keys go back to the devices) and opens the new app once this process is gone.
    private static func relaunch() {
        let script = "while /bin/kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, Bundle.main.bundlePath]
        do {
            try process.run()
        } catch {
            Log.error("Updates: could not schedule the relaunch: \(Log.describe(error))", "update")
        }
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: [String]) async throws -> (status: Int32, output: String) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { process in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                continuation.resume(returning: (process.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: - Can this copy update itself?

    private static func findBlocker() -> Blocker? {
        guard signingCertificate() == releaseCertificate else { return .notReleaseBuild }
        return locationBlocks(Bundle.main.bundleURL) ? .location : nil
    }

    /// A translocated copy, the disk image, or a folder MXCtl cannot write to.
    nonisolated static func locationBlocks(_ app: URL, writable: (String) -> Bool = FileManager.default.isWritableFile) -> Bool {
        let path = app.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") { return true }
        return !writable(app.deletingLastPathComponent().path) || !writable(path)
    }

    /// Common name of the certificate this copy is signed with; nil when ad-hoc.
    private static func signingCertificate() -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as NSDictionary?)?[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        return SecCertificateCopySubjectSummary(leaf) as String?
    }
}

// MARK: - Views

/// "Доступна версия X" in the panel: Обновить · Позже · Пропустить.
struct UpdateBanner: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        if let release = updater.bannerRelease {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label("Доступна версия \(release.version)", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Link("Что нового", destination: release.page).font(.caption)
                }
                switch updater.state {
                case .downloading:
                    ProgressView("Скачиваю…").controlSize(.small)
                case .installing:
                    ProgressView("Устанавливаю…").controlSize(.small)
                default:
                    if case .failed(let message) = updater.state {
                        Text(message).font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let blocker = updater.blocker {
                        Text(blocker.message).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        if updater.blocker == nil {
                            Button("Обновить") { updater.install() }
                                .keyboardShortcut(.defaultAction)
                        }
                        Button("Позже") { updater.snooze(release) }
                            .help("Скрыть на сутки")
                        Button("Пропустить") { updater.skip(release) }
                            .help("Не предлагать эту версию; о следующей напомню")
                    }
                    .controlSize(.small)
                }
            }
        }
    }
}

/// Общие → Обновления.
struct UpdateSettings: View {
    @ObservedObject private var updater = Updater.shared

    var body: some View {
        Section("Обновления") {
            Toggle("Проверять обновления автоматически", isOn: $updater.automatic)
                .help("Раз в 6 часов спрашивать GitHub о новой версии. Больше ничего не отправляется.")
            Toggle("Устанавливать обновления сами", isOn: $updater.autoInstall)
                .disabled(!updater.automatic || updater.blocker != nil)
                .help("Найденная версия ставится, когда клавиатурой и мышью не пользовались 2 минуты; MXCtl перезапустится.")
            HStack {
                Text(status).font(.callout).foregroundStyle(statusIsError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if updater.state == .checking {
                    ProgressView().controlSize(.small)
                }
                Button("Проверить сейчас") { Task { await updater.check(userInitiated: true) } }
                    .disabled(updater.state == .checking || updater.isInstalling)
            }
            if case .available(let release) = updater.state {
                HStack {
                    if updater.blocker == nil {
                        Button("Обновить до \(release.version)") { updater.install() }
                    }
                    Link("Что нового", destination: release.page)
                }
            }
            if !updater.skippedVersion.isEmpty {
                HStack {
                    Text("Пропущена версия \(updater.skippedVersion)").font(.caption).foregroundStyle(.secondary)
                    Button("Предлагать снова") { updater.unskip() }
                        .buttonStyle(.link).font(.caption)
                }
            }
            if let blocker = updater.blocker {
                Text(blocker.message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var statusIsError: Bool {
        if case .failed = updater.state { return true }
        return false
    }

    private var status: String {
        let version = String(localized: "Версия \(updater.currentVersion)")
        switch updater.state {
        case .checking: return String(localized: "\(version) · проверяю…")
        case .upToDate: return String(localized: "\(version) — последняя")
        case .available(let release): return String(localized: "\(version) · доступна \(release.version)")
        case .downloading: return String(localized: "\(version) · скачиваю обновление…")
        case .installing: return String(localized: "\(version) · устанавливаю…")
        case .failed(let message): return message
        case .idle:
            guard let last = updater.lastCheck else { return version }
            return String(localized: "\(version) · проверено \(last.formatted(.relative(presentation: .named)))")
        }
    }
}

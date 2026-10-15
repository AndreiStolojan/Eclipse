import ServiceManagement
import SwiftUI

/// Teal accent for the window's controls.
let notchWindowAccent = Color(red: 0.40, green: 0.84, blue: 0.75)

/// Sidebar entries. A page that is not available yet shows greyed with a Soon badge.
enum NotchPage: String, CaseIterable, Identifiable {
    case general = "General"
    case battery = "Battery"
    case connectivity = "Connectivity"
    case focus = "Focus"
    case display = "Display"
    case sound = "Sound"
    case downloads = "Downloads"
    case nowPlaying = "Now Playing"
    case calendar = "Calendar"
    case timers = "Timers"
    case shelf = "Shelf"
    case lockScreen = "Lock Screen"
    case sotto = "Sotto"
    case t3 = "T3 Code"
    case about = "About"

    var id: String { rawValue }

    static let groups: [(title: String?, pages: [NotchPage])] = [
        (nil, [.general]),
        ("Notifications", [.battery, .connectivity, .focus, .display, .sound, .downloads]),
        ("Live Activities", [.nowPlaying, .calendar, .timers, .shelf, .lockScreen]),
        ("Connected apps", [.sotto, .t3]),
        ("Eclipse", [.about])
    ]

    /// Every page exists now; a planned one returns false here to show greyed with a Soon badge.
    var available: Bool { true }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .battery: "bolt.fill"
        case .connectivity: "headphones"
        case .focus: "moon.fill"
        case .display: "sun.max.fill"
        case .sound: "speaker.wave.2.fill"
        case .downloads: "arrow.down.circle.fill"
        case .nowPlaying: "play.fill"
        case .calendar: "calendar"
        case .timers: "timer"
        case .shelf: "tray.fill"
        case .lockScreen: "lock.fill"
        case .sotto: "waveform"
        case .t3: "terminal.fill"
        case .about: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general, .about: Color(nsColor: .systemGray)
        case .battery: Color(nsColor: .systemOrange)
        case .connectivity: Color(nsColor: .systemGreen)
        case .focus: Color(nsColor: .systemIndigo)
        case .display: Color(nsColor: .systemPurple)
        case .sound: Color(nsColor: .systemPink)
        case .downloads: Color(nsColor: .systemTeal)
        case .nowPlaying, .calendar: Color(nsColor: .systemRed)
        case .timers: Color(nsColor: .systemBrown)
        case .shelf: Color(nsColor: .systemBlue)
        case .lockScreen: Color(white: 0.3)
        case .sotto: Color(red: 0.25, green: 0.72, blue: 0.65)
        case .t3: Color(nsColor: .systemIndigo)
        }
    }
}

/// Main window content: a sectioned sidebar beside scrolling settings cards.
struct NotchAppView: View {
    @ObservedObject var experience: NotchExperience
    @State private var page: NotchPage
    @StateObject private var sotto = SottoPresence()

    /// Fixtures open a given page; the app always starts on General.
    init(experience: NotchExperience, page: NotchPage = .general) {
        self.experience = experience
        _page = State(initialValue: page)
    }

    var body: some View {
        HStack(spacing: 0) {
            NotchSidebar(selection: $page, sottoRunning: sotto.running).frame(width: 240)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    NotchPageIcon(page: page, size: 24)
                    Text(page.rawValue).font(.system(size: 17, weight: .bold))
                }
                .padding(.top, 30).padding(.horizontal, 24).padding(.bottom, 14)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        switch page {
                        case .general: NotchGeneralPage(experience: experience)
                        case .battery: NotchBatteryPage(experience: experience)
                        case .connectivity: NotchConnectivityPage(experience: experience)
                        case .focus: NotchFocusPage(experience: experience)
                        case .display: NotchDisplayPage(experience: experience)
                        case .sound: NotchSoundPage(experience: experience)
                        case .downloads: NotchDownloadsPage(experience: experience)
                        case .nowPlaying: NotchNowPlayingPage(experience: experience)
                        case .calendar: NotchCalendarSettingsPage(experience: experience)
                        case .lockScreen: NotchLockScreenPage(experience: experience)
                        case .timers: NotchTimerSettingsPage(experience: experience)
                        case .shelf: NotchShelfSettingsPage(experience: experience)
                        case .sotto: NotchSottoPage(experience: experience)
                        case .t3: NotchT3Page(experience: experience)
                        case .about: NotchAboutPage(experience: experience)
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background {
            // A strong dark tint keeps the window dark whether or not it is key; the material only adds a hint of the desktop.
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
                .overlay(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.85))
                .ignoresSafeArea()
        }
        .frame(minWidth: 620, minHeight: 640)
        .onChange(of: sotto.running) { _, running in if !running && page == .sotto { page = .general } }
        .foregroundStyle(.white)
        .colorScheme(.dark)
    }
}

private struct NotchSidebar: View {
    @Binding var selection: NotchPage
    let sottoRunning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(NotchPage.groups.enumerated()), id: \.offset) { _, group in
                if let title = group.title {
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.leading, 14).padding(.top, 14).padding(.bottom, 4)
                }
                ForEach(group.pages) { page in row(page) }
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.top, 48)
        .overlay(alignment: .trailing) { Rectangle().fill(.white.opacity(0.08)).frame(width: 1).ignoresSafeArea() }
    }

    private func row(_ page: NotchPage) -> some View {
        let selected = page == selection
        // Sotto's page needs Sotto running; T3 Code's only needs it installed, since Connect waits for it to start.
        let enabled = page.available && (page != .sotto || sottoRunning) && (page != .t3 || NotchT3.appURL != nil)
        return Button { selection = page } label: {
            HStack(spacing: 10) {
                NotchPageIcon(page: page, size: 26)
                Text(page.rawValue).font(.system(size: 15)).lineLimit(1)
                Spacer(minLength: 4)
                if !page.available {
                    Text("Soon").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }
            }
            .padding(.horizontal, 10).frame(height: 40).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Color.white.opacity(0.1) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(enabled ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Whether Sotto, the dictation app, is running, so its page is only reachable while it is.
/// Watches `runningApplications` with KVO because Sotto may run as an accessory app, which posts no launch notice.
@MainActor
final class SottoPresence: ObservableObject {
    /// Sotto's release, beta and development bundle IDs.
    static let bundleIDs: Set<String> = ["ro.andrei.Voce", "ro.andrei.Voce.beta", "ro.andrei.Voce.dev"]
    /// Sotto's app icon, or nil when it is not installed.
    static let icon: NSImage? = bundleIDs.lazy
        .compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        .first.map { NSWorkspace.shared.icon(forFile: $0.path) }

    @Published private(set) var running = SottoPresence.isRunning
    private var observation: NSKeyValueObservation?

    init() {
        observation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor in self?.running = SottoPresence.isRunning }
        }
    }

    private static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier.map(bundleIDs.contains) == true }
    }
}

struct NotchPageIcon: View {
    let page: NotchPage
    let size: CGFloat
    var body: some View {
        ZStack {
            if page == .sotto, let icon = SottoPresence.icon {
                Image(nsImage: icon).resizable().scaledToFit().scaleEffect(1.2)
            } else if page == .t3, NotchT3.icon != nil {
                NotchT3Icon(size: size)
            } else {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(page.tint)
                Image(systemName: page.icon).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: - Cards and rows

/// A rounded dark card holding rows separated by hairlines.
private struct NotchCard<Content: View>: View {
    var title: String?
    @ViewBuilder let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.06)))
        }
    }
}

private struct NotchRowDivider: View {
    var body: some View { Rectangle().fill(.white.opacity(0.08)).frame(height: 1) }
}

private struct NotchToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    var body: some View {
        HStack {
            Text(label).font(.system(size: 15))
            Spacer()
            Toggle(label, isOn: $isOn).labelsHidden().toggleStyle(.switch).tint(notchWindowAccent)
        }
        .padding(.horizontal, 16).frame(height: 50)
    }
}

private struct NotchValueRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).font(.system(size: 15))
            Spacer()
            Text(value).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 16).frame(height: 50)
    }
}

/// Label with a monospaced value pill, and a tinted slider over evenly spaced tick marks.
private struct NotchSliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    init(_ label: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, step: Double,
         format: @escaping (Double) -> String) {
        self.label = label
        _value = value
        self.range = range
        self.step = step
        self.format = format
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text(label).font(.system(size: 15))
                Spacer()
                Text(format(value)).font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.1)))
            }
            // Rounding here instead of Slider's `step` keeps the value coarse without one tick per step.
            Slider(value: Binding(get: { value }, set: { value = ($0 / step).rounded() * step }), in: range)
                .tint(notchWindowAccent)
            HStack(spacing: 0) {
                ForEach(0..<11) { index in
                    Rectangle().fill(.white.opacity(0.25)).frame(width: 1.5, height: 3)
                    if index < 10 { Spacer(minLength: 0) }
                }
            }
            .padding(.horizontal, 9)
            .accessibilityHidden(true)
        }
        .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 10)
    }
}

struct NotchButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 14).frame(height: 32)
            .background(Capsule().fill(.white.opacity(configuration.isPressed ? 0.18 : 0.1)))
    }
}

private func points(_ value: Double) -> String { "\(Int(value)) pt" }
private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded())) %" }
private func milliseconds(_ value: Double) -> String { "\(Int((value * 1000).rounded())) ms" }

// MARK: - Pages

private struct NotchGeneralPage: View {
    @ObservedObject var experience: NotchExperience
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var hideSystemThumbnail = !NotchScreenshots.systemThumbnail

    private var settings: Binding<NotchSettings> { $experience.settings }

    var body: some View {
        NotchCard {
            NotchToggleRow(label: "Launch at login", isOn: $launchAtLogin)
            if let launchAtLoginError {
                Text(launchAtLoginError).font(.system(size: 12)).foregroundStyle(.red).padding(.horizontal, 16).padding(.bottom, 10)
            }
            NotchRowDivider()
            NotchToggleRow(label: "Open this window at launch", isOn: settings.openWindowAtLaunch)
        }
        NotchCard("Visibility") {
            NotchToggleRow(label: "Hide in fullscreen", isOn: settings.hideInFullscreen)
            NotchRowDivider()
            NotchToggleRow(label: "Hide in Mission Control", isOn: settings.hideInMissionControl)
            NotchRowDivider()
            NotchToggleRow(label: "Hide while gaming", isOn: settings.hideWhileGaming)
            NotchRowDivider()
            NotchToggleRow(label: "Hide from screen capture", isOn: settings.hideFromScreenCapture)
        }
        NotchCard("Display") {
            HStack {
                Text("Display on").font(.system(size: 15))
                Spacer()
                Picker("Display on", selection: settings.display) {
                    ForEach(displayChoices, id: \.self) { choice in Text(label(for: choice)).tag(choice) }
                }
                .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            .padding(.horizontal, 16).frame(height: 50)
            NotchRowDivider()
            NotchToggleRow(label: "Force simulated notch", isOn: settings.forceSimulatedNotch)
            NotchRowDivider()
            NotchSliderRow("Simulated notch width", settings.simulatedNotchWidth, 100...260, step: 2, format: points)
        }
        NotchCard("Behaviour") {
            NotchToggleRow(label: "Haptic feedback", isOn: settings.haptics)
            NotchRowDivider()
            NotchToggleRow(label: "Expand on hover", isOn: settings.expandOnHover)
            NotchRowDivider()
            NotchToggleRow(label: "Show new screenshots", isOn: settings.screenshotThumbnail)
            NotchRowDivider()
            NotchToggleRow(label: "Keep new screenshots on the shelf", isOn: settings.shelveScreenshots)
            NotchRowDivider()
            NotchToggleRow(label: "Hide the macOS screenshot thumbnail", isOn: $hideSystemThumbnail)
            NotchRowDivider()
            NotchSliderRow("Hover duration", settings.hoverOpenDelay, 0...0.5, step: 0.01, format: milliseconds)
            NotchRowDivider()
            NotchSliderRow("Close delay", settings.hoverCloseDelay, 0...0.5, step: 0.01, format: milliseconds)
        }
        NotchCard("Gestures") {
            NotchToggleRow(label: "Swipe to open and close", isOn: settings.swipeToToggle)
            NotchRowDivider()
            NotchToggleRow(label: "Swipe to switch page", isOn: settings.swipeToPage)
            NotchRowDivider()
            NotchToggleRow(label: "Swipe to skip tracks", isOn: settings.swipeToSkip)
        }
        NotchCard("Animation") {
            NotchSliderRow("Opening", settings.openAnimationDuration, 0.2...1, step: 0.01) { String(format: "%.2f s", $0) }
            NotchRowDivider()
            NotchSliderRow("Closing", settings.closeAnimationDuration, 0.15...0.8, step: 0.01) { String(format: "%.2f s", $0) }
            NotchRowDivider()
            NotchSliderRow("Bounce", settings.openAnimationBounce, 0...0.4, step: 0.01) { String(format: "%.2f", $0) }
        }
        NotchCard("Tuning") {
            NotchSliderRow("Width", settings.expandedWidth, 260...600, step: 2, format: points)
            NotchRowDivider()
            NotchSliderRow("Height below camera", settings.expandedHeight, 120...260, step: 2, format: points)
            NotchRowDivider()
            NotchSliderRow("Corner radius", settings.cornerRadius, 8...40, step: 1, format: points)
            NotchRowDivider()
            NotchSliderRow("Wing width", settings.wingWidth, 24...80, step: 1, format: points)
        }
        NotchCard("Notch") {
            NotchValueRow(label: "Panel", value: experience.concealed ? "Hidden" : experience.state.expanded ? "Expanded" : "Compact")
            NotchRowDivider()
            HStack(spacing: 10) {
                Button(experience.hidden ? "Show notch" : "Hide notch") { experience.hidden.toggle() }
                Button(experience.state.expanded ? "Collapse" : "Expand") { experience.toggleExpanded() }
                Spacer()
            }
            .buttonStyle(NotchButtonStyle())
            .padding(16)
        }
        .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
        .onChange(of: hideSystemThumbnail) { _, hide in NotchScreenshots.systemThumbnail = !hide }
    }

    /// The built-in notch display, the main display, each connected display, and a remembered one that is not. The
    /// remembered choice is its display's tag even when macOS now names that display differently, so the picker
    /// keeps showing a selection.
    private var displayChoices: [NotchDisplayChoice] {
        let chosen = experience.settings.display
        let chosenID: String? = if case .display(let id, _) = chosen { id } else { nil }
        var choices: [NotchDisplayChoice] = [.notch, .main]
        choices += experience.displays.map { $0.id == chosenID ? chosen : .display(id: $0.id, name: $0.name) }
        if let chosenID, !experience.displays.contains(where: { $0.id == chosenID }) { choices.append(chosen) }
        return choices
    }

    /// A connected display shows its current name; a disconnected one the name it had when it was picked.
    private func label(for choice: NotchDisplayChoice) -> String {
        switch choice {
        case .notch: "Built-in notch display"
        case .main: "Main display"
        case .display(let id, let name):
            experience.displays.first { $0.id == id }?.name ?? "\(name), disconnected"
        }
    }

    /// Login items are system state rather than a stored preference, so the switch reverts when macOS refuses.
    private func setLaunchAtLogin(_ enabled: Bool) {
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            launchAtLogin = !enabled
        }
    }
}

/// Sotto's link: a switch for the whole link, whether it is connected, where its dictation pill shows, and the
/// notch pill's size.
private struct NotchSottoPage: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject private var dictation: NotchDictation

    init(experience: NotchExperience) {
        self.experience = experience
        dictation = experience.socket.dictation
    }

    private var settings: Binding<NotchSettings> { $experience.settings }

    var body: some View {
        NotchCard {
            NotchToggleRow(label: "Connect", isOn: settings.sottoLinked)
            NotchRowDivider()
            HStack(spacing: 6) {
                Text("Status").font(.system(size: 15))
                Spacer()
                Circle().fill(linked ? Color(nsColor: .systemGreen) : .secondary).frame(width: 8, height: 8)
                Text(linked ? "Connected" : "Not connected").font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).frame(height: 50)
        }
        if experience.settings.sottoLinked { pillSettings }
    }

    private var linked: Bool { dictation.connected && experience.settings.sottoLinked }

    @ViewBuilder private var pillSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dictation pill").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 2)
            HStack(spacing: 12) {
                NotchPillPlacementTile(label: "In the notch", inNotch: true, selection: settings.dictationInNotch)
                NotchPillPlacementTile(label: "At the bottom", inNotch: false, selection: settings.dictationInNotch)
            }
        }
        NotchCard("Pill in the notch") {
            NotchSliderRow("Pill size", settings.dictationPillScale, 0.9...1.5, step: 0.05, format: percent)
            NotchRowDivider()
            NotchSliderRow("Bar size", settings.dictationBarScale, 0.8...1.8, step: 0.05, format: percent)
        }
    }
}

/// T3 Code's link: Connect, its status and access, then the alerts and the size of a thread's page in the notch.
private struct NotchT3Page: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject private var t3: NotchT3

    init(experience: NotchExperience) {
        self.experience = experience
        t3 = experience.t3
    }

    private var settings: Binding<NotchSettings> { $experience.settings }

    var body: some View {
        NotchCard {
            NotchToggleRow(label: "Connect", isOn: settings.t3Linked)
            NotchRowDivider()
            HStack(spacing: 6) {
                Text("Status").font(.system(size: 15))
                Spacer()
                Circle().fill(t3.status == .connected ? Color(nsColor: .systemGreen) : .secondary).frame(width: 8, height: 8)
                Text(t3.status.label).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).frame(height: 50)
            NotchRowDivider()
            HStack {
                Text("Access").font(.system(size: 15))
                Spacer()
                // Revoking also turns Connect off, or the link would ask T3 for a new session at once.
                Button("Revoke") {
                    experience.settings.t3Linked = false
                    t3.forget()
                }
                .buttonStyle(NotchButtonStyle())
            }
            .padding(.horizontal, 16).frame(height: 50)
        }
        if experience.settings.t3Linked {
            NotchCard("In the notch") {
                NotchToggleRow(label: "Alerts", isOn: settings.agentAlerts)
                NotchRowDivider()
                NotchSliderRow("Alert duration", settings.agentAlertDuration, 1...5, step: 0.5) { "\($0.formatted()) s" }
                NotchRowDivider()
                NotchSliderRow("Alert size", settings.agentAlertScale, 0.9...1.4, step: 0.05, format: percent)
                NotchRowDivider()
                NotchSliderRow("Thread page size", settings.agentPageScale, 0.9...1.4, step: 0.05, format: percent)
            }
        }
    }
}

/// One placement choice, drawn as a small screen with the pill where it would appear.
private struct NotchPillPlacementTile: View {
    let label: String
    let inNotch: Bool
    @Binding var selection: Bool

    var body: some View {
        let selected = selection == inNotch
        Button { selection = inNotch } label: {
            VStack(spacing: 8) {
                VStack(spacing: 0) {
                    if inNotch {
                        bars(count: 9).frame(width: 92, height: 20)
                            .background(UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9).fill(.black))
                    } else {
                        UnevenRoundedRectangle(bottomLeadingRadius: 6, bottomTrailingRadius: 6).fill(.black).frame(width: 52, height: 12)
                    }
                    Spacer(minLength: 0)
                    if !inNotch {
                        bars(count: 7).frame(width: 40, height: 15).background(Capsule().fill(.black)).padding(.bottom, 8)
                    }
                }
                .frame(maxWidth: .infinity).frame(height: 80)
                .background(Color(white: 0.17))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(label).font(.system(size: 14))
            }
            .padding(9)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? notchWindowAccent : .white.opacity(0.08), lineWidth: 1.5))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func bars(count: Int) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                Capsule().fill(.white).frame(width: 2, height: [3, 6, 9, 5, 8, 4, 7][index % 7])
            }
        }
    }
}

/// Spotify's Client ID: a full-width field with Save, or the saved ID with Forget, then whether the account is signed
/// in, and a footnote with the redirect URI and the setup steps. Changing the ID signs the account out, since its
/// tokens belong to the old app.
private struct NotchSpotifyCard: View {
    @State private var saved = NotchSpotify.clientID
    @State private var draft = ""

    var body: some View {
        NotchCard("Spotify") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Client ID").font(.system(size: 15))
                HStack(spacing: 10) {
                    Group {
                        if let saved {
                            Text(saved).lineLimit(1).truncationMode(.tail).textSelection(.enabled)
                        } else {
                            TextField("Client ID", text: $draft, prompt: Text("Paste the Client ID from your Spotify app"))
                                .textFieldStyle(.plain).onSubmit(saveDraft)
                        }
                    }
                    .font(.system(size: 13, design: .monospaced))
                    .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(0.06)))
                    if saved == nil {
                        Button("Save", action: saveDraft).buttonStyle(NotchButtonStyle())
                            .disabled(!NotchSpotify.validClientID(trimmed))
                    } else {
                        Button("Forget") { save(nil) }.buttonStyle(NotchButtonStyle())
                    }
                }
            }
            .padding(16)
            NotchRowDivider()
            HStack(spacing: 6) {
                Text("Status").font(.system(size: 15))
                Spacer()
                Circle().fill(status.color).frame(width: 8, height: 8)
                Text(status.label).font(.system(size: 14)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).frame(height: 50)
            NotchRowDivider()
            Text(footnote).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
        }
    }

    /// Off without a Client ID; with one, whether Like or Playlist has signed in yet.
    private var status: (label: String, color: Color) {
        guard saved != nil else { return ("Off", .secondary) }
        return NotchSpotifyAccount.shared.authorized ? ("Signed in", Color(nsColor: .systemGreen))
            : ("Set, not signed in yet", notchWindowAccent)
    }

    private var footnote: AttributedString {
        var uri = AttributedString(NotchSpotify.redirectURI)
        uri.font = .system(size: 13, design: .monospaced)
        var steps = AttributedString("Setup steps")
        steps.link = URL(string: "https://github.com/AndreiStolojan/Eclipse#spotify")
        steps.foregroundColor = notchWindowAccent
        return AttributedString("Create an app in Spotify's developer dashboard with ") + uri
            + AttributedString(" as its redirect URI, then paste the Client ID here. Stored in your Keychain. ") + steps
    }

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func saveDraft() {
        guard NotchSpotify.validClientID(trimmed) else { return }
        save(trimmed)
        draft = ""
    }

    private func save(_ id: String?) {
        NotchSpotifyAccount.shared.signOut()
        NotchSpotifyClientID.save(id)
        saved = id
    }
}

/// Live player state from the media service, plus the accent used by the expanded player.
private struct NotchNowPlayingPage: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject var media: NotchMedia
    @ObservedObject var volume: NotchVolume
    @ObservedObject var like: NotchLike

    init(experience: NotchExperience) {
        self.experience = experience
        media = experience.media
        volume = experience.volume
        like = experience.media.like
    }

    var body: some View {
        NotchCard {
            HStack(spacing: 14) {
                Group {
                    if let artwork = media.track?.artwork {
                        Image(nsImage: artwork).resizable().scaledToFill()
                    } else {
                        Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(.secondary)
                            .frame(width: 56, height: 56).background(.white.opacity(0.08))
                    }
                }
                .frame(width: 56, height: 56).notchArtworkTile(cornerRadius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(media.track?.title ?? (media.unavailable ? "Player unavailable" : "Nothing playing"))
                        .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if let track = media.track {
                        Text(track.artist ?? "Unknown artist").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                if let playing = media.track?.isPlaying {
                    Image(systemName: playing ? "waveform" : "pause.fill")
                        .foregroundStyle(playing ? experience.settings.accentColor : .secondary)
                }
            }
            .padding(16)
            NotchRowDivider()
            NotchValueRow(label: "Source", value: media.source.map { [$0.name, $0.bundleIdentifier].compactMap { $0 }.joined(separator: "  ") } ?? "None")
            NotchRowDivider()
            NotchValueRow(label: "Shuffle", value: media.shuffleMode == .off ? "Off" : "On")
            NotchRowDivider()
            NotchValueRow(label: "Repeat", value: media.repeatMode == .off ? "Off" : media.repeatMode == .one ? "One" : "All")
            NotchRowDivider()
            NotchValueRow(label: "Volume", value: volume.available ? (volume.muted ? "Muted" : "\(Int((volume.level * 100).rounded()))%") : "Unavailable")
        }
        NotchSpotifyCard()
        NotchCard("Player buttons") {
            buttonRow("Left", \.playerLeftButton, other: \.playerRightButton)
            NotchRowDivider()
            buttonRow("Right", \.playerRightButton, other: \.playerLeftButton)
            // Shown only while neither JavaScript nor Accessibility reaches the YouTube tab, and gone once a like does.
            if let request = like.unreachable {
                Text(request.target == .zen ? "Like on YouTube in Zen needs the video's tab in front, in a window on this Space."
                     : "Like on YouTube needs the video's tab in front in Safari, or Allow JavaScript from Apple Events in its Develop menu.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.bottom, 12)
            }
        }
        NotchCard("Track change") {
            NotchToggleRow(label: "Show the new track", isOn: $experience.settings.peekOnTrackChange)
            NotchRowDivider()
            Group {
                NotchToggleRow(label: "Open the full notch", isOn: $experience.settings.trackPeekOpensNotch)
                NotchRowDivider()
                NotchSliderRow("Duration", $experience.settings.peekDuration, 1...8, step: 0.5) { String(format: "%.1f s", $0) }
            }
            .disabled(!experience.settings.peekOnTrackChange)
            .opacity(experience.settings.peekOnTrackChange ? 1 : 0.5)
        }
        NotchCard("Wave") {
            NotchToggleRow(label: "Show a wave while playing", isOn: $experience.settings.playingWave)
            NotchRowDivider()
            Group {
                HStack {
                    Text("Style").font(.system(size: 15))
                    Spacer()
                    Picker("Style", selection: $experience.settings.waveStyle) {
                        ForEach(NotchWaveStyle.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize().tint(notchWindowAccent)
                }
                .padding(.horizontal, 16).frame(height: 50)
                NotchRowDivider()
                NotchToggleRow(label: "Artwork colour", isOn: $experience.settings.waveArtworkColor)
                NotchRowDivider()
                NotchWavePreview(style: experience.settings.waveStyle,
                                 color: experience.settings.waveColor(artwork: media.artworkTint),
                                 active: experience.settings.playingWave && experience.windowVisible)
            }
            .disabled(!experience.settings.playingWave)
            .opacity(experience.settings.playingWave ? 1 : 0.5)
        }
        NotchCard("Artwork") {
            HStack {
                Text("Style").font(.system(size: 15)).fixedSize()
                Spacer()
                Picker("Artwork style", selection: $experience.settings.artworkTransition) {
                    ForEach(NotchArtworkTransition.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize().tint(notchWindowAccent)
            }
            .padding(.horizontal, 16).frame(height: 50)
            NotchRowDivider()
            NotchArtworkPreview(transition: experience.settings.artworkTransition,
                                openDuration: experience.settings.openAnimationDuration)
        }
        NotchCard("Appearance") {
            HStack {
                Text("Accent colour").font(.system(size: 15))
                Spacer()
                ColorPicker("Accent colour", selection: accent, supportsOpacity: false).labelsHidden()
            }
            .padding(.horizontal, 16).frame(height: 50)
        }
        NotchCard {
            HStack {
                Button("Refresh player", action: media.refresh).buttonStyle(NotchButtonStyle())
                Spacer()
            }
            .padding(16)
        }
    }

    /// A slot picker. Picking the button the other slot holds swaps the two, so no button shows twice.
    private func buttonRow(_ label: String, _ slot: WritableKeyPath<NotchSettings, NotchPlayerButton>,
                           other: WritableKeyPath<NotchSettings, NotchPlayerButton>) -> some View {
        let selection = Binding(get: { experience.settings[keyPath: slot] }, set: { button in
            var settings = experience.settings
            if button != .none, settings[keyPath: other] == button { settings[keyPath: other] = settings[keyPath: slot] }
            settings[keyPath: slot] = button
            experience.settings = settings
        })
        return HStack {
            Text(label).font(.system(size: 15))
            Spacer()
            Picker(label, selection: selection) {
                ForEach(NotchPlayerButton.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
        }
        .padding(.horizontal, 16).frame(height: 50)
    }

    private var accent: Binding<Color> {
        Binding(get: { experience.settings.accentColor },
                set: { experience.settings.accentHex = NotchSettings.hex(for: $0) })
    }
}

/// Duration, meter colour and the key takeover are shared by the volume and brightness indicators, so both
/// pages show the same cards.
private struct NotchHUDCard: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject var keys: NotchMediaKeyTap

    init(experience: NotchExperience) {
        self.experience = experience
        keys = experience.keys
    }

    var body: some View {
        NotchCard("Indicator") {
            NotchSliderRow("Duration", $experience.settings.hudDuration, 0.5...5, step: 0.1) { String(format: "%.1f s", $0) }
            NotchRowDivider()
            HStack {
                Text("Meter colour").font(.system(size: 15))
                Spacer()
                ColorPicker("Meter colour", selection: meterColor, supportsOpacity: false).labelsHidden()
            }
            .padding(.horizontal, 16).frame(height: 50)
            NotchRowDivider()
            NotchToggleRow(label: "Glow", isOn: $experience.settings.hudGlow)
        }
        NotchCard("System indicator") {
            NotchToggleRow(label: "Replace with the notch", isOn: $experience.settings.replaceSystemHUD)
            NotchRowDivider()
            NotchValueRow(label: "Accessibility", value: keys.available ? "Granted" : experience.settings.replaceSystemHUD || experience.settings.capsLockHUD ? "Needed" : "Not used")
            if experience.settings.replaceSystemHUD, !keys.available {
                Text("The notch handles the volume and brightness keys itself, so macOS shows nothing. Allow Eclipse under Accessibility; the keys are taken as soon as the switch is on.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 4)
                HStack(spacing: 10) {
                    Button("Open Accessibility settings") {
                        experience.updateKeyTap()
                        _ = NotchMediaKeyTap.requestPermission()
                        NSWorkspace.shared.open(NotchMediaKeyTap.accessibilitySettingsURL)
                    }
                    Spacer()
                }
                .buttonStyle(NotchButtonStyle())
                .padding(16)
            }
        }
    }

    private var meterColor: Binding<Color> {
        Binding(get: { experience.settings.hudColor },
                set: { experience.settings.hudColorHex = NotchSettings.hex(for: $0) })
    }
}

private struct NotchSoundPage: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject var volume: NotchVolume

    init(experience: NotchExperience) {
        self.experience = experience
        volume = experience.volume
    }

    var body: some View {
        NotchCard {
            NotchToggleRow(label: "Show volume changes", isOn: $experience.settings.volumeHUD)
            NotchRowDivider()
            NotchValueRow(label: "Output volume", value: volume.available ? (volume.muted ? "Muted" : "\(Int((volume.level * 100).rounded()))%") : "Unavailable")
        }
        NotchHUDCard(experience: experience)
    }
}

private struct NotchDisplayPage: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject var brightness: NotchBrightness

    init(experience: NotchExperience) {
        self.experience = experience
        brightness = experience.brightness
    }

    var body: some View {
        NotchCard {
            NotchToggleRow(label: "Show brightness changes", isOn: $experience.settings.brightnessHUD)
            NotchRowDivider()
            NotchValueRow(label: "Brightness", value: brightness.available ? "\(Int((brightness.level * 100).rounded()))%" : "Unavailable on this display")
            NotchRowDivider()
            NotchToggleRow(label: "Show Caps Lock changes", isOn: $experience.settings.capsLockHUD)
        }
        NotchHUDCard(experience: experience)
    }
}

/// Power connected or removed and the low battery warnings. The thresholds are fixed at 20 %, 10 % and 5 %.
private struct NotchBatteryPage: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject var battery: NotchBattery

    init(experience: NotchExperience) {
        self.experience = experience
        battery = experience.battery
    }

    var body: some View {
        NotchCard {
            NotchToggleRow(label: "Show power changes and low battery", isOn: $experience.settings.batteryHUD)
            NotchRowDivider()
            NotchValueRow(label: "Battery", value: battery.available
                          ? "\(Int((battery.level * 100).rounded()))%" + (battery.plugged ? ", power connected" : "") : "No battery")
            NotchRowDivider()
            NotchValueRow(label: "Low battery warnings", value: "20%, 10% and 5%")
        }
        NotchCard("Indicator") {
            NotchSliderRow("Duration", $experience.settings.batteryDuration, 1...10, step: 0.5) { String(format: "%.1f s", $0) }
        }
    }
}

/// An output device becoming the output or going away. Accessory battery levels are not shown: macOS has no
/// public API for them.
private struct NotchConnectivityPage: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject var devices: NotchAudioDevices

    init(experience: NotchExperience) {
        self.experience = experience
        devices = experience.audioDevices
    }

    var body: some View {
        NotchCard {
            NotchToggleRow(label: "Show audio device changes", isOn: $experience.settings.audioDeviceHUD)
            NotchRowDivider()
            NotchValueRow(label: "Output", value: devices.output?.name ?? "None")
        }
        NotchCard("Indicator") {
            NotchSliderRow("Duration", $experience.settings.audioDeviceDuration, 1...10, step: 0.5) { String(format: "%.1f s", $0) }
        }
    }
}

/// Focus needs Full Disk Access to read the system's record of the active mode, so the page says where it stands.
/// The Clipboard list on the Shelf page: the switch, how many items it keeps and macOS's paste access, which
/// must be Always Allow for Eclipse to read copies without asking each time.
private struct NotchShelfSettingsPage: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject var clipboard: NotchClipboard

    init(experience: NotchExperience) {
        self.experience = experience
        clipboard = experience.clipboard
    }

    var body: some View {
        NotchCard("Clipboard") {
            NotchToggleRow(label: "Keep copied text and images", isOn: $experience.settings.clipboardHistory)
            NotchRowDivider()
            NotchSliderRow("Items to keep", $experience.settings.clipboardLimit, 5...50, step: 1) { "\(Int($0))" }
            NotchRowDivider()
            NotchValueRow(label: "Paste access", value: accessLabel)
            NotchRowDivider()
            HStack(spacing: 10) {
                Button("Clear history", action: clipboard.clear).disabled(clipboard.history.items.isEmpty)
                Spacer()
            }
            .buttonStyle(NotchButtonStyle())
            .padding(16)
        }
        .onAppear(perform: clipboard.refreshAccess)
        if experience.settings.clipboardHistory, !clipboard.access.reads {
            NotchCard {
                Text("macOS asks before Eclipse reads what other apps copied. Set Eclipse to Allow in Paste, under Privacy & Security.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 14)
                HStack(spacing: 10) {
                    Button("Open Privacy settings") { NSWorkspace.shared.open(NotchClipboard.settingsURL) }
                    Button("Check again", action: clipboard.refreshAccess)
                    Spacer()
                }
                .buttonStyle(NotchButtonStyle())
                .padding(16)
            }
        }
    }

    private var accessLabel: String {
        switch clipboard.access {
        case .notAsked: "Not asked yet"
        case .ask: "Ask each time"
        case .allowed: "Allowed"
        case .denied: "Denied"
        }
    }
}

/// Download alerts: the switch, how long the row stays and whether macOS lets Eclipse read the Downloads folder.
private struct NotchDownloadsPage: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject var downloads: NotchDownloads

    init(experience: NotchExperience) {
        self.experience = experience
        downloads = experience.downloads
    }

    private var blocked: Bool { experience.settings.downloadAlerts && !downloads.readable }

    var body: some View {
        NotchCard {
            NotchToggleRow(label: "Show new downloads", isOn: $experience.settings.downloadAlerts)
            NotchRowDivider()
            NotchSliderRow("Notification duration", $experience.settings.downloadDuration, 2...10, step: 0.5) {
                String(format: "%.1f s", $0)
            }
            NotchRowDivider()
            NotchValueRow(label: "Downloads folder", value: !experience.settings.downloadAlerts ? "Not read" : blocked ? "Needed" : "Granted")
        }
        if blocked {
            NotchCard {
                Text("macOS did not let Eclipse read the Downloads folder. Allow it under Files and Folders, then check again.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 14)
                HStack(spacing: 10) {
                    Button("Open Privacy settings") { NSWorkspace.shared.open(NotchDownloads.privacySettingsURL) }
                    Button("Check again", action: downloads.restart)
                    Spacer()
                }
                .buttonStyle(NotchButtonStyle())
                .padding(16)
            }
        }
    }
}

private struct NotchFocusPage: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject var focus: NotchFocus

    init(experience: NotchExperience) {
        self.experience = experience
        focus = experience.focus
    }

    var body: some View {
        NotchCard {
            NotchToggleRow(label: "Show Focus changes", isOn: $experience.settings.focusHUD)
            NotchRowDivider()
            NotchValueRow(label: "Active Focus", value: focus.accessible ? (focus.active.isEmpty ? "None" : focus.active.map(\.name).joined(separator: ", ")) : "Unknown")
            NotchRowDivider()
            NotchValueRow(label: "Full Disk Access", value: focus.accessible ? "Granted" : "Needed")
        }
        .onAppear { if !focus.accessible { focus.retry() } }
        if !focus.accessible {
            NotchCard {
                Text("macOS keeps the active Focus in a protected folder. Add Eclipse under Full Disk Access, then check again.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 14)
                HStack(spacing: 10) {
                    Button("Open Privacy settings") { NSWorkspace.shared.open(NotchFocus.privacySettingsURL) }
                    Button("Check again") { focus.retry() }
                    Spacer()
                }
                .buttonStyle(NotchButtonStyle())
                .padding(16)
            }
        }
    }
}

/// The Calendar page of the open notch, the countdown, time to leave and Quick Peek in the closed notch and which
/// calendars feed them.
private struct NotchCalendarSettingsPage: View {
    @ObservedObject var experience: NotchExperience
    @ObservedObject var calendar: NotchCalendar
    @ObservedObject var travel: NotchTravel

    init(experience: NotchExperience) {
        self.experience = experience
        calendar = experience.calendar
        travel = experience.travel
    }

    var body: some View {
        NotchCard {
            NotchToggleRow(label: "Show calendar", isOn: $experience.settings.calendar)
            NotchRowDivider()
            NotchValueRow(label: "Calendar access", value: calendar.access == .granted ? "Granted" : calendar.access == .denied ? "Off" : "Needed")
            if calendar.access != .granted {
                Text("Eclipse reads today's and tomorrow's events to show them in the notch. Nothing leaves this Mac.")
                    .font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 4)
                HStack {
                    Button(calendar.access == .denied ? "Open Privacy settings" : "Allow calendar access", action: calendar.requestAccess)
                    Spacer()
                }
                .buttonStyle(NotchButtonStyle())
                .padding(16)
            }
        }
        .onAppear { calendar.refreshAccess() }
        NotchCard("Live activity") {
            NotchToggleRow(label: "Count down to the next event", isOn: $experience.settings.calendarCountdown)
            NotchRowDivider()
            NotchSliderRow("Time before event", $experience.settings.calendarLead, 5...60, step: 5) { "\(Int($0)) min" }
        }
        NotchCard("Time to leave") {
            NotchToggleRow(label: "Notify when time to leave", isOn: $experience.settings.timeToLeave)
            NotchRowDivider()
            HStack {
                Text("Location access").font(.system(size: 15))
                Spacer()
                if travel.access == .granted {
                    Text("Granted").font(.system(size: 15)).foregroundStyle(.secondary)
                } else {
                    // Before the first answer it asks macOS; after a refusal it opens the Location Services pane.
                    Button(travel.access == .denied ? "Open Settings" : "Allow", action: travel.requestAccess)
                        .buttonStyle(NotchButtonStyle())
                }
            }
            .padding(.horizontal, 16).frame(height: 50)
            NotchRowDivider()
            HStack {
                Text("Travel mode").font(.system(size: 15))
                Spacer()
                Picker("Travel mode", selection: $experience.settings.travelMode) {
                    ForEach(NotchTravelMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize().tint(notchWindowAccent)
            }
            .padding(.horizontal, 16).frame(height: 50)
            NotchRowDivider()
            NotchSliderRow("Leave buffer", $experience.settings.leaveBuffer, 0...30, step: 5) { "\(Int($0)) min" }
            NotchRowDivider()
            NotchSliderRow("Notification duration", $experience.settings.leaveDuration, 2...15, step: 1) { "\(Int($0)) s" }
        }
        if !calendar.calendars.isEmpty {
            NotchCard("Calendars") {
                ForEach(Array(calendar.calendars.enumerated()), id: \.element.id) { index, source in
                    if index > 0 { NotchRowDivider() }
                    HStack(spacing: 10) {
                        Circle().fill(Color(nsColor: source.color)).frame(width: 10, height: 10)
                        Text(source.title).font(.system(size: 15)).lineLimit(1)
                        Spacer()
                        Text(source.account).font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                        Toggle(source.title, isOn: shown(source.id)).labelsHidden().toggleStyle(.switch).tint(notchWindowAccent)
                    }
                    .padding(.horizontal, 16).frame(height: 50)
                }
            }
        }
        NotchCard("Quick Peek") {
            NotchToggleRow(label: "Before event starts", isOn: $experience.settings.calendarPeekBefore)
            NotchRowDivider()
            NotchToggleRow(label: "When event is starting", isOn: $experience.settings.calendarPeekAtStart)
            NotchRowDivider()
            NotchSliderRow("Peek duration", $experience.settings.calendarPeekDuration, 1...10, step: 0.5) { String(format: "%.1f s", $0) }
        }
    }

    private func shown(_ id: String) -> Binding<Bool> {
        Binding(get: { !experience.settings.hiddenCalendars.contains(id) },
                set: { show in
                    if show { experience.settings.hiddenCalendars.remove(id) } else { experience.settings.hiddenCalendars.insert(id) }
                })
    }
}

/// The Timer page of the open notch, its phase alerts and its finish.
private struct NotchTimerSettingsPage: View {
    @ObservedObject var experience: NotchExperience

    var body: some View {
        NotchCard {
            NotchToggleRow(label: "Show timer", isOn: $experience.settings.timer)
        }
        Group {
            NotchCard("Alerts") {
                NotchToggleRow(label: "Alert at 10, 5 and 1 min left", isOn: $experience.settings.timerPhaseAlerts)
            }
            NotchCard("Done") {
                HStack {
                    Text("Sound").font(.system(size: 15))
                    Spacer()
                    Picker("Sound", selection: sound) {
                        Text("None").tag("")
                        Divider()
                        ForEach(NotchTimer.sounds, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
                }
                .padding(.horizontal, 16).frame(height: 50)
                NotchRowDivider()
                NotchSliderRow("Duration", $experience.settings.timerDoneDuration, 5...120, step: 5) { "\(Int($0)) s" }
            }
        }
        .disabled(!experience.settings.timer)
        .opacity(experience.settings.timer ? 1 : 0.5)
    }

    /// Picking a sound plays it.
    private var sound: Binding<String> {
        Binding(get: { experience.settings.timerSound },
                set: { experience.settings.timerSound = $0; experience.playTimerSound() })
    }
}

private struct NotchAboutPage: View {
    @ObservedObject var experience: NotchExperience

    var body: some View {
        NotchCard {
            NotchValueRow(label: "Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
            NotchRowDivider()
            NotchValueRow(label: "License", value: "GPL v3")
            NotchRowDivider()
            HStack {
                Text("Repository").font(.system(size: 15))
                Spacer()
                Link("AndreiStolojan/Eclipse", destination: URL(string: "https://github.com/AndreiStolojan/Eclipse")!)
                    .font(.system(size: 14)).foregroundStyle(notchWindowAccent)
            }
            .padding(.horizontal, 16).frame(height: 50)
        }
        NotchCard {
            HStack {
                Button("Reset all settings to defaults") { experience.settings = NotchSettings() }
                    .buttonStyle(NotchButtonStyle())
                Spacer()
            }
            .padding(16)
        }
    }
}

/// The lock in the notch and the media widget on the lock screen, with the widget's material and place.
private struct NotchLockScreenPage: View {
    @ObservedObject var experience: NotchExperience

    var body: some View {
        NotchCard {
            NotchToggleRow(label: "Show lock in the notch", isOn: $experience.settings.lockIcon)
            NotchRowDivider()
            NotchToggleRow(label: "Show media on the lock screen", isOn: $experience.settings.lockScreenMedia)
            NotchRowDivider()
            // The windows rely on a private macOS call; say so when this macOS no longer offers it.
            NotchValueRow(label: "Above the lock screen", value: NotchLockSpace.available ? "Supported" : "Unavailable on this macOS")
        }
        NotchCard("Media widget") {
            HStack {
                Text("Style").font(.system(size: 15))
                Spacer()
                Picker("Style", selection: $experience.settings.lockScreenGlass) {
                    ForEach(NotchLockGlass.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().pickerStyle(.segmented).fixedSize().tint(notchWindowAccent)
            }
            .padding(.horizontal, 16).frame(height: 50)
            NotchRowDivider()
            NotchSliderRow("Opacity", $experience.settings.lockScreenDimming, 0...0.8, step: 0.05, format: percent)
            NotchRowDivider()
            NotchSliderRow("Vertical offset", $experience.settings.lockScreenWidgetOffset, NotchLockScreenLayout.offsetRange,
                           step: 4, format: points)
            NotchRowDivider()
            NotchToggleRow(label: "Enlarge artwork on tap", isOn: $experience.settings.lockScreenArtTap)
        }
        .disabled(!experience.settings.lockScreenMedia)
        .opacity(experience.settings.lockScreenMedia ? 1 : 0.5)
    }
}

extension NotchSettings {
    var accentColor: Color { Self.color(hex: accentHex) ?? Color(red: 164 / 255, green: 216 / 255, blue: 223 / 255) }
    var hudColor: Color { Self.color(hex: hudColorHex) ?? .white }
    /// The wave's colour: the artwork's average when chosen and known, the dictation bars' white otherwise.
    func waveColor(artwork tint: NSColor?) -> Color {
        guard waveArtworkColor, let tint else { return .white.opacity(0.85) }
        return Color(nsColor: tint)
    }

    static func color(hex: String) -> Color? {
        var value: UInt64 = 0
        guard hex.count == 6, Scanner(string: hex).scanHexInt64(&value) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    static func hex(for color: Color) -> String {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return NotchSettings().accentHex }
        let channel = { (component: CGFloat) in Int((max(0, min(1, component)) * 255).rounded()) }
        return String(format: "%02X%02X%02X", channel(rgb.redComponent), channel(rgb.greenComponent), channel(rgb.blueComponent))
    }
}

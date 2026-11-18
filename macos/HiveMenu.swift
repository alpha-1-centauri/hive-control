import AppKit
import SwiftUI
import ServiceManagement

struct Product: Decodable, Identifiable {
    let id: String
    let type: String
    let name: String?
    let online: Bool?
    let temperature: Double?
    let target: Double?
    let mode: String?
    let working: Bool?
    let boost: Int?
    var title: String { name ?? "Heating" }
    var isOnline: Bool { online == true }
    var isHeating: Bool { isOnline && working == true }
    /// One short line describing what the zone is doing right now.
    var status: String {
        guard isOnline else { return "Offline" }
        let goal = target.map(Format.short)
        switch mode {
        case "SCHEDULE": return ["Schedule", goal].compactMap { $0 }.joined(separator: " · ")
        case "MANUAL": return ["Holding", goal].compactMap { $0 }.joined(separator: " ")
        case "BOOST": return [goal ?? "Boost", boost.map { "\($0) min left" }].compactMap { $0 }.joined(separator: " · ")
        case "OFF": return "Off"
        default: return "Unknown mode"
        }
    }
}

enum Format {
    /// Target-style temperature: "20°" or "20.5°".
    static func short(_ value: Double) -> String {
        value == value.rounded() ? String(format: "%.0f°", value) : String(format: "%.1f°", value)
    }
    /// Measured temperature, always one decimal: "19.5°".
    static func reading(_ value: Double?) -> String {
        value.map { String(format: "%.1f°", $0) } ?? "–"
    }
}

struct Snapshot: Decodable {
    let temperature_unit: String?
    let products: [Product]
}

struct CommandResult: Decodable {
    let submitted: Bool?
    let observed: Product?
}

struct RuntimeConfig: Decodable { let python: String }
struct BridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Bridge {
    static func run(_ arguments: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard let resources = Bundle.main.resourceURL else {
                        throw BridgeError(message: "App resources are missing. Rebuild Hive Control.")
                    }
                    let config = try JSONDecoder().decode(RuntimeConfig.self,
                        from: Data(contentsOf: resources.appendingPathComponent("runtime.json")))
                    guard FileManager.default.isExecutableFile(atPath: config.python) else {
                        throw BridgeError(message: "The Hive Python runtime was moved. Rebuild Hive Control from its project folder.")
                    }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: config.python)
                    process.arguments = [resources.appendingPathComponent("hive_control.py").path] + arguments
                    var env = ProcessInfo.processInfo.environment
                    env["PYTHONUNBUFFERED"] = "1"
                    env["PYTHONDONTWRITEBYTECODE"] = "1"
                    process.environment = env
                    let output = Pipe(), errors = Pipe()
                    process.standardOutput = output
                    process.standardError = errors
                    try process.run()
                    let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                    DispatchQueue.global().asyncAfter(deadline: .now() + (arguments.first == "login" ? 600 : 90), execute: timeout)
                    let data = output.fileHandleForReading.readDataToEndOfFile()
                    let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    timeout.cancel()
                    guard process.terminationStatus == 0 else {
                        let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        // Only surface the wrapper's concise errors, never arbitrary tracebacks.
                        throw BridgeError(message: message.isEmpty || message.contains("Traceback")
                            ? "Hive could not complete this request. Refresh to check the current state."
                            : String(message.suffix(450)))
                    }
                    continuation.resume(returning: data)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

@MainActor final class HiveModel: ObservableObject {
    @Published var zones: [Product] = []
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var updated: Date?
    @Published var unit: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Zone id → the mode just asked for. The strip shows it straight away and
    /// keeps it until Hive's reported state takes over.
    @Published var intents: [String: String] = [:]
    private var requests: [String: Int] = [:]  // zone id → latest command number
    var lastAttempt = Date.distantPast
    var onUpdate: (() -> Void)?

    var isCelsius: Bool { ["C", "CELSIUS", "Celsius", "celsius", "°C"].contains(unit ?? "") }

    func accept(_ data: Data) throws {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        zones = snapshot.products.filter { $0.type == "heating" }.sorted { $0.title < $1.title }
        unit = snapshot.temperature_unit
        updated = Date()
        onUpdate?()
    }

    func refresh() {
        guard !busy else { return }
        Task { await reload() }
    }

    private func reload() async {
        guard !busy else { return }
        busy = true
        lastAttempt = Date()
        defer { busy = false }
        do {
            try accept(await Bridge.run(["status"]))
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func control(_ zone: Product, action: String, temperature: Double? = nil, minutes: Int? = nil, mode: String? = nil) {
        guard !busy else { return }
        busy = true
        error = nil
        notice = nil
        lastAttempt = Date()
        intents[zone.id] = action == "manual" ? "MANUAL" : action == "boost" ? "BOOST" : mode
        let request = (requests[zone.id] ?? 0) + 1
        requests[zone.id] = request
        var args = [action, zone.id]
        if action == "manual", let temperature { args.append(String(temperature)) }
        if action == "boost", let temperature, let minutes {
            args += ["--minutes", String(minutes), "--temperature", String(temperature)]
        }
        if let mode { args.append(mode) }
        Task {
            var confirmed = false
            do {
                let result = try JSONDecoder().decode(CommandResult.self, from: await Bridge.run(args))
                if let observed = result.observed, let index = zones.firstIndex(where: { $0.id == observed.id }) {
                    zones[index] = observed
                    updated = Date()
                    if action == "manual" {
                        confirmed = observed.mode == "MANUAL" && abs((observed.target ?? -100) - (temperature ?? 0)) < 0.1
                    } else if action == "boost" {
                        confirmed = observed.mode == "BOOST" && abs((observed.target ?? -100) - (temperature ?? 0)) < 0.1
                    } else { confirmed = observed.mode == mode }
                    onUpdate?()
                }
            } catch {
                self.error = error.localizedDescription
                confirmed = true  // nothing was accepted: fall straight back to the reported state
            }
            busy = false
            if !confirmed {
                // Hive took the command but has not reported it yet. Keep showing
                // what was asked for, look once more, then show whatever Hive says.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                await reload()
            }
            if requests[zone.id] == request { intents[zone.id] = nil }
        }
    }

    func reconnect() {
        guard !busy else { return }
        busy = true
        error = nil
        notice = "Complete the Hive login in the Mac dialogs."
        Task {
            defer { busy = false }
            do {
                try accept(await Bridge.run(["login", "--gui"]))
                notice = "Connected to Hive."
            } catch { self.error = error.localizedDescription; notice = nil }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            if enabled && !launchAtLogin {
                notice = "Allow Hive Control in System Settings → General → Login Items."
                SMAppService.openSystemSettingsLoginItems()
            }
        } catch { self.error = "Could not change launch at login: \(error.localizedDescription)" }
    }
}

// MARK: - Design

enum Theme {
    static let width: CGFloat = 340
    static let warm = LinearGradient(
        colors: [Color(red: 1.0, green: 0.64, blue: 0.20), Color(red: 0.97, green: 0.36, blue: 0.22)],
        startPoint: .topLeading, endPoint: .bottomTrailing)
    static let accent = Color(red: 0.98, green: 0.52, blue: 0.16)
    /// Accent that stays legible as small text in both appearances.
    static let accentText = dynamic(light: NSColor(red: 0.78, green: 0.33, blue: 0.04, alpha: 1),
                                    dark: NSColor(red: 1.0, green: 0.66, blue: 0.30, alpha: 1))
    static let card = dynamic(light: NSColor(white: 1, alpha: 0.75), dark: NSColor(white: 1, alpha: 0.07))
    /// Selected-mode pill for Off: a neutral raised thumb rather than a warm one.
    static let raised = dynamic(light: NSColor(white: 1, alpha: 1), dark: NSColor(white: 1, alpha: 0.22))
    /// The one motion curve for anything that slides or settles.
    static let slide = Animation.spring(response: 0.42, dampingFraction: 0.74)
    static let control = Color.primary.opacity(0.06)
    static let controlHover = Color.primary.opacity(0.12)

    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

struct PressStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(enabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Slow pulse while a command is in flight.
struct Breathing: ViewModifier {
    let active: Bool
    @State private var low = false
    func body(content: Content) -> some View {
        content.opacity(low ? 0.55 : 1)
            .onChange(of: active) { on in
                if on {
                    withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) { low = true }
                } else {
                    withAnimation(.easeOut(duration: 0.3)) { low = false }
                }
            }
    }
}

extension View {
    /// Bounce an SF Symbol each time `value` changes (macOS 14+).
    @ViewBuilder func bounces(on value: Int) -> some View {
        if #available(macOS 14.0, *) { symbolEffect(.bounce, value: value) } else { self }
    }
    /// Keep firing while the button is held (macOS 14+); a plain click elsewhere.
    @ViewBuilder func repeatsWhileHeld() -> some View {
        if #available(macOS 14.0, *) { buttonRepeatBehavior(.enabled) } else { self }
    }
}

/// A native pop-up menu shown from any custom-drawn button.
struct MenuEntry {
    var title = ""
    var checked = false
    var enabled = true
    var action: (() -> Void)?
    static let separator = MenuEntry(title: "-")
    static func header(_ title: String) -> MenuEntry { MenuEntry(title: title, enabled: false) }
}

final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

@MainActor func showMenu(_ entries: [MenuEntry]) {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for entry in entries {
        if entry.title == "-" { menu.addItem(.separator()); continue }
        let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
        if let action = entry.action {
            let target = MenuAction(action)
            item.target = target
            item.action = #selector(MenuAction.fire)
            item.representedObject = target  // keeps the target alive with its item
        }
        item.isEnabled = entry.enabled && entry.action != nil
        item.state = entry.checked ? .on : .off
        menu.addItem(item)
    }
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
}

/// Small round toolbar button.
struct IconButton: View {
    let icon: String
    let label: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(hover ? Theme.controlHover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle()).onHover { hover = $0 }
        .help(label).accessibilityLabel(label)
    }
}

/// One segment of a zone's mode strip. The strip draws a single pill behind the
/// selected segment; each segment only reports its frame for the pill to follow.
struct ModeChip: View {
    let mode: String
    let title: String
    let icon: String
    let selected: Bool
    var hinted = false     // this action would apply the unsent temperature
    var opensMenu = false
    var width: CGFloat?    // nil shares the strip's remaining width equally
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var hover = false
    @State private var taps = 0

    private var ink: Color {
        if selected { return mode == "OFF" ? .primary : .white }
        return hinted ? Theme.accentText : .primary.opacity(0.8)
    }
    private var wash: Color {
        if selected { return .clear }
        if hinted { return Theme.accent.opacity(hover ? 0.28 : 0.18) }
        return hover ? Theme.controlHover : .clear
    }

    var body: some View {
        Button { taps += 1; action() } label: {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold)).bounces(on: taps)
                Text(title).font(.system(size: 11, weight: .medium))
                if opensMenu {
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).opacity(0.6)
                }
            }
            .lineLimit(1).foregroundStyle(ink)
            .frame(maxWidth: width ?? .infinity).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(wash))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .matchedGeometryEffect(id: mode, in: namespace, isSource: true)
        }
        .buttonStyle(PressStyle()).onHover { hover = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Schedule / Hold / Boost / Off as one track with a pill that springs to the
/// selected mode. `selected` is nil when the zone has no known mode.
struct ModeStrip: View {
    let selected: String?
    let inFlight: Bool
    let hinted: Bool
    let draft: Double
    let choose: (String) -> Void
    @Namespace private var strip

    private var pill: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        let off = selected == "OFF"
        return ZStack {
            shape.fill(Theme.raised).opacity(off ? 1 : 0)
            shape.fill(Theme.warm).opacity(off ? 0 : 1)
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.04)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
        }
        .shadow(color: off ? .black.opacity(0.14) : Theme.accent.opacity(0.4), radius: off ? 2 : 5, y: off ? 1 : 2)
        .modifier(Breathing(active: inFlight))
    }

    var body: some View {
        HStack(spacing: 2) {
            ModeChip(mode: "SCHEDULE", title: "Schedule", icon: "calendar",
                     selected: selected == "SCHEDULE", namespace: strip) { choose("SCHEDULE") }
                .help("Follow the Hive schedule. Ends a boost or hold.")
            ModeChip(mode: "MANUAL", title: "Hold", icon: "pin.fill",
                     selected: selected == "MANUAL", hinted: hinted, namespace: strip) { choose("MANUAL") }
                .help("Hold \(Format.short(draft)) until you change it.")
            ModeChip(mode: "BOOST", title: "Boost", icon: "bolt.fill",
                     selected: selected == "BOOST", hinted: hinted, opensMenu: true, namespace: strip) { choose("BOOST") }
                .help("Heat to \(Format.short(draft)) for a set time, then return to the previous mode.")
            ModeChip(mode: "OFF", title: "Off", icon: "power",
                     selected: selected == "OFF", width: 54, namespace: strip) { choose("OFF") }
                .help("Turn this zone's heating off.")
        }
        .padding(2)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.control)
                if let selected {
                    pill.matchedGeometryEffect(id: selected, in: strip, isSource: false)
                        .transition(.opacity.combined(with: .scale(scale: 0.85)))
                }
            }
        }
        .animation(Theme.slide, value: selected)
        .animation(.easeOut(duration: 0.2), value: hinted)
    }
}

/// Compact − value + control for the temperature that Hold and Boost will send.
struct TemperatureStepper: View {
    @Binding var value: Double
    let pending: Bool
    let name: String
    static let range = 5.0...32.0

    private func nudge(_ delta: Double) {
        value = min(Self.range.upperBound, max(Self.range.lowerBound, value + delta))
    }
    private func side(_ icon: String, _ delta: Double, disabled: Bool) -> some View {
        Button { nudge(delta) } label: {
            Image(systemName: icon).font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(PressStyle()).repeatsWhileHeld().disabled(disabled)
    }

    var body: some View {
        HStack(spacing: 0) {
            side("minus", -0.5, disabled: value <= Self.range.lowerBound)
            Text(Format.short(value))
                .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(pending ? Theme.accentText : .primary)
                .contentTransition(.numericText()).animation(.spring(response: 0.3, dampingFraction: 0.8), value: value)
                .frame(width: 42)
            side("plus", 0.5, disabled: value >= Self.range.upperBound)
        }
        .background(Capsule().fill(Theme.control))
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(pending ? 0.55 : 0), lineWidth: 1))
        .help("Temperature to use for Hold or Boost. Changing it sends nothing by itself.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) set temperature")
        .accessibilityValue(String(format: "%.1f degrees", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: nudge(0.5)
            case .decrement: nudge(-0.5)
            @unknown default: break
            }
        }
    }
}

struct ZoneCard: View {
    let zone: Product
    @ObservedObject var model: HiveModel
    @State private var draft: Double
    @State private var edited = false

    init(zone: Product, model: HiveModel) {
        self.zone = zone
        self.model = model
        _draft = State(initialValue: Self.suggestion(for: zone))
    }

    /// The temperature offered before the user edits it. An Off zone reports its
    /// frost-protection target, so start from an ordinary room temperature instead.
    static func suggestion(for zone: Product) -> Double {
        zone.mode == "OFF" ? 20 : min(32, max(5, zone.target ?? 20))
    }
    private var selection: Binding<Double> {
        Binding(get: { draft }, set: { draft = $0; edited = true })
    }
    /// The stepper holds a value that has not been sent to Hive.
    private var pending: Bool { edited && draft != Self.suggestion(for: zone) }
    private var usable: Bool { zone.isOnline && model.isCelsius }
    /// What the strip shows: the mode just asked for, else the one Hive reports.
    private var shownMode: String? { model.intents[zone.id] ?? (zone.isOnline ? zone.mode : nil) }
    private func choose(_ mode: String) {
        switch mode {
        case "MANUAL": send("manual")
        case "BOOST": boostMenu()
        default: send("mode", mode: mode)
        }
    }

    private func send(_ action: String, minutes: Int? = nil, mode: String? = nil) {
        model.control(zone, action: action, temperature: draft, minutes: minutes, mode: mode)
        edited = false
    }
    private func boostMenu() {
        showMenu([.header("Boost to \(Format.short(draft)) for")] + [(30, "30 minutes"), (60, "1 hour"), (120, "2 hours")].map { minutes, title in
            MenuEntry(title: title) { send("boost", minutes: minutes) }
        })
    }

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Text(Format.reading(zone.isOnline ? zone.temperature : nil))
                    .font(.system(size: 27, weight: .regular, design: .rounded)).monospacedDigit()
                    .foregroundStyle(zone.isHeating ? AnyShapeStyle(Theme.warm)
                                     : AnyShapeStyle(zone.isOnline ? .primary : .tertiary))
                    .contentTransition(.numericText()).fixedSize()
                    .accessibilityLabel("Current temperature \(Format.reading(zone.temperature))")
                VStack(alignment: .leading, spacing: 2) {
                    Text(zone.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 3) {
                        if pending {
                            Text("Hold or Boost to set").foregroundStyle(Theme.accentText)
                        } else {
                            if zone.isHeating {
                                Image(systemName: "flame.fill").foregroundStyle(Theme.warm)
                                    .accessibilityLabel("Heating")
                            } else if !zone.isOnline {
                                Image(systemName: "wifi.slash")
                            }
                            Text(zone.status).contentTransition(.opacity)
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
                }
                Spacer(minLength: 4)
                TemperatureStepper(value: selection, pending: pending, name: zone.title)
            }
            ModeStrip(selected: shownMode, inFlight: model.intents[zone.id] != nil,
                      hinted: pending && usable, draft: draft, choose: choose)
                .allowsHitTesting(!model.busy)  // one command at a time, without dimming the strip
        }
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card)
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(LinearGradient(
                    colors: [Theme.accent.opacity(0.16), Theme.accent.opacity(0)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .opacity(zone.isHeating ? 1 : 0)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
        .disabled(!usable)
        .animation(.easeOut(duration: 0.18), value: pending)
        .animation(.easeInOut(duration: 0.45), value: zone.isHeating)
        .animation(Theme.slide, value: zone.temperature)
        .animation(.easeOut(duration: 0.25), value: zone.status)
        .onChange(of: zone.target) { _ in if !edited { draft = Self.suggestion(for: zone) } }
        .onChange(of: zone.mode) { _ in if !edited { draft = Self.suggestion(for: zone) } }
    }
}

struct Banner: View {
    let text: String
    let icon: String
    let tint: Color
    var dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 14, height: 14).contentShape(Rectangle())
                }.buttonStyle(PressStyle()).help("Dismiss").accessibilityLabel("Dismiss")
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.12)))
    }
}

struct Panel: View {
    @ObservedObject var model: HiveModel

    private func optionsMenu() {
        showMenu([
            MenuEntry(title: "Launch at login", checked: model.launchAtLogin) { model.setLaunchAtLogin(!model.launchAtLogin) },
            MenuEntry(title: "Reconnect to Hive…", enabled: !model.busy) { model.reconnect() },
            .separator,
            MenuEntry(title: "Quit Hive Control") { NSApp.terminate(nil) },
        ])
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "flame.fill").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.warm))
                .accessibilityHidden(true)
            Text("Hive").font(.system(size: 13, weight: .semibold))
            Group {
                if let updated = model.updated {
                    Text("Updated \(updated.formatted(date: .omitted, time: .shortened))")
                } else {
                    Text(model.busy ? "Connecting…" : "Not connected")
                }
            }.font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            ZStack {
                if model.busy {
                    ProgressView().controlSize(.small).scaleEffect(0.75)
                } else {
                    IconButton(icon: "arrow.clockwise", label: "Refresh temperatures") { model.refresh() }
                }
            }.frame(width: 24, height: 24)
            IconButton(icon: "ellipsis", label: "Options") { optionsMenu() }
        }
    }

    private var zones: some View {
        VStack(spacing: 8) {
            ForEach(model.zones) { zone in ZoneCard(zone: zone, model: model) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let error = model.error {
                Banner(text: error, icon: "exclamationmark.triangle.fill", tint: .red) { model.error = nil }
                    .transition(.opacity)
            }
            if let notice = model.notice {
                Banner(text: notice, icon: "info.circle.fill", tint: .secondary) { model.notice = nil }
                    .transition(.opacity)
            }
            if model.zones.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "house").font(.system(size: 22)).foregroundStyle(.secondary)
                    Text(model.busy ? "Connecting to your home…" : "No heating zones available.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    if !model.busy {
                        Button("Reconnect to Hive…") { model.reconnect() }.controlSize(.small)
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 18)
            } else {
                if !model.isCelsius {
                    Banner(text: "Temperature controls require a Celsius account.",
                           icon: "exclamationmark.triangle.fill", tint: .red)
                }
                // Up to five zones fit as-is; a larger home scrolls.
                if model.zones.count > 5 { ScrollView { zones }.frame(height: 500) } else { zones }
            }
        }
        .padding(12).frame(width: Theme.width)
        .animation(.easeOut(duration: 0.2), value: model.error)
        .animation(.easeOut(duration: 0.2), value: model.notice)
        .background {
            // The app has no main menu, so keep ⌘Q working while the panel is open.
            Button("Quit Hive Control") { NSApp.terminate(nil) }
                .keyboardShortcut("q").opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
        }
    }
}

// MARK: - Menu bar

enum Tray {
    /// Diverging colour map for a room temperature: blue at 18 °C and below,
    /// the ordinary menu bar text colour at 20 °C, orange at 22 °C and above.
    /// Resolved at draw time, so it follows a light or dark menu bar.
    static func color(for temperature: Double) -> NSColor {
        let t = min(1, max(0, (temperature - 18) / 4))
        return NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .aqua, .vibrantLight])
            let dark = match == .darkAqua || match == .vibrantDark
            let cold: [CGFloat] = dark ? [0.36, 0.72, 1.00] : [0.00, 0.40, 0.90]
            let plain: [CGFloat] = dark ? [1, 1, 1] : [0, 0, 0]
            let warm: [CGFloat] = dark ? [1.00, 0.60, 0.20] : [0.84, 0.38, 0.00]
            let (from, to, f) = t < 0.5 ? (cold, plain, CGFloat(t * 2)) : (plain, warm, CGFloat((t - 0.5) * 2))
            let c = zip(from, to).map { $0 + ($1 - $0) * f }
            return NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
        }
    }

    /// "D: 19.5°  U: 18.2°": each zone's initial and its measured temperature, as
    /// plain text for VoiceOver and for telling when the readings have changed.
    static func summary(for zones: [Product]) -> String {
        zones.map { zone in
            "\(zone.title.prefix(1).uppercased()): \(Format.reading(zone.isOnline ? zone.temperature : nil))"
        }.joined(separator: "  ")
    }

    /// Each zone's initial and temperature as two short rows per column: narrow
    /// enough to sit beside a MacBook notch. Colours resolve each time it is drawn.
    static func stacked(for zones: [Product]) -> NSImage {
        let labelFont = NSFont.systemFont(ofSize: 10)
        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        let cells: [(label: NSAttributedString, value: NSAttributedString)] = zones.map { zone in
            let known = zone.isOnline ? zone.temperature : nil
            return (NSAttributedString(string: "\(zone.title.prefix(1).uppercased()):", attributes: [
                        .font: labelFont, .foregroundColor: NSColor.secondaryLabelColor]),
                    NSAttributedString(string: Format.reading(known), attributes: [
                        .font: numberFont, .foregroundColor: known.map(color(for:)) ?? .tertiaryLabelColor]))
        }
        let columns = stride(from: 0, to: cells.count, by: 2).map { Array(cells[$0..<min($0 + 2, cells.count)]) }
        let widths = columns.map { column in
            (label: column.map { $0.label.size().width }.max() ?? 0, value: column.map { $0.value.size().width }.max() ?? 0)
        }
        let pitch: CGFloat = 11, gap: CGFloat = 3, spacing: CGFloat = 8
        let width = ceil(widths.reduce(0) { $0 + $1.label + gap + $1.value } + spacing * CGFloat(max(0, columns.count - 1)))
        let height = pitch * 2
        return NSImage(size: NSSize(width: max(1, width), height: height), flipped: false) { _ in
            var x: CGFloat = 0
            for (column, w) in zip(columns, widths) {
                let top = (height + pitch * CGFloat(column.count)) / 2  // a lone row sits centred
                for (row, cell) in column.enumerated() {
                    let y = top - pitch * CGFloat(row + 1) + (pitch - cell.value.size().height) / 2
                    cell.label.draw(at: NSPoint(x: x, y: y))
                    cell.value.draw(at: NSPoint(x: x + w.label + gap + w.value - cell.value.size().width, y: y))
                }
                x += w.label + gap + w.value + spacing
            }
            return true
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = HiveModel()
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var timer: Timer?
    private var trayState: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // One copy only: a second one (say, the build folder's app beside the installed
        // one) takes a menu bar slot of its own and can push both under the notch.
        // The newest launch wins, so reopening after a rebuild replaces the old copy.
        let current = NSRunningApplication.current
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where other.processIdentifier != current.processIdentifier {
            other.terminate()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusBar.system.thickness)
        if let button = statusItem.button {
            button.toolTip = "Hive Control"
            button.target = self
            button.action = #selector(togglePopover)
        }
        popover.behavior = .transient
        let hosting = NSHostingController(rootView: Panel(model: model))
        hosting.sizingOptions = [.preferredContentSize]  // popover hugs the panel as it grows and shrinks
        popover.contentViewController = hosting
        model.onUpdate = { [weak self] in
            guard let self else { return }
            let text = self.model.zones.map { zone in
                "\(zone.title): \(zone.temperature.map { String(format: "%.1f°C", $0) } ?? "unavailable")"
            }.joined(separator: " · ")
            self.statusItem.button?.toolTip = "Hive — \(text)"
            self.updateStatusItem()
        }
        updateStatusItem()
        model.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let interval: TimeInterval = self.popover.isShown ? 60 : 300
                if Date().timeIntervalSince(self.model.lastAttempt) >= interval { self.model.refresh() }
            }
        }
    }

    /// Always the two-row form once there are readings; a thermometer before the
    /// first one. The form never depends on the room in the menu bar: choosing by
    /// measured room made the item flip between forms while the screen was shared.
    func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let zones = model.zones
        let summary = Tray.summary(for: zones)
        guard summary != trayState else { return }
        trayState = summary
        button.attributedTitle = NSAttributedString()
        button.imagePosition = .imageOnly
        if zones.isEmpty {
            let icon = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "Hive Control")
            icon?.isTemplate = true
            button.image = icon
            statusItem.length = NSStatusBar.system.thickness
        } else {
            let stacked = Tray.stacked(for: zones)
            button.image = stacked
            statusItem.length = stacked.size.width + 4
        }
        button.setAccessibilityLabel(zones.isEmpty ? "Hive Control" : "Hive Control, \(summary)")
    }

    @objc func togglePopover() {
        if popover.isShown { popover.performClose(nil) }
        else if let button = statusItem.button {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            if Date().timeIntervalSince(model.lastAttempt) > 30 { model.refresh() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !popover.isShown { togglePopover() }
        return true
    }
}

@main enum HiveMenuApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

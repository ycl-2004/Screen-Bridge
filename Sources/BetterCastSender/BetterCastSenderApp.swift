import SwiftUI
@preconcurrency import Network
@preconcurrency import Dispatch
import Security
import ScreenCaptureKit
import IOKit.graphics
import BetterCastShared


@main
struct BetterCastSenderApp: App {
    @StateObject private var networkClient = NetworkClient()
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @AppStorage("hasCompletedTour") private var hasCompletedTour = false

    var body: some Scene {
        WindowGroup {
            if hasCompletedOnboarding {
                mainView
            } else {
                OnboardingView(onComplete: {
                    hasCompletedOnboarding = true
                })
                .frame(minWidth: 520, minHeight: 600)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }

        // macOS expects preferences under the app menu at ⌘,. Without this scene
        // the shortcut did nothing and the menu item was missing entirely; the
        // settings were only reachable as a sidebar item in the main window.
        Settings {
            DetailPanelView(
                client: networkClient,
                selection: .constant(.settings)
            )
            .frame(minWidth: 620, idealWidth: 660, minHeight: 500, idealHeight: 600)
        }
    }

    enum SidebarSelection: Hashable {
        case devices
        case settings
        case device(UUID)
        case discovered(String) // Unconnected device by service name
        case logs
    }

    @State private var sidebarSelection: SidebarSelection? = .devices
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showTour = false

    private var mainView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(client: networkClient, selection: $sidebarSelection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 350)
        } detail: {
            DetailPanelView(client: networkClient, selection: $sidebarSelection)
        }
        .frame(minWidth: 750, minHeight: 540)
        .overlay {
            if showTour {
                GuidedTourOverlay(
                    selection: $sidebarSelection,
                    onDismiss: {
                        withAnimation { showTour = false }
                        hasCompletedTour = true
                    }
                )
                .transition(.opacity)
            }
        }
        .onAppear {
            networkClient.checkScreenRecordingPermission()
            networkClient.startBrowsing()
            if !hasCompletedTour {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    withAnimation { showTour = true }
                }
            }
        }
        .onChange(of: hasCompletedTour) { _, completed in
            if !completed {
                sidebarSelection = .devices
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation { showTour = true }
                }
            }
        }
    }
}

// MARK: - Tour Anchor Store (global coordinates)

/// Stores sidebar item frames in global coordinate space for the tour spotlight.
@MainActor
final class TourAnchorStore: ObservableObject {
    static let shared = TourAnchorStore()
    @Published var globalFrames: [String: CGRect] = [:]
    @Published var overlayOrigin: CGPoint = .zero

    /// Returns the frame of a tour anchor relative to the overlay.
    func frame(for key: String) -> CGRect? {
        guard let gf = globalFrames[key] else { return nil }
        return CGRect(
            x: gf.minX - overlayOrigin.x,
            y: gf.minY - overlayOrigin.y,
            width: gf.width,
            height: gf.height
        )
    }
}

extension View {
    /// Tags this view so the guided tour can spotlight it.
    func tourAnchor(_ key: String) -> some View {
        self.background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        TourAnchorStore.shared.globalFrames[key] = geo.frame(in: .global)
                    }
                    .onChange(of: geo.frame(in: .global).origin.x) { _, _ in
                        TourAnchorStore.shared.globalFrames[key] = geo.frame(in: .global)
                    }
                    .onChange(of: geo.frame(in: .global).origin.y) { _, _ in
                        TourAnchorStore.shared.globalFrames[key] = geo.frame(in: .global)
                    }
            }
        )
    }
}

// MARK: - Guided Tour

struct TourStep {
    let title: String
    let description: String
    let icon: String
    let sidebarTarget: BetterCastSenderApp.SidebarSelection?
    let anchorKey: String?  // key into TourAnchorKey dict to spotlight
}

struct GuidedTourOverlay: View {
    @Binding var selection: BetterCastSenderApp.SidebarSelection?
    @ObservedObject var anchorStore: TourAnchorStore = .shared
    let onDismiss: () -> Void
    @State private var currentStep = 0

    private let steps: [TourStep] = [
        TourStep(
            title: "Welcome to Screen Bridge",
            description: "Let's take a quick tour of the app. Screen Bridge turns any device into a wireless extended display for your Mac.",
            icon: "hand.wave.fill",
            sidebarTarget: nil,
            anchorKey: nil
        ),
        TourStep(
            title: "Overview",
            description: "This is your dashboard. See all connected displays with live previews, manage connections, and use \"Arrange...\" to position displays in System Settings.",
            icon: "rectangle.on.rectangle",
            sidebarTarget: .devices,
            anchorKey: "sidebar_overview"
        ),
        TourStep(
            title: "Device Settings",
            description: "Click any connected device in the sidebar to adjust resolution, bitrate, Retina mode, and audio streaming for that specific display.",
            icon: "gearshape",
            sidebarTarget: .devices,
            anchorKey: "sidebar_devices_section"
        ),
        TourStep(
            title: "Settings",
            description: "Configure pairing, display mode, quality, and private peer-to-peer networking.",
            icon: "gearshape.2",
            sidebarTarget: .settings,
            anchorKey: "sidebar_settings"
        ),
        TourStep(
            title: "Logs",
            description: "View detailed connection and streaming logs for troubleshooting. Useful if something isn't working right.",
            icon: "text.alignleft",
            sidebarTarget: .logs,
            anchorKey: "sidebar_logs"
        ),
        TourStep(
            title: "You're All Set!",
            description: "Run the paired iPad receiver, select it from the sidebar, and use it as your private extended display.",
            icon: "checkmark.circle.fill",
            sidebarTarget: .devices,
            anchorKey: nil
        ),
    ]

    var body: some View {
        let step = steps[currentStep]
        let spotlightRect = step.anchorKey.flatMap { anchorStore.frame(for: $0) }

        GeometryReader { geo in
            let size = geo.size

            ZStack {
                // Dimmed background with spotlight cutout
                SpotlightCutoutShape(spotlight: spotlightRect, cornerRadius: 8)
                    .fill(Color.black.opacity(0.6))
                    .onTapGesture { }

                // Highlight border around the spotlighted item
                if let rect = spotlightRect {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.accentColor, lineWidth: 2)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.accentColor.opacity(0.08))
                        )
                        .frame(width: rect.width + 12, height: rect.height + 6)
                        .position(x: rect.midX, y: rect.midY)
                }

                // Tour card — positioned near the spotlight or centered
                tourCard
                    .frame(maxWidth: 380)
                    .position(cardPosition(in: size, spotlight: spotlightRect))
            }
            .onAppear {
                anchorStore.overlayOrigin = CGPoint(
                    x: geo.frame(in: .global).minX,
                    y: geo.frame(in: .global).minY
                )
            }
        }
        .animation(.easeInOut(duration: 0.35), value: currentStep)
        .onChange(of: currentStep) { _, _ in
            if let target = steps[currentStep].sidebarTarget {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selection = target
                }
            }
        }
    }

    /// Positions the card to the right of the spotlight, or centered if no spotlight.
    private func cardPosition(in size: CGSize, spotlight: CGRect?) -> CGPoint {
        guard let spot = spotlight else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }

        let cardWidth: CGFloat = 380
        let cardHeight: CGFloat = 260
        let padding: CGFloat = 20

        // Try to place to the right of the spotlight
        let rightX = spot.maxX + padding + cardWidth / 2
        let leftX = spot.minX - padding - cardWidth / 2

        let x: CGFloat
        if rightX + cardWidth / 2 < size.width {
            x = rightX
        } else if leftX - cardWidth / 2 > 0 {
            x = leftX
        } else {
            x = size.width / 2
        }

        // Vertically align with spotlight center, clamped to window
        let y = min(max(spot.midY, cardHeight / 2 + 20), size.height - cardHeight / 2 - 20)

        return CGPoint(x: x, y: y)
    }

    private var tourCard: some View {
        let step = steps[currentStep]

        return VStack(spacing: 16) {
            Image(systemName: step.icon)
                .font(.system(size: 36))
                .foregroundColor(.accentColor)
                .padding(.top, 8)

            Text(step.title)
                .font(.system(size: 18, weight: .bold))

            Text(step.description)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Progress dots
            HStack(spacing: 6) {
                ForEach(0..<steps.count, id: \.self) { i in
                    Circle()
                        .fill(i == currentStep ? Color.accentColor : Color.gray.opacity(0.4))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.top, 4)

            // Navigation
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentStep -= 1
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }

                Spacer()

                Button("Skip Tour") {
                    onDismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.system(size: 12))

                Spacer()

                if currentStep < steps.count - 1 {
                    Button("Next") {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            currentStep += 1
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                } else {
                    Button("Done") {
                        onDismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(.green)
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        )
    }
}

/// Shape that fills the entire rect but cuts out a rounded-rect spotlight hole.
struct SpotlightCutoutShape: Shape {
    var spotlight: CGRect?
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        if let spot = spotlight {
            let cutout = Path(roundedRect: spot.insetBy(dx: -6, dy: -6), cornerRadius: cornerRadius)
            path = path.subtracting(cutout)
        }
        return path
    }
}

// MARK: - Onboarding View

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var currentStep = 0
    @State private var screenRecordingGranted = false

    /// Screen Recording is the only permission this app needs. There used to be a
    /// "Local Control" step here, left over from a version that required
    /// Accessibility: it was hardcoded as already granted, had no action, and the
    /// poll timer skipped past it after 1.5s.
    private let steps = ["Screen Recording", "Ready"]

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)

                Text("Welcome to Screen Bridge")
                    .font(.system(size: 26, weight: .bold))

                Text("Screen capture plus local Mac control")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 40)
            .padding(.bottom, 30)

            // Step indicators
            HStack(spacing: 24) {
                ForEach(0..<steps.count, id: \.self) { index in
                    StepIndicator(
                        number: index + 1,
                        title: steps[index],
                        isActive: currentStep == index,
                        isCompleted: stepCompleted(index)
                    )
                    if index < steps.count - 1 {
                        Rectangle()
                            .fill(stepCompleted(index) ? Color.green : Color(nsColor: .separatorColor))
                            .frame(height: 2)
                            .frame(maxWidth: 40)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)

            // Step content
            VStack(spacing: 20) {
                switch currentStep {
                case 0:
                    screenRecordingStep
                default:
                    readyStep
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)

            Spacer()

            // Navigation buttons
            HStack {
                if currentStep > 0 {
                    Button("Back") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            currentStep -= 1
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                Spacer()

                if currentStep < steps.count - 1 {
                    // Skipping isn't the recommended action, so it doesn't get
                    // prominent styling — only "Next" does.
                    if stepCompleted(currentStep) {
                        Button("Next") {
                            withAnimation(.easeInOut(duration: 0.2)) { currentStep += 1 }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Button("Skip for Now") {
                            withAnimation(.easeInOut(duration: 0.2)) { currentStep += 1 }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                } else {
                    Button("Get Started") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 30)
        }
        .onAppear {
            checkPermissions()
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                pollPermissions()
            }
        }
    }

    // MARK: - Step Views

    private var screenRecordingStep: some View {
        PermissionStepCard(
            icon: "record.circle",
            iconColor: .red,
            title: "Screen Recording",
            description: "Screen Bridge needs Screen Recording permission to capture your display and stream it to receivers.",
            isGranted: screenRecordingGranted,
            actionTitle: "Open Screen Recording Settings",
            action: {
                // Open one pane, not two. Both URLs used to be opened
                // unconditionally, so System Settings was launched twice and
                // could land on the wrong pane.
                let paneURLs = [
                    "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                ]
                for string in paneURLs {
                    if let url = URL(string: string), NSWorkspace.shared.open(url) {
                        break
                    }
                }
            }
        )
    }

    private var readyStep: some View {
        VStack(spacing: 16) {
            DashboardCard {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)

                    Text("You're all set!")
                        .font(.system(size: 20, weight: .semibold))

                    VStack(alignment: .leading, spacing: 8) {
                        permissionRow("Screen Recording", granted: screenRecordingGranted)
                        permissionRow("Local Mac control", granted: true)
                    }
                    .padding(.top, 4)

                    if !screenRecordingGranted {
                        Text("Screen Recording is still missing. You can grant it later in System Settings, but streaming cannot start until it's enabled.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
        }
    }

    private func permissionRow(_ name: String, granted: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(granted ? .green : .orange)
            Text(name)
                .font(.system(size: 14))
            Spacer()
            Text(granted ? "Granted" : "Not granted")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(granted ? .green : .orange)
        }
    }

    // MARK: - Helpers

    private func stepCompleted(_ step: Int) -> Bool {
        switch step {
        case 0: return screenRecordingGranted
        default: return true
        }
    }

    private func checkPermissions() {
        // Screen Recording: check via CGPreflightScreenCaptureAccess (macOS 10.15+)
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
    }

    private func pollPermissions() {
        checkPermissions()
        // Advance once the permission the user just went to grant comes back.
        if currentStep == 0 && screenRecordingGranted {
            withAnimation(.easeInOut(duration: 0.2)) {
                currentStep = 1
            }
        }
    }
}

// MARK: - Step Indicator

struct StepIndicator: View {
    let number: Int
    let title: String
    let isActive: Bool
    let isCompleted: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isCompleted ? Color.green : (isActive ? Color.accentColor : Color(nsColor: .separatorColor)))
                    .frame(width: 32, height: 32)
                if isCompleted {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(isActive ? .white : .secondary)
                }
            }
            Text(title)
                .font(.system(size: 11, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
        }
    }
}

// MARK: - Permission Step Card

struct PermissionStepCard: View {
    let icon: String
    let iconColor: Color
    let title: String
    let description: String
    let isGranted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        DashboardCard {
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(iconColor.opacity(0.12))
                            .frame(width: 48, height: 48)
                        Image(systemName: icon)
                            .font(.system(size: 22))
                            .foregroundStyle(iconColor)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(title)
                                .font(.system(size: 16, weight: .semibold))
                            if isGranted {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                        Text(description)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if isGranted {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Permission granted")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.green.opacity(0.08))
                    )
                } else {
                    Button(action: action) {
                        HStack {
                            Image(systemName: "gear")
                            Text(actionTitle)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Dashboard Card Container (fallback for pre-macOS 26)

struct DashboardCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.05), radius: 4, x: 0, y: 1)
            )
    }
}

extension DashboardCard {
    init(padded: Bool = true, @ViewBuilder content: () -> Content) {
        self.content = content()
    }
}

// MARK: - Sidebar (native List)

struct SidebarView: View {
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?

    var body: some View {
        List {
            // Devices first — the main dashboard
            Section("Devices") {
                sidebarRow("Overview", icon: "rectangle.on.rectangle", tag: .devices)
                    .tourAnchor("sidebar_overview")

                if client.foundServices.isEmpty && client.connectedServices.isEmpty {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Searching...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(client.foundServices.filter { service in
                        let serviceKey = canonicalDeviceName(service.name)
                        // Hide " P2P" entry when base device exists (merged into one entry)
                        let isP2PDuplicate = service.name.hasSuffix(" P2P")
                            && client.foundServices.contains(where: { canonicalDeviceName($0.name) == serviceKey && $0.name != service.name })
                        let duplicateDiscovered = client.foundServices.contains(where: {
                            canonicalDeviceName($0.name) == serviceKey && $0.name < service.name
                        })
                        return !isP2PDuplicate && !duplicateDiscovered
                    }, id: \.name) { service in
                        SidebarDeviceRow(service: service, client: client, selection: $selection)
                    }
                }

                ForEach(client.connectedDisplays.filter { display in
                    let displayKey = canonicalDeviceName(display.name)
                    let inFoundServices = client.foundServices.contains(where: { canonicalDeviceName($0.name) == displayKey })
                    // Hide " P2P" connected entry when base device is also connected
                    let isP2PConnected = display.name.hasSuffix(" P2P")
                        && client.connectedDisplays.contains(where: { canonicalDeviceName($0.name) == displayKey && $0.name != display.name })
                    let duplicateConnected = client.connectedDisplays.contains(where: {
                        canonicalDeviceName($0.name) == displayKey && $0.name < display.name
                    })
                    return !inFoundServices && !isP2PConnected && !duplicateConnected
                }) { display in
                    sidebarRow(display.name, subtitle: display.resolution, icon: "display", tag: .device(display.id), iconTint: .green)
                }
            }
            .tourAnchor("sidebar_devices_section")

            // Settings & Logs at the bottom
            Section {
                sidebarRow("Settings", icon: "gearshape", tag: .settings)
                    .tourAnchor("sidebar_settings")
                sidebarRow("Logs", icon: "text.alignleft", tag: .logs)
                    .tourAnchor("sidebar_logs")
            }
        }
        .navigationTitle("Screen Bridge")
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 6) {
                // Native-feeling connection state: dot or spinner + phase text.
                if client.connectionPhase.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 8, height: 8)
                } else {
                    Circle()
                        .fill(phaseColor)
                        .frame(width: 8, height: 8)
                }
                Text(client.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(client.status)
                Spacer()
                Button(role: .destructive) {
                    client.quitApp()
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Quit Screen Bridge")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)
        }
    }

    private var phaseColor: Color {
        switch client.connectionPhase {
        case .connected: return .green
        case .failed: return .red
        case .disconnected: return .secondary.opacity(0.5)
        case .discovering: return .blue
        default: return .orange
        }
    }

    // Apple Music-style sidebar row: tinted icon+text when selected, subtle matte bg
    @ViewBuilder
    private func sidebarRow(
        _ title: String,
        subtitle: String? = nil,
        icon: String,
        tag: BetterCastSenderApp.SidebarSelection,
        iconTint: Color? = nil
    ) -> some View {
        let isSelected = selection == tag
        let tint = iconTint ?? .accentColor

        Button {
            selection = tag
        } label: {
            Label {
                if let subtitle = subtitle {
                    VStack(alignment: .leading) {
                        Text(title)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(isSelected ? tint.opacity(0.7) : .secondary)
                    }
                } else {
                    Text(title)
                }
            } icon: {
                Image(systemName: icon)
                    .foregroundColor(isSelected ? tint : .secondary)
            }
            .foregroundColor(isSelected ? tint : .primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            isSelected
                ? RoundedRectangle(cornerRadius: 6)
                    .fill(tint.opacity(0.1))
                : nil
        )
    }
}

// MARK: - Sidebar Device Row

struct SidebarDeviceRow: View {
    let service: DiscoveredService
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?

    private var isConnected: Bool {
        let serviceKey = canonicalDeviceName(service.name)
        return client.connectedServices.contains(where: { canonicalDeviceName($0.name) == serviceKey })
    }

    private var connectedDisplayId: UUID? {
        let serviceKey = canonicalDeviceName(service.name)
        return client.connectedDisplays.first(where: { canonicalDeviceName($0.name) == serviceKey })?.id
    }

    private var deviceIcon: String {
        if isConnected { return "display" }
        return "display"
    }

    private var rowTag: BetterCastSenderApp.SidebarSelection {
        isConnected
            ? connectedDisplayId.map { .device($0) } ?? .discovered(service.name)
            : .discovered(service.name)
    }

    private var isSelected: Bool { selection == rowTag }

    var body: some View {
        Button {
            selection = rowTag
        } label: {
            HStack {
                Label {
                    VStack(alignment: .leading) {
                        Text(service.name)
                            .lineLimit(1)
                        Text(isConnected ? "Connected" : "Available")
                            .font(.caption)
                            .foregroundStyle(isConnected ? .green : .secondary)
                    }
                } icon: {
                    Image(systemName: deviceIcon)
                        .foregroundColor(isSelected ? .accentColor : (isConnected ? .green : .secondary))
                }
                .foregroundColor(isSelected ? .accentColor : .primary)
                Spacer()
                if !isConnected {
                    if client.isConnecting(to: service) {
                        ProgressView()
                            .controlSize(.mini)
                            .help("Connecting...")
                    } else {
                        Button {
                            client.connect(to: service)
                        } label: {
                            Image(systemName: "link")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(.accentColor)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                client.forgetDevice(named: service.name)
            } label: {
                Label("Remove Device", systemImage: "trash")
            }
        }
        .listRowBackground(
            isSelected
                ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.1))
                : nil
        )
    }
}

// MARK: - Detail Panel

struct DetailPanelView: View {
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?
    @State private var pairingCodeInput = ""
    @State private var pairingAlert: PairingAlert?
    @State private var isConfirmingClearPairing = false

    /// Feedback for a pairing-code save. Previously a failed save changed nothing
    /// on screen, so it was indistinguishable from success.
    private struct PairingAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        switch selection {
        case .device(let id):
            if let display = client.connectedDisplays.first(where: { $0.id == id }) {
                DeviceDetailView(display: display, client: client, selection: $selection)
            } else {
                settingsForm
            }
        case .discovered(let name):
            if let service = client.foundServices.first(where: { $0.name == name }) {
                DiscoveredDeviceView(service: service, client: client, selection: $selection)
            } else {
                settingsForm
            }
        case .logs:
            LogView()
                .navigationTitle("Logs")
        case .settings:
            settingsForm
        case .devices, nil:
            gettingStartedView
        }
    }

    // MARK: - Settings (native Form)

    /// Discovered services that are not yet connected
    private var availableDevices: [DiscoveredService] {
        client.foundServices.filter { service in
            let serviceKey = canonicalDeviceName(service.name)
            let isConnected = client.connectedServices.contains(where: { canonicalDeviceName($0.name) == serviceKey })
            let isDuplicate = client.foundServices.contains(where: {
                canonicalDeviceName($0.name) == serviceKey && $0.name < service.name
            })
            return !isConnected && !isDuplicate
        }
    }

    private var settingsForm: some View {
        Form {
            if !availableDevices.isEmpty {
                Section("Devices") {
                    ForEach(availableDevices) { service in
                        HStack {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(service.name)
                                        .lineLimit(1)
                                    Text("Available")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: deviceIcon(for: service))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(client.isConnecting(to: service) ? "Connecting..." : "Connect") {
                                client.connect(to: service)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(client.isConnecting(to: service))

                            Button(role: .destructive) {
                                client.forgetDevice(named: service.name)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Picker("Use as", selection: $client.useVirtualDisplay) {
                        Text("Extended Display").tag(true)
                        Text("Mirror Built-in").tag(false)
                    }
                    InfoTip(text: "Extended creates a separate display. Mirror streams your Mac's built-in display.")
                }

                HStack {
                    Picker("Resolution", selection: $client.selectedResolution) {
                        ForEach(VirtualDisplayManager.defaultResolutions, id: \.self) { res in
                            Text(res.name).tag(res)
                        }
                    }
                    .disabled(!client.useVirtualDisplay)
                    InfoTip(text: "Best Fit matches the iPad at 1344 × 934 HiDPI.")
                }

                HStack {
                    Picker("Position", selection: $client.displayPlacement) {
                        ForEach(VirtualDisplayManager.DisplayPlacement.allCases) { placement in
                            Text(placement.title).tag(placement)
                        }
                    }
                    .disabled(!client.useVirtualDisplay)
                    InfoTip(text: "Used the next time an extended display connects. Default: Right.")
                }

                HStack {
                    Toggle("Retina (HiDPI)", isOn: $client.isRetina)
                        .disabled(!client.useVirtualDisplay || client.selectedResolution == VirtualDisplayManager.receiverBestFitResolution)
                    InfoTip(text: "Uses HiDPI for sharper text. Best Fit already includes it.")
                }

                HStack {
                    Slider(value: $client.displayBrightness, in: 0...1, step: 0.05) {
                        Text("Brightness")
                    }
                    InfoTip(text: "Adjusts hardware brightness when the display supports it.")
                }

                HStack {
                    Toggle("Chrome Audio to iPad", isOn: $client.audioStreamingEnabled)
                    InfoTip(text: "Streams Chrome audio to the iPad and mutes it on this Mac.")
                }

                Button("Arrange Displays") {
                    client.openDisplaySettings()
                }
            } header: {
                Text("Display")
            }

            Section("Connection") {
                HStack {
                    LabeledContent("Pairing") {
                        Text(client.hasPairingSecret ? "Paired" : "Not Paired")
                            .foregroundStyle(client.hasPairingSecret ? .green : .orange)
                    }
                    InfoTip(text: "Use the same code on both devices. It stays local and is never logged.")
                }

                SecureField("Pairing code", text: $pairingCodeInput)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("Save Pairing Code") {
                        switch client.savePairingCode(pairingCodeInput) {
                        case .saved:
                            pairingCodeInput = ""
                            pairingAlert = PairingAlert(
                                title: "Pairing Code Saved",
                                message: "Enter the same code on your iPad to finish pairing."
                            )
                        case .tooWeak:
                            pairingAlert = PairingAlert(
                                title: "Pairing Code Too Weak",
                                message: "Use at least \(PairingAuthenticator.minimumSecretLength) letters or digits and don't repeat a single character. Spaces and dashes are ignored, so \"-\" alone is not a code."
                            )
                        case .storageFailed:
                            pairingAlert = PairingAlert(
                                title: "Couldn't Save Pairing Code",
                                message: "The keychain refused the write. Try again, and restart Screen Bridge if it keeps failing."
                            )
                        }
                    }
                    .disabled(pairingCodeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Generate") {
                        let code = PairingAuthenticator.generatePairingCode()
                        switch client.savePairingCode(code) {
                        case .saved:
                            pairingCodeInput = ""
                            // The field is a SecureField, so the code has to be
                            // shown here or it can never be typed on the iPad.
                            pairingAlert = PairingAlert(
                                title: "Pairing Code: \(code)",
                                message: "Saved on this Mac. Enter this code on your iPad to pair. It won't be shown again — generate a new one if you lose it."
                            )
                        case .tooWeak, .storageFailed:
                            pairingAlert = PairingAlert(
                                title: "Couldn't Save Pairing Code",
                                message: "The keychain refused the write. Try again, and restart Screen Bridge if it keeps failing."
                            )
                        }
                    }
                    .help("Create a strong random code and save it on this Mac")

                    Button("Clear Pairing…") {
                        isConfirmingClearPairing = true
                    }
                    .disabled(!client.hasPairingSecret)
                }

                HStack {
                    Toggle("Auto-Connect", isOn: $client.autoConnect)
                    InfoTip(text: "Connects automatically when the paired iPad appears.")
                }

                HStack {
                    Picker("Mode", selection: $client.interfacePreference) {
                        ForEach(NetworkInterfacePreference.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    InfoTip(text: "Auto chooses the route. A required route never falls back to another connection.")
                }

                HStack {
                    LabeledContent("Protocol") {
                        Text("Private TCP only")
                            .foregroundStyle(.secondary)
                    }
                    InfoTip(text: "Video and control use one private TCP stream. Chrome audio uses a second authenticated stream.")
                }

                HStack {
                    Picker("Quality", selection: $client.selectedQuality) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.name).tag(quality)
                        }
                    }
                    InfoTip(text: "Raises bitrate to reduce compression. Resolution still controls detail.")
                }

                if client.isConnected {
                    LabeledContent("Transfer Speed") {
                        Text(client.transferRate)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.green)
                    }
                }
            }

            Section {
                LabeledContent {
                    Button("Open Settings…") {
                        client.openPrivacySettings()
                    }
                } label: {
                    Label("Screen Recording", systemImage: "rectangle.dashed.badge.record")
                }

                LabeledContent {
                    Button("Open Settings…") {
                        client.openLocalNetworkSettings()
                    }
                } label: {
                    Label("Local Network", systemImage: "network")
                }

                if client.localNetworkNeedsAttention {
                    HStack {
                        Label("Device discovery is blocked.", systemImage: "network.slash")
                            .foregroundStyle(.orange)

                        Spacer()

                        Button("Retry Discovery") {
                            client.startBrowsing()
                        }
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Screen Recording captures the display. Local Network finds your iPad.")
            }

            if !client.connectedDisplays.isEmpty {
                Section("Connected Displays") {
                    ForEach(client.connectedDisplays) { display in
                        HStack {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(display.name)
                                    Text(display.resolution)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "display")
                                    .foregroundStyle(.green)
                            }
                            Spacer()
                            Button("Disconnect") {
                                client.disconnectConnection(display.id)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.red)

                            Button(role: .destructive) {
                                client.forgetDevice(named: display.name)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }
            if !client.hiddenDeviceKeys.isEmpty {
                Section("Hidden Devices") {
                    LabeledContent("Removed devices") {
                        Text("\(client.hiddenDeviceKeys.count)")
                            .foregroundStyle(.secondary)
                    }

                    Button("Show Hidden Devices") {
                        client.showHiddenDevices()
                    }
                }
            }
            Section("About") {
                LabeledContent("Release") {
                    Text("Screen Bridge \(AppVersion.current)")
                        .foregroundStyle(.secondary)
                }

                Label("Private, self-built release", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
            }

            Section("What's New") {
                ForEach(Changelog.entries) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(entry.version) · Initial Release")
                            .font(.headline)

                        ForEach(entry.highlights, id: \.self) { item in
                            Label(item, systemImage: "checkmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .alert(item: $pairingAlert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog(
            "Clear the pairing code?",
            isPresented: $isConfirmingClearPairing,
            titleVisibility: .visible
        ) {
            Button("Clear Pairing", role: .destructive) {
                client.clearPairingSecret()
                pairingCodeInput = ""
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any connected iPad is disconnected, and both devices will need the same code again.")
        }
    }

    private func deviceIcon(for service: DiscoveredService) -> String {
        let name = service.name.lowercased()
        if name.contains("ipad") || name.contains("ios") { return "ipad" }
        return "display"
    }

    // MARK: - Getting Started / Overview

    private var hasAnyDevices: Bool {
        !client.foundServices.isEmpty || !client.connectedDisplays.isEmpty
    }

    private var gettingStartedView: some View {
        VStack(spacing: 0) {
            if !client.connectedDisplays.isEmpty {
                // Display arrangement overview
                DisplayOverviewView(client: client, selection: $selection)
            } else if hasAnyDevices {
                // Devices are visible in sidebar — show a nudge
                VStack(spacing: 16) {
                    Image(systemName: "arrow.left")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("Select a device from the sidebar to connect")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // No devices found — onboarding empty state
                VStack(spacing: 32) {
                    Spacer()

                    VStack(spacing: 12) {
                        Image(systemName: "display.2")
                            .font(.system(size: 56, weight: .thin))
                            .foregroundStyle(.secondary)

                        Text("No Devices Found")
                            .font(.system(size: 24, weight: .bold))

                        Text("Run the paired private receiver app on your iPad.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 400)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        gettingStartedStep(
                            number: 1,
                            title: "Install the iPad Receiver",
                            subtitle: "Build and run the private receiver on your own iPad from this source tree."
                        )
                        gettingStartedStep(
                            number: 2,
                            title: "Use the Same Pairing Code",
                            subtitle: "Save the same local pairing code on the Mac and iPad."
                        )
                        gettingStartedStep(
                            number: 3,
                            title: "Open the Receiver App",
                            subtitle: "Your paired iPad appears automatically when Apple peer-to-peer networking is available."
                        )
                    }
                    .padding(.horizontal, 40)

                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Searching for paired iPad receivers...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("Devices")
    }

    private func gettingStartedStep(number: Int, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.accentColor))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Display Overview (arrangement view)

/// A display item in the arrangement view — either the built-in display or a Screen Bridge virtual display.
struct DisplayItem: Identifiable {
    let id: String
    let name: String
    let width: CGFloat   // pixels
    let height: CGFloat  // pixels
    let originX: CGFloat // CG coordinate origin
    let originY: CGFloat
    let isBuiltIn: Bool
    var connectionId: UUID? = nil
    var cgDisplayID: CGDirectDisplayID? = nil
}

/// Captures periodic screenshots for all active displays.
private struct DisplayThumbnailSnapshot: @unchecked Sendable {
    let images: [String: NSImage]
}

final class DisplayThumbnailProvider: ObservableObject, @unchecked Sendable {
    @Published var thumbnails: [String: NSImage] = [:] // keyed by DisplayItem.id
    private var timer: Timer?

    func start(displays: [DisplayItem]) {
        capture(displays: displays)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.capture(displays: displays)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func capture(displays: [DisplayItem]) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var newThumbs: [String: NSImage] = [:]

            for display in displays {
                let displayID: CGDirectDisplayID
                if display.isBuiltIn {
                    displayID = CGMainDisplayID()
                    // Try to find actual built-in display
                    var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: 16)
                    var displayCount: UInt32 = 0
                    CGGetOnlineDisplayList(16, &onlineDisplays, &displayCount)
                    let builtIn = onlineDisplays.prefix(Int(displayCount)).first { CGDisplayIsBuiltin($0) != 0 }
                    if let builtIn = builtIn {
                        if let cgImage = CGDisplayCreateImage(builtIn) {
                            newThumbs[display.id] = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                        }
                        continue
                    }
                } else if let did = display.cgDisplayID {
                    displayID = did
                } else {
                    continue
                }

                if let cgImage = CGDisplayCreateImage(displayID) {
                    newThumbs[display.id] = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                }
            }

            let snapshot = DisplayThumbnailSnapshot(images: newThumbs)
            DispatchQueue.main.async { [weak self] in
                self?.thumbnails = snapshot.images
            }
        }
    }
}

/// macOS System Settings–style display arrangement overview with drag and live previews.
struct DisplayOverviewView: View {
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?
    @State private var selectedDisplayId: String? = nil
    @StateObject private var thumbProvider = DisplayThumbnailProvider()

    private var displays: [DisplayItem] {
        var items: [DisplayItem] = []

        // Built-in display
        if let builtinScreen = NSScreen.builtin ?? NSScreen.main {
            let frame = builtinScreen.frame
            items.append(DisplayItem(
                id: "builtin",
                name: builtinScreen.localizedName,
                width: frame.width,
                height: frame.height,
                originX: frame.origin.x,
                originY: frame.origin.y,
                isBuiltIn: true
            ))
        }

        // Connected Screen Bridge displays
        for display in client.connectedDisplays {
            let b = display.displayBounds
            let w = b.width > 0 ? b.width : 1920
            let h = b.height > 0 ? b.height : 1080
            items.append(DisplayItem(
                id: display.id.uuidString,
                name: display.name,
                width: w,
                height: h,
                originX: b.origin.x,
                originY: b.origin.y,
                isBuiltIn: false,
                connectionId: display.id,
                cgDisplayID: display.cgDisplayID
            ))
        }

        return items
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Display arrangement area
                DashboardCard {
                    VStack(spacing: 12) {
                        HStack {
                            Text("Displays")
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Button {
                                openDisplaySettings()
                            } label: {
                                Label("Arrange...", systemImage: "rectangle.3.group")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }

                        displayArrangementView
                            .frame(height: 240)
                            .frame(maxWidth: .infinity)
                    }
                }

                // Selected display info
                if let selected = displays.first(where: { $0.id == selectedDisplayId }) {
                    selectedDisplayCard(selected)
                }

                // Connected devices list
                DashboardCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Connected Devices")
                            .font(.system(size: 14, weight: .semibold))

                        ForEach(client.connectedDisplays) { display in
                            HStack(spacing: 12) {
                                Image(systemName: deviceIcon(for: display.name))
                                    .font(.system(size: 20))
                                    .foregroundStyle(.green)
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(display.name)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(display.resolution)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Settings") {
                                    selection = .device(display.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)

                                Button("Disconnect") {
                                    client.disconnectConnection(display.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .tint(.red)
                            }
                            .padding(.vertical, 4)

                            if display.id != client.connectedDisplays.last?.id {
                                Divider()
                            }
                        }
                    }
                }

                // Discovered (not yet connected)
                if !client.foundServices.isEmpty {
                    let unconnected = client.foundServices.filter { svc in
                        !client.connectedDisplays.contains(where: { $0.name == svc.name })
                    }
                    if !unconnected.isEmpty {
                        DashboardCard {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Available Devices")
                                    .font(.system(size: 14, weight: .semibold))

                                ForEach(unconnected) { service in
                                    HStack(spacing: 12) {
                                        Image(systemName: "display")
                                            .font(.system(size: 20))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 28)

                                        Text(service.name)
                                            .font(.system(size: 13))

                                        Spacer()

                                        Button(client.isConnecting(to: service) ? "Connecting..." : "Connect") {
                                            client.connect(to: service)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .disabled(client.isConnecting(to: service))
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }
                    }
                }

                // Transfer speed
                if !client.connectedDisplays.isEmpty {
                    DashboardCard {
                        HStack {
                            Text("Transfer Speed")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(client.transferRate)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("Devices")
        .onAppear { thumbProvider.start(displays: displays) }
        .onDisappear { thumbProvider.stop() }
        .onChange(of: client.connectedDisplays.count) { _, _ in
            thumbProvider.start(displays: displays)
        }
    }

    // MARK: - Display Arrangement (draggable + live preview)

    private var displayArrangementView: some View {
        GeometryReader { geo in
            let allDisplays = displays
            let layout = computeLayout(displays: allDisplays, containerSize: geo.size)

            ZStack {
                ForEach(allDisplays) { display in
                    if let info = layout.positions[display.id] {
                        displayThumbnail(display: display, width: info.thumbW, height: info.thumbH)
                            .position(x: info.centerX, y: info.centerY)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    selectedDisplayId = display.id
                                }
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.5))
            )
        }
    }

    private func displayThumbnail(display: DisplayItem, width: CGFloat, height: CGFloat) -> some View {
        let isSelected = selectedDisplayId == display.id

        return VStack(spacing: 4) {
            ZStack {
                // Live preview or fallback
                if let thumb = thumbProvider.thumbnails[display.id] {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(display.isBuiltIn
                            ? Color(nsColor: .controlBackgroundColor)
                            : Color.accentColor.opacity(0.1))
                }

                // Border
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(
                        isSelected ? Color.accentColor : Color.gray.opacity(0.5),
                        lineWidth: isSelected ? 2.5 : 1
                    )
            }
            .frame(width: width, height: height)
            .shadow(color: isSelected ? Color.accentColor.opacity(0.3) : .clear, radius: 4)

            Text(displayLabel(display))
                .font(.system(size: 9))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: max(width, 60))
        }
    }

    private func displayLabel(_ display: DisplayItem) -> String {
        if display.isBuiltIn { return "Built-in Display" }
        let name = display.name
        if name.count > 20 { return String(name.prefix(18)) + "..." }
        return name
    }

    // MARK: - Layout Computation

    private struct LayoutInfo {
        var positions: [String: ThumbPosition] = [:]
        var scale: CGFloat = 1
    }

    private struct ThumbPosition {
        var centerX: CGFloat
        var centerY: CGFloat
        var thumbW: CGFloat
        var thumbH: CGFloat
    }

    /// Compute positions based on actual CG display origins, scaled to fit the container.
    private func computeLayout(displays: [DisplayItem], containerSize: CGSize) -> LayoutInfo {
        guard !displays.isEmpty else { return LayoutInfo() }

        // Find the bounding box of all displays in CG coordinates
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
        for d in displays {
            minX = min(minX, d.originX)
            minY = min(minY, d.originY)
            maxX = max(maxX, d.originX + d.width)
            maxY = max(maxY, d.originY + d.height)
        }
        let totalW = maxX - minX
        let totalH = maxY - minY

        // Scale to fit in container with padding
        let padW = containerSize.width * 0.85
        let padH = containerSize.height * 0.7
        let scale = min(padW / max(totalW, 1), padH / max(totalH, 1), 0.15)

        // Center offset
        let scaledTotalW = totalW * scale
        let scaledTotalH = totalH * scale
        let offsetX = (containerSize.width - scaledTotalW) / 2
        let offsetY = (containerSize.height - scaledTotalH) / 2 - 10

        var info = LayoutInfo(scale: scale)
        for d in displays {
            let thumbW = d.width * scale
            let thumbH = d.height * scale
            let x = (d.originX - minX) * scale + offsetX
            let y = (d.originY - minY) * scale + offsetY
            info.positions[d.id] = ThumbPosition(
                centerX: x + thumbW / 2,
                centerY: y + thumbH / 2,
                thumbW: thumbW,
                thumbH: thumbH
            )
        }
        return info
    }

    private func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Selected Display Card

    private func selectedDisplayCard(_ display: DisplayItem) -> some View {
        DashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: display.isBuiltIn ? "laptopcomputer" : "display")
                        .font(.system(size: 18))
                        .foregroundColor(display.isBuiltIn ? .secondary : .green)
                    Text(display.isBuiltIn ? "Built-in Display" : display.name)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                }

                HStack(spacing: 20) {
                    LabeledContent("Resolution") {
                        Text("\(Int(display.width)) x \(Int(display.height))")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Position") {
                        Text("(\(Int(display.originX)), \(Int(display.originY)))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 13))

                if !display.isBuiltIn, let connId = display.connectionId {
                    HStack {
                        Button("View Settings") {
                            selection = .device(connId)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func deviceIcon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("ipad") || lower.contains("ios") { return "ipad" }
        return "display"
    }
}

// Helper to find the built-in screen
private extension NSScreen {
    static var builtin: NSScreen? {
        NSScreen.screens.first { screen in
            // Built-in displays have a specific device description key
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                return CGDisplayIsBuiltin(screenNumber) != 0
            }
            return false
        }
    }
}

// MARK: - Unified Device View (connected + discovered)

struct DeviceDetailView: View {
    let display: ConnectedDisplayInfo
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?

    var body: some View {
        Form {
            Section("Resolution") {
                HStack {
                    Picker("Dimensions", selection: $client.selectedResolution) {
                        ForEach(VirtualDisplayManager.defaultResolutions, id: \.self) { res in
                            Text(res.name).tag(res)
                        }
                    }
                    InfoTip(text: "Best Fit matches the iPad with HiDPI and native capture.")
                }

                HStack {
                    Toggle("Retina (HiDPI)", isOn: $client.isRetina)
                        .disabled(client.selectedResolution == VirtualDisplayManager.receiverBestFitResolution)
                    InfoTip(text: "Uses HiDPI for sharper text. Best Fit already includes it.")
                }
            }

            Section("Quality") {
                HStack {
                    Picker("Bitrate", selection: $client.selectedQuality) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.name).tag(quality)
                        }
                    }
                    InfoTip(text: "Higher bitrate reduces compression. Native Max needs a strong direct connection.")
                }

                HStack {
                    Toggle("Chrome Audio to iPad", isOn: Binding(
                        get: { display.audioEnabled },
                        set: { client.setAudioEnabled($0, for: display.id) }
                    ))
                    InfoTip(text: "Streams Chrome audio to this iPad and mutes it on this Mac.")
                }

                if display.audioEnabled {
                    LabeledContent("Audio Status") {
                        Label(display.audioState.label, systemImage: display.audioState.symbolName)
                            .foregroundStyle(display.audioState.tint)
                    }
                }

            }

            Section("Status") {
                LabeledContent("Current") {
                    Text(display.resolution)
                }

                if display.displayBounds != .zero {
                    LabeledContent("Position") {
                        Text("(\(Int(display.displayBounds.origin.x)), \(Int(display.displayBounds.origin.y)))")
                    }
                }

                LabeledContent("Requested Route") {
                    Text(display.requestedRoute)
                }

                LabeledContent("System Path") {
                    Text(display.systemPath)
                        .font(.system(.body, design: .monospaced))
                }

                LabeledContent("Route Evidence") {
                    Label(
                        display.routeEvidence,
                        systemImage: display.hasVerifiedRouteEvidence ? "checkmark.seal.fill" : "questionmark.circle"
                    )
                    .foregroundStyle(display.hasVerifiedRouteEvidence ? .green : .secondary)
                }

                LabeledContent("Transfer Speed") {
                    Text(client.transferRate)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.green)
                }
            }

            Section {
                HStack(spacing: 10) {
                    Button("Apply Settings") {
                        client.updateStreamResolution()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Disconnect") {
                        client.disconnectConnection(display.id)
                        selection = .settings
                    }
                    .tint(.red)

                    Button(role: .destructive) {
                        client.forgetDevice(named: display.name)
                        selection = .settings
                    } label: {
                        Label("Remove Device", systemImage: "trash")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(display.name)
    }
}

struct DiscoveredDeviceView: View {
    let service: DiscoveredService
    @ObservedObject var client: NetworkClient
    @Binding var selection: BetterCastSenderApp.SidebarSelection?

    private var connectedDisplay: ConnectedDisplayInfo? {
        let serviceKey = canonicalDeviceName(service.name)
        return client.connectedDisplays.first(where: { canonicalDeviceName($0.name) == serviceKey })
    }

    var body: some View {
        if let display = connectedDisplay {
            // Connected — show per-device settings
            DeviceDetailView(display: display, client: client, selection: $selection)
        } else {
            // Not connected — show connect options
            connectForm
        }
    }

    private var connectForm: some View {
        Form {
            Section("Connect") {
                HStack {
                    Image(systemName: "network")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text("Connect")
                            .fontWeight(.medium)
                        Text("Use the selected network mode")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(client.isConnecting(to: service) ? "Connecting..." : "Connect") {
                        client.connect(to: service)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(client.isConnecting(to: service))
                    InfoTip(text: "Auto chooses the route. A required route never falls back to another connection.")
                }
            }

            Section("Resolution") {
                HStack {
                    Picker("Dimensions", selection: $client.selectedResolution) {
                        ForEach(VirtualDisplayManager.defaultResolutions, id: \.self) { res in
                            Text(res.name).tag(res)
                        }
                    }
                    InfoTip(text: "Best Fit matches the iPad at a sharp HiDPI resolution.")
                }

                HStack {
                    Toggle("Retina (HiDPI)", isOn: $client.isRetina)
                        .disabled(client.selectedResolution == VirtualDisplayManager.receiverBestFitResolution)
                    InfoTip(text: "Uses HiDPI for sharper text. Best Fit already includes it.")
                }
            }

            Section("Quality") {
                HStack {
                    Picker("Bitrate", selection: $client.selectedQuality) {
                        ForEach(StreamQuality.allCases) { quality in
                            Text(quality.name).tag(quality)
                        }
                    }
                    InfoTip(text: "Raises bitrate to reduce compression. Resolution still controls detail.")
                }

                HStack {
                    Toggle("Chrome Audio to iPad", isOn: $client.audioStreamingEnabled)
                    InfoTip(text: "Streams Chrome audio to the iPad and mutes it on this Mac.")
                }

            }
        }
        .formStyle(.grouped)
        .navigationTitle(service.name)
    }
}

// MARK: - Display Brightness Control

enum DisplayBrightnessControl {
    static func setBrightness(_ brightness: Double) {
        let value = max(0, min(1, brightness))
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator)
        guard result == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            IODisplaySetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, Float(value))
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    static func getBrightness() -> Double {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator)
        guard result == kIOReturnSuccess else { return 0.5 }
        defer { IOObjectRelease(iterator) }

        var brightness: Float = 0.5
        let service = IOIteratorNext(iterator)
        if service != 0 {
            IODisplayGetFloatParameter(service, 0, kIODisplayBrightnessKey as CFString, &brightness)
            IOObjectRelease(service)
        }
        return Double(brightness)
    }
}

// MARK: - Info Tip

struct InfoTip: View {
    let text: String
    @State private var isShowing = false

    var body: some View {
        Button {
            isShowing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(text)
        .accessibilityLabel("More information")
        .popover(isPresented: $isShowing, arrowEdge: .top) {
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 260, alignment: .leading)
                .padding(12)
        }
    }
}

// MARK: - Settings Row

// MARK: - Connected Display Info

enum AudioStreamingState: String, Equatable {
    case off
    case waitingForChrome
    case connecting
    case streaming
    case retrying
    case failed

    var label: String {
        switch self {
        case .off: return "Off"
        case .waitingForChrome: return "Waiting for Chrome"
        case .connecting: return "Connecting"
        case .streaming: return "Streaming"
        case .retrying: return "Reconnecting"
        case .failed: return "Needs Attention"
        }
    }

    var symbolName: String {
        switch self {
        case .off: return "speaker.slash"
        case .waitingForChrome: return "hourglass"
        case .connecting, .retrying: return "arrow.triangle.2.circlepath"
        case .streaming: return "speaker.wave.2.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .streaming: return .green
        case .failed: return .red
        case .waitingForChrome, .connecting, .retrying: return .orange
        case .off: return .secondary
        }
    }
}

struct ConnectedDisplayInfo: Identifiable {
    let id: UUID
    let name: String
    let resolution: String
    let displayBounds: CGRect
    var audioEnabled: Bool
    var audioState: AudioStreamingState
    var cgDisplayID: CGDirectDisplayID? = nil
    /// The route requested when this connection was created.
    var requestedRoute: String = NetworkInterfacePreference.auto.label
    /// Network.framework's path-type report. Wi-Fi and AWDL share the `.wifi`
    /// type, so this deliberately does not pretend to identify the radio.
    var systemPath: String = "Unknown"
    /// Concrete discovery/connection evidence, when a strict mode required a
    /// specific Bonjour interface.
    var routeEvidence: String = "System selected; no physical-interface proof"
    var hasVerifiedRouteEvidence = false
}

struct DiscoveredService: Identifiable {
    let id = UUID()
    let name: String
    let endpoint: NWEndpoint
    /// Interfaces on which NWBrowser observed this exact Bonjour result.
    /// Source: NWBrowser.Result.interfaces in Network.framework.
    let interfaces: [NWInterface]

    init(name: String, endpoint: NWEndpoint, interfaces: [NWInterface] = []) {
        self.name = name
        self.endpoint = endpoint
        self.interfaces = interfaces
    }

    var interfaceSummary: String {
        guard !interfaces.isEmpty else { return "No interface evidence" }
        return interfaces.map { "\($0.name)[\($0.type)]" }.joined(separator: ", ")
    }

    func requiredInterface(for preference: NetworkInterfacePreference) -> NWInterface? {
        switch preference {
        case .auto:
            return nil
        case .requireCable:
            return interfaces.first(where: Self.isWiredInterface)
        case .awdl:
            return interfaces.first(where: Self.isAWDLInterface)
        case .wifi:
            return interfaces.first(where: Self.isInfrastructureWiFiInterface)
        }
    }

    func isVisible(in preference: NetworkInterfacePreference) -> Bool {
        preference == .auto || requiredInterface(for: preference) != nil
    }

    private static func isAWDLInterface(_ interface: NWInterface) -> Bool {
        interface.name.hasPrefix("awdl") || interface.name.hasPrefix("llw")
    }

    private static func isInfrastructureWiFiInterface(_ interface: NWInterface) -> Bool {
        interface.type == .wifi && !isAWDLInterface(interface)
    }

    private static func isWiredInterface(_ interface: NWInterface) -> Bool {
        if interface.type == .wiredEthernet { return true }
        guard interface.type == .other else { return false }
        return interface.name.hasPrefix("en") || interface.name.hasPrefix("bridge")
    }
}

private func canonicalDeviceName(_ name: String) -> String {
    var result = name.trimmingCharacters(in: .whitespacesAndNewlines)

    if result.hasSuffix(" P2P") {
        result = String(result.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    while result.hasSuffix(")") {
        guard let openParen = result.range(of: " (", options: .backwards),
              result[openParen.upperBound...].dropLast().allSatisfy(\.isNumber) else {
            break
        }
        result = String(result[..<openParen.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    return result
}

enum StreamQuality: Int, CaseIterable, Identifiable {
    case low = 5_000_000
    case medium = 10_000_000
    case high = 20_000_000
    case ultra = 50_000_000
    case extreme = 100_000_000
    case nativeMax = 150_000_000
    
    var id: Int { self.rawValue }
    var name: String {
        switch self {
        case .low: return "Low (5 Mbps)"
        case .medium: return "Medium (10 Mbps)"
        case .high: return "High (20 Mbps)"
        case .ultra: return "Ultra (50 Mbps)"
        case .extreme: return "Extreme (100 Mbps)"
        case .nativeMax: return "Native Max (150 Mbps)"
        }
    }
}

enum NetworkInterfacePreference: String, CaseIterable, Identifiable {
    case auto
    case requireCable
    case awdl
    case wifi

    var id: String { self.rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .requireCable: return "Require Cable"
        case .awdl: return "AWDL"
        case .wifi: return "Wi-Fi"
        }
    }

    static func restored(from storedValue: String) -> Self? {
        if let current = Self(rawValue: storedValue) { return current }
        switch storedValue {
        case "Auto (Apple Default)": return .auto
        case "USB / Thunderbolt Cable": return .requireCable
        case "Force P2P (WiFi Direct)": return .awdl
        case "Force Router/WiFi": return .wifi
        default: return nil
        }
    }
}

/// The route we explicitly asked Network.framework to establish. NWPath's
/// `availableInterfaces` is a capability list, not a reliable selected-interface
/// signal, so link policy must be derived from this intent plus `usesInterfaceType`.
private enum ConnectionRouteIntent: Equatable {
    case automatic
    case peerToPeer
    case infrastructure
    case wired
}

private struct ConnectionRouteClassification {
    let isP2P: Bool
    let isWiredCable: Bool

    var description: String {
        if isP2P { return "P2P Direct Link (AWDL)" }
        if isWiredCable { return "Wired/cable link" }
        return "Router/infrastructure link"
    }
}

private struct ReceiverDisplaySize {
    let reportedWidth: Int
    let reportedHeight: Int
    let logicalWidth: Int
    let logicalHeight: Int
    let backingWidth: Int
    let backingHeight: Int
    let captureWidth: Int
    let captureHeight: Int
}

// Per-connection pipeline: each device gets its own virtual display, screen capture, and encoder
struct ConnectionPipeline {
    let id: UUID
    let connection: NWConnection
    let streamEndpoint: NWEndpoint
    let service: DiscoveredService
    let receiverSessionID: UUID
    var lastHeartbeat: Date
    var sessionKey: Data

    // Per-connection components (isolated pipeline)
    var audioConnection: NWConnection?
    var audioSessionKey: Data?
    var virtualDisplayManager: VirtualDisplayManager?
    var screenRecorder: ScreenRecorder?
    var videoEncoder: VideoEncoder?
    var audioEncoder: AudioEncoder?
    var processAudioCapture: ProcessAudioTapCapture?
    var audioPacketSender: AudioPacketSender?
    /// Invalidates delayed display/capture callbacks from an older pipeline
    /// incarnation after a resolution or orientation rebuild.
    var lifecycleGeneration: UInt64 = 0

    // Adaptive: P2P (AWDL) connections get full quality; infrastructure gets throttled
    var isP2P: Bool = false
    // USB-C / Thunderbolt / Ethernet-style direct links — higher bandwidth than router Wi-Fi
    var isWiredCable: Bool = false
    var requestedPreference: NetworkInterfacePreference = .auto
    var requiredRouteInterface: NWInterface?
    // TCP backpressure is bounded per route and retains at most one recovery
    // keyframe; see VideoFlightWindowPolicy.
    var requestedRoute: String = NetworkInterfacePreference.auto.label
    var systemPath: String = "Unknown"
    var routeEvidence: String = "System selected; no physical-interface proof"
    var hasVerifiedRouteEvidence = false

    /// Frames handed to the transport but not yet reported complete.
    /// Counted rather than flagged so reliable links can keep several frames in
    /// flight instead of one per round trip.
    var framesInFlight: Int = 0
    var pendingKeyframePacket: Data?
    var mediaHeartbeatInProgress: Bool = false
    var currentAdaptiveBitrate: Int = 0
    var targetAdaptiveBitrate: Int = 0
    var sendLatencyEWMA: TimeInterval = 0
    var sentFramesSinceAdjustment: Int = 0
    var droppedFramesSinceAdjustment: Int = 0
    var lastBitrateAdjustment: Date = Date()
    /// When the current capture pipeline started streaming, used to ignore
    /// start-up burst congestion when adapting the bitrate.
    var streamingStartedAt: Date = Date()
    // iOS/Mac Swift receivers don't strip the type byte — send raw payloads for them
    var supportsTypeByte: Bool = true
    // Receiver-reported screen dimensions (pixels) — used to match aspect ratio
    var reportedScreenWidth: Int? = nil
    var reportedScreenHeight: Int? = nil
    var lastInputSequence: UInt64 = 0
    // Background grace: set when the receiver announces it is backgrounding
    // (command 555). While set, the sender pauses video/audio sends, keeps the
    // virtual display and connection alive, and replaces the 15s heartbeat
    // timeout with a longer grace deadline. Cleared by any authenticated
    // message from the receiver.
    var backgroundGraceStart: Date? = nil
    // Settings actually applied to this pipeline. Requested UI values may be
    // newer until the user presses Apply.
    var appliedUseVirtualDisplay: Bool = true
    var appliedResolutionName: String = ""
    var appliedRetina: Bool = false
    var appliedQuality: StreamQuality = .high
    var appliedAudioEnabled: Bool = false
    var audioState: AudioStreamingState = .off
}

private enum PairingTransportError: LocalizedError {
    case missingSecret
    case emptyFrame
    case invalidFrameLength(Int)
    case missingFrameBody
    case decodeFailed
    case unsupportedProtocol
    case invalidProof
    case invalidSession
    case sendFailed(Error?)
    case handshakeTimedOut

    var errorDescription: String? {
        switch self {
        case .missingSecret:
            return "Pairing code is not configured"
        case .emptyFrame:
            return "Received empty pairing frame"
        case .invalidFrameLength(let length):
            return "Invalid pairing frame length: \(length)"
        case .missingFrameBody:
            return "Pairing frame body was missing"
        case .decodeFailed:
            return "Unable to decode pairing message"
        case .unsupportedProtocol:
            return "Receiver uses an unsupported private protocol version"
        case .invalidProof:
            return "Pairing proof did not match"
        case .invalidSession:
            return "Auxiliary connection did not join the active receiver session"
        case .sendFailed(let error):
            return error?.localizedDescription ?? "Pairing send failed"
        case .handshakeTimedOut:
            return "Receiver did not finish pairing in time"
        }
    }
}

private struct AuthenticatedPairing: Sendable {
    let sessionKey: Data
    let receiverSessionID: UUID
    let receiverCapabilities: ReceiverCapabilities?
}

/// Ensures a completion handler runs exactly once.
///
/// Handshake completions can be reached from the Network queue and from a
/// timeout scheduled on main. Without this, a late reply after a timeout would
/// deliver a second result for the same attempt.
private final class SingleCompletionGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Mutable attempt state is touched only by callbacks delivered on the main
/// queue. A reference box avoids capturing a mutable local across Sendable
/// callback boundaries while preserving that single-queue ownership.
private final class ConnectionAttemptState: @unchecked Sendable {
    var isSettled = false
}

/// Single source of truth for the sender's connection lifecycle.
/// `status` (free text) is derived alongside it for display.
enum ConnectionPhase: String, Equatable {
    case disconnected = "Disconnected"
    case discovering = "Discovering"
    case connecting = "Connecting"
    case authenticating = "Authenticating"
    case connected = "Connected"
    case reconnecting = "Reconnecting"
    case failed = "Failed"

    var tintIsActive: Bool { self == .connected }
    var isBusy: Bool {
        self == .connecting || self == .authenticating || self == .reconnecting
    }
}

final class NetworkClient: ObservableObject, VideoEncoderDelegate, ScreenRecorderDelegate, @unchecked Sendable {
    private static let displayPlacementDefaultsKey = "displayPlacement"
    private static let hiddenDeviceKeysDefaultsKey = "hiddenDeviceKeys"

    private var browser: NWBrowser?
    private var pipelines: [UUID: ConnectionPipeline] = [:]
    /// Transports that are dialing or authenticating but do not yet own a
    /// pipeline. Keeping them explicit makes pairing reset a true revocation
    /// barrier, including late handshake completions.
    private var pendingConnections: [UUID: NWConnection] = [:]
    private let pairingSecretStore: PairingSecretStoring = KeychainPairingSecretStore()

    @Published var status: String = "Idle"
    @Published private(set) var connectionPhase: ConnectionPhase = .disconnected
    @Published private(set) var hasPairingSecret: Bool = false
    @Published private(set) var localNetworkNeedsAttention: Bool = false
    @Published var foundServices: [DiscoveredService] = []
    @Published var connectedServices: [DiscoveredService] = []
    @Published var hiddenDeviceKeys: Set<String> = []
    @Published private(set) var connectingServiceNames: Set<String> = [] // Prevent double-connect race; drives per-row spinners

    /// Set phase and status text together so UI state can never drift from the text.
    func setPhase(_ phase: ConnectionPhase, _ text: String) {
        connectionPhase = phase
        status = text
    }

    /// True while a dial/handshake to this service is in flight (for button state).
    func isConnecting(to service: DiscoveredService) -> Bool {
        connectingServiceNames.contains(deviceKey(for: service.name))
    }
    @Published var useVirtualDisplay: Bool = true { // Toggle between mirroring and extended display
        didSet { UserDefaults.standard.set(useVirtualDisplay, forKey: Self.useVirtualDisplayKey) }
    }
    @Published var audioStreamingEnabled: Bool = false { // Master toggle for audio streaming
        didSet {
            UserDefaults.standard.set(audioStreamingEnabled, forKey: Self.audioStreamingEnabledKey)
            if oldValue != audioStreamingEnabled && isConnected {
                for index in connectedDisplays.indices {
                    connectedDisplays[index].audioEnabled = audioStreamingEnabled
                }
                for connectionID in Array(pipelines.keys) {
                    reconcileAudioPipeline(for: connectionID)
                }
            }
        }
    }
    @Published var displayBrightness: Float = Float(DisplayBrightnessControl.getBrightness()) {
        didSet { DisplayBrightnessControl.setBrightness(Double(displayBrightness)) }
    }
    @Published var connectedDisplays: [ConnectedDisplayInfo] = [] // Per-device display info


    // Transfer Stats
    @Published var transferRate: String = "0 Mbps"
    private var bytesSentWindow: Int = 0
    private var lastStatsTime: Date = Date()
    
    // Settings
    @Published var selectedResolution: VirtualDisplayManager.Resolution = VirtualDisplayManager.receiverBestFitResolution {
        didSet { UserDefaults.standard.set(selectedResolution.name, forKey: Self.selectedResolutionKey) }
    }
    @Published var isRetina: Bool = false {
        didSet { UserDefaults.standard.set(isRetina, forKey: Self.isRetinaKey) }
    }
    @Published var displayPlacement: VirtualDisplayManager.DisplayPlacement = .right {
        didSet {
            UserDefaults.standard.set(displayPlacement.rawValue, forKey: Self.displayPlacementDefaultsKey)
        }
    }
    /// The private build streams over TCP only. This was a user-settable
    /// "TCP or UDP" switch whose setter silently rewrote every other value back
    /// to TCP, so the UDP send path it guarded could never run — that path has
    /// been removed along with it.
    
    @Published var selectedQuality: StreamQuality = .high {
        didSet { UserDefaults.standard.set(selectedQuality.rawValue, forKey: Self.selectedQualityKey) }
    }

    // Private build uses Apple peer-to-peer/AWDL first.
    @Published var interfacePreference: NetworkInterfacePreference = .auto {
        didSet {
            guard oldValue != interfacePreference else { return }
            UserDefaults.standard.set(interfacePreference.rawValue, forKey: Self.interfacePreferenceKey)
            guard hasFinishedInitialization else { return }
            restartBrowsingForRouteChange()
        }
    }
    private var hasFinishedInitialization = false

    // Auto-connect: automatically connect to discovered receivers
    @Published var autoConnect: Bool = false {
        didSet { UserDefaults.standard.set(autoConnect, forKey: Self.autoConnectKey) }
    }

    // MARK: - Persisted settings
    //
    // These all used to be plain @Published values, so every one of them silently
    // reverted to its default on the next launch.
    private static let useVirtualDisplayKey = "settings.useVirtualDisplay"
    private static let audioStreamingEnabledKey = "settings.audioStreamingEnabled"
    private static let selectedResolutionKey = "settings.selectedResolutionName"
    private static let isRetinaKey = "settings.isRetina"
    private static let selectedQualityKey = "settings.selectedQuality"
    private static let interfacePreferenceKey = "settings.interfacePreference"
    private static let autoConnectKey = "settings.autoConnect"

    /// Restores saved settings, falling back to the default when a stored value
    /// no longer maps to anything valid (for example a resolution preset that was
    /// renamed or removed in a later build).
    private func restorePersistedSettings() {
        let defaults = UserDefaults.standard

        if defaults.object(forKey: Self.useVirtualDisplayKey) != nil {
            useVirtualDisplay = defaults.bool(forKey: Self.useVirtualDisplayKey)
        }
        if defaults.object(forKey: Self.audioStreamingEnabledKey) != nil {
            audioStreamingEnabled = defaults.bool(forKey: Self.audioStreamingEnabledKey)
        }
        if defaults.object(forKey: Self.isRetinaKey) != nil {
            isRetina = defaults.bool(forKey: Self.isRetinaKey)
        }
        if defaults.object(forKey: Self.autoConnectKey) != nil {
            autoConnect = defaults.bool(forKey: Self.autoConnectKey)
        }
        if let name = defaults.string(forKey: Self.selectedResolutionKey),
           let match = VirtualDisplayManager.defaultResolutions.first(where: { $0.name == name }) {
            selectedResolution = match
        }
        if defaults.object(forKey: Self.selectedQualityKey) != nil,
           let quality = StreamQuality(rawValue: defaults.integer(forKey: Self.selectedQualityKey)) {
            selectedQuality = quality
        }
        if let raw = defaults.string(forKey: Self.interfacePreferenceKey),
           let preference = NetworkInterfacePreference.restored(from: raw) {
            interfacePreference = preference
        }
    }

    var isConnected: Bool { !pipelines.isEmpty }

    private func deviceKey(for name: String) -> String {
        canonicalDeviceName(name)
    }

    private func saveHiddenDeviceKeys() {
        UserDefaults.standard.set(Array(hiddenDeviceKeys), forKey: Self.hiddenDeviceKeysDefaultsKey)
    }

    private func removeExistingConnections(matching service: DiscoveredService, keeping connectionId: UUID? = nil) {
        let key = deviceKey(for: service.name)
        let duplicateIds = pipelines.compactMap { id, pipeline -> UUID? in
            guard id != connectionId, deviceKey(for: pipeline.service.name) == key else { return nil }
            return id
        }

        for id in duplicateIds {
            LogManager.shared.log("Sender: Removing duplicate connection for \(service.name)")
            removeConnection(id)
        }

        connectedServices.removeAll { deviceKey(for: $0.name) == key && $0.name != service.name }
    }

    func forgetDevice(named name: String) {
        let key = deviceKey(for: name)
        reconnectAttempts.removeValue(forKey: key)
        let matchingIds = pipelines.compactMap { id, pipeline in
            deviceKey(for: pipeline.service.name) == key ? id : nil
        }

        for id in matchingIds {
            removeConnection(id)
        }

        foundServices.removeAll { deviceKey(for: $0.name) == key }
        connectedServices.removeAll { deviceKey(for: $0.name) == key }
        connectingServiceNames.remove(key)
        hiddenDeviceKeys.insert(key)
        saveHiddenDeviceKeys()
        LogManager.shared.log("Sender: Forgot device \(name)")
    }

    func showHiddenDevices() {
        hiddenDeviceKeys.removeAll()
        saveHiddenDeviceKeys()
        startBrowsing()
        LogManager.shared.log("Sender: Cleared hidden devices")
    }

    private func restartBrowsingForRouteChange() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.restartBrowsingForRouteChange()
            }
            return
        }

        LogManager.shared.log("Sender: Route changed to \(interfacePreference.label) — cancelling old discovery and pending dials")
        browserRetryWork?.cancel()
        browserRetryWork = nil
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        foundServices.removeAll()

        for connection in pendingConnections.values {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        pendingConnections.removeAll()
        connectingServiceNames.removeAll()
        startBrowsing()
    }


    private var browserGeneration = UUID()
    private var browserRetryWork: DispatchWorkItem?
    private var browserRetryAttempt = 0
    private let maxBrowserRetryAttempts = 5

    func startBrowsing(resetRetryBudget: Bool = true) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.startBrowsing(resetRetryBudget: resetRetryBudget)
            }
            return
        }

        browserRetryWork?.cancel()
        browserRetryWork = nil
        if resetRetryBudget {
            browserRetryAttempt = 0
        }

        // A new browse generation atomically retires all callbacks from the old
        // browser. Repeated settings changes or path notifications must never
        // leave multiple Bonjour browsers publishing competing result sets.
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        let generation = UUID()
        browserGeneration = generation

        let typeVal = BCConstants.tcpServiceType
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        
        configureParameters(parameters) // Apply user pref
        
        // Scan for the appropriate service type
        LogManager.shared.log("Sender: Browsing for \(typeVal)...")
        
        let browser = NWBrowser(for: .bonjour(type: typeVal, domain: nil), using: parameters)
        self.browser = browser
        
        browser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.browserGeneration == generation,
                      self.browser === browser else { return }
                switch state {
                case .ready:
                    self.browserRetryAttempt = 0
                    self.localNetworkNeedsAttention = false
                    // A denied Local Network permission does NOT fail the
                    // browser. It stays `.ready` and simply never reports a
                    // result, which is indistinguishable from "no receiver is
                    // running" unless we watch for the silence ourselves.
                    self.scheduleDiscoverySilenceCheck(generation: generation)
                    // Only surface "discovering" when idle — browsing continues
                    // in the background while connected.
                    if self.pipelines.isEmpty && self.connectingServiceNames.isEmpty {
                        self.setPhase(.discovering, "Looking for devices...")
                    }
                case .failed(let error):
                    if self.pipelines.isEmpty {
                        self.setPhase(.discovering, "Local Network unavailable — retrying discovery...")
                    }
                    self.scheduleBrowserRetry(after: error, generation: generation)
                default:
                    break
                }
            }
        }
        
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard self.browserGeneration == generation,
                      self.browser === browser else { return }
                // Build list from mDNS browse results
                let discovered = results.compactMap { result -> DiscoveredService? in
                    if case .service(let name, _, _, _) = result.endpoint {
                        return DiscoveredService(
                            name: name,
                            endpoint: result.endpoint,
                            interfaces: result.interfaces
                        )
                    }
                    return nil
                }
                var services = discovered.filter { $0.isVisible(in: self.interfacePreference) }
                services.removeAll { self.hiddenDeviceKeys.contains(self.deviceKey(for: $0.name)) }
                self.foundServices = services

                for service in discovered {
                    LogManager.shared.log(
                        "Sender: Bonjour found \(service.name) via \(service.interfaceSummary); "
                            + "visible in \(self.interfacePreference.label): \(service.isVisible(in: self.interfacePreference))"
                    )
                }

                // Any result at all proves discovery is permitted.
                if !services.isEmpty {
                    self.localNetworkNeedsAttention = false
                }

                // Auto-connect to newly discovered services
                if self.autoConnect {
                    for service in services {
                        let serviceKey = self.deviceKey(for: service.name)
                        if !self.connectedServices.contains(where: { self.deviceKey(for: $0.name) == serviceKey })
                            && !self.connectingServiceNames.contains(serviceKey) {
                            // Skip " P2P" duplicate — sender uses P2P automatically for Apple devices
                            if service.name.hasSuffix(" P2P") && services.contains(where: { $0.name == String(service.name.dropLast(4)) }) { continue }
                            LogManager.shared.log("Sender: Auto-connecting to \(service.name)")
                            self.connect(to: service)
                        }
                    }
                }
            }
        }

        browser.start(queue: .main)
    }

    /// Time a ready browser is allowed to report nothing before we treat the
    /// silence as a blocked Local Network permission rather than an empty network.
    private static let discoverySilenceTimeout: TimeInterval = 8.0

    private func scheduleDiscoverySilenceCheck(generation: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.discoverySilenceTimeout) { [weak self] in
            guard let self, self.browserGeneration == generation else { return }
            guard self.foundServices.isEmpty,
                  self.pipelines.isEmpty,
                  !self.localNetworkNeedsAttention else { return }

            // Attribute the silence correctly. In a mode that bans interfaces,
            // an empty result set usually means the permitted link is down —
            // blaming the Local Network permission there sends the user to fix
            // something that was never broken.
            if self.interfacePreference != .auto {
                LogManager.shared.log(
                    "Sender: No devices found in \(Int(Self.discoverySilenceTimeout))s while restricted to "
                        + "\(self.interfacePreference.label). Either that link is down or the receiver is not on it — "
                        + "switch to Auto to search every route."
                )
                return
            }

            self.localNetworkNeedsAttention = true
            LogManager.shared.log(
                "Sender: Bonjour browser has been ready for \(Int(Self.discoverySilenceTimeout))s "
                    + "without a single result — Local Network permission is most likely denied "
                    + "(System Settings > Privacy & Security > Local Network)"
            )
        }
    }

    private func scheduleBrowserRetry(after error: NWError, generation: UUID) {
        guard browserGeneration == generation else { return }
        browserRetryAttempt += 1

        guard browserRetryAttempt <= maxBrowserRetryAttempts else {
            localNetworkNeedsAttention = true
            if pipelines.isEmpty {
                setPhase(.failed, "Local Network access unavailable — check Privacy & Security")
            }
            LogManager.shared.log("Sender: Bonjour browsing stopped after \(maxBrowserRetryAttempts) retries: \(error.localizedDescription)")
            return
        }

        let delay = min(pow(2.0, Double(browserRetryAttempt - 1)), 8.0)
        LogManager.shared.log("Sender: Bonjour browse failed (\(error.localizedDescription)); retry \(browserRetryAttempt)/\(maxBrowserRetryAttempts) in \(Int(delay))s")
        let retryWork = DispatchWorkItem { [weak self] in
            guard let self, self.browserGeneration == generation else { return }
            self.startBrowsing(resetRetryBudget: false)
        }
        browserRetryWork = retryWork
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: retryWork)
    }
    
    // Heartbeat
    private var lastHeartbeatTime: Date = Date()
    private var heartbeatTimer: Timer?
    private var lastAudioRecoveryCheck: Date = .distantPast
    private var connectionRefusedCount: Int = 0
    
    // Hard-Lock AWDL Logic
    private let interfaceMonitor = NWPathMonitor()
    private var cachedAWDLInterface: NWInterface?
    private var cachedInfraInterface: NWInterface?
    
    init() {
        LogManager.shared.log("Sender: App Starting")
        refreshPairingState()
        displayPlacement = UserDefaults.standard.string(forKey: Self.displayPlacementDefaultsKey)
            .flatMap(VirtualDisplayManager.DisplayPlacement.init(rawValue:)) ?? .right
        hiddenDeviceKeys = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenDeviceKeysDefaultsKey) ?? [])
        restorePersistedSettings()
        hasFinishedInitialization = true
        // Screen Bridge is display-only: all direct control stays on the Mac.
        UserDefaults.standard.removeObject(forKey: "iPadInputEnabled")
        
        // We can't monitor recursively in init easily, but we can start it.
        interfaceMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for interface in path.availableInterfaces {
                    // Cache AWDL
                    if interface.name.contains("awdl") || interface.name.contains("llw") {
                        let isNew = self.cachedAWDLInterface == nil
                        self.cachedAWDLInterface = interface

                        if isNew {
                            LogManager.shared.log("Network: Found P2P Interface: \(interface.name) (\(interface.type))")
                            // Restart browsing on this interface so we get the Link-Local Address
                            // If we don't, we might try to connect to the Router IP via AWDL, which fails.
                            if self.interfacePreference == .awdl {
                                LogManager.shared.log("Network: Restarting Browser to force discovery via \(interface.name)...")
                                self.startBrowsing()
                            }
                        }
                    }
                    // Cache Infra WiFi (en0 typically) — only log on first discovery
                    if interface.type == .wifi && !interface.name.contains("awdl") && !interface.name.contains("llw") {
                        let isNew = self.cachedInfraInterface == nil
                        self.cachedInfraInterface = interface
                        if isNew {
                            LogManager.shared.log("Network: Found Infra Interface: \(interface.name) (\(interface.type))")
                        }
                    }
                }

            }
        }
        interfaceMonitor.start(queue: .global())
    }

    func refreshPairingState() {
        do {
            hasPairingSecret = try pairingSecretStore.loadSecret() != nil
        } catch {
            hasPairingSecret = false
            LogManager.shared.log("Pairing: Unable to read pairing state")
        }
    }

    /// Result of a pairing-code save, so the UI can explain a failure instead of
    /// silently doing nothing.
    enum PairingSaveResult: Equatable {
        case saved
        case tooWeak
        case storageFailed
    }

    func savePairingCode(_ code: String) -> PairingSaveResult {
        // Normalization strips whitespace and `-`, so "-" and "---" previously
        // passed the non-empty check and became SHA256("") — a fixed secret
        // shared by every install that did it.
        guard PairingAuthenticator.isAcceptableSecretInput(code) else {
            LogManager.shared.log("Pairing: Rejected pairing code — too short or no variety")
            return .tooWeak
        }
        do {
            let secret = PairingAuthenticator.normalizedSecret(from: code)
            try pairingSecretStore.saveSecret(secret)
            hasPairingSecret = true
            LogManager.shared.log("Pairing: Pairing code saved")
            return .saved
        } catch {
            LogManager.shared.log("Pairing: Failed to save pairing code")
            return .storageFailed
        }
    }

    /// Clears the pairing secret and drops every session that was authenticated
    /// with it.
    ///
    /// Deleting only the stored secret left existing sessions streaming, so
    /// "Clear Pairing" did not actually revoke anything until the next restart.
    func clearPairingSecret() {
        do {
            try pairingSecretStore.deleteSecret()
            hasPairingSecret = false
            LogManager.shared.log("Pairing: Pairing cleared")
        } catch {
            LogManager.shared.log("Pairing: Failed to clear pairing")
        }

        if !pipelines.isEmpty {
            LogManager.shared.log("Pairing: Revoking \(pipelines.count) active session(s)")
            disconnect()
        }
        if !pendingConnections.isEmpty {
            LogManager.shared.log("Pairing: Cancelling \(pendingConnections.count) pending connection(s)")
            let pending = pendingConnections.values
            pendingConnections.removeAll()
            connectingServiceNames.removeAll()
            for connection in pending {
                connection.stateUpdateHandler = nil
                connection.cancel()
            }
        }
    }

    func loadPairingSecret() -> Data? {
        do {
            return try pairingSecretStore.loadSecret()
        } catch {
            LogManager.shared.log("Pairing: Unable to load pairing secret")
            return nil
        }
    }

    private func sendLengthPrefixedData(_ data: Data, on connection: NWConnection, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        guard !data.isEmpty else {
            completion(.failure(PairingTransportError.emptyFrame))
            return
        }

        var packet = Data()
        var length = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &length, count: 4))
        packet.append(data)

        connection.send(content: packet, completion: .contentProcessed { error in
            if let error {
                completion(.failure(PairingTransportError.sendFailed(error)))
            } else {
                completion(.success(()))
            }
        })
    }

    private func receiveLengthPrefixedData(on connection: NWConnection, completion: @escaping @Sendable (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { content, _, isComplete, error in
            if let error {
                completion(.failure(error))
                return
            }

            guard let content, content.count == 4, !isComplete else {
                completion(.failure(PairingTransportError.emptyFrame))
                return
            }

            let rawLength = content.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            let bodyLength: Int
            do {
                bodyLength = try StreamFraming.validateBodyLength(rawLength, limit: StreamFraming.maxHandshakeFrameBytes)
            } catch {
                completion(.failure(PairingTransportError.invalidFrameLength(Int(rawLength))))
                return
            }

            connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { body, _, _, error in
                if let error {
                    completion(.failure(error))
                    return
                }
                guard let body, body.count == bodyLength else {
                    completion(.failure(PairingTransportError.missingFrameBody))
                    return
                }
                completion(.success(body))
            }
        }
    }

    private func sendCodable<T: Encodable>(_ value: T, on connection: NWConnection, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        do {
            let data = try JSONEncoder().encode(value)
            sendLengthPrefixedData(data, on: connection, completion: completion)
        } catch {
            completion(.failure(error))
        }
    }

    private func receiveCodable<T: Decodable & Sendable>(_ type: T.Type, on connection: NWConnection, completion: @escaping @Sendable (Result<T, Error>) -> Void) {
        receiveLengthPrefixedData(on: connection) { result in
            switch result {
            case .success(let data):
                do {
                    completion(.success(try JSONDecoder().decode(T.self, from: data)))
                } catch {
                    completion(.failure(PairingTransportError.decodeFailed))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// A peer that accepts the TCP connection but never sends its hello used to
    /// leave the sender in `Authenticating` forever: the 5s connect timer is
    /// cancelled as soon as TCP reaches `.ready`, and nothing bounded the
    /// handshake that follows.
    private static let handshakeTimeout: TimeInterval = 10

    private func performPairingHandshake(
        on connection: NWConnection,
        secret: Data,
        role: StreamConnectionRole,
        receiverSessionID: UUID? = nil,
        completion: @escaping @Sendable (Result<AuthenticatedPairing, Error>) -> Void
    ) {
        let completionGuard = SingleCompletionGuard()
        let finish: @Sendable (Result<AuthenticatedPairing, Error>) -> Void = { result in
            guard completionGuard.claim() else { return }
            completion(result)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.handshakeTimeout) {
            finish(.failure(PairingTransportError.handshakeTimedOut))
        }

        let senderNonce = PairingAuthenticator.randomNonce()
        let hello = SenderHello(
            senderNonce: senderNonce,
            role: role,
            sessionID: receiverSessionID
        )

        sendCodable(hello, on: connection) { [weak self] sendResult in
            if case .failure(let error) = sendResult {
                finish(.failure(error))
                return
            }

            self?.receiveCodable(ReceiverHello.self, on: connection) { [weak self] receiverResult in
                switch receiverResult {
                case .success(let receiverHello):
                    if role == .audio && receiverHello.sessionID != receiverSessionID {
                        finish(.failure(PairingTransportError.invalidSession))
                        return
                    }
                    guard PairingAuthenticator.verifyReceiverProof(
                        receiverHello.receiverProof,
                        secret: secret,
                        senderNonce: senderNonce,
                        receiverNonce: receiverHello.receiverNonce
                    ) else {
                        finish(.failure(PairingTransportError.invalidProof))
                        return
                    }

                    let proof = SenderProof(senderProof: PairingAuthenticator.senderProof(
                        secret: secret,
                        senderNonce: senderNonce,
                        receiverNonce: receiverHello.receiverNonce
                    ))
                    let sessionKey = PairingAuthenticator.deriveSessionKey(
                        secret: secret,
                        senderNonce: senderNonce,
                        receiverNonce: receiverHello.receiverNonce
                    )
                    self?.sendCodable(proof, on: connection) { proofResult in
                        switch proofResult {
                        case .success:
                            finish(.success(AuthenticatedPairing(
                                sessionKey: sessionKey,
                                receiverSessionID: receiverHello.sessionID,
                                receiverCapabilities: receiverHello.capabilities?.isValid == true
                                    ? receiverHello.capabilities
                                    : nil
                            )))
                        case .failure(let error):
                            finish(.failure(error))
                        }
                    }
                case .failure(let error):
                    finish(.failure(error))
                }
            }
        }
    }

    private func activateAuthenticatedConnection(
        _ connection: NWConnection,
        connectionId: UUID,
        service: DiscoveredService,
        streamEndpoint: NWEndpoint,
        isP2P: Bool,
        isWiredCable: Bool,
        requestedPreference: NetworkInterfacePreference,
        requiredInterface: NWInterface?,
        authentication: AuthenticatedPairing
    ) {
        removeExistingConnections(matching: service, keeping: connectionId)
        pendingConnections.removeValue(forKey: connectionId)

        // Create pipeline for this connection only after pairing authentication succeeds.
        var pipeline = ConnectionPipeline(
            id: connectionId,
            connection: connection,
            streamEndpoint: streamEndpoint,
            service: service,
            receiverSessionID: authentication.receiverSessionID,
            lastHeartbeat: Date(),
            sessionKey: authentication.sessionKey
        )
        pipeline.isP2P = isP2P
        pipeline.isWiredCable = isWiredCable
        pipeline.requestedPreference = requestedPreference
        pipeline.requiredRouteInterface = requiredInterface
        pipeline.requestedRoute = requestedPreference.label
        pipeline.systemPath = Self.systemPathDescription(connection.currentPath)
        if let requiredInterface {
            pipeline.routeEvidence = "Required \(requiredInterface.name)[\(requiredInterface.type)] from Bonjour"
            pipeline.hasVerifiedRouteEvidence = true
        } else {
            pipeline.routeEvidence = "Bonjour: \(service.interfaceSummary); system selected route"
            pipeline.hasVerifiedRouteEvidence = false
        }
        pipeline.appliedUseVirtualDisplay = useVirtualDisplay
        pipeline.appliedResolutionName = selectedResolution.name
        pipeline.appliedRetina = isRetina
        pipeline.appliedQuality = selectedQuality
        if let capabilities = authentication.receiverCapabilities {
            pipeline.reportedScreenWidth = capabilities.pixelWidth
            pipeline.reportedScreenHeight = capabilities.pixelHeight
            LogManager.shared.log("Sender: Receiver handshake reported screen \(capabilities.pixelWidth)x\(capabilities.pixelHeight) for \(service.name)")
        }

        let isLegacyReceiver = service.name.lowercased().hasPrefix("bettercast receiver")
        pipeline.supportsTypeByte = !isLegacyReceiver

        pipelines[connectionId] = pipeline
        connectedServices.removeAll { deviceKey(for: $0.name) == deviceKey(for: service.name) }
        connectedServices.append(service)
        updateConnectedDisplays()

        let count = pipelines.count
        setPhase(.connected, "Connected to \(count) device(s)")
        clearReconnectState(forServiceNamed: service.name)
        LogManager.shared.log("Sender: Authenticated \(service.name) (Total: \(count), P2P: \(isP2P), typeByte: \(pipeline.supportsTypeByte))")

        // Wireless diagnostics: log viability/path transitions on the stream
        // connection so real-world drops are attributable in the logs.
        connection.viabilityUpdateHandler = { viable in
            LogManager.shared.log("Sender: Path \(viable ? "viable again ✅" : "NOT viable (radio/route lost) ⚠️") for \(service.name)")
        }
        connection.betterPathUpdateHandler = { better in
            LogManager.shared.log("Sender: Better path \(better ? "available" : "no longer available") for \(service.name)")
        }
        connection.pathUpdateHandler = { [weak self] path in
            let pathDescription = Self.systemPathDescription(path)
            LogManager.shared.log("Sender: Path changed for \(service.name): \(pathDescription), status=\(path.status)")
            DispatchQueue.main.async { [weak self] in
                guard self?.pipelines[connectionId]?.connection === connection else { return }
                self?.pipelines[connectionId]?.systemPath = pathDescription
                self?.updateConnectedDisplays()
            }
        }

        startPipeline(for: connectionId)

        if count == 1 {
            startHeartbeatMonitor()
            startStatsTimer()
        }

        receive(on: connection, connectionId: connectionId)
    }

    private func authenticateAndActivateConnection(
        _ connection: NWConnection,
        connectionId: UUID,
        service: DiscoveredService,
        streamEndpoint: NWEndpoint,
        isP2P: Bool,
        isWiredCable: Bool,
        requestedPreference: NetworkInterfacePreference,
        requiredInterface: NWInterface?
    ) {
        let serviceKey = deviceKey(for: service.name)
        guard let secret = loadPairingSecret() else {
            connectingServiceNames.remove(serviceKey)
            pendingConnections.removeValue(forKey: connectionId)
            setPhase(.failed, "Pairing required before connecting")
            LogManager.shared.log("Pairing: Missing pairing code; refusing to stream to \(service.name)")
            connection.cancel()
            return
        }

        setPhase(.authenticating, "Authenticating \(service.name)...")
        performPairingHandshake(
            on: connection,
            secret: secret,
            role: .mediaControl
        ) { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.connectingServiceNames.remove(serviceKey)

                switch result {
                case .success(let authentication):
                    guard self.pendingConnections.removeValue(forKey: connectionId) === connection else {
                        LogManager.shared.log("Pairing: Ignoring late authentication for revoked connection to \(service.name)")
                        connection.cancel()
                        return
                    }
                    self.activateAuthenticatedConnection(
                        connection,
                        connectionId: connectionId,
                        service: service,
                        streamEndpoint: streamEndpoint,
                        isP2P: isP2P,
                        isWiredCable: isWiredCable,
                        requestedPreference: requestedPreference,
                        requiredInterface: requiredInterface,
                        authentication: authentication
                    )
                case .failure(let error):
                    self.pendingConnections.removeValue(forKey: connectionId)
                    self.setPhase(.failed, "Pairing failed — check that both devices use the same code")
                    LogManager.shared.log("Pairing: Authentication failed for \(service.name): \(error.localizedDescription)")
                    connection.cancel()
                    self.removeConnection(connectionId)
                }
            }
        }
    }

    private func makeDedicatedAudioParameters(for pipeline: ConnectionPipeline) -> NWParameters {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.noDelay = true
        tcpOptions.connectionTimeout = 10

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.serviceClass = .interactiveVideo
        parameters.preferNoProxies = true

        switch pipeline.requestedPreference {
        case .auto:
            parameters.includePeerToPeer = true
            parameters.prohibitedInterfaceTypes = [.loopback]
        case .requireCable:
            parameters.includePeerToPeer = false
            parameters.prohibitedInterfaceTypes = [.loopback, .wifi]
            parameters.requiredInterface = pipeline.requiredRouteInterface
        case .awdl:
            parameters.includePeerToPeer = true
            parameters.requiredInterface = pipeline.requiredRouteInterface
        case .wifi:
            parameters.includePeerToPeer = false
            parameters.requiredInterface = pipeline.requiredRouteInterface
        }

        return parameters
    }

    /// Wall-clock budget for the auxiliary audio dial.
    ///
    /// `NWConnection` parks in `.waiting` when no permitted route exists — it
    /// never fails, so the TCP-level timeout never fires and the UI sat on
    /// "Connecting" forever while encoded AAC was thrown away.
    private static let audioConnectTimeout: TimeInterval = 8.0

    private func startDedicatedAudioConnection(for connectionId: UUID, allowAnyRoute: Bool = false) {
        guard let pipeline = pipelines[connectionId], pipeline.supportsTypeByte else { return }
        guard pipeline.audioConnection == nil else { return }
        guard let secret = loadPairingSecret() else {
            LogManager.shared.log("AudioConnection: Missing pairing secret for \(pipeline.service.name)")
            stopAudioPipeline(for: connectionId)
            setAudioState(.failed, for: connectionId)
            return
        }

        let audioParameters: NWParameters
        if allowAnyRoute {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = true
            tcpOptions.noDelay = true
            tcpOptions.connectionTimeout = 10
            audioParameters = NWParameters(tls: nil, tcp: tcpOptions)
            audioParameters.serviceClass = .interactiveVideo
        } else {
            audioParameters = makeDedicatedAudioParameters(for: pipeline)
        }
        let audioConnection = NWConnection(to: pipeline.streamEndpoint, using: audioParameters)
        let serviceName = pipeline.service.name
        // Store the in-flight transport immediately so repeated setting
        // reconciliation cannot start duplicate auxiliary handshakes.
        pipelines[connectionId]?.audioConnection = audioConnection
        if pipeline.audioState != .retrying {
            setAudioState(.connecting, for: connectionId)
        }

        // Bound the dial in wall-clock time so a route that never materialises
        // degrades to another route instead of hanging in "Connecting".
        let attemptState = ConnectionAttemptState()
        let requestedPreference = pipeline.requestedPreference
        let receiverSessionID = pipeline.receiverSessionID
        let audioTimeout = DispatchWorkItem { [weak self] in
            guard let self, !attemptState.isSettled else { return }
            attemptState.isSettled = true
            guard self.pipelines[connectionId]?.audioConnection === audioConnection else { return }

            if allowAnyRoute || requestedPreference != .auto {
                LogManager.shared.log("AudioConnection: Timed out on every route for \(serviceName)")
                self.handleAudioConnectionEnded(
                    audioConnection,
                    connectionId: connectionId,
                    reason: "audio transport timed out"
                )
            } else {
                LogManager.shared.log(
                    "AudioConnection: Timed out on the restricted route for \(serviceName) — "
                        + "retrying without interface restrictions"
                )
                audioConnection.stateUpdateHandler = nil
                audioConnection.cancel()
                self.pipelines[connectionId]?.audioConnection = nil
                self.startDedicatedAudioConnection(for: connectionId, allowAnyRoute: true)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.audioConnectTimeout, execute: audioTimeout)

        audioConnection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                switch state {
                case .ready:
                    attemptState.isSettled = true
                    audioTimeout.cancel()
                    self.performPairingHandshake(
                        on: audioConnection,
                        secret: secret,
                        role: .audio,
                        receiverSessionID: receiverSessionID
                    ) { [weak self] result in
                        DispatchQueue.main.async { [weak self] in
                            guard let self else { return }

                            switch result {
                            case .success(let authentication):
                                guard self.pipelines[connectionId]?.audioConnection === audioConnection else {
                                    audioConnection.cancel()
                                    return
                                }
                                self.pipelines[connectionId]?.audioSessionKey = authentication.sessionKey
                                let packetSender = AudioPacketSender(
                                    connection: audioConnection,
                                    connectionId: connectionId,
                                    serviceName: serviceName
                                ) { [weak self, weak audioConnection] error in
                                    guard let audioConnection else { return }
                                    DispatchQueue.main.async { [weak self] in
                                        self?.handleAudioConnectionEnded(
                                            audioConnection,
                                            connectionId: connectionId,
                                            reason: "send error: \(error)"
                                        )
                                    }
                                }
                                self.pipelines[connectionId]?.audioPacketSender = packetSender
                                self.pipelines[connectionId]?.audioEncoder?.delegate = packetSender
                                packetSender.setPaused(
                                    self.pipelines[connectionId]?.backgroundGraceStart != nil
                                )
                                self.setAudioState(.streaming, for: connectionId)
                                LogManager.shared.log("AudioConnection: Dedicated audio TCP ready for \(serviceName)")
                                self.receiveAuxiliary(on: audioConnection, connectionId: connectionId)
                            case .failure(let error):
                                LogManager.shared.log("AudioConnection: Authentication failed for \(serviceName): \(error.localizedDescription)")
                                self.handleAudioConnectionEnded(
                                    audioConnection,
                                    connectionId: connectionId,
                                    reason: "authentication failed"
                                )
                            }
                        }
                    }
                case .failed(let error):
                    attemptState.isSettled = true
                    audioTimeout.cancel()
                    LogManager.shared.log("AudioConnection: Failed for \(serviceName): \(error)")
                    self.handleAudioConnectionEnded(
                        audioConnection,
                        connectionId: connectionId,
                        reason: "transport failed"
                    )
                case .cancelled:
                    attemptState.isSettled = true
                    audioTimeout.cancel()
                    self.handleAudioConnectionEnded(
                        audioConnection,
                        connectionId: connectionId,
                        reason: "transport cancelled"
                    )
                case .waiting(let error):
                    // Not an error yet, but it is why "Connecting" can persist:
                    // no permitted route is available for this endpoint.
                    LogManager.shared.log("AudioConnection: Waiting for a route to \(serviceName): \(error)")
                default:
                    break
                }
            }
        }

        audioConnection.start(queue: .main)
    }

    private func handleAudioConnectionEnded(
        _ connection: NWConnection,
        connectionId: UUID,
        reason: String
    ) {
        guard pipelines[connectionId]?.audioConnection === connection else { return }

        connection.stateUpdateHandler = nil
        connection.cancel()
        pipelines[connectionId]?.audioEncoder?.delegate = nil
        pipelines[connectionId]?.audioPacketSender?.invalidate()
        pipelines[connectionId]?.audioConnection = nil
        pipelines[connectionId]?.audioSessionKey = nil
        pipelines[connectionId]?.audioPacketSender = nil

        if desiredAudioEnabled(for: connectionId) {
            // A process tap configured as `.muted` must not outlive its output
            // transport. Tear it down immediately so Chrome becomes audible on
            // the Mac during retry instead of disappearing on both devices.
            pipelines[connectionId]?.processAudioCapture?.stop()
            pipelines[connectionId]?.audioEncoder?.delegate = nil
            pipelines[connectionId]?.processAudioCapture = nil
            pipelines[connectionId]?.audioEncoder = nil
            pipelines[connectionId]?.appliedAudioEnabled = false
            setAudioState(.retrying, for: connectionId)
            LogManager.shared.log("AudioConnection: Will retry \(reason) for \(pipelines[connectionId]?.service.name ?? "receiver")")
        } else {
            setAudioState(.off, for: connectionId)
        }
    }

    private func classifyConnectionRoute(
        path: NWPath?,
        intent: ConnectionRouteIntent
    ) -> ConnectionRouteClassification {
        switch intent {
        case .peerToPeer:
            return ConnectionRouteClassification(isP2P: true, isWiredCable: false)
        case .wired:
            return ConnectionRouteClassification(isP2P: false, isWiredCable: true)
        case .infrastructure:
            return ConnectionRouteClassification(isP2P: false, isWiredCable: false)
        case .automatic:
            return ConnectionRouteClassification(
                isP2P: false,
                isWiredCable: path?.usesInterfaceType(.wiredEthernet) == true
            )
        }
    }

    private func logConnectionRoute(_ route: ConnectionRouteClassification, path: NWPath?) {
        if let path {
            LogManager.shared.log("Sender: Connected path: \(path)")
        }
        LogManager.shared.log("Sender: \(route.description) active")
    }

    /// Network.framework can distinguish path interface *types*, but AWDL and
    /// infrastructure Wi-Fi both report as `.wifi`. Keep that ambiguity visible
    /// instead of presenting an available interface as the active one.
    fileprivate static func systemPathDescription(_ path: NWPath?) -> String {
        guard let path else { return "Unknown" }
        if path.usesInterfaceType(.wiredEthernet) { return "Wired Ethernet family" }
        if path.usesInterfaceType(.wifi) { return "Wi-Fi family (Wi-Fi or AWDL)" }
        if path.usesInterfaceType(.cellular) { return "Cellular" }
        if path.usesInterfaceType(.loopback) { return "Loopback" }
        return "Other network path"
    }

    private func configureParameters(_ parameters: NWParameters) {
        parameters.serviceClass = .interactiveVideo
        parameters.preferNoProxies = true

        switch interfacePreference {
        case .auto:
            parameters.includePeerToPeer = true
            parameters.prohibitedInterfaceTypes = [.loopback]

        case .requireCable:
            // Browser broadly excludes radio paths, then each result is filtered
            // and the connection requires the exact wired Bonjour interface.
            parameters.includePeerToPeer = false
            parameters.prohibitedInterfaceTypes = [.loopback, .wifi]

        case .awdl:
            parameters.includePeerToPeer = true
            parameters.prohibitedInterfaceTypes = [.loopback, .wiredEthernet]
            if let awdl = cachedAWDLInterface {
                parameters.requiredInterface = awdl
                LogManager.shared.log("Parameters: Requiring AWDL discovery on \(awdl.name)")
            } else if let infrastructure = cachedInfraInterface {
                parameters.prohibitedInterfaces = [infrastructure]
                LogManager.shared.log("Parameters: AWDL not ready; excluding infrastructure interface \(infrastructure.name)")
            }

        case .wifi:
            parameters.includePeerToPeer = false
            parameters.prohibitedInterfaceTypes = [.loopback, .wiredEthernet]
            if let infrastructure = cachedInfraInterface {
                parameters.requiredInterface = infrastructure
                LogManager.shared.log("Parameters: Requiring infrastructure Wi-Fi discovery on \(infrastructure.name)")
            }
        }
    }

    /// AWDL can need several cold-start dials while its radio wakes. Cable and
    /// infrastructure modes get one dial because retrying cannot create a
    /// missing interface/address.
    private static let maximumAWDLConnectAttempts = ConnectionRetryPolicy.maximumAWDLAttempts
    private static let connectRetryBackoff: TimeInterval = ConnectionRetryPolicy.backoffSeconds
    private static let connectTimeout: TimeInterval = 10.0

    private struct PlannedConnection {
        let parameters: NWParameters
        let intent: ConnectionRouteIntent
        let requiredInterface: NWInterface?
    }

    private func planConnection(
        to service: DiscoveredService,
        preference: NetworkInterfacePreference
    ) -> PlannedConnection? {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.noDelay = true
        tcpOptions.connectionTimeout = 10

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.serviceClass = .interactiveVideo
        parameters.preferNoProxies = true

        switch preference {
        case .auto:
            parameters.includePeerToPeer = true
            parameters.prohibitedInterfaceTypes = [.loopback]
            return PlannedConnection(parameters: parameters, intent: .automatic, requiredInterface: nil)

        case .requireCable:
            guard let interface = service.requiredInterface(for: .requireCable) else { return nil }
            parameters.includePeerToPeer = false
            parameters.requiredInterface = interface
            parameters.prohibitedInterfaceTypes = [.loopback, .wifi]
            return PlannedConnection(parameters: parameters, intent: .wired, requiredInterface: interface)

        case .awdl:
            guard let interface = service.requiredInterface(for: .awdl) else { return nil }
            parameters.includePeerToPeer = true
            parameters.requiredInterface = interface
            parameters.prohibitedInterfaceTypes = [.loopback, .wiredEthernet]
            return PlannedConnection(parameters: parameters, intent: .peerToPeer, requiredInterface: interface)

        case .wifi:
            guard let interface = service.requiredInterface(for: .wifi) else { return nil }
            parameters.includePeerToPeer = false
            parameters.requiredInterface = interface
            parameters.prohibitedInterfaceTypes = [.loopback, .wiredEthernet]
            return PlannedConnection(parameters: parameters, intent: .infrastructure, requiredInterface: interface)
        }
    }

    func connect(to service: DiscoveredService, attempt: Int = 1) {
        let serviceKey = deviceKey(for: service.name)
        if connectedServices.contains(where: { deviceKey(for: $0.name) == serviceKey }) {
            LogManager.shared.log("Sender: Already connected to \(service.name)")
            return
        }
        guard ConnectionRetryPolicy.shouldAcceptConnect(
            attempt: attempt,
            hasReservation: connectingServiceNames.contains(serviceKey)
        ) else {
            LogManager.shared.log("Sender: Already connecting to \(service.name) — ignoring duplicate")
            return
        }

        let requestedPreference = interfacePreference
        guard let plan = planConnection(to: service, preference: requestedPreference) else {
            connectingServiceNames.remove(serviceKey)
            setPhase(
                .failed,
                "\(requestedPreference.label) unavailable — receiver was not discovered on that interface"
            )
            LogManager.shared.log(
                "Sender: Refusing \(requestedPreference.label) connection to \(service.name); "
                    + "Bonjour evidence was \(service.interfaceSummary)"
            )
            return
        }

        connectingServiceNames.insert(serviceKey)
        let deviceCount = pipelines.count + 1
        setPhase(
            .connecting,
            "Connecting to \(service.name) via \(requestedPreference.label) (Device #\(deviceCount))..."
        )

        if let requiredInterface = plan.requiredInterface {
            LogManager.shared.log(
                "Sender: Requiring \(requestedPreference.label) interface "
                    + "\(requiredInterface.name)[\(requiredInterface.type)] for \(service.name)"
            )
        } else {
            LogManager.shared.log("Sender: Auto route for \(service.name); system may choose any discovered path")
        }

        let connection = NWConnection(to: service.endpoint, using: plan.parameters)
        let connectionId = UUID()
        pendingConnections[connectionId] = connection
        let attemptState = ConnectionAttemptState()

        let timeoutWork = DispatchWorkItem { [weak self] in
            guard let self, self.pipelines[connectionId] == nil, !attemptState.isSettled else { return }
            attemptState.isSettled = true
            self.pendingConnections.removeValue(forKey: connectionId)
            connection.stateUpdateHandler = nil
            connection.cancel()

            if requestedPreference == .awdl && attempt < Self.maximumAWDLConnectAttempts {
                let nextAttempt = attempt + 1
                self.setPhase(
                    .connecting,
                    "AWDL is waking — retrying \(service.name) (\(nextAttempt)/\(Self.maximumAWDLConnectAttempts))..."
                )
                LogManager.shared.log(
                    "Sender: AWDL timed out for \(service.name); retrying "
                        + "\(nextAttempt)/\(Self.maximumAWDLConnectAttempts)"
                )
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectRetryBackoff) { [weak self] in
                    guard let self else { return }
                    let alreadyConnected = self.pipelines.values.contains {
                        self.deviceKey(for: $0.service.name) == serviceKey
                    }
                    switch ConnectionRetryPolicy.backoffOutcome(
                        hasReservation: self.connectingServiceNames.contains(serviceKey),
                        deviceAlreadyConnected: alreadyConnected
                    ) {
                    case .abandonSuperseded:
                        return
                    case .releaseReservation:
                        self.connectingServiceNames.remove(serviceKey)
                    case .proceedWithRetry:
                        self.connect(to: service, attempt: nextAttempt)
                    }
                }
                return
            }

            self.connectingServiceNames.remove(serviceKey)
            self.setPhase(
                .failed,
                "\(requestedPreference.label) could not reach \(service.name)"
            )
            LogManager.shared.log(
                "Sender: \(requestedPreference.label) connection to \(service.name) timed out; "
                    + "strict modes do not fall back to another interface"
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.connectTimeout, execute: timeoutWork)

        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }

                switch state {
                case .ready:
                    timeoutWork.cancel()
                    let route = self.classifyConnectionRoute(path: connection.currentPath, intent: plan.intent)
                    self.logConnectionRoute(route, path: connection.currentPath)
                    self.authenticateAndActivateConnection(
                        connection,
                        connectionId: connectionId,
                        service: service,
                        streamEndpoint: service.endpoint,
                        isP2P: route.isP2P,
                        isWiredCable: route.isWiredCable,
                        requestedPreference: requestedPreference,
                        requiredInterface: plan.requiredInterface
                    )

                case .failed(let error):
                    timeoutWork.cancel()
                    self.connectingServiceNames.remove(serviceKey)
                    self.pendingConnections.removeValue(forKey: connectionId)
                    self.setPhase(.failed, "\(requestedPreference.label) connection failed")
                    LogManager.shared.log(
                        "Sender: \(requestedPreference.label) connection to \(service.name) failed: \(error)"
                    )

                case .waiting(let error):
                    self.setPhase(
                        .connecting,
                        "Waiting for \(requestedPreference.label) route to \(service.name)… (\(error.localizedDescription))"
                    )

                case .cancelled:
                    timeoutWork.cancel()
                    if ConnectionRetryPolicy.shouldReleaseReservationOnCancel(
                        cancelledForRetry: attemptState.isSettled
                    ) {
                        self.connectingServiceNames.remove(serviceKey)
                    }
                    self.pendingConnections.removeValue(forKey: connectionId)

                default:
                    break
                }
            }
        }

        connection.start(queue: .main)
    }

    // MARK: - App Controls
    func checkScreenRecordingPermission() {
        // Trigger generic check.
        // For macOS 11+, requesting CGWindowList or SCShareableContent triggers the prompt if mostly bundled correctly.
        // We use SCShareableContent.current asynchronously to trigger it without blocking main thread hard.
        Task {
            do {
                _ = try await SCShareableContent.current
                LogManager.shared.log("Permission Check: Screen Recording access appears active ✅")
            } catch {
                LogManager.shared.log("Permission Check: Screen Recording access might be missing or pending. Watch for System Popup. ⚠️")
            }
        }
    }

    func openDisplaySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }


    func openPrivacySettings() {
        // macOS 13+ Deep Link
        if let url = URL(string: "x-apple.systempreferences:com.apple.PrivacySecurity.extension?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        // Fallback for older macOS
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLocalNetworkSettings() {
        let localNetworkURL = URL(
            string: "x-apple.systempreferences:com.apple.PrivacySecurity.extension?Privacy_LocalNetwork"
        )
        let privacyURL = URL(
            string: "x-apple.systempreferences:com.apple.PrivacySecurity.extension"
        )

        if let localNetworkURL, NSWorkspace.shared.open(localNetworkURL) {
            return
        }
        if let privacyURL {
            NSWorkspace.shared.open(privacyURL)
        }
    }

    @MainActor
    func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Dynamic Updates
    private var updateDebounceWork: DispatchWorkItem?

    func updateStreamResolution() {
        // Debounce: cancel any pending update and schedule a new one
        updateDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.performUpdateStreamResolution()
        }
        updateDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func performUpdateStreamResolution() {
        LogManager.shared.log("Sender: Applying display, quality, and audio settings...")
        let connectionIDs = Array(pipelines.keys)
        var displayRebuilds: [(id: UUID, generation: UInt64)] = []

        for id in connectionIDs {
            guard let pipeline = pipelines[id] else { continue }
            let appliedSettings = PipelineSettingsSnapshot(
                useVirtualDisplay: pipeline.appliedUseVirtualDisplay,
                resolutionIdentifier: pipeline.appliedResolutionName,
                usesRetinaBacking: pipeline.appliedRetina,
                qualityBitrate: pipeline.appliedQuality.rawValue,
                audioEnabled: pipeline.appliedAudioEnabled
            )
            let requestedSettings = PipelineSettingsSnapshot(
                useVirtualDisplay: useVirtualDisplay,
                resolutionIdentifier: selectedResolution.name,
                usesRetinaBacking: isRetina,
                qualityBitrate: selectedQuality.rawValue,
                audioEnabled: desiredAudioEnabled(for: id)
            )
            let actions = PipelineUpdatePolicy.actions(from: appliedSettings, to: requestedSettings)

            if actions.contains(.rebuildDisplay) {
                stopPipeline(for: id)
                if let generation = pipelines[id]?.lifecycleGeneration {
                    displayRebuilds.append((id, generation))
                }
                continue
            }

            if actions.contains(.updateBitrate) {
                let bitrate = effectiveBitrate(for: pipeline)
                let rateLimitWindow: Double = (pipeline.isP2P || pipeline.isWiredCable) ? 0.1 : 1.0
                pipeline.videoEncoder?.updateBitrate(bitrate, rateLimitWindow: rateLimitWindow)
                pipelines[id]?.appliedQuality = selectedQuality
                pipelines[id]?.targetAdaptiveBitrate = bitrate
                pipelines[id]?.currentAdaptiveBitrate = bitrate
                pipelines[id]?.sendLatencyEWMA = 0
                pipelines[id]?.sentFramesSinceAdjustment = 0
                pipelines[id]?.droppedFramesSinceAdjustment = 0
                pipelines[id]?.lastBitrateAdjustment = Date()
                LogManager.shared.log("Sender: Updated bitrate in place for \(pipeline.service.name) to \(bitrate / 1_000_000) Mbps")
            }

            if actions.contains(.reconcileAudio) {
                reconcileAudioPipeline(for: id)
            }
        }

        guard !displayRebuilds.isEmpty else { return }
        // A display mode, backing size, or HiDPI change genuinely requires a
        // virtual display rebuild. Quality and audio changes never come here.
        let scheduledRebuilds = displayRebuilds
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self else { return }
            for rebuild in scheduledRebuilds where self.pipelines[rebuild.id] != nil {
                self.startPipeline(for: rebuild.id, expectedGeneration: rebuild.generation)
            }
        }
    }

    private func effectiveBitrate(for pipeline: ConnectionPipeline) -> Int {
        if pipeline.isP2P || pipeline.isWiredCable {
            return selectedQuality.rawValue
        }
        return min(selectedQuality.rawValue, StreamQuality.high.rawValue)
    }
    
    // How long a backgrounded receiver may stay silent before the session is
    // cleanly torn down (virtual display destroyed). See ConnectionPipeline.backgroundGraceStart.
    let backgroundGraceDuration: TimeInterval = 300

    func startHeartbeatMonitor() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if !self.pipelines.isEmpty {
                let now = Date()
                var heartbeatTimeoutIds: [UUID] = []
                var graceExpiredIds: [UUID] = []

                for (id, pipeline) in self.pipelines {
                    // Backgrounded receivers are expected to be silent: skip the
                    // 15s heartbeat check and apply the grace deadline instead.
                    if let graceStart = pipeline.backgroundGraceStart {
                        if now.timeIntervalSince(graceStart) > self.backgroundGraceDuration {
                            LogManager.shared.log("Sender: Background grace period expired for \(pipeline.service.name) (\(Int(self.backgroundGraceDuration))s) — disconnecting cleanly")
                            graceExpiredIds.append(id)
                        }
                        continue
                    }

                    // ScreenCaptureKit can legitimately produce no complete
                    // frame while the desktop is static. Keep media transport
                    // liveness independent from changed video frames.
                    self.sendMediaHeartbeat(for: pipeline)

                    let interval = now.timeIntervalSince(pipeline.lastHeartbeat)
                    if interval > 15.0 {
                        LogManager.shared.log("Sender: Connection to \(pipeline.service.name) timed out (No Heartbeat for 15s)")
                        heartbeatTimeoutIds.append(id)
                    }
                }

                for id in heartbeatTimeoutIds {
                    self.removeConnection(id, attemptReconnect: true, reason: "heartbeat timeout")
                }
                // No auto-reconnect after grace expiry: the receiver is knowingly
                // backgrounded, so re-dialing would fail until the user returns.
                for id in graceExpiredIds {
                    self.removeConnection(id, attemptReconnect: false, reason: "background grace period expired")
                }

                if now.timeIntervalSince(self.lastAudioRecoveryCheck) >= 3.0 {
                    self.lastAudioRecoveryCheck = now
                    self.recoverAudioPipelines()
                }
            }
        }
    }

    private func sendMediaHeartbeat(for pipeline: ConnectionPipeline) {
        guard pipeline.supportsTypeByte, !pipeline.mediaHeartbeatInProgress else { return }

        let payload = Data([0x04])
        var lengthPrefix = UInt32(payload.count).bigEndian
        var packet = Data(bytes: &lengthPrefix, count: MemoryLayout<UInt32>.size)
        packet.append(payload)
        let connectionID = pipeline.id
        let connection = pipeline.connection
        let serviceName = pipeline.service.name
        pipelines[connectionID]?.mediaHeartbeatInProgress = true
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.pipelines[connectionID]?.connection === connection else { return }
                self.pipelines[connectionID]?.mediaHeartbeatInProgress = false
                if let error {
                    LogManager.shared.log("Sender: Media heartbeat to \(serviceName) failed: \(error.localizedDescription)")
                }
            }
        })
    }

    // MARK: - Auto-reconnect after unexpected drops
    //
    // Distinct from the Auto-Connect discovery setting: this only re-dials a device
    // whose authenticated session dropped unexpectedly (heartbeat timeout, transport
    // failure). Manual disconnects never trigger it.
    private var reconnectAttempts: [String: Int] = [:]
    private let maxReconnectAttempts = 3

    private func clearReconnectState(forServiceNamed name: String) {
        reconnectAttempts.removeValue(forKey: deviceKey(for: name))
    }

    private func scheduleReconnect(to service: DiscoveredService) {
        let key = deviceKey(for: service.name)
        let attempt = (reconnectAttempts[key] ?? 0) + 1
        guard attempt <= maxReconnectAttempts else {
            LogManager.shared.log("Sender: Giving up auto-reconnect to \(service.name) after \(maxReconnectAttempts) attempts")
            reconnectAttempts.removeValue(forKey: key)
            if pipelines.isEmpty {
                setPhase(.failed, "Could not reconnect to \(service.name)")
            }
            return
        }
        reconnectAttempts[key] = attempt

        let delay = pow(2.0, Double(attempt)) // 2s, 4s, 8s
        if pipelines.isEmpty {
            setPhase(.reconnecting, "Reconnecting to \(service.name) (attempt \(attempt) of \(maxReconnectAttempts))...")
        }
        LogManager.shared.log("Sender: Auto-reconnect to \(service.name) in \(Int(delay))s (attempt \(attempt)/\(maxReconnectAttempts))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            // Abort if this reconnect cycle was cancelled (manual disconnect/forget)
            // or superseded by a newer attempt.
            guard self.reconnectAttempts[key] == attempt else { return }
            guard !self.connectedServices.contains(where: { self.deviceKey(for: $0.name) == key }),
                  !self.connectingServiceNames.contains(key) else {
                self.reconnectAttempts.removeValue(forKey: key)
                return
            }
            // Prefer the freshest Bonjour record if the device was re-discovered.
            let target = self.foundServices.first(where: { self.deviceKey(for: $0.name) == key }) ?? service
            LogManager.shared.log("Sender: Auto-reconnecting to \(target.name) (attempt \(attempt)/\(self.maxReconnectAttempts))")
            self.connect(to: target)

            // If this attempt doesn't produce an authenticated session, chain the
            // next one. Success clears reconnectAttempts (see
            // activateAuthenticatedConnection), which aborts the chain.
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, self.reconnectAttempts[key] == attempt else { return }
                self.scheduleReconnect(to: service)
            }
        }
    }

    func removeConnection(_ connectionId: UUID, attemptReconnect: Bool = false, reason: String? = nil) {
        if let pending = pendingConnections.removeValue(forKey: connectionId) {
            pending.stateUpdateHandler = nil
            pending.cancel()
        }
        guard let pipeline = pipelines[connectionId] else { return }

        // Tear down this connection's pipeline
        pipeline.screenRecorder?.stopCapture()
        pipeline.processAudioCapture?.stop()
        pipeline.audioConnection?.cancel()
        pipeline.videoEncoder?.invalidate()
        pipeline.virtualDisplayManager?.destroyDisplay()
        let didSendDisconnectNotice = sendDisconnectNotice(for: pipeline)
        if didSendDisconnectNotice {
            let connection = pipeline.connection
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                connection.cancel()
            }
        } else {
            pipeline.connection.cancel()
        }
        InputHandler.shared.removeDisplayBounds(for: connectionId)

        pipelines.removeValue(forKey: connectionId)
        let removedKey = deviceKey(for: pipeline.service.name)
        connectedServices.removeAll { deviceKey(for: $0.name) == removedKey }

        let remaining = pipelines.count
        let reasonNote = reason.map { " (\($0))" } ?? ""
        LogManager.shared.log("Sender: Disconnected from \(pipeline.service.name)\(reasonNote). Remaining: \(remaining)")

        if remaining == 0 {
            setPhase(.disconnected, "Disconnected")
            heartbeatTimer?.invalidate()
        } else {
            setPhase(.connected, "Connected to \(remaining) device(s)")
        }
        updateConnectedDisplays()

        if attemptReconnect {
            scheduleReconnect(to: pipeline.service)
        }
    }

    private func sendDisconnectNotice(for pipeline: ConnectionPipeline) -> Bool {
        guard pipeline.supportsTypeByte else { return false }

        var packet = Data()
        let payload = Data([0x03])
        var lengthPrefix = UInt32(payload.count).bigEndian
        packet.append(Data(bytes: &lengthPrefix, count: 4))
        packet.append(payload)

        let serviceName = pipeline.service.name
        pipeline.connection.send(content: packet, completion: .contentProcessed { error in
            if let error {
                LogManager.shared.log("Sender: Disconnect notice to \(serviceName) failed: \(error.localizedDescription)")
            } else {
                LogManager.shared.log("Sender: Sent disconnect notice to \(serviceName)")
            }
        })
        return true
    }

    func disconnect() {
        reconnectAttempts.removeAll()
        let pending = pendingConnections.values
        pendingConnections.removeAll()
        connectingServiceNames.removeAll()
        for connection in pending {
            connection.stateUpdateHandler = nil
            connection.cancel()
        }
        for (id, pipeline) in pipelines {
            pipeline.screenRecorder?.stopCapture()
            pipeline.processAudioCapture?.stop()
            // Drain the encoder before dropping it so no VideoToolbox callback
            // lands on a released object.
            pipeline.videoEncoder?.invalidate()
            pipeline.virtualDisplayManager?.destroyDisplay()
            pipeline.connection.cancel()
            // The auxiliary audio connection is a second authenticated TCP
            // session. Leaving it open here kept the receiver believing it was
            // still connected after the main session had gone.
            pipeline.audioConnection?.cancel()
            InputHandler.shared.removeDisplayBounds(for: id)
        }
        pipelines.removeAll()
        connectedServices.removeAll()
        connectedDisplays.removeAll()
        setPhase(.disconnected, "Disconnected")
        heartbeatTimer?.invalidate()
    }

    func disconnectService(_ service: DiscoveredService) {
        let serviceKey = deviceKey(for: service.name)
        reconnectAttempts.removeValue(forKey: serviceKey)
        if let entry = pipelines.first(where: { deviceKey(for: $0.value.service.name) == serviceKey }) {
            removeConnection(entry.key)
        }
    }

    func disconnectConnection(_ connectionId: UUID) {
        if let pipeline = pipelines[connectionId] {
            clearReconnectState(forServiceNamed: pipeline.service.name)
        }
        removeConnection(connectionId)
    }

    func setAudioEnabled(_ enabled: Bool, for connectionId: UUID) {
        if let idx = connectedDisplays.firstIndex(where: { $0.id == connectionId }) {
            connectedDisplays[idx].audioEnabled = enabled
            let name = connectedDisplays[idx].name
            LogManager.shared.log("Sender: Audio \(enabled ? "enabled" : "disabled") for \(name)")
            if pipelines[connectionId] != nil {
                reconcileAudioPipeline(for: connectionId)
            }
        }
    }

    func updateConnectedDisplays() {
        var seenDeviceKeys: Set<String> = []
        connectedDisplays = pipelines.compactMap { (id, pipeline) in
            let key = deviceKey(for: pipeline.service.name)
            guard seenDeviceKeys.insert(key).inserted else { return nil }
            let bounds = InputHandler.shared.getDisplayBounds(for: id)
            let res = bounds.width > 0 ? "\(Int(bounds.width))x\(Int(bounds.height))" : "Initializing..."
            return ConnectedDisplayInfo(
                id: id,
                name: pipeline.service.name,
                resolution: res,
                displayBounds: bounds,
                audioEnabled: connectedDisplays.first(where: { $0.id == id })?.audioEnabled ?? audioStreamingEnabled,
                audioState: pipeline.audioState,
                cgDisplayID: pipeline.virtualDisplayManager?.displayID,
                requestedRoute: pipeline.requestedRoute,
                systemPath: pipeline.systemPath,
                routeEvidence: pipeline.routeEvidence,
                hasVerifiedRouteEvidence: pipeline.hasVerifiedRouteEvidence
            )
        }
    }
    
    private func startStatsTimer() {
        // Simple timer to update transfer rate UI
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if self.pipelines.isEmpty { timer.invalidate(); return }
            
            let bytes = self.bytesSentWindow
            self.bytesSentWindow = 0
            
            let mbps = Double(bytes * 8) / 1_000_000.0
            self.transferRate = String(format: "%.1f Mbps", mbps)
        }
    }
    
    private func receive(on connection: NWConnection, connectionId: UUID) {
        receiveTCP(on: connection, connectionId: connectionId)
    }
    
    private func receiveTCP(on connection: NWConnection, connectionId: UUID) {
        // Don't schedule receives on dead connections
        guard pipelines[connectionId] != nil else { return }

        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, contentContext, isComplete, error in
            if let error = error {
                // Fatal errors: connection is truly dead. Tear down immediately and
                // try to reconnect instead of waiting for the 15s heartbeat timeout.
                if case let NWError.posix(code) = error,
                   (code == .ECONNRESET || code == .ENOTCONN || code == .ECANCELED) {
                    LogManager.shared.log("Sender: Receive error (fatal): \(error)")
                    DispatchQueue.main.async { [weak self] in
                        self?.removeConnection(connectionId, attemptReconnect: true, reason: "receive error: \(error)")
                    }
                    return
                }
                // Non-fatal (e.g. ENODATA/96): keep receiving, don't spam logs
                self?.receiveTCP(on: connection, connectionId: connectionId)
                return
            }

            // A clean close arrives as isComplete with no error. Treating it as
            // "keep receiving" left the UI and the virtual display alive until the
            // 15s heartbeat timeout and kept re-arming receives on a finished stream.
            if isComplete {
                LogManager.shared.log("Sender: Receiver closed the control stream")
                DispatchQueue.main.async { [weak self] in
                    self?.removeConnection(connectionId, attemptReconnect: true, reason: "peer closed connection")
                }
                return
            }

            if let content = content, content.count == 4 {
                let rawLength = content.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }

                // The length is peer-supplied and therefore untrusted even after
                // pairing. Without a cap this asked the socket for up to ~4 GiB.
                let bodyLength: Int
                do {
                    bodyLength = try StreamFraming.validateBodyLength(rawLength, limit: StreamFraming.maxControlFrameBytes)
                } catch {
                    LogManager.shared.log("Sender: Rejected control frame length \(rawLength) (\(error)) — closing connection")
                    DispatchQueue.main.async { [weak self] in
                        self?.removeConnection(connectionId, attemptReconnect: false, reason: "invalid control frame length")
                    }
                    return
                }

                connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { [weak self] body, bodyContext, bodyComplete, bodyError in
                    if bodyError != nil || (body?.count ?? 0) != bodyLength {
                        // A short body means the stream ended mid-frame; anything we
                        // decoded from it would be garbage.
                        LogManager.shared.log("Sender: Control frame truncated (expected \(bodyLength), got \(body?.count ?? 0))")
                        DispatchQueue.main.async { [weak self] in
                            self?.removeConnection(connectionId, attemptReconnect: true, reason: "truncated control frame")
                        }
                        return
                    }

                    // All pipelines access must happen on main thread to avoid dictionary races
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, let body = body, let pipeline = self.pipelines[connectionId] else { return }

                        do {
                            let envelope = try JSONDecoder().decode(AuthenticatedEnvelope.self, from: body)
                            guard envelope.sequence > pipeline.lastInputSequence else {
                                LogManager.shared.log("Sender: Ignoring replayed input envelope from \(pipeline.service.name)")
                                return
                            }

                            let payload = try envelope.verifiedPayload(sessionKey: pipeline.sessionKey)
                            if let event = try? JSONDecoder().decode(InputEvent.self, from: payload) {
                                self.pipelines[connectionId]?.lastInputSequence = envelope.sequence
                                self.pipelines[connectionId]?.lastHeartbeat = Date()

                                if event.type == .command && event.keyCode == 555 {
                                    // Receiver is backgrounding: hold the session and the
                                    // virtual display, pause sends, and switch to the
                                    // grace deadline instead of the 15s heartbeat timeout.
                                    if self.pipelines[connectionId]?.backgroundGraceStart == nil {
                                        self.pipelines[connectionId]?.backgroundGraceStart = Date()
                                        self.pipelines[connectionId]?.audioPacketSender?.setPaused(true)
                                        LogManager.shared.log("Sender: Receiver \(pipeline.service.name) entered background — grace period started (\(Int(self.backgroundGraceDuration))s), pausing stream, keeping virtual display")
                                    }
                                    return
                                }

                                // Any other authenticated message means the receiver is
                                // active again — end the grace period and resume the stream.
                                if let graceStart = self.pipelines[connectionId]?.backgroundGraceStart {
                                    self.pipelines[connectionId]?.backgroundGraceStart = nil
                                    self.pipelines[connectionId]?.audioPacketSender?.setPaused(false)
                                    let away = Int(Date().timeIntervalSince(graceStart))
                                    LogManager.shared.log("Sender: Receiver \(pipeline.service.name) resumed after \(away)s in background — resuming stream")
                                    self.pipelines[connectionId]?.videoEncoder?.forceKeyframe()
                                }

                                if event.type == .command && event.keyCode == 888 {
                                    // Heartbeat - ignore
                                } else if event.type == .command && event.keyCode == 999 {
                                    self.pipelines[connectionId]?.videoEncoder?.forceKeyframe()
                                } else if event.type == .command && event.keyCode == 777 {
                                    // Screen info from receiver: deltaX=width, deltaY=height (pixels)
                                    self.handleScreenInfo(for: connectionId, width: Int(event.deltaX), height: Int(event.deltaY))
                                } else {
                                    // Display-only mode: authenticated receiver commands are allowed,
                                    // but iPad pointer, scroll, touch, and keyboard input are ignored.
                                    // Log it — in the current product path no such event should ever
                                    // arrive, so this line appearing means the boundary is being probed.
                                    LogManager.shared.log("Sender: Ignoring receiver input event (type \(event.type.rawValue), keyCode \(event.keyCode)) from \(pipeline.service.name) — display-only mode")
                                    return
                                }
                            }
                        } catch {
                            LogManager.shared.log("Sender: Rejected unauthenticated input from \(pipeline.service.name)")
                        }
                    }
                    self?.receiveTCP(on: connection, connectionId: connectionId)
                }
            } else {
                self?.receiveTCP(on: connection, connectionId: connectionId)
            }
        }
    }

    private func receiveAuxiliary(on connection: NWConnection, connectionId: UUID) {
        guard pipelines[connectionId] != nil else { return }

        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] content, _, isComplete, error in
            if let error {
                LogManager.shared.log("AudioConnection: Receive error: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.handleAudioConnectionEnded(
                        connection,
                        connectionId: connectionId,
                        reason: "receive error"
                    )
                }
                return
            }

            guard let content, content.count == 4 else {
                if isComplete {
                    DispatchQueue.main.async { [weak self] in
                        self?.handleAudioConnectionEnded(
                            connection,
                            connectionId: connectionId,
                            reason: "receiver closed stream"
                        )
                    }
                } else {
                    self?.receiveAuxiliary(on: connection, connectionId: connectionId)
                }
                return
            }

            let rawLength = content.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }

            let bodyLength: Int
            do {
                bodyLength = try StreamFraming.validateBodyLength(rawLength, limit: StreamFraming.maxControlFrameBytes)
            } catch {
                LogManager.shared.log("AudioConnection: Rejected frame length \(rawLength) (\(error)) — dropping auxiliary connection")
                connection.cancel()
                DispatchQueue.main.async { [weak self] in
                    self?.handleAudioConnectionEnded(
                        connection,
                        connectionId: connectionId,
                        reason: "invalid frame"
                    )
                }
                return
            }

            connection.receive(minimumIncompleteLength: bodyLength, maximumLength: bodyLength) { [weak self] body, _, bodyComplete, bodyError in
                if bodyError != nil || (body?.count ?? 0) != bodyLength {
                    LogManager.shared.log("AudioConnection: Frame truncated (expected \(bodyLength), got \(body?.count ?? 0))")
                    connection.cancel()
                    DispatchQueue.main.async { [weak self] in
                        self?.handleAudioConnectionEnded(
                            connection,
                            connectionId: connectionId,
                            reason: "truncated frame"
                        )
                    }
                    return
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          let body,
                          let pipeline = self.pipelines[connectionId],
                          let sessionKey = pipeline.audioSessionKey else {
                        return
                    }

                    if let envelope = try? JSONDecoder().decode(AuthenticatedEnvelope.self, from: body),
                       let payload = try? envelope.verifiedPayload(sessionKey: sessionKey),
                       let event = try? JSONDecoder().decode(InputEvent.self, from: payload),
                       event.type == .command,
                       event.keyCode == 888 {
                        self.pipelines[connectionId]?.lastHeartbeat = Date()
                    }
                }
                self?.receiveAuxiliary(on: connection, connectionId: connectionId)
            }
        }
    }
    
    // Handle screen info from iOS receiver (command 777)
    // Receiver reports its native screen dimensions so we can match the aspect ratio
    private func handleScreenInfo(for connectionId: UUID, width: Int, height: Int) {
        guard width > 0 && height > 0 else { return }
        guard let pipeline = pipelines[connectionId] else { return }

        let serviceName = pipeline.service.name

        // Command 777 is sent by iOS/Mac Swift receivers to report screen dimensions.
        // These receivers now support type-byte framing (auto-detect), so keep supportsTypeByte = true.
        LogManager.shared.log("Sender: Screen info (command 777) from \(serviceName)")

        let oldW = pipeline.reportedScreenWidth
        let oldH = pipeline.reportedScreenHeight

        // Skip if dimensions haven't changed
        if oldW == width && oldH == height { return }

        pipelines[connectionId]?.reportedScreenWidth = width
        pipelines[connectionId]?.reportedScreenHeight = height
        LogManager.shared.log("Sender: Screen info from \(serviceName): \(width)x\(height)")

        // Restart pipeline with new dimensions
        stopPipeline(for: connectionId)
        startPipeline(for: connectionId)
    }

    private func stopPipeline(for connectionId: UUID) {
        pipelines[connectionId]?.lifecycleGeneration &+= 1
        pipelines[connectionId]?.screenRecorder?.stopCapture()
        pipelines[connectionId]?.screenRecorder = nil
        // Resolution and orientation changes run through here while frames are
        // still in flight, so the encoder must be drained, not just dropped.
        pipelines[connectionId]?.videoEncoder?.invalidate()
        pipelines[connectionId]?.videoEncoder = nil
        pipelines[connectionId]?.processAudioCapture?.stop()
        pipelines[connectionId]?.processAudioCapture = nil
        pipelines[connectionId]?.audioEncoder?.delegate = nil
        pipelines[connectionId]?.audioPacketSender?.invalidate()
        pipelines[connectionId]?.audioConnection?.cancel()
        pipelines[connectionId]?.audioConnection = nil
        pipelines[connectionId]?.audioSessionKey = nil
        pipelines[connectionId]?.audioEncoder = nil
        pipelines[connectionId]?.audioPacketSender = nil
        pipelines[connectionId]?.framesInFlight = 0
        pipelines[connectionId]?.pendingKeyframePacket = nil
        if let dm = pipelines[connectionId]?.virtualDisplayManager {
            dm.destroyDisplay()
            pipelines[connectionId]?.virtualDisplayManager = nil
        }
    }

    func startPipeline(for connectionId: UUID, expectedGeneration: UInt64? = nil) {
        guard let existingPipeline = pipelines[connectionId] else { return }
        if let expectedGeneration,
           existingPipeline.lifecycleGeneration != expectedGeneration {
            LogManager.shared.log("Sender: Ignoring superseded pipeline start for \(existingPipeline.service.name)")
            return
        }
        pipelines[connectionId]?.lifecycleGeneration &+= 1
        guard let lifecycleGeneration = pipelines[connectionId]?.lifecycleGeneration else { return }

        let serviceName = pipelines[connectionId]?.service.name ?? "unknown"
        LogManager.shared.log("Sender: Starting pipeline for \(serviceName)...")

        var targetDisplayID: CGDirectDisplayID? = nil
        let receiverDisplaySize = useVirtualDisplay
            && selectedResolution == VirtualDisplayManager.receiverBestFitResolution
            ? preferredReceiverDisplaySize(for: connectionId)
            : nil

        // Create virtual display if enabled
        if useVirtualDisplay {
            LogManager.shared.log("Sender: Creating virtual display for \(serviceName)...")
            let displayManager = VirtualDisplayManager()
            displayManager.onDisplayBoundsChanged = { [weak self] bounds in
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.pipelines[connectionId]?.lifecycleGeneration == lifecycleGeneration,
                          self.pipelines[connectionId]?.virtualDisplayManager === displayManager else { return }
                    InputHandler.shared.updateDisplayBounds(bounds: bounds, for: connectionId)
                    LogManager.shared.log("Sender: Updated display placement for \(serviceName): \(bounds)")
                    self.updateConnectedDisplays()
                }
            }

            // Use receiver-reported aspect ratio, but expose a smaller HiDPI logical mode.
            let res: (width: Int, height: Int, ppi: Int)
            if let receiverDisplaySize {
                res = (width: receiverDisplaySize.backingWidth, height: receiverDisplaySize.backingHeight, ppi: selectedResolution.ppi)
                LogManager.shared.log("Sender: Using HiDPI receiver display \(receiverDisplaySize.logicalWidth)x\(receiverDisplaySize.logicalHeight) logical / \(receiverDisplaySize.backingWidth)x\(receiverDisplaySize.backingHeight) backing from reported \(receiverDisplaySize.reportedWidth)x\(receiverDisplaySize.reportedHeight) for \(serviceName)")
            } else {
                res = (width: selectedResolution.width, height: selectedResolution.height, ppi: selectedResolution.ppi)
            }
            let shouldUseHiDPI = receiverDisplaySize != nil || selectedResolution.hiDPI || isRetina
            let resolution = VirtualDisplayManager.Resolution(
                width: res.width,
                height: res.height,
                ppi: shouldUseHiDPI ? min(220, res.ppi * 2) : res.ppi,
                hiDPI: shouldUseHiDPI,
                name: "Screen Bridge Display (\(serviceName))"
            )

            if let displayID = displayManager.createDisplay(resolution: resolution, placement: displayPlacement) {
                targetDisplayID = displayID
                pipelines[connectionId]?.virtualDisplayManager = displayManager

                // Update InputHandler with this connection's display bounds
                // Retry with increasing delays — macOS may take time to register the virtual display
                @Sendable func pollDisplayBounds(attempt: Int) {
                    guard self.pipelines[connectionId]?.lifecycleGeneration == lifecycleGeneration,
                          self.pipelines[connectionId]?.virtualDisplayManager === displayManager else { return }
                    let bounds = CGDisplayBounds(displayID)
                    if bounds.width > 0 && bounds.height > 0 {
                        InputHandler.shared.updateDisplayBounds(bounds: bounds, for: connectionId)
                        LogManager.shared.log("Sender: Virtual display for \(serviceName) bounds: \(bounds) (attempt \(attempt))")
                        self.updateConnectedDisplays()
                    } else if attempt < 10 {
                        // Retry after increasing delay (0.5s, 1s, 1.5s, ...)
                        DispatchQueue.main.asyncAfter(deadline: .now() + Double(attempt) * 0.5) {
                            pollDisplayBounds(attempt: attempt + 1)
                        }
                    } else {
                        // Fallback: use the resolution we requested
                        let fallbackBounds = CGRect(x: 0, y: 0, width: res.width, height: res.height)
                        InputHandler.shared.updateDisplayBounds(bounds: fallbackBounds, for: connectionId)
                        LogManager.shared.log("Sender: Virtual display bounds unavailable after retries, using fallback: \(fallbackBounds)")
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    pollDisplayBounds(attempt: 1)
                }

                LogManager.shared.log("Sender: Virtual display created for \(serviceName) with ID \(displayID)")
                LogManager.shared.log("Sender: Go to System Settings > Displays to arrange it")
            } else {
                LogManager.shared.log("Sender: Failed to create virtual display for \(serviceName); refusing to mirror the main screen in Extended Display mode")
                removeConnection(connectionId)
                // Set after teardown so the failure reason stays visible.
                setPhase(.failed, "Virtual display unavailable")
                return
            }
        } else {
            LogManager.shared.log("Sender: Using main screen (mirroring mode) for \(serviceName)")
            let mainBounds = CGDisplayBounds(CGMainDisplayID())
            if mainBounds.width > 0 && mainBounds.height > 0 {
                InputHandler.shared.updateDisplayBounds(bounds: mainBounds, for: connectionId)
            }
        }

        // Calculate Physical Capture Resolution
        // Match the virtual display dimensions so macOS default scaling stays stable.
        let captureWidth: Int
        let captureHeight: Int
        if !useVirtualDisplay {
            let mainDisplayID = CGMainDisplayID()
            captureWidth = max(1, Int(CGDisplayPixelsWide(mainDisplayID)))
            captureHeight = max(1, Int(CGDisplayPixelsHigh(mainDisplayID)))
            LogManager.shared.log("Sender: Mirror capture follows source display pixels \(captureWidth)x\(captureHeight) for \(serviceName)")
        } else if let receiverDisplaySize {
            captureWidth = receiverDisplaySize.captureWidth
            captureHeight = receiverDisplaySize.captureHeight
        } else {
            let scale = isRetina && !selectedResolution.hiDPI ? 2 : 1
            captureWidth = selectedResolution.width * scale
            captureHeight = selectedResolution.height * scale
        }

        // Adaptive quality: verified AWDL/cable links get full quality;
        // infrastructure and ambiguous Auto paths use the conservative cap.
        let isP2P = pipelines[connectionId]?.isP2P ?? false
        let isWiredCable = pipelines[connectionId]?.isWiredCable ?? false
        let fps: Int
        let bitrate: Int
        let keyframeInterval: Double
        if isP2P {
            fps = 60  // AWDL can't sustain 120fps at typical bitrates; 60fps = 2x bits per frame
            bitrate = selectedQuality.rawValue
            keyframeInterval = 10.0 // P2P is reliable, long interval is fine
        } else if isWiredCable {
            fps = 60
            bitrate = selectedQuality.rawValue
            keyframeInterval = 10.0
            LogManager.shared.log("Sender: USB/Cable mode — \(fps) FPS / \(bitrate / 1_000_000) Mbps / KF every 10s for \(serviceName)")
        } else {
            // Infrastructure (WiFi router, Windows/Linux receivers).
            //
            // Until the P2P detection fix, "awdl" appearing anywhere in the
            // interface list marked nearly every connection as P2P, so this branch
            // almost never ran and router links were really running the 60 FPS
            // profile below. Dropping them to 30 FPS now that detection is correct
            // would read as a regression, and for desktop content it isn't needed:
            // static frames cost almost nothing, so frame rate is cheap and motion
            // smoothness is what the user actually sees.
            fps = 60
            bitrate = min(selectedQuality.rawValue, StreamQuality.high.rawValue)
            keyframeInterval = 2.0  // Short interval for fast error recovery over WiFi
            let capNote = bitrate < selectedQuality.rawValue ? " (capped from \(selectedQuality.rawValue / 1_000_000) Mbps for WiFi stability)" : ""
            LogManager.shared.log("Sender: Infrastructure mode — \(fps) FPS / \(bitrate / 1_000_000) Mbps / KF every 2s\(capNote) for \(serviceName)")
        }

        LogManager.shared.log("Sender: Pipeline \(serviceName): \(captureWidth)x\(captureHeight)\(receiverDisplaySize != nil ? " (native capture)" : "") @ \(selectedQuality.name) [\(fps) FPS, P2P: \(isP2P)]")

        // P2P: tight 0.1s rate limit window prevents AWDL buffer bloat
        // Infrastructure: loose 1.0s window lets the encoder handle burst scenes naturally
        let rateLimitWindow: Double = (isP2P || isWiredCable) ? 0.1 : 1.0
        let encoder = VideoEncoder(connectionId: connectionId, width: captureWidth, height: captureHeight, bitrate: bitrate, expectedFPS: fps, keyframeIntervalSeconds: keyframeInterval, rateLimitWindow: rateLimitWindow)
        encoder.delegate = self
        pipelines[connectionId]?.videoEncoder = encoder

        let recorder = ScreenRecorder(
            videoEncoder: encoder,
            targetDisplayID: targetDisplayID,
            width: captureWidth,
            height: captureHeight,
            captureFPS: Int32(fps)
        )
        recorder.delegate = self
        recorder.captureAudio = false
        recorder.audioEncoder = nil
        pipelines[connectionId]?.screenRecorder = recorder
        pipelines[connectionId]?.appliedUseVirtualDisplay = useVirtualDisplay
        pipelines[connectionId]?.appliedResolutionName = selectedResolution.name
        pipelines[connectionId]?.appliedRetina = isRetina
        pipelines[connectionId]?.appliedQuality = selectedQuality
        pipelines[connectionId]?.currentAdaptiveBitrate = bitrate
        pipelines[connectionId]?.targetAdaptiveBitrate = bitrate
        pipelines[connectionId]?.sendLatencyEWMA = 0
        pipelines[connectionId]?.sentFramesSinceAdjustment = 0
        pipelines[connectionId]?.droppedFramesSinceAdjustment = 0
        pipelines[connectionId]?.lastBitrateAdjustment = Date()
        pipelines[connectionId]?.streamingStartedAt = Date()

        reconcileAudioPipeline(for: connectionId)

        Task {
            await recorder.startCapture()
        }
    }

    private func desiredAudioEnabled(for connectionId: UUID) -> Bool {
        connectedDisplays.first(where: { $0.id == connectionId })?.audioEnabled
            ?? audioStreamingEnabled
    }

    private func setAudioState(_ state: AudioStreamingState, for connectionId: UUID) {
        guard pipelines[connectionId]?.audioState != state else { return }
        pipelines[connectionId]?.audioState = state
        if let index = connectedDisplays.firstIndex(where: { $0.id == connectionId }) {
            connectedDisplays[index].audioState = state
        }
    }

    /// Retry only the auxiliary audio branch. Video capture, the encoder, and
    /// the virtual display stay untouched while Chrome appears or the audio TCP
    /// transport reconnects.
    private func recoverAudioPipelines() {
        for connectionId in Array(pipelines.keys) {
            guard let pipeline = pipelines[connectionId],
                  desiredAudioEnabled(for: connectionId),
                  pipeline.backgroundGraceStart == nil,
                  pipeline.audioState != .failed else {
                continue
            }

            if let processTap = pipeline.processAudioCapture,
               processTap.requiresRebuildForCurrentProcesses() {
                LogManager.shared.log("Sender: Chrome audio process set changed; rebuilding audio branch for \(pipeline.service.name)")
                stopAudioPipeline(for: connectionId)
                setAudioState(.retrying, for: connectionId)
            }

            guard let currentPipeline = pipelines[connectionId] else { continue }
            if currentPipeline.processAudioCapture == nil || currentPipeline.audioConnection == nil {
                reconcileAudioPipeline(for: connectionId)
            }
        }
    }

    private func reconcileAudioPipeline(for connectionId: UUID) {
        guard let pipeline = pipelines[connectionId] else { return }
        let shouldEnable = desiredAudioEnabled(for: connectionId)

        if !shouldEnable {
            stopAudioPipeline(for: connectionId)
            pipelines[connectionId]?.appliedAudioEnabled = false
            return
        }

        if pipeline.processAudioCapture != nil {
            if pipeline.audioConnection == nil {
                startDedicatedAudioConnection(for: connectionId)
            }
            pipelines[connectionId]?.appliedAudioEnabled = true
            return
        }

        let audioEncoder = AudioEncoder(connectionId: connectionId)
        let processTap = ProcessAudioTapCapture(
            bundleIDPrefixes: ["com.google.Chrome"],
            muteProcess: true
        ) { audioBufferList, format in
            audioEncoder.encode(audioBufferList: audioBufferList, sourceFormat: format)
        }

        do {
            try processTap.start()
            pipelines[connectionId]?.audioEncoder = audioEncoder
            pipelines[connectionId]?.processAudioCapture = processTap
            pipelines[connectionId]?.appliedAudioEnabled = true
            setAudioState(.connecting, for: connectionId)
            startDedicatedAudioConnection(for: connectionId)
            LogManager.shared.log("Sender: Chrome audio capture enabled without rebuilding display for \(pipeline.service.name)")
        } catch let error as ProcessAudioTapCaptureError {
            audioEncoder.delegate = nil
            pipelines[connectionId]?.audioEncoder = nil
            pipelines[connectionId]?.processAudioCapture = nil
            pipelines[connectionId]?.appliedAudioEnabled = false
            switch error {
            case .noMatchingAudioProcess:
                setAudioState(.waitingForChrome, for: connectionId)
            case .unsupportedOS:
                setAudioState(.failed, for: connectionId)
            default:
                setAudioState(.retrying, for: connectionId)
            }
            LogManager.shared.log("Sender: Chrome-only audio capture unavailable (\(error.localizedDescription)); video/display remain active")
        } catch {
            audioEncoder.delegate = nil
            pipelines[connectionId]?.audioEncoder = nil
            pipelines[connectionId]?.processAudioCapture = nil
            pipelines[connectionId]?.appliedAudioEnabled = false
            setAudioState(.retrying, for: connectionId)
            LogManager.shared.log("Sender: Chrome-only audio capture unavailable (\(error.localizedDescription)); video/display remain active")
        }
    }

    private func stopAudioPipeline(for connectionId: UUID) {
        guard let pipeline = pipelines[connectionId] else { return }
        let hadAudioResources = pipeline.processAudioCapture != nil
            || pipeline.audioConnection != nil
            || pipeline.audioEncoder != nil
        pipeline.processAudioCapture?.stop()
        pipeline.audioConnection?.stateUpdateHandler = nil
        pipeline.audioConnection?.cancel()
        pipeline.audioEncoder?.delegate = nil
        pipeline.audioPacketSender?.invalidate()
        pipelines[connectionId]?.processAudioCapture = nil
        pipelines[connectionId]?.audioConnection = nil
        pipelines[connectionId]?.audioSessionKey = nil
        pipelines[connectionId]?.audioEncoder = nil
        pipelines[connectionId]?.audioPacketSender = nil
        setAudioState(.off, for: connectionId)
        if hadAudioResources {
            LogManager.shared.log("Sender: Audio pipeline stopped without rebuilding display for \(pipeline.service.name)")
        }
    }

    func screenRecorderDidFailToStart(_ recorder: ScreenRecorder, reason: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self, weak recorder] in
                guard let self, let recorder else { return }
                self.screenRecorderDidFailToStart(recorder, reason: reason)
            }
            return
        }
        guard let entry = pipelines.first(where: { $0.value.screenRecorder === recorder }) else { return }
        LogManager.shared.log("Sender: Screen capture did not start for \(entry.value.service.name): \(reason)")
        let connectionID = entry.key
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.removeConnection(connectionID)
            // Set after teardown so the failure reason stays visible.
            self.setPhase(.failed, "Screen capture unavailable — check Screen Recording permission")
        }
    }

    func screenRecorderDidStopUnexpectedly(_ recorder: ScreenRecorder) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self, weak recorder] in
                guard let self, let recorder else { return }
                self.screenRecorderDidStopUnexpectedly(recorder)
            }
            return
        }
        guard let entry = pipelines.first(where: { $0.value.screenRecorder === recorder }) else { return }
        LogManager.shared.log("Sender: Screen sharing stopped by system for \(entry.value.service.name)")
        removeConnection(entry.key)
    }

    private func preferredReceiverDisplaySize(for connectionId: UUID) -> ReceiverDisplaySize? {
        guard let reportedWidth = pipelines[connectionId]?.reportedScreenWidth,
              let reportedHeight = pipelines[connectionId]?.reportedScreenHeight,
              reportedWidth > 0,
              reportedHeight > 0 else {
            return nil
        }

        let logical = scaledReceiverDisplaySize(
            width: reportedWidth,
            height: reportedHeight,
            targetLongEdge: BCConstants.defaultReceiverVirtualDisplayLogicalLongEdge
        )
        let backingScale = BCConstants.defaultReceiverVirtualDisplayScale
        return ReceiverDisplaySize(
            reportedWidth: reportedWidth,
            reportedHeight: reportedHeight,
            logicalWidth: logical.width,
            logicalHeight: logical.height,
            backingWidth: logical.width * backingScale,
            backingHeight: logical.height * backingScale,
            // Capture at exactly the virtual display's backing size.
            //
            // This used to capture at the iPad's reported native pixel size,
            // which is not the size of the display being captured: with a fixed
            // 1344pt logical long edge, a 2752x2064 iPad produces a 2688x2016
            // backing store. Asking ScreenCaptureKit for 2752x2064 made it
            // resample every frame by ~2.4% before encoding — a non-integer
            // scale, so text picked up softness everywhere, and part of the
            // bitrate went into interpolated pixels.
            //
            // Capturing 1:1 keeps the encoder on real pixels. The aspect ratio is
            // unchanged, so the iPad still scales it cleanly to fill the screen.
            captureWidth: logical.width * backingScale,
            captureHeight: logical.height * backingScale
        )
    }

    private func scaledReceiverDisplaySize(width: Int, height: Int, targetLongEdge: Int) -> (width: Int, height: Int) {
        let longEdge = max(width, height)
        guard longEdge > targetLongEdge else {
            return (width, height)
        }

        let scale = Double(targetLongEdge) / Double(longEdge)
        return (
            width: roundedEvenPixelCount(Double(width) * scale),
            height: roundedEvenPixelCount(Double(height) * scale)
        )
    }

    private func roundedEvenPixelCount(_ value: Double) -> Int {
        max(2, Int((value / 2).rounded()) * 2)
    }
    
    // VideoEncoderDelegate - Send to the specific connection that owns this encoder
    private var encodedFrameCount: Int = 0

    func videoEncoder(_ encoder: VideoEncoder, didEncode data: Data, for connectionId: UUID, isKeyframe: Bool) {
        // VideoToolbox callbacks arrive on VideoEncoder's callback queue. Keep
        // every pipeline mutation on NetworkClient's main-queue owner.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self, weak encoder] in
                guard let self, let encoder else { return }
                self.videoEncoder(
                    encoder,
                    didEncode: data,
                    for: connectionId,
                    isKeyframe: isKeyframe
                )
            }
            return
        }

        guard let pipeline = pipelines[connectionId],
              pipeline.videoEncoder === encoder else { return }

        // Background grace: receiver is suspended and can't drain the socket.
        // Drop all frames (including keyframes) so nothing queues in the
        // connection; a keyframe is forced on resume.
        if pipeline.backgroundGraceStart != nil { return }

        encodedFrameCount += 1
        if encodedFrameCount <= 3 || encodedFrameCount % 300 == 0 {
            LogManager.shared.log("Sender: Sending frame #\(encodedFrameCount) (\(data.count) bytes, KF: \(isKeyframe), inFlight: \(pipeline.framesInFlight)/\(self.maxFramesInFlight(for: pipeline))) to \(pipeline.service.name)")
        }

        // Length-prefixed framing, sent to this connection only.
        var packet = Data()
        if pipeline.supportsTypeByte {
            // Format: [4-byte length][1-byte type: 0x01=video][payload]
            var typedPayload = Data([0x01])
            typedPayload.append(data)
            var lengthPrefix = UInt32(typedPayload.count).bigEndian
            packet.append(Data(bytes: &lengthPrefix, count: 4))
            packet.append(typedPayload)
        } else {
            // Legacy format: [4-byte length][payload] (iOS/Mac Swift receivers)
            var lengthPrefix = UInt32(data.count).bigEndian
            packet.append(Data(bytes: &lengthPrefix, count: 4))
            packet.append(data)
        }

        enqueueVideoPacket(packet, isKeyframe: isKeyframe, for: connectionId)
    }

    /// How many video frames may be in flight on this link at once.
    ///
    /// Before backpressure was unified across every transport, USB/Thunderbolt,
    /// peer-to-peer links ran with no completion gating at all and
    /// were the most stable paths there were. Gating them at a single frame
    /// capped throughput at one frame per round trip and produced drops on a
    /// link that was not actually congested — which then pulled the adaptive
    /// bitrate down. These links get real headroom back; the queue stays bounded
    /// so a genuinely stalled link still cannot accumulate latency.
    private func maxFramesInFlight(for pipeline: ConnectionPipeline) -> Int {
        VideoFlightWindowPolicy.maxFramesInFlight(
            isP2P: pipeline.isP2P,
            isWiredCable: pipeline.isWiredCable
        )
    }

    private func enqueueVideoPacket(_ packet: Data, isKeyframe: Bool, for connectionId: UUID) {
        guard let pipeline = pipelines[connectionId] else { return }

        if pipeline.framesInFlight >= maxFramesInFlight(for: pipeline) {
            if isKeyframe {
                if pipeline.pendingKeyframePacket != nil {
                    pipelines[connectionId]?.droppedFramesSinceAdjustment += 1
                }
                // Retain only the newest recovery point. This bounds the queue
                // while guaranteeing a keyframe follows the in-flight packet.
                pipelines[connectionId]?.pendingKeyframePacket = packet
            } else {
                pipelines[connectionId]?.droppedFramesSinceAdjustment += 1
            }
            maybeAdjustBitrate(for: connectionId)
            return
        }

        pipelines[connectionId]?.framesInFlight += 1
        bytesSentWindow += packet.count
        let connection = pipeline.connection
        let serviceName = pipeline.service.name
        let lifecycleGeneration = pipeline.lifecycleGeneration
        let startedAt = DispatchTime.now().uptimeNanoseconds

        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                self?.finishVideoSend(
                    on: connection,
                    connectionId: connectionId,
                    serviceName: serviceName,
                    lifecycleGeneration: lifecycleGeneration,
                    startedAt: startedAt,
                    error: error
                )
            }
        })
    }

    private func finishVideoSend(
        on connection: NWConnection,
        connectionId: UUID,
        serviceName: String,
        lifecycleGeneration: UInt64,
        startedAt: UInt64,
        error: NWError?
    ) {
        guard let pipeline = pipelines[connectionId],
              pipeline.connection === connection,
              pipeline.lifecycleGeneration == lifecycleGeneration else { return }

        pipelines[connectionId]?.framesInFlight = max(0, pipeline.framesInFlight - 1)

        if let error {
            pipelines[connectionId]?.pendingKeyframePacket = nil
            LogManager.shared.log("Sender: TCP send error to \(serviceName): \(error)")
            return
        }

        let elapsedNanos = DispatchTime.now().uptimeNanoseconds - startedAt
        let latency = TimeInterval(elapsedNanos) / 1_000_000_000
        let previousEWMA = pipeline.sendLatencyEWMA
        pipelines[connectionId]?.sendLatencyEWMA = previousEWMA == 0
            ? latency
            : (previousEWMA * 0.8) + (latency * 0.2)
        pipelines[connectionId]?.sentFramesSinceAdjustment += 1
        maybeAdjustBitrate(for: connectionId)

        if let pendingKeyframe = pipelines[connectionId]?.pendingKeyframePacket {
            pipelines[connectionId]?.pendingKeyframePacket = nil
            enqueueVideoPacket(pendingKeyframe, isKeyframe: true, for: connectionId)
        }
    }

    /// Frames dropped during this window after capture starts are start-up
    /// burst, not congestion: the first frames are full keyframes sent
    /// back-to-back while only one packet may be in flight, so drops are
    /// expected even on an idle link. Adapting on them dropped a 100 Mbps
    /// cable link to 80 Mbps two seconds in, with a measured latency of 0 ms.
    private static let bitrateWarmUpWindow: TimeInterval = 5.0

    private func maybeAdjustBitrate(for connectionId: UUID) {
        guard let pipeline = pipelines[connectionId],
              pipeline.currentAdaptiveBitrate > 0,
              pipeline.targetAdaptiveBitrate > 0,
              Date().timeIntervalSince(pipeline.lastBitrateAdjustment) >= 2.0 else {
            return
        }

        if Date().timeIntervalSince(pipeline.streamingStartedAt) < Self.bitrateWarmUpWindow {
            // Discard the warm-up sample instead of acting on it.
            pipelines[connectionId]?.sentFramesSinceAdjustment = 0
            pipelines[connectionId]?.droppedFramesSinceAdjustment = 0
            pipelines[connectionId]?.lastBitrateAdjustment = Date()
            return
        }

        let recommendation = AdaptiveBitratePolicy.recommendedBitrate(
            currentBitrate: pipeline.currentAdaptiveBitrate,
            targetBitrate: pipeline.targetAdaptiveBitrate,
            sendLatencyEWMA: pipeline.sendLatencyEWMA,
            sentFrames: pipeline.sentFramesSinceAdjustment,
            droppedFrames: pipeline.droppedFramesSinceAdjustment
        )

        pipelines[connectionId]?.sentFramesSinceAdjustment = 0
        pipelines[connectionId]?.droppedFramesSinceAdjustment = 0
        pipelines[connectionId]?.lastBitrateAdjustment = Date()

        guard recommendation != pipeline.currentAdaptiveBitrate else { return }
        pipelines[connectionId]?.currentAdaptiveBitrate = recommendation
        let rateLimitWindow: Double = (pipeline.isP2P || pipeline.isWiredCable) ? 0.1 : 1.0
        pipeline.videoEncoder?.updateBitrate(recommendation, rateLimitWindow: rateLimitWindow)
        LogManager.shared.log(
            "Sender: Adaptive bitrate for \(pipeline.service.name) -> \(recommendation / 1_000_000) Mbps "
                + "(latency \(Int(pipeline.sendLatencyEWMA * 1_000))ms, drops \(pipeline.droppedFramesSinceAdjustment))"
        )
    }

}

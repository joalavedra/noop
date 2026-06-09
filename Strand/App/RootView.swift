import SwiftUI
import StrandDesign

enum NavItem: String, CaseIterable, Identifiable, Hashable {
    case today = "Today"
    case intelligence = "Intelligence"
    case coach = "Coach"
    case live = "Live"
    case breathe = "Breathe"
    case intervals = "Intervals"
    case explore = "Explore"
    case compare = "Compare"
    case insights = "Insights"
    case sleep = "Sleep"
    case trends = "Trends"
    case workouts = "Workouts"
    case health = "Health"
    case stress = "Stress"
    case appleHealth = "Apple Health"
    case googleHealth = "Google Health"
    case dataSources = "Data Sources"
    case notifications = "Notifications"
    case automation = "Automations"
    case settings = "Settings"
    case support = "Support"

    var id: String { rawValue }

    /// Items shown in the sidebar. Live (BLE strap) and Stress (needs continuous
    /// R-R intervals a strap provides) are hidden while NOOP runs on imported data;
    /// the screens and the BLE engine remain in the codebase.
    static var sidebarItems: [NavItem] { allCases.filter { $0 != .live && $0 != .stress } }

    /// Localized sidebar label. Each case maps to a string literal so Xcode extracts
    /// it into the String Catalog as an English (US) base entry.
    var titleKey: LocalizedStringKey {
        switch self {
        case .today: return "Today"
        case .intelligence: return "Intelligence"
        case .coach: return "Coach"
        case .live: return "Live"
        case .breathe: return "Breathe"
        case .intervals: return "Intervals"
        case .explore: return "Explore"
        case .compare: return "Compare"
        case .insights: return "Insights"
        case .sleep: return "Sleep"
        case .trends: return "Trends"
        case .workouts: return "Workouts"
        case .health: return "Health"
        case .stress: return "Stress"
        case .appleHealth: return "Apple Health"
        case .googleHealth: return "Google Health"
        case .dataSources: return "Data Sources"
        case .notifications: return "Notifications"
        case .automation: return "Automations"
        case .settings: return "Settings"
        case .support: return "Support"
        }
    }

    var icon: String {
        switch self {
        case .today: return "circle.hexagongrid.fill"
        case .intelligence: return "brain.head.profile"
        case .coach: return "sparkles"
        case .live: return "waveform.path.ecg"
        case .breathe: return "lungs.fill"
        case .intervals: return "timer"
        case .explore: return "square.grid.2x2.fill"
        case .compare: return "chart.line.uptrend.xyaxis"
        case .insights: return "lightbulb.fill"
        case .sleep: return "moon.stars.fill"
        case .trends: return "chart.xyaxis.line"
        case .workouts: return "figure.run"
        case .health: return "heart.text.square.fill"
        case .stress: return "gauge.with.dots.needle.50percent"
        case .appleHealth: return "heart.fill"
        case .googleHealth: return "figure.run"
        case .dataSources: return "square.and.arrow.down.fill"
        case .notifications: return "bell.badge.fill"
        case .automation: return "wand.and.stars"
        case .settings: return "gearshape.fill"
        case .support: return "heart.fill"
        }
    }
}

struct RootView: View {
    // Observe only Repository (changes on data refresh, not the ~1 Hz HR/frame stream). The live
    // status pill is isolated into SidebarStatus so HR/frame ticks don't re-render the whole
    // NavigationSplitView shell + sidebar list.
    @EnvironmentObject var repo: Repository
    @State private var selection: NavItem? = .today

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(NavItem.sidebarItems, selection: $selection) { item in
                    Label(item.titleKey, systemImage: item.icon)
                        .font(.system(size: 13, weight: .medium))
                        .tag(item)
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
            .safeAreaInset(edge: .top) { brand }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
        }
        .task { await repo.refresh() }
    }

    private var brand: some View {
        HStack(spacing: 8) {
            Text("NOOP")
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .today {
        case .today: TodayView()
        case .intelligence: IntelligenceView()
        case .coach: CoachView()
        case .live: LiveView()
        case .breathe: BreathingView()
        case .intervals: IntervalTimerView()
        case .explore: MetricExplorerView()
        case .compare: CompareView()
        case .insights: InsightsView()
        case .sleep: SleepView()
        case .trends: TrendsView()
        case .workouts: WorkoutsView()
        case .health: HealthView()
        case .stress: StressView()
        case .appleHealth: AppleHealthView()
        case .googleHealth: AppleHealthView(source: "google-health", title: "Google Health")
        case .dataSources: DataSourcesView()
        case .notifications: NotificationSettingsView()
        case .automation: AutomationsView()
        case .settings: SettingsView()
        case .support: SupportView()
        }
    }
}

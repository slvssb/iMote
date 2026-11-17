import SwiftUI

enum HostSection: String, CaseIterable, Identifiable {
    case overview
    case devices
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .devices: "Devices"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "wave.3.right.circle"
        case .devices: "iphone"
        case .settings: "gearshape"
        }
    }
}

struct HostMainWindow: View {
    @ObservedObject var appState: MacAppState
    @State private var section: HostSection? = .overview

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(HostSection.allCases) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(Optional(item))
                }
            }
            .navigationTitle("iMote Host")
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            NavigationStack {
                switch section ?? .overview {
                case .overview:
                    HostOverviewView(appState: appState)
                case .devices:
                    HostDevicesView(appState: appState)
                case .settings:
                    HostSettingsView(appState: appState)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 560)
    }
}

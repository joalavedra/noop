import SwiftUI
import UniformTypeIdentifiers
import StrandDesign

struct DataSourcesView: View {
    @EnvironmentObject var model: AppModel
    @State private var showingImporter = false
    @State private var importTarget: ImportTarget = .whoop
    @State private var googleClientId = GoogleHealthKeychain.clientId ?? ""
    @State private var googleClientSecret = GoogleHealthKeychain.clientSecret ?? ""

    var body: some View {
        ScreenScaffold(title: "Data Sources",
                       subtitle: "Everything stays on this Mac. Bring your history in once, then it's yours.") {
            googleHealthCard
            appleHealthCard
        }
        // A single target-aware importer avoids SwiftUI collapsing competing importers on the same screen.
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: importTarget.allowedContentTypes,
                      allowsMultipleSelection: false) { result in
            handleImportResult(result, for: importTarget)
        }
    }

    private var appleHealthCard: some View {
        card(title: "Apple Health", icon: "heart.fill",
             subtitle: "Import an Apple Health export (Health app → profile → Export All Health Data → export.zip). 7 years of HR, HRV, sleep, SpO₂, steps and more — streamed locally. Large exports take a minute or two.") {
            let importingAppleHealth = model.isImporting(.appleHealth)
            HStack(spacing: 12) {
                Button { presentImporter(.appleHealth) } label: {
                    Label(importingAppleHealth ? "Working…" : "Choose export.zip…", systemImage: "tray.and.arrow.down")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                .disabled(model.hasActiveImport)
                if importingAppleHealth { ProgressView().controlSize(.small) }
            }
            if let s = model.appleHealthImportSummary {
                Text(s).font(StrandFont.subhead).foregroundStyle(StrandPalette.statusPositive)
            }
        }
    }

    private var googleHealthCard: some View {
        card(title: "Google Health (Fitbit)", icon: "figure.run",
             subtitle: "Connect a Google account to pull Fitbit / Pixel Watch data — heart rate, HRV, resting HR, sleep, SpO₂, respiratory rate — over the Google Health API. Sign in once in your browser; everything stays on this Mac. Needs a Google Cloud OAuth client ID + secret (Desktop type).") {
            let connecting = model.isImporting(.googleHealth)
            let hasToken = GoogleHealthKeychain.refreshToken != nil
            VStack(alignment: .leading, spacing: 8) {
                TextField("OAuth client ID", text: $googleClientId)
                    .textFieldStyle(.roundedBorder).disableAutocorrection(true)
                    .textContentType(.none)
                SecureField("OAuth client secret", text: $googleClientSecret)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: 12) {
                    Button {
                        model.connectGoogleHealth(clientId: googleClientId, clientSecret: googleClientSecret)
                    } label: {
                        Label(connecting ? "Connecting…" : (hasToken ? "Sync now" : "Connect Google Health"),
                              systemImage: hasToken ? "arrow.clockwise" : "link")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                    .disabled(model.hasActiveImport || googleClientId.isEmpty || googleClientSecret.isEmpty)
                    if connecting { ProgressView().controlSize(.small) }
                }
            }
            if let s = model.googleHealthImportSummary {
                Text(s).font(StrandFont.subhead).foregroundStyle(StrandPalette.statusPositive)
            }
        }
    }

    private func presentImporter(_ target: ImportTarget) {
        importTarget = target
        showingImporter = true
    }

    private func handleImportResult(_ result: Result<[URL], Error>, for target: ImportTarget) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        switch target {
        case .whoop:
            model.importWhoop(url: url)
        case .appleHealth:
            model.importAppleHealth(url: url)
        }
    }

    private enum ImportTarget {
        case whoop
        case appleHealth

        var allowedContentTypes: [UTType] {
            switch self {
            case .whoop:
                return [.zip, .folder]
            case .appleHealth:
                return [.zip, .xml, .folder]
            }
        }
    }
    @ViewBuilder
    private func card<C: View>(title: String, icon: String, subtitle: String,
                              @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(StrandPalette.accent)
                Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            }
            Text(subtitle).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceRaised, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(StrandPalette.hairline))
    }
}

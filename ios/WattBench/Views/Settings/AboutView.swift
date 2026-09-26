import SwiftUI

/// Version, links and the FNIRSI disclaimer, pushed from Settings.
struct AboutView: View {
    var body: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    AppIconImage()
                        .frame(width: 72, height: 72)
                        .clipShape(.rect(cornerRadius: 16, style: .continuous))
                        .accessibilityHidden(true)
                    Text("WattBench")
                        .font(.title2.weight(.semibold))
                    Text("Live power meter for the FNIRSI FNB58")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }

            Section("Version") {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("Build", value: AppInfo.build)
            }

            Section("Links") {
                ExternalLink("Privacy policy", url: AppInfo.privacyPolicyURL)
                ExternalLink("Support", url: AppInfo.supportURL)
                ExternalLink("Source code", url: AppInfo.sourceURL)
            }

            Section {
                Text(AppInfo.disclaimer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.clear)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Values from the bundle plus the fixed links shown in Settings and About.
enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }

    /// "1.1 (7)".
    static var versionSummary: String { "\(version) (\(build))" }

    static let privacyPolicyURL = URL(string: "https://github.com/RedThoroughbred/FNB58-MacOS/blob/main/PRIVACY.md")
    static let supportURL = URL(string: "https://github.com/RedThoroughbred/FNB58-MacOS/issues")
    static let sourceURL = URL(string: "https://github.com/RedThoroughbred/FNB58-MacOS")

    static let disclaimer = "WattBench is an independent project and is not affiliated with or endorsed by FNIRSI."
}

/// A row that opens a web page: primary text with a trailing arrow.up.right.
struct ExternalLink: View {
    let title: String
    let url: URL?

    init(_ title: String, url: URL?) {
        self.title = title
        self.url = url
    }

    var body: some View {
        if let url {
            Link(destination: url) {
                HStack {
                    Text(title)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(.primary)
            .accessibilityHint("Opens in Safari")
        }
    }
}

/// The app icon from the built bundle, with a symbol fallback.
private struct AppIconImage: View {
    /// The asset catalog does not expose "AppIcon" to `UIImage(named:)`; the
    /// compiled bundle lists the rendered files under CFBundleIcons.
    private static var icon: UIImage? {
        guard let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
              let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primary["CFBundleIconFiles"] as? [String],
              let name = files.last else { return nil }
        return UIImage(named: name)
    }

    var body: some View {
        if let icon = Self.icon {
            Image(uiImage: icon)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "bolt.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    NavigationStack { AboutView() }
}

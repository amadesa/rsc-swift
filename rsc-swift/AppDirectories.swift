import Foundation

/// Where the app keeps its files.
enum AppDirectories {
    /// Application Support: options.ini, worlds.cfg and the 2001 data. An
    /// app installed from a jailbreak repo (in /Applications) has no data
    /// container, so its Application Support is the one every such app
    /// shares, /var/mobile/Library/Application Support; there it gets a
    /// folder of its own.
    static let applicationSupport: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]

        guard !hasDataContainer else { return base }

        return base.appendingPathComponent(
            Bundle.main.bundleIdentifier ?? "io.github.amadesa.rscswift",
            isDirectory: true)
    }()

    /// False for an app installed outside the App Store's layout, whose home
    /// is the mobile user's own (/var/mobile) rather than a
    /// Containers/Data/Application folder.
    static var hasDataContainer: Bool {
        let home = (NSHomeDirectory() as NSString).resolvingSymlinksInPath

        return home != "/var/mobile" && home != "/private/var/mobile"
    }
}

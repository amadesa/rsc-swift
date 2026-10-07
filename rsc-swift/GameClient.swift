import Foundation
import UIKit

/// Owns the rsc-c game thread and routes its callbacks back onto the main
/// thread.
final class GameClient {
    static let shared = GameClient()

    /// Called when the game focuses a text field: (current text, is password).
    var onKeyboardRequest: ((String, Bool) -> Void)?

    /// Called when the game's focused text field goes away.
    var onHideKeyboard: (() -> Void)?

    /// Called when "Add world" is tapped on the world list.
    var onWorldRequest: (() -> Void)?

    /// Called when "Remove" is tapped: (world index, world name).
    var onRemoveWorldRequest: ((Int, String) -> Void)?

    /// Called when "Register" is tapped: (world name, registration page or
    /// nil if the world has none).
    var onRegister: ((String, URL?) -> Void)?

    private let audio = GameAudio()
    private(set) var isStarted = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid

    var isLoggedIn: Bool { rsc_is_logged_in() != 0 }

    private init() {}

    func start(width: Int, height: Int) {
        guard !isStarted else { return }
        isStarted = true

        guard let cacheDirectory = Bundle.main
            .url(forResource: "config85", withExtension: "jag")?
            .deletingLastPathComponent()
        else {
            fatalError("game cache files are missing from the app bundle")
        }

        let configDirectory = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(
            at: configDirectory, withIntermediateDirectories: true)
        excludeFromBackup(configDirectory)

        var config = RscConfig()
        config.width = Int32(width)
        config.height = Int32(height)
        config.members = 1
        config.context = Unmanaged.passUnretained(self).toOpaque()

        config.on_keyboard = { context, text, isPassword in
            let client = Unmanaged<GameClient>.fromOpaque(context!)
                .takeUnretainedValue()
            let current = text.map { String(cString: $0) } ?? ""

            DispatchQueue.main.async {
                client.onKeyboardRequest?(current, isPassword != 0)
            }
        }

        config.on_hide_keyboard = { context in
            let client = Unmanaged<GameClient>.fromOpaque(context!)
                .takeUnretainedValue()

            DispatchQueue.main.async {
                client.onHideKeyboard?()
            }
        }

        config.on_sound = { context, pcm, samples, sampleRate in
            guard let pcm = pcm, samples > 0 else { return }

            let client = Unmanaged<GameClient>.fromOpaque(context!)
                .takeUnretainedValue()
            let buffer = Array(UnsafeBufferPointer(start: pcm, count: Int(samples)))

            client.audio.play(buffer, sampleRate: Double(sampleRate))
        }

        config.on_open_url = { _, url in
            guard let url = url, let link = URL(string: String(cString: url)) else { return }

            DispatchQueue.main.async {
                UIApplication.shared.open(link)
            }
        }

        config.on_request_world = { context in
            let client = Unmanaged<GameClient>.fromOpaque(context!)
                .takeUnretainedValue()

            DispatchQueue.main.async {
                client.onWorldRequest?()
            }
        }

        config.on_request_remove_world = { context, index, name in
            let client = Unmanaged<GameClient>.fromOpaque(context!)
                .takeUnretainedValue()
            let worldName = name.map { String(cString: $0) } ?? ""

            DispatchQueue.main.async {
                client.onRemoveWorldRequest?(Int(index), worldName)
            }
        }

        config.on_register = { context, name, url in
            let client = Unmanaged<GameClient>.fromOpaque(context!)
                .takeUnretainedValue()
            let worldName = name.map { String(cString: $0) } ?? ""
            let link = url.flatMap { URL(string: String(cString: $0)) }

            DispatchQueue.main.async {
                client.onRegister?(worldName, link)
            }
        }

        // rsc_start copies the path strings before returning
        cacheDirectory.path.withCString { cachePath in
            configDirectory.path.withCString { configPath in
                config.cache_dir = cachePath
                config.config_dir = configPath
                rsc_start(&config)
            }
        }
    }

    func add(_ world: WorldConfig) {
        world.name.withCString { name in
            world.host.withCString { host in
                world.rsaExponent.withCString { exponent in
                    world.rsaModulus.withCString { modulus in
                        (world.registerURL ?? "").withCString { registerURL in
                            rsc_add_world(
                                name, host, Int32(world.port), exponent, modulus,
                                registerURL)
                        }
                    }
                }
            }
        }
    }

    func removeWorld(at index: Int) {
        rsc_remove_world(Int32(index))
    }

    /// iOS gives an app about 30 seconds of running time after it's left
    /// before suspending it. Using that keeps the connection alive for quick
    /// app switches; the server allows another 30 seconds of silence before
    /// logging the player out. After longer absences the client's automatic
    /// reconnect logs back in with the stored credentials on return.
    func enterBackground() {
        rsc_set_background(1)

        guard isLoggedIn, backgroundTask == .invalid else { return }

        backgroundTask = UIApplication.shared.beginBackgroundTask(
            withName: "Stay connected") { [weak self] in
            self?.endBackgroundTask()
        }
    }

    func enterForeground() {
        rsc_set_background(0)
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }

        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// options.ini can hold the remembered password in plain text, so keep
    /// the settings folder (options.ini and worlds.cfg) out of iCloud and
    /// computer backups. Excluding the folder covers files created later.
    private func excludeFromBackup(_ directory: URL) {
        var directory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
    }

    func resize(width: Int, height: Int) {
        rsc_resize(Int32(width), Int32(height))
    }
}

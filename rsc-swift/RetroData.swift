import CommonCrypto
import Foundation

/// The May 2001 game's data, which 2001Scape's worlds need. It isn't shipped
/// in the app: the game asks for it (on_request_retro_data) the first time
/// such a world is chosen, and it's fetched from the files of rsc.vet's 2001
/// web client, about 600 KB. Each file is checked against the copy the
/// client was tested with before the game can read it.
enum RetroData {
    static let baseURL = URL(string: "https://rsc.vet/client2/cache/")!

    static let files: [(name: String, sha256: String)] = [
        ("config17.jag", "c5ed0c8e17ee42dbb8a302e2bbd7ca16761766f0b745e5a1e9e5823cb36948c6"),
        ("media12.jag", "94675382016c138fd3956f229c07593f40e3b34a1235fa84a10f8777f08bf410"),
        ("entity3.jag", "61fdce3927e66f4893f6871e85fd5dd18253f93a32551c9aa9e2a651071bcaec"),
        ("textures5.jag", "1fb8e222bba361788176776c37a8789a44e725adc7594c2af298d31b83230ea7"),
        ("models6.jag", "f9d121af9d72e3af783c5d6badd8639679d736298d5de5df3cf999671c647b1d"),
        ("maps14.jag", "0ae6ace8443b3e6cd4d8ed8162b379f842de6885361a0617efecc88f80fb0c29"),
    ]

    /// Application Support/2001, the game's data_dir. Not backed up: it can
    /// be fetched again.
    static let directory: URL = {
        let directory = AppDirectories.applicationSupport
            .appendingPathComponent("2001", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        var excluded = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)

        // first used just before the game starts, which only checks that
        // the files are there
        removeDamagedFiles(in: directory)

        return directory
    }()

    /// Removes any file that isn't the tested copy, so it's fetched again
    /// rather than failing to load. About 600 KB to hash.
    static func removeDamagedFiles(in directory: URL) {
        for file in files {
            let url = directory.appendingPathComponent(file.name)

            guard let data = try? Data(contentsOf: url) else { continue }

            if sha256(data) != file.sha256 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Fetches the files the directory doesn't have yet, one at a time, then
    /// calls back on the main queue with whether they're all there.
    static func download(into directory: URL, completion: @escaping (Bool) -> Void) {
        // in case one changed since launch
        removeDamagedFiles(in: directory)

        let missing = files.filter {
            !FileManager.default.fileExists(
                atPath: directory.appendingPathComponent($0.name).path)
        }

        fetch(missing[...], into: directory) { success in
            DispatchQueue.main.async { completion(success) }
        }
    }

    private static func fetch(
        _ remaining: ArraySlice<(name: String, sha256: String)>, into directory: URL,
        completion: @escaping (Bool) -> Void
    ) {
        guard let file = remaining.first else {
            completion(true)
            return
        }

        let request = URLRequest(
            url: baseURL.appendingPathComponent(file.name),
            cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)

        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data = data,
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  sha256(data) == file.sha256,
                  (try? data.write(
                      to: directory.appendingPathComponent(file.name),
                      options: .atomic)) != nil
            else {
                completion(false)
                return
            }

            fetch(remaining.dropFirst(), into: directory, completion: completion)
        }.resume()
    }

    private static func sha256(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))

        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &digest)
        }

        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

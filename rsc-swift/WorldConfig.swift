import Foundation

/// A game world as the client's world list stores it.
struct WorldConfig {
    /// OpenRSC's key, used by game.openrsc.com and most self-hosted servers.
    static let openRSCModulus =
        "87cef754966ecb19806238d9fecf0f421e816976f74f365c86a584e51049794d41fefbdc5fed3a3ed3b7495ba24262bb7d1dd5d2ff9e306b5bbf5522a2e85b25"

    enum ParseError: LocalizedError {
        case missing(String)
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .missing(let key): return "The world file has no \(key)."
            case .invalid(let key): return "The world file has an invalid \(key)."
            }
        }
    }

    var name: String
    var host: String
    var port: Int
    /// Hex, 0-padded to a multiple of 8 characters as rsc-c expects.
    var rsaExponent: String
    var rsaModulus: String
    /// Account creation page opened by "Register". When nil the client
    /// falls back to its built-in links for known servers.
    var registerURL: String?

    init(name: String, host: String, port: Int, rsaExponent: String, rsaModulus: String,
         registerURL: String? = nil) {
        self.name = name
        self.host = host
        self.port = port
        self.rsaExponent = rsaExponent
        self.rsaModulus = rsaModulus
        self.registerURL = registerURL
    }

    /// Parses an rscplus world file, e.g. https://rsc.vet/worlds/01_Preservation.ini
    ///
    ///     name=RSC Preservation
    ///     url=game.openrsc.com
    ///     port=43596
    ///     rsa_pub_key=7112866275...
    ///     rsa_exponent=65537
    ///
    /// rsc-swift also reads an optional `register_url=` line.
    init(ini: String) throws {
        var values: [String: String] = [:]

        for line in ini.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";"),
                  let equals = trimmed.firstIndex(of: "=")
            else { continue }

            let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            // java properties files escape ':' and '='
            let value = trimmed[trimmed.index(after: equals)...]
                .replacingOccurrences(of: "\\:", with: ":")
                .replacingOccurrences(of: "\\=", with: "=")
                .trimmingCharacters(in: .whitespaces)

            values[key] = value
        }

        guard let host = values["url"] ?? values["host"] ?? values["server"], !host.isEmpty else {
            throw ParseError.missing("url")
        }
        guard let portText = values["port"] else { throw ParseError.missing("port") }
        guard let port = Int(portText), (1...65535).contains(port) else {
            throw ParseError.invalid("port")
        }

        let modulus = try values["rsa_pub_key"].map {
            guard let hex = Self.hexKey($0) else { throw ParseError.invalid("rsa_pub_key") }
            return hex
        } ?? Self.openRSCModulus

        let exponent = try values["rsa_exponent"].map {
            guard let hex = Self.hexKey($0) else { throw ParseError.invalid("rsa_exponent") }
            return hex
        } ?? "00010001"

        var registerURL = values["register_url"] ?? values["register"]
        if let url = registerURL, !url.isEmpty {
            // the world list file is whitespace separated
            guard !url.contains(where: \.isWhitespace), url.count < 256 else {
                throw ParseError.invalid("register_url")
            }
            if !url.contains("://") {
                registerURL = "https://" + url
            }
        } else {
            registerURL = nil
        }

        self.init(
            name: values["name"].flatMap { $0.isEmpty ? nil : $0 } ?? host,
            host: Self.stripScheme(host), port: port,
            rsaExponent: exponent, rsaModulus: modulus,
            registerURL: registerURL)
    }

    /// Accepts "game.example.com" or "https://game.example.com/".
    static func stripScheme(_ host: String) -> String {
        var host = host
        if let range = host.range(of: "://") {
            host = String(host[range.upperBound...])
        }
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }

    /// Converts an RSA value to padded lowercase hex. rscplus files use
    /// decimal; a "0x" prefix or any a-f digit is treated as hex already.
    static func hexKey(_ text: String) -> String? {
        var text = text.trimmingCharacters(in: .whitespaces).lowercased()
        let isHex = text.hasPrefix("0x") || text.contains { "abcdef".contains($0) }

        if text.hasPrefix("0x") {
            text.removeFirst(2)
        }

        guard !text.isEmpty else { return nil }

        var hex: String
        if isHex {
            guard text.allSatisfy(\.isHexDigit) else { return nil }
            hex = text
        } else {
            guard let converted = decimalToHex(text) else { return nil }
            hex = converted
        }

        while hex.count > 1 && hex.hasPrefix("0") {
            hex.removeFirst()
        }

        let padding = (8 - hex.count % 8) % 8
        return String(repeating: "0", count: padding) + hex
    }

    private static func decimalToHex(_ decimal: String) -> String? {
        // little-endian base 256 digits
        var bytes: [UInt8] = [0]

        for character in decimal {
            guard let digit = character.wholeNumberValue, character.isASCII else { return nil }

            var carry = digit
            for i in bytes.indices {
                let value = Int(bytes[i]) * 10 + carry
                bytes[i] = UInt8(value & 0xff)
                carry = value >> 8
            }
            while carry > 0 {
                bytes.append(UInt8(carry & 0xff))
                carry >>= 8
            }
        }

        return bytes.reversed().map { String(format: "%02x", $0) }.joined()
    }
}

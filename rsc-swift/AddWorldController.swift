import MobileCoreServices
import UIKit

/// Shown when "Add world" is tapped on the login screen's world list.
final class AddWorldController: NSObject {
    private weak var presenter: UIViewController?
    private let onAdd: (WorldConfig) -> Void

    init(presenter: UIViewController, onAdd: @escaping (WorldConfig) -> Void) {
        self.presenter = presenter
        self.onAdd = onAdd
    }

    func present() {
        guard let presenter = presenter else { return }

        let sheet = UIAlertController(
            title: "Add world",
            message: "Import an rscplus world .ini (like rsc.vet/worlds/01_Preservation.ini) or enter a server yourself.",
            preferredStyle: .actionSheet)

        sheet.addAction(UIAlertAction(title: "Import .ini file", style: .default) { [self] _ in
            pickFile()
        })
        sheet.addAction(UIAlertAction(title: "Download .ini from URL", style: .default) { [self] _ in
            askForURL()
        })
        sheet.addAction(UIAlertAction(title: "Enter manually", style: .default) { [self] _ in
            askForDetails()
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))

        // iPad shows action sheets as popovers
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(
                x: presenter.view.bounds.midX, y: presenter.view.bounds.midY,
                width: 0, height: 0)
            popover.permittedArrowDirections = []
        }

        presenter.present(sheet, animated: true)
    }

    // MARK: - Sources

    private func pickFile() {
        let picker = UIDocumentPickerViewController(
            documentTypes: [kUTTypeItem as String], in: .import)
        picker.delegate = self
        presenter?.present(picker, animated: true)
    }

    private func askForURL() {
        let alert = UIAlertController(
            title: "Download world", message: "Link to a world .ini file.",
            preferredStyle: .alert)

        alert.addTextField { field in
            field.placeholder = "https://example.com/world.ini"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Download", style: .default) { [self] _ in
            let text = alert.textFields?[0].text?.trimmingCharacters(in: .whitespaces) ?? ""

            guard let url = URL(string: text.contains("://") ? text : "https://" + text) else {
                showError("That isn't a valid link.")
                return
            }

            download(url)
        })

        presenter?.present(alert, animated: true)
    }

    private func askForDetails() {
        let alert = UIAlertController(
            title: "Enter world",
            message: "Leave the RSA key empty to use OpenRSC's (works for OpenRSC worlds like Uranium on port 43235).",
            preferredStyle: .alert)

        let fields: [(String, UIKeyboardType)] = [
            ("Name", .default),
            ("Host, e.g. game.openrsc.com", .URL),
            ("Port, e.g. 43596", .numberPad),
            ("RSA modulus (optional, decimal or hex)", .asciiCapable),
            ("Registration page (optional)", .URL),
        ]

        for (placeholder, keyboard) in fields {
            alert.addTextField { field in
                field.placeholder = placeholder
                field.keyboardType = keyboard
                field.autocapitalizationType = .none
                field.autocorrectionType = .no
            }
        }

        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [self] _ in
            let values = (alert.textFields ?? []).map {
                $0.text?.trimmingCharacters(in: .whitespaces) ?? ""
            }

            var ini = "url=\(values[1])\nport=\(values[2])\n"
            if !values[0].isEmpty { ini += "name=\(values[0])\n" }
            if !values[3].isEmpty { ini += "rsa_pub_key=\(values[3])\n" }
            if !values[4].isEmpty { ini += "register_url=\(values[4])\n" }

            add(ini: ini)
        })

        presenter?.present(alert, animated: true)
    }

    private func download(_ url: URL) {
        URLSession.shared.dataTask(with: url) { [self] data, response, error in
            DispatchQueue.main.async { [self] in
                if let error = error {
                    showError(error.localizedDescription)
                } else if let status = (response as? HTTPURLResponse)?.statusCode,
                          !(200..<300).contains(status) {
                    showError("The server responded with HTTP \(status).")
                } else {
                    add(ini: data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                }
            }
        }.resume()
    }

    // MARK: - Result

    private func add(ini: String) {
        do {
            let world = try WorldConfig(ini: ini)
            onAdd(world)

            let alert = UIAlertController(
                title: "Added \(world.name)",
                message: "\(world.host):\(world.port) is now selected.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            presenter?.present(alert, animated: true)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(
            title: "Couldn't add world", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        presenter?.present(alert, animated: true)
    }
}

extension AddWorldController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }

        guard let ini = try? String(contentsOf: url, encoding: .utf8) else {
            showError("That file couldn't be read as text.")
            return
        }

        add(ini: ini)
    }
}

import SafariServices
import SwiftUI

struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

struct IdentifiedURL: Identifiable {
    let id: String
    let url: URL
}

extension IdentifiedURL {
    init?(_ string: String) {
        if let url = URL(string: string).map({ Self(id: string, url: $0) }) {
            self = url
        } else {
            return nil
        }
    }
}

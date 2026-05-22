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
        guard let url = URL(string: string) else { return nil }
        self = Self(id: string, url: url)
    }
}

import Foundation

/// Checks GitHub for a newer Coast release shortly after launch and then about once a day. When it
/// finds one it calls `found` on the main thread; the menu then offers it. Nothing is downloaded or
/// installed: the item opens the release page.
final class UpdateChecker {
    private static let latest = URL(string: "https://api.github.com/repos/seastwood/coast/releases/latest")!
    private let found: (_ version: String, _ page: URL) -> Void
    private var timer: Timer?

    init(found: @escaping (_ version: String, _ page: URL) -> Void) { self.found = found }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.check() }
        let t = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in self?.check() }
        t.tolerance = 60 * 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func check() {
        guard appVersion != "dev" else { return }   // unbundled development runs have no version
        var request = URLRequest(url: Self.latest, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let self, let data,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else {
                if let error { log("update check failed: \(error.localizedDescription)") }
                return
            }
            // Releases are tagged "Coast<version>" (Coast1.4, Coast2.0).
            let version = String(tag.drop { !$0.isNumber })
            log("update check: latest \(tag), running \(appVersion)")
            if Self.isNewer(version, than: appVersion) {
                DispatchQueue.main.async { self.found(version, page) }
            }
        }.resume()
    }

    /// Compares dotted version numbers: 2.1 > 2.0.9, 2.0 == 2.0.0.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }
}

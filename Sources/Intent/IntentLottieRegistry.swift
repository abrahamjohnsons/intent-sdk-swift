import Foundation

/// Curated Lottie animation library — mirrors apps/web/src/lib/lottie-registry.ts.
/// AI references animations by name; this resolves the name to a CDN URL.
/// Update URLs here without touching any AI prompts.
enum IntentLottieRegistry {

    private static let registry: [String: String] = [
        "confetti":      "https://assets9.lottiefiles.com/packages/lf20_touohxv0.json",
        "checkmark":     "https://assets1.lottiefiles.com/packages/lf20_lkzqdlt5.json",
        "loading_dots":  "https://assets4.lottiefiles.com/packages/lf20_qwl7qipb.json",
        "rocket":        "https://assets5.lottiefiles.com/packages/lf20_ydmNHH.json",
        "stars":         "https://assets3.lottiefiles.com/packages/lf20_xlmz9xwm.json",
        "celebration":   "https://assets2.lottiefiles.com/packages/lf20_obhph8js.json",
        "heart_pulse":   "https://assets2.lottiefiles.com/packages/lf20_ydHob8.json",
        "meditation":    "https://assets1.lottiefiles.com/packages/lf20_9cyyl9dg.json",
        "trophy":        "https://assets3.lottiefiles.com/packages/lf20_achjq6as.json",
        "coins":         "https://assets4.lottiefiles.com/packages/lf20_06a6pf9i.json",
        "progress_fill": "https://assets2.lottiefiles.com/packages/lf20_2cwDXD.json",
        "brain":         "https://assets8.lottiefiles.com/packages/lf20_hntzYU.json",
    ]

    /// Resolve a name like "confetti" or a full https:// URL to a URL.
    /// Returns nil if the input is empty or unresolvable.
    static func resolve(_ nameOrURL: String) -> URL? {
        guard !nameOrURL.isEmpty else { return nil }
        if nameOrURL.hasPrefix("http") { return URL(string: nameOrURL) }
        if let urlString = registry[nameOrURL] { return URL(string: urlString) }
        return nil
    }
}

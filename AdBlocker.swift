import WebKit

/// A lightweight ad/tracker blocker for the in-app game web views.
///
/// Compiles a WKContentRuleList once and caches it. The rules block network
/// loads to well-known ad, analytics and pop-under hosts, and hide a few common
/// ad container elements — enough to stop the noisy banners and redirect
/// pop-ups that flash-game sites are riddled with, without a full filter list.
enum AdBlocker {
    private static var cached: WKContentRuleList?

    /// Host substrings blocked outright. Kept deliberately conservative so it
    /// never blocks a game's own CDN.
    private static let blockedHosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com",
        "google-analytics.com", "googletagmanager.com", "googletagservices.com",
        "adservice.google.com", "pagead2.googlesyndication.com",
        "amazon-adsystem.com", "adnxs.com", "adsrvr.org", "rubiconproject.com",
        "pubmatic.com", "openx.net", "criteo.com", "taboola.com", "outbrain.com",
        "media.net", "propellerads.com", "popads.net", "popcash.net",
        "adsterra.com", "hilltopads.net", "onclickalgo.com", "onclckds.com",
        "exoclick.com", "juicyads.com", "trafficjunky.net", "revcontent.com",
        "mgid.com", "adcash.com", "smartadserver.com", "yllix.com",
        "clicksgear.com", "clickadu.com", "admaven.com", "monetag.com",
        "facebook.net", "connect.facebook.net", "scorecardresearch.com",
        "quantserve.com", "moatads.com", "zedo.com", "adform.net"
    ]

    private static var ruleJSON: String {
        let urlRules = blockedHosts.map { host -> [String: Any] in
            [
                "trigger": ["url-filter": "https?://([^/]*\\.)?\(NSRegularExpression.escapedPattern(for: host))"],
                "action": ["type": "block"]
            ]
        }
        // Hide common ad containers by class/id.
        let cosmetic: [String: Any] = [
            "trigger": ["url-filter": ".*"],
            "action": ["type": "css-display-none",
                       "selector": ".adsbygoogle, ins.adsbygoogle, .ad, .ads, .adsbox, .ad-container, [id^=ad-], [class*=banner-ad]"]
        ]
        let all = urlRules + [cosmetic]
        let data = try? JSONSerialization.data(withJSONObject: all)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    /// Compiles (or returns cached) rules, applies them to `config`, then calls
    /// `then` — so the caller can load content only once the blocker is active.
    @MainActor
    static func apply(to config: WKWebViewConfiguration, then: @escaping () -> Void) {
        if let cached {
            config.userContentController.add(cached)
            then()
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "livewall-adblock", encodedContentRuleList: ruleJSON) { list, _ in
            if let list { cached = list; config.userContentController.add(list) }
            then()   // load even if compilation somehow fails, just without blocking
        }
    }
}

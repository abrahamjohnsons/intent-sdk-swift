import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Main entry point for the Intent SDK.
///
/// Setup (AppDelegate or @main):
///   Intent.configure(projectId: "your-project-id", sdkKey: "your-sdk-key")
///
/// Trigger a flow:
///   if let flow = await Intent.shared.flow(type: .onboarding) {
///       let vc = IntentFlowViewController(flow: flow, onComplete: { ... })
///       present(vc, animated: true)
///   }
public final class Intent {

    // MARK: - Singleton

    public static let shared = Intent()
    private init() {}

    // MARK: - Configuration

    private var config: IntentConfig?
    private var cachedConfig: SDKConfig?
    private var fetchTask: Task<SDKConfig?, Never>?
    private var userAttributes: [String: Any] = [:]
    private var sessionId = UUID().uuidString

    /// Configure the Intent SDK at app launch.
    ///
    /// - Parameters:
    ///   - projectId: Your Intent project ID.
    ///   - sdkKey: Your Intent SDK key.
    ///   - userId: A stable identifier for the current user (default: "anonymous").
    ///   - acquisitionChannel: How this user was acquired — drives campaign personalization.
    ///     Paid users get urgency-heavy copy; organic users get value-heavy copy.
    ///     Use `IntentAcquisitionChannel` constants or pass a raw string.
    ///     Combine with `Intent.resolveAttribution()` for automatic attribution.
    ///   - source: Legacy alias for `acquisitionChannel`. Prefer `acquisitionChannel`.
    ///   - apiBaseURL: Override the Intent API base URL (advanced).
    ///   - debug: Enable verbose logging.
    ///
    /// ```swift
    /// // Recommended: resolve attribution then configure
    /// let channel = await Intent.resolveAttribution(projectId: "...", sdkKey: "...")
    /// Intent.configure(
    ///     projectId: "YOUR_PROJECT_ID",
    ///     sdkKey: "YOUR_SDK_KEY",
    ///     acquisitionChannel: channel ?? IntentAcquisitionChannel.organic.rawValue
    /// )
    /// ```
    public static func configure(
        projectId: String,
        sdkKey: String,
        userId: String = "anonymous",
        acquisitionChannel: String? = nil,
        source: String? = nil,
        apiBaseURL: String = "https://useintent.vercel.app",
        debug: Bool = false
    ) {
        shared.config = IntentConfig(
            projectId: projectId,
            sdkKey: sdkKey,
            userId: userId,
            apiBaseURL: apiBaseURL,
            debug: debug,
            acquisitionChannel: acquisitionChannel,
            source: source
        )
        // Prefetch in background
        Task { await shared.fetchSDKConfig() }
    }

    /// Convenience overload accepting a typed `IntentAcquisitionChannel`.
    public static func configure(
        projectId: String,
        sdkKey: String,
        userId: String = "anonymous",
        acquisitionChannel: IntentAcquisitionChannel,
        apiBaseURL: String = "https://useintent.vercel.app",
        debug: Bool = false
    ) {
        configure(
            projectId: projectId,
            sdkKey: sdkKey,
            userId: userId,
            acquisitionChannel: acquisitionChannel.rawValue,
            apiBaseURL: apiBaseURL,
            debug: debug
        )
    }

    // MARK: - Attribution

    /// Resolves the acquisition source from an Intent tracking link click.
    ///
    /// Call this **before** `configure()` on first launch. It checks whether
    /// the user clicked an Intent tracking link (e.g. in a TikTok ad) and
    /// returns the matched source. The result is cached in UserDefaults so
    /// subsequent launches skip the network call.
    ///
    /// Returns nil if no tracking link click was found within the 24h window.
    /// Treat nil as organic.
    ///
    /// ```swift
    /// let source = await Intent.resolveAttribution(
    ///     projectId: "YOUR_PROJECT_ID",
    ///     sdkKey:    "YOUR_SDK_KEY"
    /// )
    /// Intent.configure(
    ///     projectId: "YOUR_PROJECT_ID",
    ///     sdkKey:    "YOUR_SDK_KEY",
    ///     source:    source ?? "organic"
    /// )
    /// ```
    public static func resolveAttribution(
        projectId: String,
        sdkKey: String,
        apiBaseURL: String = "https://useintent.vercel.app"
    ) async -> String? {
        let cacheKey = "intent_attribution_\(projectId)"

        // Return persisted result from previous launch — avoids double-matching
        if let cached = UserDefaults.standard.string(forKey: cacheKey) {
            return cached.isEmpty ? nil : cached
        }

        guard let url = URL(string: "\(apiBaseURL)/api/sdk/\(projectId)/attribution") else {
            return nil
        }

        var request = URLRequest(url: url)
        request.setValue(sdkKey, forHTTPHeaderField: "x-sdk-key")
        request.timeoutInterval = 5

        struct AttributionResponse: Decodable { let source: String? }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let decoded = try JSONDecoder().decode(AttributionResponse.self, from: data)
            // Persist: empty string means "checked but no match", non-empty is the source
            UserDefaults.standard.set(decoded.source ?? "", forKey: cacheKey)
            return decoded.source
        } catch {
            return nil
        }
    }

    // MARK: - Flow access

    /// Returns the active published flow for the given type, or nil if none published.
    public func flow(type flowType: FlowType) async -> IntentFlow? {
        let config = await fetchSDKConfig()
        return config?.flows.first(where: { $0.type == flowType.rawValue })
    }

    /// Returns a flow by its ID.
    public func flow(id flowId: String) async -> IntentFlow? {
        let config = await fetchSDKConfig()
        return config?.flows.first(where: { $0.id == flowId })
    }

    // MARK: - Campaign registration

    /// Fire a placement event. Intent evaluates all active campaigns that include
    /// this event, picks the highest-priority match, respects the holdout group,
    /// and presents the associated flow automatically.
    ///
    /// ```swift
    /// // UIKit
    /// Intent.shared.register(event: "app_opened", from: self)
    ///
    /// // SwiftUI — use evaluate() instead:
    /// let flow = await Intent.shared.evaluate(event: "feature_tapped")
    /// ```
    #if canImport(UIKit)
    @MainActor
    public func register(event eventName: String, from viewController: UIViewController) {
        Task { @MainActor in
            guard let flow = await evaluate(event: eventName) else {
                log("No matching campaign for event '\(eventName)'")
                return
            }
            let vc = IntentFlowViewController(flow: flow, onComplete: nil)
            viewController.present(vc, animated: true)
            log("Campaign matched '\(eventName)' → presenting flow '\(flow.name)'")
        }
    }
    #endif

    /// Evaluate campaigns for the given event and return the flow to present,
    /// or nil if no campaign matches (or the user is in a holdout group).
    /// Use this in SwiftUI where you present views declaratively.
    public func evaluate(event eventName: String) async -> IntentFlow? {
        guard let sdkConfig = await fetchSDKConfig() else { return nil }

        let ctx = buildUserContext()

        // Campaigns are already sorted by priority desc from the server
        for campaign in sdkConfig.campaigns where campaign.placements.contains(eventName) {
            guard matchesAudience(campaign.audience, ctx: ctx) else { continue }

            // Holdout check — deterministically bucket user so it's stable across calls
            if campaign.holdoutPercentage > 0 {
                let bucketInput = "\(config?.userId ?? "anon")-\(campaign.id)"
                let bucket = abs(bucketInput.hashValue) % 100
                if bucket < campaign.holdoutPercentage {
                    log("User in holdout group for campaign '\(campaign.name)'")
                    return nil
                }
            }

            guard let flowId = campaign.flowId else { continue }
            return sdkConfig.flows.first(where: { $0.id == flowId })
        }
        return nil
    }

    // MARK: - Audience evaluation (client-side mirror of server logic)

    private func buildUserContext() -> [String: String] {
        var ctx: [String: String] = [
            "platform":    "ios",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "user_id":     config?.userId ?? "",
        ]
        // Propagate acquisition channel so campaign audience rules can match on it.
        // acquisitionChannel takes precedence over the legacy `source` field.
        if let channel = config?.resolvedChannel {
            ctx["source"] = channel
            ctx["acquisition_channel"] = channel
            // Convenience: "paid_social" and "paid_search" also match the generic "paid" bucket
            if channel.hasPrefix("paid") {
                ctx["acquisition_type"] = "paid"
            } else {
                ctx["acquisition_type"] = "organic"
            }
        }
        // Merge typed user attributes
        for (k, v) in userAttributes {
            ctx[k] = "\(v)"
        }
        // Expose subscription status
        switch subscriptionStatus {
        case .active:   ctx["subscription_status"] = "active"
        case .inactive: ctx["subscription_status"] = "inactive"
        default:        ctx["subscription_status"] = "unknown"
        }
        return ctx
    }

    private func matchesAudience(_ audience: CampaignAudience?, ctx: [String: String]) -> Bool {
        guard let audience = audience, !audience.rules.isEmpty else { return true }
        let results = audience.rules.map { evaluateCampaignRule($0, ctx: ctx) }
        return audience.logic == "or" ? results.contains(true) : results.allSatisfy { $0 }
    }

    private func evaluateCampaignRule(_ rule: CampaignRule, ctx: [String: String]) -> Bool {
        let actual = ctx[rule.attribute] ?? ""
        let expected = rule.value
        switch rule.operator {
        case "equals":     return actual == expected
        case "not_equals": return actual != expected
        case "contains":   return actual.lowercased().contains(expected.lowercased())
        case "gte":        return actual >= expected
        case "lte":        return actual <= expected
        case "in":
            let list = expected.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return list.contains(actual)
        case "not_in":
            let list = expected.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return !list.contains(actual)
        default:           return true
        }
    }

    // MARK: - Fetching

    @discardableResult
    private func fetchSDKConfig() async -> SDKConfig? {
        guard let cfg = config else {
            log("Intent not configured. Call Intent.configure() first.")
            return cachedConfig
        }

        if let cached = cachedConfig { return cached }

        var components = URLComponents(string: "\(cfg.apiBaseURL)/api/sdk/\(cfg.projectId)")!
        var queryItems = [
            URLQueryItem(name: "userId", value: cfg.userId),
            URLQueryItem(name: "platform", value: "ios"),
            URLQueryItem(name: "appVersion", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"),
        ]
        if let channel = cfg.resolvedChannel {
            queryItems.append(URLQueryItem(name: "source", value: channel))
            queryItems.append(URLQueryItem(name: "acquisitionChannel", value: channel))
        }
        components.queryItems = queryItems

        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue(cfg.sdkKey, forHTTPHeaderField: "x-sdk-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let channel = cfg.resolvedChannel {
            request.setValue(channel, forHTTPHeaderField: "x-intent-source")
            request.setValue(channel, forHTTPHeaderField: "x-intent-acquisition-channel")
        }
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                log("SDK config fetch failed: \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            let sdkConfig = try JSONDecoder().decode(SDKConfig.self, from: data)
            cachedConfig = sdkConfig
            log("Fetched \(sdkConfig.flows.count) active flows")
            return sdkConfig
        } catch {
            log("SDK config error: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Event tracking

    public func track(event: IntentEvent) {
        guard let cfg = config else { return }
        Task {
            var enriched = event
            enriched.userId = cfg.userId
            enriched.sessionId = sessionId
            enriched.timestamp = Int64(Date().timeIntervalSince1970 * 1000)

            var request = URLRequest(url: URL(string: "\(cfg.apiBaseURL)/api/sdk/\(cfg.projectId)")!)
            request.httpMethod = "POST"
            request.setValue(cfg.sdkKey, forHTTPHeaderField: "x-sdk-key")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONEncoder().encode(["events": [enriched]])
            _ = try? await URLSession.shared.data(for: request)
        }
    }

    public func trackScreenView(screenId: String, flowId: String) {
        track(event: IntentEvent(
            eventType: "screen_view",
            eventName: "screen_viewed",
            flowId: flowId,
            screenId: screenId
        ))
    }

    public func trackScreenComplete(screenId: String, flowId: String) {
        track(event: IntentEvent(
            eventType: "screen_complete",
            eventName: "screen_completed",
            flowId: flowId,
            screenId: screenId
        ))
    }

    public func trackCTATap(flowId: String, screenId: String? = nil, properties: [String: AnyCodable]? = nil) {
        track(event: IntentEvent(
            eventType: "cta_tap",
            eventName: "cta_tapped",
            flowId: flowId,
            screenId: screenId,
            properties: properties
        ))
    }

    public func trackPurchaseStarted(flowId: String, screenId: String? = nil, properties: [String: AnyCodable]? = nil) {
        track(event: IntentEvent(
            eventType: "purchase_started",
            eventName: "purchase_started",
            flowId: flowId,
            screenId: screenId,
            properties: properties
        ))
    }

    public func trackFlowStart(flowId: String) {
        track(event: IntentEvent(
            eventType: "flow_start",
            eventName: "flow_started",
            flowId: flowId
        ))
    }

    public func trackFlowPresented(flowId: String) {
        track(event: IntentEvent(
            eventType: "flow_presented",
            eventName: "flow_presented",
            flowId: flowId
        ))
    }

    public func trackFlowComplete(flowId: String) {
        track(event: IntentEvent(
            eventType: "flow_complete",
            eventName: "flow_completed",
            flowId: flowId
        ))
    }

    // MARK: - Revenue attribution

    /// Reports a verified StoreKit purchase to Intent for flow/screen attribution.
    /// Called automatically by IntentPurchaseManager — no need to call this directly.
    func reportPurchase(
        productId: String,
        transactionId: String,
        flowId: String,
        screenId: String?,
        price: Double,
        currency: String
    ) async {
        guard let cfg = config else { return }

        // Fire the standard event pipeline (analytics, experiments)
        track(event: IntentEvent(
            eventType: "purchase",
            eventName: "purchase_completed",
            flowId: flowId,
            screenId: screenId,
            properties: [
                "product_id":     AnyCodable(productId),
                "transaction_id": AnyCodable(transactionId),
                "price":          AnyCodable(price),
                "currency":       AnyCodable(currency),
                "platform":       AnyCodable("ios"),
            ]
        ))

        // Also hit the dedicated purchase endpoint for richer revenue attribution
        guard let url = URL(string: "\(cfg.apiBaseURL)/api/sdk/\(cfg.projectId)/purchase") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(cfg.sdkKey, forHTTPHeaderField: "x-sdk-key")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "productId":     productId,
            "transactionId": transactionId,
            "flowId":        flowId,
            "screenId":      screenId as Any,
            "price":         price,
            "currency":      currency,
            "userId":        cfg.userId,
            "platform":      "ios",
            "timestamp":     Int64(Date().timeIntervalSince1970 * 1000),
        ])
        _ = try? await URLSession.shared.data(for: req)
        log("Purchase reported: \(productId) (flow: \(flowId), $\(price) \(currency))")
    }

    // MARK: - Identity

    /// Associate the current user and set attributes. Call after sign-in.
    ///
    /// ```swift
    /// Intent.identify(userId: user.id, attributes: ["plan": "free", "source": "tiktok"])
    /// ```
    public static func identify(userId: String, attributes: [String: Any] = [:]) {
        shared.config = shared.config.map { config in
            IntentConfig(
                projectId: config.projectId,
                sdkKey: config.sdkKey,
                userId: userId,
                apiBaseURL: config.apiBaseURL,
                debug: config.debug,
                acquisitionChannel: config.acquisitionChannel,
                source: config.source
            )
        }
        shared.userAttributes.merge(attributes) { _, new in new }
        // Invalidate cache so next fetch picks up the new userId
        shared.cachedConfig = nil
    }

    /// Merge additional attributes into the current user profile without
    /// resetting the user identity.
    ///
    /// ```swift
    /// Intent.setUserAttributes(["plan": "pro", "trialing": true])
    /// ```
    public static func setUserAttributes(_ attributes: [String: Any]) {
        shared.userAttributes.merge(attributes) { _, new in new }
    }

    /// The user's current subscription status. Set this after verifying a
    /// purchase so personalization rules can target subscribers.
    ///
    /// ```swift
    /// Intent.shared.subscriptionStatus = .active(productId: "com.app.pro_monthly")
    /// ```
    public var subscriptionStatus: IntentSubscriptionStatus = .unknown

    // MARK: - Entitlement restore

    /// Checks current App Store entitlements and auto-sets `subscriptionStatus`.
    /// Call this at app launch (after `Intent.configure`) so returning subscribers
    /// never see the paywall again without triggering an App Store prompt.
    ///
    /// Returns `true` if the user has an active subscription.
    ///
    /// ```swift
    /// // AppDelegate / @main
    /// let isSubscribed = await Intent.restoreEntitlements()
    /// if isSubscribed {
    ///     showMainApp()
    /// } else {
    ///     showOnboarding()
    /// }
    /// ```
    @discardableResult
    public static func restoreEntitlements() async -> Bool {
        guard #available(iOS 15, *) else { return false }
        let active = await IntentPurchaseManager.shared.currentEntitlements()
        if let first = active.first {
            shared.subscriptionStatus = .active(productId: first)
            return true
        }
        shared.subscriptionStatus = .inactive
        return false
    }

    // MARK: - Reset

    /// Clear user identity and attributes on sign-out.
    public static func reset() {
        shared.config = shared.config.map { config in
            IntentConfig(
                projectId: config.projectId,
                sdkKey: config.sdkKey,
                userId: "anonymous",
                apiBaseURL: config.apiBaseURL,
                debug: config.debug,
                acquisitionChannel: config.acquisitionChannel,
                source: config.source
            )
        }
        shared.userAttributes = [:]
        shared.subscriptionStatus = .unknown
        shared.cachedConfig = nil
        shared.sessionId = UUID().uuidString
    }

    // MARK: - Utilities

    private func log(_ message: String) {
        if config?.debug == true {
            print("[Intent] \(message)")
        }
    }
}

// MARK: - Config

struct IntentConfig {
    let projectId: String
    let sdkKey: String
    let userId: String
    let apiBaseURL: String
    let debug: Bool
    /// Preferred acquisition channel (e.g. "paid_social", "organic"). Used for audience rule evaluation.
    let acquisitionChannel: String?
    /// Legacy alias — maps to acquisitionChannel if acquisitionChannel is nil.
    let source: String?

    /// The resolved channel string: acquisitionChannel takes precedence over source.
    var resolvedChannel: String? { acquisitionChannel ?? source }
}

// MARK: - Flow type enum

public enum FlowType: String {
    case onboarding
    case paywall
    case survey
    case upsell
    case custom
}

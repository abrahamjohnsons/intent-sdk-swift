import Foundation

// MARK: - Subscription Status

/// The user's current subscription state. Set via `Intent.shared.subscriptionStatus`.
public enum IntentSubscriptionStatus {
    /// No active subscription.
    case inactive
    /// Active subscription with an optional product identifier.
    case active(productId: String?)
    /// Not yet determined (default).
    case unknown

    public var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

// MARK: - SDK API Response

struct SDKConfig: Codable {
    let projectId: String
    let flows: [IntentFlow]
    let campaigns: [IntentCampaign]
    let fetchedAt: String?
}

// MARK: - Campaign

public struct IntentCampaign: Codable {
    public let id: String
    public let name: String
    public let placements: [String]
    public let flowId: String?
    public let audience: CampaignAudience?
    public let priority: Int
    public let holdoutPercentage: Int

    enum CodingKeys: String, CodingKey {
        case id, name, placements, audience, priority
        case flowId             = "flow_id"
        case holdoutPercentage  = "holdout_percentage"
    }
}

public struct CampaignAudience: Codable {
    public let logic: String
    public let rules: [CampaignRule]
}

public struct CampaignRule: Codable {
    public let id: String
    public let attribute: String
    public let `operator`: String
    public let value: String
}

// MARK: - Flow

public struct IntentFlow: Codable {
    public let id: String
    public let name: String
    public let type: String
    public let status: String
    public let schema: FlowSchema
}

// MARK: - Flow Schema

public struct FlowSchema: Codable {
    public let version: String?
    public let id: String?
    public let type: String?
    public let name: String?
    public let screens: [FlowScreen]
    public let theme: FlowTheme?
    public let settings: FlowSettings?
}

// MARK: - Screen

public struct FlowScreen: Codable {
    public let id: String
    public let type: String
    public let name: String
    public let layout: String?
    public let components: [FlowComponent]
    public let actions: [FlowAction]?
    public let metadata: ScreenMetadata?
}

// MARK: - Component

public struct FlowComponent: Codable {
    public let id: String
    public let type: String
    public let props: [String: AnyCodable]
}

// MARK: - Action

public struct FlowAction: Codable {
    public let id: String
    public let trigger: String
    public let type: String
    public let target: String?
}

// MARK: - Screen metadata (quiz)

public struct ScreenMetadata: Codable {
    public let quizKey: String?
    public let quizOptions: [QuizOption]?
    public let multiSelect: Bool?
}

public struct QuizOption: Codable {
    public let id: String
    public let label: String
    public let value: String
    public let icon: String?
    public let description: String?
}

// MARK: - Theme

public struct FlowTheme: Codable {
    public let background: String?
    public let backgroundGradient: String?
    public let foreground: String?
    public let primary: String?
    public let primaryForeground: String?
    public let secondary: String?
    public let accent: String?
    public let radius: CGFloat?
}

// MARK: - Settings

public struct FlowSettings: Codable {
    public let canSkip: Bool?
    public let showProgress: Bool?
    public let progressStyle: String?
    public let exitBehavior: String?
}

// MARK: - Event

public struct IntentEvent: Codable {
    public let eventType: String
    public let eventName: String
    public var userId: String?
    public var sessionId: String?
    public var timestamp: Int64?
    public let flowId: String?
    public let screenId: String?
    public let experimentId: String?
    public let variantId: String?
    public var properties: [String: AnyCodable]?

    public init(
        eventType: String,
        eventName: String,
        userId: String? = nil,
        sessionId: String? = nil,
        timestamp: Int64? = nil,
        flowId: String? = nil,
        screenId: String? = nil,
        experimentId: String? = nil,
        variantId: String? = nil,
        properties: [String: AnyCodable]? = nil
    ) {
        self.eventType = eventType
        self.eventName = eventName
        self.userId = userId
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.flowId = flowId
        self.screenId = screenId
        self.experimentId = experimentId
        self.variantId = variantId
        self.properties = properties
    }
}

// MARK: - AnyCodable (for dynamic component props)

public struct AnyCodable: Codable {
    public let value: Any?

    public init(_ value: Any?) { self.value = value }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = nil }
        else if let v = try? container.decode(Bool.self) { value = v }
        else if let v = try? container.decode(Int.self) { value = v }
        else if let v = try? container.decode(Double.self) { value = v }
        else if let v = try? container.decode(String.self) { value = v }
        else if let v = try? container.decode([String: AnyCodable].self) { value = v.mapValues { $0.value as Any } }
        else if let v = try? container.decode([AnyCodable].self) { value = v.map { $0.value as Any } }
        else { value = nil }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case nil: try container.encodeNil()
        case let v as Bool: try container.encode(v)
        case let v as Int: try container.encode(v)
        case let v as Double: try container.encode(v)
        case let v as String: try container.encode(v)
        default: try container.encodeNil()
        }
    }

    public var stringValue: String? { value as? String }
    public var intValue: Int? { value as? Int }
    public var doubleValue: Double? { value as? Double }
    public var boolValue: Bool? { value as? Bool }
    public var arrayValue: [Any]? { value as? [Any] }
    public var dictValue: [String: Any]? { value as? [String: Any] }
}

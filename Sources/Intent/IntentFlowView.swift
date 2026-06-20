import SwiftUI

/// SwiftUI wrapper around IntentFlowViewController.
/// Use this if your app uses SwiftUI navigation.
///
/// Usage:
///   .fullScreenCover(isPresented: $showOnboarding) {
///       IntentFlowView(flow: flow, onComplete: { showOnboarding = false })
///   }
@available(iOS 15, *)
public struct IntentFlowView: UIViewControllerRepresentable {
    public let flow: IntentFlow
    public let onComplete: () -> Void
    public let onDismiss: (() -> Void)?

    public init(flow: IntentFlow, onComplete: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        self.flow = flow
        self.onComplete = onComplete
        self.onDismiss = onDismiss
    }

    public func makeUIViewController(context: Context) -> IntentFlowViewController {
        IntentFlowViewController(flow: flow, onComplete: onComplete, onDismiss: onDismiss)
    }

    public func updateUIViewController(_ uiViewController: IntentFlowViewController, context: Context) {}
}

/// SwiftUI convenience modifier — shows the flow as a fullScreenCover when a flow is available.
///
/// Usage:
///   ContentView()
///       .intentFlow(type: .onboarding, config: config) {
///           // onComplete
///       }
@available(iOS 15, *)
public struct IntentFlowModifier: ViewModifier {
    let flowType: FlowType
    let config: IntentClientConfig
    let onComplete: () -> Void

    @State private var flow: IntentFlow? = nil
    @State private var isPresented = false

    public func body(content: Content) -> some View {
        content
            .task {
                Intent.configure(
                    projectId: config.projectId,
                    sdkKey: config.sdkKey,
                    userId: config.userId ?? "anonymous"
                )
                if let fetched = await Intent.shared.flow(type: flowType) {
                    flow = fetched
                    isPresented = true
                }
            }
            .fullScreenCover(isPresented: $isPresented) {
                if let flow {
                    IntentFlowView(flow: flow, onComplete: {
                        isPresented = false
                        onComplete()
                    }, onDismiss: {
                        isPresented = false
                    })
                    .ignoresSafeArea()
                }
            }
    }
}

@available(iOS 15, *)
extension View {
    public func intentFlow(
        type: FlowType,
        config: IntentClientConfig,
        onComplete: @escaping () -> Void
    ) -> some View {
        modifier(IntentFlowModifier(flowType: type, config: config, onComplete: onComplete))
    }
}

/// Config struct for SwiftUI modifier
public struct IntentClientConfig {
    public let projectId: String
    public let sdkKey: String
    public let userId: String?

    public init(projectId: String, sdkKey: String, userId: String? = nil) {
        self.projectId = projectId
        self.sdkKey = sdkKey
        self.userId = userId
    }
}

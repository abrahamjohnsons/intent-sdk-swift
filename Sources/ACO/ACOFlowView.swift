import SwiftUI

/// SwiftUI wrapper around ACOFlowViewController.
/// Use this if your app uses SwiftUI navigation.
///
/// Usage:
///   .fullScreenCover(isPresented: $showOnboarding) {
///       ACOFlowView(flow: flow, onComplete: { showOnboarding = false })
///   }
@available(iOS 15, *)
public struct ACOFlowView: UIViewControllerRepresentable {
    public let flow: ACOFlow
    public let onComplete: () -> Void
    public let onDismiss: (() -> Void)?

    public init(flow: ACOFlow, onComplete: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
        self.flow = flow
        self.onComplete = onComplete
        self.onDismiss = onDismiss
    }

    public func makeUIViewController(context: Context) -> ACOFlowViewController {
        ACOFlowViewController(flow: flow, onComplete: onComplete, onDismiss: onDismiss)
    }

    public func updateUIViewController(_ uiViewController: ACOFlowViewController, context: Context) {}
}

/// SwiftUI convenience modifier — shows the flow as a fullScreenCover when a flow is available.
///
/// Usage:
///   ContentView()
///       .acoFlow(type: .onboarding, config: config) {
///           // onComplete
///       }
@available(iOS 15, *)
public struct ACOFlowModifier: ViewModifier {
    let flowType: FlowType
    let config: ACOClientConfig
    let onComplete: () -> Void

    @State private var flow: ACOFlow? = nil
    @State private var isPresented = false

    public func body(content: Content) -> some View {
        content
            .task {
                ACO.configure(
                    projectId: config.projectId,
                    sdkKey: config.sdkKey,
                    userId: config.userId ?? "anonymous"
                )
                if let fetched = await ACO.shared.flow(type: flowType) {
                    flow = fetched
                    isPresented = true
                }
            }
            .fullScreenCover(isPresented: $isPresented) {
                if let flow {
                    ACOFlowView(flow: flow, onComplete: {
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
    public func acoFlow(
        type: FlowType,
        config: ACOClientConfig,
        onComplete: @escaping () -> Void
    ) -> some View {
        modifier(ACOFlowModifier(flowType: type, config: config, onComplete: onComplete))
    }
}

/// Config struct for SwiftUI modifier
public struct ACOClientConfig {
    public let projectId: String
    public let sdkKey: String
    public let userId: String?

    public init(projectId: String, sdkKey: String, userId: String? = nil) {
        self.projectId = projectId
        self.sdkKey = sdkKey
        self.userId = userId
    }
}

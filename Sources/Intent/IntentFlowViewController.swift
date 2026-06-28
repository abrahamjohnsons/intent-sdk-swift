import UIKit
import Lottie
import StoreKit

/// Renders an Intent flow schema as a native UIKit view controller.
/// Presented modally, it navigates through screens and calls onComplete/onDismiss.
///
/// Paywall screens (`type: "paywall"` or `"paywall_soft"`) automatically:
///   - Load real App Store prices via StoreKit 2 (requires `productId` on each pricing option)
///   - Handle purchase, transaction verification, and revenue attribution
///   - Advance the flow on successful purchase
///
/// Usage:
///   let vc = IntentFlowViewController(flow: flow, onComplete: {
///       // user finished — navigate to main app
///   })
///   present(vc, animated: true)
public final class IntentFlowViewController: UIViewController {

    // MARK: - Properties

    private let flow: IntentFlow
    private let onComplete: (() -> Void)?
    private let onDismiss: (() -> Void)?

    private var screenIndex = 0
    private var quizAnswers: [String: Any] = [:]
    private var collectedData: [String: Any] = [:]
    private var currentScreenLayout: String = "default"
    private var theme: ResolvedTheme

    private var screens: [FlowScreen] { flow.schema.screens }
    private var currentScreen: FlowScreen? { screens[safe: screenIndex] }

    // MARK: - Paywall / StoreKit state

    private var isPaywallScreen = false
    private var paywallOptions: [PaywallOption] = []
    private var paywallCards: [PricingCardView] = []
    private var selectedPaywallIndex: Int? = nil
    private var paywallProductLoadTask: Task<Void, Never>? = nil

    // MARK: - UI

    private let progressView = UIProgressView(progressViewStyle: .default)
    private let skipButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()
    private let heroContainerView = UIView()
    private var heroHeightConstraint: NSLayoutConstraint?
    private var backgroundGradientLayer: CAGradientLayer?

    // MARK: - Init

    public init(
        flow: IntentFlow,
        onComplete: (() -> Void)?,
        onDismiss: (() -> Void)? = nil
    ) {
        self.flow = flow
        self.onComplete = onComplete
        self.onDismiss = onDismiss
        self.theme = ResolvedTheme(from: flow.schema.theme)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .pageSheet
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Lifecycle

    public override func viewDidLoad() {
        super.viewDidLoad()
        setupLayout()
        setupKeyboardAvoidance()
        Intent.shared.trackFlowStart(flowId: flow.id)
        Intent.shared.trackFlowPresented(flowId: flow.id)
        renderCurrentScreen()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyGradientBackground()
    }

    // MARK: - Layout

    private func setupLayout() {
        view.backgroundColor = theme.background

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = theme.primary
        progressView.trackTintColor = theme.secondary
        progressView.layer.cornerRadius = 2
        progressView.clipsToBounds = true
        view.addSubview(progressView)

        skipButton.translatesAutoresizingMaskIntoConstraints = false
        skipButton.setTitle("Skip", for: .normal)
        skipButton.setTitleColor(theme.foreground.withAlphaComponent(0.5), for: .normal)
        skipButton.titleLabel?.font = theme.font(size: 14, weight: .medium)
        skipButton.addTarget(self, action: #selector(didTapSkip), for: .touchUpInside)
        skipButton.isHidden = !(flow.schema.settings?.canSkip ?? false)
        view.addSubview(skipButton)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        heroContainerView.translatesAutoresizingMaskIntoConstraints = false
        heroContainerView.clipsToBounds = true
        scrollView.addSubview(heroContainerView)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 20
        contentStack.alignment = .fill
        scrollView.addSubview(contentStack)

        let safe = view.safeAreaLayoutGuide
        let hc = heroContainerView.heightAnchor.constraint(equalToConstant: 0)
        heroHeightConstraint = hc

        NSLayoutConstraint.activate([
            progressView.topAnchor.constraint(equalTo: safe.topAnchor, constant: 16),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            progressView.heightAnchor.constraint(equalToConstant: 4),

            skipButton.centerYAnchor.constraint(equalTo: progressView.centerYAnchor),
            skipButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            skipButton.leadingAnchor.constraint(equalTo: progressView.trailingAnchor, constant: 12),
            skipButton.widthAnchor.constraint(equalToConstant: 40),

            scrollView.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            heroContainerView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            heroContainerView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            heroContainerView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            heroContainerView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            hc,

            contentStack.topAnchor.constraint(equalTo: heroContainerView.bottomAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -24),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -40),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -48),
        ])
    }

    // MARK: - Gradient background

    private func applyGradientBackground() {
        guard let gradientCSS = flow.schema.theme?.backgroundGradient,
              let colors = parseGradientColors(from: gradientCSS),
              colors.count >= 2 else { return }

        if backgroundGradientLayer == nil {
            let gradLayer = CAGradientLayer()
            gradLayer.startPoint = CGPoint(x: 0, y: 0)
            gradLayer.endPoint = CGPoint(x: 1, y: 1)
            view.layer.insertSublayer(gradLayer, at: 0)
            backgroundGradientLayer = gradLayer
        }
        backgroundGradientLayer?.frame = view.bounds
        backgroundGradientLayer?.colors = colors.map { $0.cgColor }
    }

    private func parseGradientColors(from css: String) -> [UIColor]? {
        let pattern = "#[0-9A-Fa-f]{6,8}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(css.startIndex..., in: css)
        let matches = regex.matches(in: css, range: range)
        let colors = matches.compactMap { match -> UIColor? in
            guard let r = Range(match.range, in: css) else { return nil }
            return UIColor(hex: String(css[r]))
        }
        return colors.isEmpty ? nil : colors
    }

    // MARK: - Screen rendering

    private func renderCurrentScreen() {
        guard let screen = currentScreen else { return }

        if flow.schema.settings?.showProgress != false {
            let progress = Float(screenIndex + 1) / Float(max(screens.count, 1))
            progressView.setProgress(progress, animated: screenIndex > 0)
        }

        Intent.shared.trackScreenView(screenId: screen.id, flowId: flow.id)

        isPaywallScreen = screen.type == "paywall" || screen.type == "paywall_soft"
        paywallOptions = []
        paywallCards = []
        selectedPaywallIndex = nil
        paywallProductLoadTask?.cancel()
        paywallProductLoadTask = nil

        if screen.type == "loading" {
            renderLoadingScreen(screen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.goNext()
            }
            return
        }

        currentScreenLayout = screen.layout ?? "default"
        let layout = currentScreenLayout
        let isFullBleed = layout == "full_bleed_hero"
        let isCenterHero = layout == "center_hero"
        let isCardStack = layout == "card_stack"

        // Hero container
        heroContainerView.subviews.forEach { $0.removeFromSuperview() }

        if isFullBleed, let heroComp = screen.components.first(where: { $0.type == "hero_image" || $0.type == "lottie_animation" }) {
            heroHeightConstraint?.constant = 280
            let hv = heroComp.type == "lottie_animation" ? makeLottieView(component: heroComp) : makeHeroView(component: heroComp)
            hv.translatesAutoresizingMaskIntoConstraints = false
            heroContainerView.addSubview(hv)
            NSLayoutConstraint.activate([
                hv.topAnchor.constraint(equalTo: heroContainerView.topAnchor),
                hv.leadingAnchor.constraint(equalTo: heroContainerView.leadingAnchor),
                hv.trailingAnchor.constraint(equalTo: heroContainerView.trailingAnchor),
                hv.bottomAnchor.constraint(equalTo: heroContainerView.bottomAnchor),
            ])
        } else {
            heroHeightConstraint?.constant = 0
        }

        // Content stack alignment
        contentStack.alignment = isCenterHero ? .center : .fill
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for component in screen.components {
            if isFullBleed && (component.type == "hero_image" || component.type == "lottie_animation") { continue }
            guard let componentView = makeComponentView(component: component, screen: screen) else { continue }

            // card_stack wraps non-action components in elevated cards
            if isCardStack && !["button", "secondary_button", "spacer", "divider", "separator", "guarantee", "guarantee_badge"].contains(component.type) {
                contentStack.addArrangedSubview(wrapInCard(componentView))
            } else {
                contentStack.addArrangedSubview(componentView)
            }
        }

        if isPaywallScreen && !paywallOptions.isEmpty {
            let defaultIdx = paywallOptions.firstIndex(where: { $0.highlighted }) ?? 0
            selectPaywallOption(at: defaultIdx)
            startPaywallProductLoad()
            injectRestoreButton()
        }
    }

    private func renderLoadingScreen(_ screen: FlowScreen) {
        currentScreenLayout = "default"
        heroHeightConstraint?.constant = 0
        heroContainerView.subviews.forEach { $0.removeFromSuperview() }
        contentStack.alignment = .fill
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let container = UIView()
        let spinner = UIActivityIndicatorView(style: .large)
        spinner.color = theme.primary
        spinner.startAnimating()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: container.topAnchor, constant: 60),
            container.bottomAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 40),
        ])
        contentStack.addArrangedSubview(container)

        for component in screen.components where component.type == "heading" || component.type == "subheading" {
            if let view = makeComponentView(component: component, screen: screen) {
                contentStack.addArrangedSubview(view)
            }
        }
    }

    // MARK: - card_stack card wrapper

    private func wrapInCard(_ content: UIView) -> UIView {
        let card = UIView()
        card.backgroundColor = theme.secondary
        card.layer.cornerRadius = theme.radius
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = 0.18
        card.layer.shadowOffset = CGSize(width: 0, height: 4)
        card.layer.shadowRadius = 12

        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])
        return card
    }

    // MARK: - Component factory

    private func makeComponentView(component: FlowComponent, screen: FlowScreen) -> UIView? {
        let props = component.props

        switch component.type {

        // ── Hero / Media ──────────────────────────────────────────────────────

        case "hero_image":
            return makeHeroView(component: component)

        case "lottie_animation":
            return makeLottieView(component: component)

        // ── Text ──────────────────────────────────────────────────────────────

        case "heading":
            let text = props["text"]?.stringValue ?? ""
            let accentWord = props["accentWord"]?.stringValue
            if let accent = accentWord, !accent.isEmpty, text.contains(accent) {
                return makeAttributedHeading(text: text, accentWord: accent)
            }
            return makeLabel(text: text, font: theme.font(size: 28, weight: .bold), color: theme.foreground, lines: 0)

        case "subheading":
            return makeLabel(text: props["text"]?.stringValue ?? "", font: theme.font(size: 17, weight: .semibold), color: theme.foreground.withAlphaComponent(0.8), lines: 0)

        case "body", "text":
            return makeLabel(text: props["text"]?.stringValue ?? "", font: theme.font(size: 15), color: theme.foreground.withAlphaComponent(0.6), lines: 0)

        case "badge", "label":
            return makeBadge(text: props["text"]?.stringValue ?? "")

        // ── Input ─────────────────────────────────────────────────────────────

        case "text_input":
            return makeTextInputField(
                placeholder: props["placeholder"]?.stringValue ?? "",
                collects: props["collects"]?.stringValue ?? props["name"]?.stringValue ?? "input",
                fieldLabel: props["label"]?.stringValue,
                keyboard: props["keyboard"]?.stringValue
            )

        // ── Buttons ───────────────────────────────────────────────────────────

        case "button":
            return makePrimaryButton(title: props["text"]?.stringValue ?? "Continue")

        case "secondary_button":
            return makeSecondaryButton(title: props["text"]?.stringValue ?? "Skip")

        // ── Quiz options ──────────────────────────────────────────────────────

        case "options", "quiz_option":
            let quizKey = props["quizKey"]?.stringValue ?? screen.metadata?.quizKey ?? "answer"
            let multiSelect = screen.metadata?.multiSelect ?? false
            let autoAdvance = props["autoAdvance"]?.boolValue ?? !multiSelect
            let collectsKey = props["collects"]?.stringValue
            let columns = props["columns"]?.intValue ?? 1
            var options = screen.metadata?.quizOptions ?? []
            if options.isEmpty, let rawOptions = props["options"]?.arrayValue as? [[String: Any]] {
                options = rawOptions.compactMap { d in
                    guard let id = d["id"] as? String, let label = d["label"] as? String else { return nil }
                    return QuizOption(
                        id: id,
                        label: label,
                        value: (d["value"] as? String) ?? id,
                        icon: (d["emoji"] as? String) ?? (d["icon"] as? String),
                        description: d["description"] as? String
                    )
                }
            }
            // Auto-detect 2-col grid: explicit columns=2, or 4+ options all with icons and short labels
            let useGrid = columns == 2 || (options.count >= 4 && options.allSatisfy { $0.icon != nil && $0.label.count <= 22 })
            if useGrid {
                return makeOptionsGrid(quizKey: quizKey, options: options, multiSelect: multiSelect, autoAdvance: autoAdvance, collectsKey: collectsKey)
            }
            return makeOptionsStack(quizKey: quizKey, options: options, multiSelect: multiSelect, autoAdvance: autoAdvance, collectsKey: collectsKey)

        // ── Lists ─────────────────────────────────────────────────────────────

        case "list", "feature_list", "benefit_list":
            let rawItems = props["items"]?.arrayValue ?? []
            let items: [(String, String)] = rawItems.compactMap { item in
                if let s = item as? String { return ("✓", s) }
                if let d = item as? [String: Any] {
                    let text = (d["text"] as? String) ?? (d["label"] as? String) ?? ""
                    let icon = (d["emoji"] as? String) ?? (d["icon"] as? String) ?? "✓"
                    return (icon, text)
                }
                return nil
            }
            return makeListView(items: items)

        // ── Social proof ──────────────────────────────────────────────────────

        case "testimonial":
            return makeTestimonialCard(
                quote: props["quote"]?.stringValue ?? props["text"]?.stringValue ?? "",
                author: props["author"]?.stringValue ?? props["name"]?.stringValue ?? "",
                rating: props["rating"]?.doubleValue.map { Int($0) }
            )

        case "stats", "social_proof":
            let rawItems = props["items"]?.arrayValue as? [[String: Any]] ?? []
            let items = rawItems.compactMap { d -> (String, String)? in
                guard let val = d["value"] as? String, let label = d["label"] as? String else { return nil }
                return (val, label)
            }
            return makeStatsRow(items: items)

        // ── Pricing ───────────────────────────────────────────────────────────

        case "pricing", "price_card", "pricing_option":
            var rawOptions = props["options"]?.arrayValue as? [[String: Any]] ?? []
            if rawOptions.isEmpty, let rawPlans = props["plans"]?.arrayValue as? [[String: Any]] {
                rawOptions = rawPlans.map { p in
                    var mapped = p
                    if mapped["label"] == nil { mapped["label"] = p["name"] }
                    if mapped["perMonth"] == nil { mapped["perMonth"] = p["period"] }
                    return mapped
                }
            }
            return makePricingStack(options: rawOptions)

        // ── Guarantee ─────────────────────────────────────────────────────────

        case "guarantee", "guarantee_badge":
            return makeGuaranteeRow(text: props["text"]?.stringValue ?? "30-day money back guarantee")

        // ── Spacer / divider ──────────────────────────────────────────────────

        case "spacer", "divider", "separator":
            let spacer = UIView()
            spacer.heightAnchor.constraint(equalToConstant: 12).isActive = true
            return spacer

        default:
            return nil
        }
    }

    // MARK: - Component builders

    private func makeLabel(text: String, font: UIFont, color: UIColor, lines: Int) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = lines
        if currentScreenLayout == "center_hero" {
            label.textAlignment = .center
        }
        return label
    }

    private func makeAttributedHeading(text: String, accentWord: String) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        if currentScreenLayout == "center_hero" {
            label.textAlignment = .center
        }
        let baseFont = theme.font(size: 28, weight: .bold)
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [.font: baseFont, .foregroundColor: theme.foreground]
        )
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: accentWord, options: .caseInsensitive, range: searchRange) {
            attributed.addAttribute(.foregroundColor, value: theme.primary, range: NSRange(range, in: text))
            searchRange = range.upperBound..<text.endIndex
        }
        label.attributedText = attributed
        return label
    }

    private func makeHeroView(component: FlowComponent) -> UIView {
        let props = component.props
        let emoji = props["emoji"]?.stringValue ?? props["icon"]?.stringValue ?? "✨"
        let glowColor: UIColor = props["glowColor"]?.stringValue.map { UIColor(hex: $0) } ?? theme.primary

        // If lottieUrl provided on hero_image, use Lottie instead (supports named animations)
        if let rawLottieUrl = props["lottieUrl"]?.stringValue ?? props["lottie_url"]?.stringValue,
           let url = IntentLottieRegistry.resolve(rawLottieUrl) {
            return makeLottieViewFromURL(url: url, loop: true)
        }

        let container = UIView()
        container.backgroundColor = .clear

        let glowView = RadialGlowView(color: glowColor)
        glowView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glowView)

        let emojiLabel = UILabel()
        emojiLabel.text = emoji
        emojiLabel.font = .systemFont(ofSize: 88)
        emojiLabel.textAlignment = .center
        emojiLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emojiLabel)

        NSLayoutConstraint.activate([
            glowView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            glowView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            glowView.widthAnchor.constraint(equalToConstant: 220),
            glowView.heightAnchor.constraint(equalToConstant: 220),
            emojiLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emojiLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private func makeLottieView(component: FlowComponent) -> UIView {
        let props = component.props
        let rawUrlString = props["url"]?.stringValue ?? props["src"]?.stringValue ?? ""
        let loop = props["loop"]?.boolValue ?? true
        let height = props["height"]?.doubleValue.map { CGFloat($0) } ?? 240
        guard let url = IntentLottieRegistry.resolve(rawUrlString) else {
            let v = UIView()
            v.heightAnchor.constraint(equalToConstant: height).isActive = true
            return v
        }
        let container = makeLottieViewFromURL(url: url, loop: loop)
        container.heightAnchor.constraint(equalToConstant: height).isActive = true
        return container
    }

    private func makeLottieViewFromURL(url: URL, loop: Bool) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear

        let animView = LottieAnimationView()
        animView.contentMode = .scaleAspectFit
        animView.loopMode = loop ? .loop : .playOnce
        animView.backgroundBehavior = .pauseAndRestore
        animView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(animView)

        NSLayoutConstraint.activate([
            animView.topAnchor.constraint(equalTo: container.topAnchor),
            animView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            animView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            animView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        LottieAnimation.loadedFrom(
            url: url,
            closure: { [weak animView] animation in
                guard let animView else { return }
                animView.animation = animation
                animView.play()
            },
            animationCache: DefaultAnimationCache.sharedCache
        )
        return container
    }

    private func makeTextInputField(placeholder: String, collects: String, fieldLabel: String?, keyboard: String?) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8

        if let lbl = fieldLabel, !lbl.isEmpty {
            let label = UILabel()
            label.text = lbl
            label.font = theme.font(size: 13, weight: .medium)
            label.textColor = theme.foreground.withAlphaComponent(0.6)
            stack.addArrangedSubview(label)
        }

        let field = UITextField()
        field.placeholder = placeholder
        field.font = theme.font(size: 16)
        field.textColor = theme.foreground
        field.backgroundColor = theme.secondary
        field.layer.cornerRadius = theme.radius
        field.layer.borderWidth = 1
        field.layer.borderColor = theme.foreground.withAlphaComponent(0.15).cgColor
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 0))
        field.leftViewMode = .always
        field.rightView = UIView(frame: CGRect(x: 0, y: 0, width: 16, height: 0))
        field.rightViewMode = .always
        field.heightAnchor.constraint(equalToConstant: 52).isActive = true
        field.accessibilityIdentifier = collects

        switch keyboard {
        case "email", "email-address":
            field.keyboardType = .emailAddress
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        case "phone":
            field.keyboardType = .phonePad
        case "number":
            field.keyboardType = .numberPad
        default:
            field.keyboardType = .default
        }

        field.addTarget(self, action: #selector(textFieldChanged(_:)), for: .editingChanged)
        field.addTarget(self, action: #selector(textFieldFocused(_:)), for: .editingDidBegin)
        field.addTarget(self, action: #selector(textFieldBlurred(_:)), for: .editingDidEnd)

        stack.addArrangedSubview(field)
        return stack
    }

    @objc private func textFieldChanged(_ sender: UITextField) {
        guard let key = sender.accessibilityIdentifier else { return }
        collectedData[key] = sender.text ?? ""
    }

    @objc private func textFieldFocused(_ sender: UITextField) {
        UIView.animate(withDuration: 0.15) {
            sender.layer.borderColor = self.theme.primary.cgColor
            sender.layer.borderWidth = 2
        }
    }

    @objc private func textFieldBlurred(_ sender: UITextField) {
        UIView.animate(withDuration: 0.15) {
            sender.layer.borderColor = self.theme.foreground.withAlphaComponent(0.15).cgColor
            sender.layer.borderWidth = 1
        }
    }

    private func makeBadge(text: String) -> UIView {
        let container = UIView()
        container.backgroundColor = theme.primary.withAlphaComponent(0.15)
        container.layer.cornerRadius = 100
        container.clipsToBounds = true

        let label = UILabel()
        label.text = text
        label.font = theme.font(size: 13, weight: .semibold)
        label.textColor = theme.primary
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let wrapper = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(container)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            container.topAnchor.constraint(equalTo: wrapper.topAnchor),
            container.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
        ])
        return wrapper
    }

    private func makePrimaryButton(title: String) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = theme.font(size: 16, weight: .bold)
        btn.setTitleColor(theme.primaryForeground, for: .normal)
        btn.backgroundColor = theme.primary
        btn.layer.cornerRadius = theme.radius
        btn.heightAnchor.constraint(equalToConstant: 54).isActive = true

        if isPaywallScreen {
            btn.addTarget(self, action: #selector(handlePaywallPurchaseTap), for: .touchUpInside)
        } else {
            btn.addTarget(self, action: #selector(didTapNext), for: .touchUpInside)
        }
        return btn
    }

    private func makeSecondaryButton(title: String) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = theme.font(size: 15, weight: .medium)
        btn.setTitleColor(theme.foreground.withAlphaComponent(0.6), for: .normal)
        btn.backgroundColor = .clear
        btn.layer.cornerRadius = theme.radius
        btn.layer.borderWidth = 1
        btn.layer.borderColor = theme.foreground.withAlphaComponent(0.2).cgColor
        btn.heightAnchor.constraint(equalToConstant: 50).isActive = true
        btn.addTarget(self, action: #selector(didTapNext), for: .touchUpInside)
        return btn
    }

    // MARK: - Options: list layout

    private func makeOptionsStack(quizKey: String, options: [QuizOption], multiSelect: Bool, autoAdvance: Bool, collectsKey: String?) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 10

        for option in options {
            let optView = OptionCardView(
                option: option,
                theme: theme,
                isSelected: {
                    if multiSelect {
                        return (self.quizAnswers[quizKey] as? [String] ?? []).contains(option.value)
                    }
                    return self.quizAnswers[quizKey] as? String == option.value
                },
                onTap: { [weak self] in
                    guard let self else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if multiSelect {
                        var current = self.quizAnswers[quizKey] as? [String] ?? []
                        if current.contains(option.value) { current.removeAll { $0 == option.value } }
                        else { current.append(option.value) }
                        self.quizAnswers[quizKey] = current
                        if let key = collectsKey { self.collectedData[key] = current }
                        optView.updateSelection((self.quizAnswers[quizKey] as? [String] ?? []).contains(option.value))
                    } else {
                        self.quizAnswers[quizKey] = option.value
                        if let key = collectsKey { self.collectedData[key] = option.value }
                        if autoAdvance {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { self.goNext() }
                        }
                    }
                }
            )
            stack.addArrangedSubview(optView)
        }

        if multiSelect {
            stack.addArrangedSubview(makePrimaryButton(title: "Continue"))
        }
        return stack
    }

    // MARK: - Options: 2-column grid layout

    private func makeOptionsGrid(quizKey: String, options: [QuizOption], multiSelect: Bool, autoAdvance: Bool, collectsKey: String?) -> UIView {
        let outer = UIStackView()
        outer.axis = .vertical
        outer.spacing = 10

        stride(from: 0, to: options.count, by: 2).forEach { i in
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 10
            row.distribution = .fillEqually

            let card1 = GridOptionCardView(option: options[i], theme: theme,
                isSelected: { self.isOptionSelected(quizKey: quizKey, value: options[i].value, multiSelect: multiSelect) },
                onTap: { [weak self] in self?.handleOptionTap(quizKey: quizKey, option: options[i], multiSelect: multiSelect, autoAdvance: autoAdvance, collectsKey: collectsKey) }
            )
            row.addArrangedSubview(card1)

            if i + 1 < options.count {
                let card2 = GridOptionCardView(option: options[i + 1], theme: theme,
                    isSelected: { self.isOptionSelected(quizKey: quizKey, value: options[i + 1].value, multiSelect: multiSelect) },
                    onTap: { [weak self] in self?.handleOptionTap(quizKey: quizKey, option: options[i + 1], multiSelect: multiSelect, autoAdvance: autoAdvance, collectsKey: collectsKey) }
                )
                row.addArrangedSubview(card2)
            } else {
                row.addArrangedSubview(UIView()) // empty fill
            }

            outer.addArrangedSubview(row)
        }

        if multiSelect {
            outer.addArrangedSubview(makePrimaryButton(title: "Continue"))
        }
        return outer
    }

    private func isOptionSelected(quizKey: String, value: String, multiSelect: Bool) -> Bool {
        if multiSelect { return (quizAnswers[quizKey] as? [String] ?? []).contains(value) }
        return quizAnswers[quizKey] as? String == value
    }

    private func handleOptionTap(quizKey: String, option: QuizOption, multiSelect: Bool, autoAdvance: Bool, collectsKey: String?) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if multiSelect {
            var current = quizAnswers[quizKey] as? [String] ?? []
            if current.contains(option.value) { current.removeAll { $0 == option.value } }
            else { current.append(option.value) }
            quizAnswers[quizKey] = current
            if let key = collectsKey { collectedData[key] = current }
        } else {
            quizAnswers[quizKey] = option.value
            if let key = collectsKey { collectedData[key] = option.value }
            if autoAdvance {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in self?.goNext() }
            }
        }
    }

    // MARK: - List / stats / social proof

    private func makeListView(items: [(String, String)]) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 14

        for (icon, text) in items {
            let row = UIStackView()
            row.axis = .horizontal
            row.spacing = 12
            row.alignment = .top

            let iconLabel = UILabel()
            iconLabel.text = icon
            iconLabel.font = theme.font(size: 15, weight: .bold)
            iconLabel.textColor = theme.primary
            iconLabel.widthAnchor.constraint(equalToConstant: 20).isActive = true
            iconLabel.textAlignment = .center

            let textLabel = UILabel()
            textLabel.text = text
            textLabel.font = theme.font(size: 15)
            textLabel.textColor = theme.foreground.withAlphaComponent(0.8)
            textLabel.numberOfLines = 0

            row.addArrangedSubview(iconLabel)
            row.addArrangedSubview(textLabel)
            stack.addArrangedSubview(row)
        }
        return stack
    }

    private func makeTestimonialCard(quote: String, author: String, rating: Int?) -> UIView {
        let card = UIView()
        card.backgroundColor = theme.secondary
        card.layer.cornerRadius = theme.radius
        card.layer.borderWidth = 1
        card.layer.borderColor = theme.foreground.withAlphaComponent(0.08).cgColor

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
        ])

        if let rating, rating > 0 {
            let stars = UILabel()
            stars.text = String(repeating: "★", count: rating)
            stars.font = theme.font(size: 16)
            stars.textColor = UIColor(hex: "#F59E0B")
            stack.addArrangedSubview(stars)
        }

        let quoteLabel = UILabel()
        quoteLabel.text = "\"\(quote)\""
        quoteLabel.font = UIFont(descriptor: theme.font(size: 15).fontDescriptor.withSymbolicTraits(.traitItalic) ?? theme.font(size: 15).fontDescriptor, size: 15)
        quoteLabel.textColor = theme.foreground
        quoteLabel.numberOfLines = 0
        stack.addArrangedSubview(quoteLabel)

        if !author.isEmpty {
            let authorLabel = UILabel()
            authorLabel.text = "— \(author)"
            authorLabel.font = theme.font(size: 13, weight: .medium)
            authorLabel.textColor = theme.foreground.withAlphaComponent(0.5)
            stack.addArrangedSubview(authorLabel)
        }
        return card
    }

    private func makeStatsRow(items: [(String, String)]) -> UIView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 16

        for (value, label) in items {
            let col = UIStackView()
            col.axis = .vertical
            col.alignment = .center
            col.spacing = 4

            let valLabel = UILabel()
            valLabel.text = value
            valLabel.font = theme.font(size: 24, weight: .black)
            valLabel.textColor = theme.primary
            valLabel.textAlignment = .center

            let lblLabel = UILabel()
            lblLabel.text = label
            lblLabel.font = theme.font(size: 12, weight: .medium)
            lblLabel.textColor = theme.foreground.withAlphaComponent(0.5)
            lblLabel.textAlignment = .center
            lblLabel.numberOfLines = 2

            col.addArrangedSubview(valLabel)
            col.addArrangedSubview(lblLabel)
            stack.addArrangedSubview(col)
        }
        return stack
    }

    // MARK: - Pricing stack (paywall)

    private func makePricingStack(options: [[String: Any]]) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12
        paywallCards = []
        paywallOptions = []

        for (index, option) in options.enumerated() {
            let wo = PaywallOption(
                label: option["label"] as? String ?? "",
                productId: option["productId"] as? String,
                fallbackPrice: option["price"] as? String ?? "",
                fallbackPerMonth: option["perMonth"] as? String,
                badge: option["badge"] as? String,
                highlighted: option["highlighted"] as? Bool ?? false
            )
            paywallOptions.append(wo)

            if isPaywallScreen {
                let card = PricingCardView(option: wo, theme: theme) { [weak self] in
                    self?.selectPaywallOption(at: index)
                }
                paywallCards.append(card)
                stack.addArrangedSubview(card)
            } else {
                stack.addArrangedSubview(makeStaticPricingCard(option: option))
            }
        }
        return stack
    }

    private func makeStaticPricingCard(option: [String: Any]) -> UIView {
        let highlighted = option["highlighted"] as? Bool ?? false
        let card = UIView()
        card.backgroundColor = highlighted ? theme.primary.withAlphaComponent(0.1) : theme.secondary
        card.layer.cornerRadius = theme.radius
        card.layer.borderWidth = highlighted ? 2 : 1
        card.layer.borderColor = highlighted ? theme.primary.cgColor : theme.foreground.withAlphaComponent(0.12).cgColor

        let inner = UIStackView()
        inner.axis = .vertical
        inner.spacing = 4
        inner.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            inner.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            inner.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            inner.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])

        let planLabel = UILabel()
        planLabel.text = option["label"] as? String ?? ""
        planLabel.font = theme.font(size: 14, weight: .medium)
        planLabel.textColor = theme.foreground.withAlphaComponent(0.7)
        inner.addArrangedSubview(planLabel)

        let priceLabel = UILabel()
        priceLabel.text = option["price"] as? String ?? ""
        priceLabel.font = theme.font(size: 22, weight: .black)
        priceLabel.textColor = highlighted ? theme.primary : theme.foreground
        inner.addArrangedSubview(priceLabel)

        if let perMonth = option["perMonth"] as? String {
            let pm = UILabel()
            pm.text = perMonth
            pm.font = theme.font(size: 13)
            pm.textColor = theme.foreground.withAlphaComponent(0.5)
            inner.addArrangedSubview(pm)
        }
        return card
    }

    private func makeGuaranteeRow(text: String) -> UIView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center

        let icon = UILabel()
        icon.text = "🛡️"
        icon.font = .systemFont(ofSize: 16)

        let label = UILabel()
        label.text = text
        label.font = theme.font(size: 13, weight: .medium)
        label.textColor = theme.foreground.withAlphaComponent(0.5)
        label.numberOfLines = 0

        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(label)

        let wrapper = UIView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor),
            stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: wrapper.leadingAnchor),
        ])
        return wrapper
    }

    // MARK: - Paywall: plan selection

    private func selectPaywallOption(at index: Int) {
        selectedPaywallIndex = index
        for (i, card) in paywallCards.enumerated() { card.setSelected(i == index) }
    }

    // MARK: - Paywall: StoreKit product loading

    private func startPaywallProductLoad() {
        guard #available(iOS 15, *) else { return }
        let ids = paywallOptions.compactMap { $0.productId }
        guard !ids.isEmpty else { return }

        paywallProductLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let products = try? await IntentPurchaseManager.shared.loadProducts(ids: ids) else { return }
            guard !Task.isCancelled else { return }

            for (index, option) in self.paywallOptions.enumerated() {
                guard index < self.paywallCards.count else { break }
                guard let productId = option.productId,
                      let product = products.first(where: { $0.id == productId }) else { continue }

                var perMonth: String? = nil
                if #available(iOS 15, *), let sub = product.subscription {
                    let period = sub.subscriptionPeriod
                    if period.unit == .year && period.value == 1 {
                        let monthly = NSDecimalNumber(decimal: product.price)
                            .dividing(by: 12, withBehavior: NSDecimalNumberHandler(
                                roundingMode: .plain, scale: 2,
                                raiseOnExactness: false, raiseOnOverflow: false,
                                raiseOnUnderflow: false, raiseOnDivideByZero: false
                            ))
                        perMonth = "\(product.priceFormatStyle.format(monthly.decimalValue)) / month"
                    }
                    if let offer = sub.introductoryOffer, offer.paymentMode == .freeTrial {
                        let p = offer.period
                        let unitStr: String
                        switch p.unit {
                        case .day:   unitStr = p.value == 1 ? "day"   : "\(p.value) days"
                        case .week:  unitStr = p.value == 1 ? "week"  : "\(p.value) weeks"
                        case .month: unitStr = p.value == 1 ? "month" : "\(p.value) months"
                        case .year:  unitStr = p.value == 1 ? "year"  : "\(p.value) years"
                        @unknown default: unitStr = "period"
                        }
                        perMonth = "Try free for \(unitStr), then \(product.displayPrice)"
                    }
                }
                self.paywallCards[index].updatePrice(product.displayPrice, perMonth: perMonth)
            }
        }
    }

    // MARK: - Paywall: restore purchases

    private func injectRestoreButton() {
        let btn = UIButton(type: .system)
        btn.setTitle("Restore Purchases", for: .normal)
        btn.titleLabel?.font = theme.font(size: 13)
        btn.setTitleColor(theme.foreground.withAlphaComponent(0.4), for: .normal)
        btn.addTarget(self, action: #selector(handleRestorePurchases), for: .touchUpInside)
        contentStack.addArrangedSubview(btn)
    }

    @objc private func handleRestorePurchases() {
        guard #available(iOS 15, *) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let active = await IntentPurchaseManager.shared.currentEntitlements()
            if let first = active.first {
                Intent.shared.subscriptionStatus = .active(productId: first)
                self.goNext()
            } else {
                self.showAlert(title: "No Purchases Found", message: "No active subscriptions were found for your Apple ID.")
            }
        }
    }

    // MARK: - Paywall: purchase

    @objc private func handlePaywallPurchaseTap() {
        let index = selectedPaywallIndex ?? paywallOptions.firstIndex(where: { $0.highlighted }) ?? 0
        guard index < paywallOptions.count else { goNext(); return }
        let option = paywallOptions[index]
        guard let productId = option.productId else { goNext(); return }
        Task { @MainActor [weak self] in
            await self?.executePurchase(productId: productId, cardIndex: index)
        }
    }

    @MainActor
    private func executePurchase(productId: String, cardIndex: Int) async {
        guard #available(iOS 15, *) else { goNext(); return }

        Intent.shared.trackPurchaseStarted(
            flowId: flow.id,
            screenId: currentScreen?.id,
            properties: ["product_id": AnyCodable(productId)]
        )
        if cardIndex < paywallCards.count { paywallCards[cardIndex].setLoading(true) }

        guard let products = try? await IntentPurchaseManager.shared.loadProducts(ids: [productId]),
              let product = products.first else {
            if cardIndex < paywallCards.count { paywallCards[cardIndex].setLoading(false) }
            showAlert(title: "Couldn't Load Product", message: "Please check your connection and try again.")
            return
        }

        do {
            let result = try await IntentPurchaseManager.shared.purchase(product: product, flowId: flow.id, screenId: currentScreen?.id)
            if cardIndex < paywallCards.count { paywallCards[cardIndex].setLoading(false) }
            switch result {
            case .success: goNext()
            case .cancelled: break
            case .pending:
                showAlert(title: "Purchase Pending", message: "Your purchase is awaiting approval. You'll unlock access once it's approved.")
            }
        } catch {
            if cardIndex < paywallCards.count { paywallCards[cardIndex].setLoading(false) }
            showAlert(title: "Purchase Failed", message: error.localizedDescription)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    // MARK: - Keyboard avoidance

    private func setupKeyboardAvoidance() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillShow(_:)),
            name: UIResponder.keyboardWillShowNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification, object: nil
        )
    }

    @objc private func keyboardWillShow(_ notification: Notification) {
        guard let info = notification.userInfo,
              let frame = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
              let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double else { return }
        let inset = max(0, frame.height - view.safeAreaInsets.bottom)
        UIView.animate(withDuration: duration) {
            self.scrollView.contentInset.bottom = inset + 16
            self.scrollView.verticalScrollIndicatorInsets.bottom = inset + 16
        }
        // Scroll active text field into view
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self else { return }
            if let active = self.findFirstResponder(in: self.scrollView) {
                let rect = active.convert(active.bounds, to: self.scrollView)
                self.scrollView.scrollRectToVisible(rect.insetBy(dx: 0, dy: -24), animated: true)
            }
        }
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        UIView.animate(withDuration: 0.25) {
            self.scrollView.contentInset.bottom = 0
            self.scrollView.verticalScrollIndicatorInsets.bottom = 0
        }
    }

    private func findFirstResponder(in view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for sub in view.subviews {
            if let found = findFirstResponder(in: sub) { return found }
        }
        return nil
    }

    // MARK: - Navigation

    @objc private func didTapNext() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        goNext()
    }

    @objc private func didTapSkip() {
        let behavior = flow.schema.settings?.exitBehavior ?? "dismiss"
        if behavior == "block" { return }
        onDismiss?()
        dismiss(animated: true)
    }

    private func goNext() {
        if screenIndex >= screens.count - 1 {
            Intent.shared.trackFlowComplete(flowId: flow.id)
            dismiss(animated: true) { [weak self] in self?.onComplete?() }
            return
        }

        let style = flow.schema.settings?.transitionStyle ?? "slide"

        if style == "fade" {
            screenIndex += 1
            UIView.transition(with: scrollView, duration: 0.25, options: .transitionCrossDissolve) {
                self.renderCurrentScreen()
            }
            scrollView.setContentOffset(.zero, animated: false)
            return
        }

        // Slide transition: snapshot current state, slide new content in from right
        let snapshot = scrollView.snapshotView(afterScreenUpdates: false)
        screenIndex += 1
        renderCurrentScreen()
        scrollView.setContentOffset(.zero, animated: false)

        if let snapshot {
            snapshot.frame = scrollView.frame
            view.addSubview(snapshot)
            scrollView.transform = CGAffineTransform(translationX: view.bounds.width, y: 0)
            UIView.animate(withDuration: 0.34, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0.2, options: .curveEaseOut) {
                self.scrollView.transform = .identity
                snapshot.transform = CGAffineTransform(translationX: -self.view.bounds.width * 0.3, y: 0)
                snapshot.alpha = 0
            } completion: { _ in
                snapshot.removeFromSuperview()
            }
        }
    }
}

// MARK: - PaywallOption

private struct PaywallOption {
    let label: String
    let productId: String?
    let fallbackPrice: String
    let fallbackPerMonth: String?
    let badge: String?
    let highlighted: Bool
}

// MARK: - PricingCardView

private final class PricingCardView: UIView {
    private let option: PaywallOption
    private let theme: ResolvedTheme
    private let onTap: () -> Void
    private let priceLabel = UILabel()
    private let perMonthLabel = UILabel()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private var _isSelected = false

    init(option: PaywallOption, theme: ResolvedTheme, onTap: @escaping () -> Void) {
        self.option = option; self.theme = theme; self.onTap = onTap
        super.init(frame: .zero)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        layer.cornerRadius = theme.radius
        layer.borderWidth = 1.5
        updateAppearance()
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        let inner = UIStackView()
        inner.axis = .vertical
        inner.spacing = 4
        inner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            inner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            inner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            inner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])

        if let badge = option.badge { inner.addArrangedSubview(makeBadge(text: badge)) }

        let planLabel = UILabel()
        planLabel.text = option.label
        planLabel.font = theme.font(size: 14, weight: .medium)
        planLabel.textColor = theme.foreground.withAlphaComponent(0.7)
        inner.addArrangedSubview(planLabel)

        priceLabel.text = option.fallbackPrice
        priceLabel.font = theme.font(size: 22, weight: .black)
        priceLabel.textColor = option.highlighted ? theme.primary : theme.foreground
        inner.addArrangedSubview(priceLabel)

        if let pm = option.fallbackPerMonth, !pm.isEmpty {
            perMonthLabel.text = pm
            perMonthLabel.font = theme.font(size: 13)
            perMonthLabel.textColor = theme.foreground.withAlphaComponent(0.5)
            inner.addArrangedSubview(perMonthLabel)
        }

        loadingIndicator.color = theme.primary
        loadingIndicator.hidesWhenStopped = true
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(loadingIndicator)
        NSLayoutConstraint.activate([
            loadingIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func makeBadge(text: String) -> UIView {
        let container = UIView()
        container.backgroundColor = theme.primary
        container.layer.cornerRadius = 100
        let label = UILabel()
        label.text = text
        label.font = theme.font(size: 11, weight: .bold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        let wrapper = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(container)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            container.topAnchor.constraint(equalTo: wrapper.topAnchor),
            container.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
        ])
        return wrapper
    }

    func updatePrice(_ price: String, perMonth: String?) {
        priceLabel.text = price
        if let pm = perMonth, !pm.isEmpty { perMonthLabel.text = pm; perMonthLabel.isHidden = false }
    }
    func setSelected(_ selected: Bool) { _isSelected = selected; UIView.animate(withDuration: 0.18) { self.updateAppearance() } }
    func setLoading(_ loading: Bool) { loading ? loadingIndicator.startAnimating() : loadingIndicator.stopAnimating(); isUserInteractionEnabled = !loading }

    private func updateAppearance() {
        backgroundColor = _isSelected ? theme.primary.withAlphaComponent(0.15) : option.highlighted ? theme.primary.withAlphaComponent(0.07) : theme.secondary
        layer.borderColor = _isSelected ? theme.primary.cgColor : option.highlighted ? theme.primary.withAlphaComponent(0.4).cgColor : theme.foreground.withAlphaComponent(0.12).cgColor
    }
    @objc private func tapped() { onTap() }
}

// MARK: - OptionCardView (list layout)

private final class OptionCardView: UIView {
    private let option: QuizOption
    private let theme: ResolvedTheme
    private var _isSelected: () -> Bool
    private let onTap: () -> Void
    private let checkView = UIView()

    init(option: QuizOption, theme: ResolvedTheme, isSelected: @escaping () -> Bool, onTap: @escaping () -> Void) {
        self.option = option; self.theme = theme; self._isSelected = isSelected; self.onTap = onTap
        super.init(frame: .zero)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        layer.cornerRadius = theme.radius
        layer.borderWidth = 1.5
        updateColors()
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        if let icon = option.icon, !icon.isEmpty {
            let iconLabel = UILabel()
            iconLabel.text = icon
            iconLabel.font = .systemFont(ofSize: 24)
            iconLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
            iconLabel.textAlignment = .center
            row.addArrangedSubview(iconLabel)
        }

        let textStack = UIStackView()
        textStack.axis = .vertical
        textStack.spacing = 2
        let titleLabel = UILabel()
        titleLabel.text = option.label
        titleLabel.font = theme.font(size: 15, weight: .semibold)
        titleLabel.textColor = theme.foreground
        textStack.addArrangedSubview(titleLabel)
        if let desc = option.description, !desc.isEmpty {
            let descLabel = UILabel()
            descLabel.text = desc
            descLabel.font = theme.font(size: 13)
            descLabel.textColor = theme.foreground.withAlphaComponent(0.5)
            descLabel.numberOfLines = 2
            textStack.addArrangedSubview(descLabel)
        }
        row.addArrangedSubview(textStack)
        row.addArrangedSubview(UIView())

        checkView.backgroundColor = theme.primary
        checkView.layer.cornerRadius = 11
        checkView.widthAnchor.constraint(equalToConstant: 22).isActive = true
        checkView.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let checkLabel = UILabel()
        checkLabel.text = "✓"
        checkLabel.font = theme.font(size: 12, weight: .bold)
        checkLabel.textColor = .white
        checkLabel.textAlignment = .center
        checkLabel.translatesAutoresizingMaskIntoConstraints = false
        checkView.addSubview(checkLabel)
        NSLayoutConstraint.activate([
            checkLabel.centerXAnchor.constraint(equalTo: checkView.centerXAnchor),
            checkLabel.centerYAnchor.constraint(equalTo: checkView.centerYAnchor),
        ])
        row.addArrangedSubview(checkView)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
        ])
    }

    func updateSelection(_ selected: Bool) { UIView.animate(withDuration: 0.18) { self.updateColors() } }
    private func updateColors() {
        let selected = _isSelected()
        layer.borderColor = selected ? theme.primary.cgColor : theme.foreground.withAlphaComponent(0.15).cgColor
        backgroundColor = selected ? theme.primary.withAlphaComponent(0.1) : theme.secondary
        checkView.alpha = selected ? 1 : 0
    }
    @objc private func tapped() { onTap() }
}

// MARK: - GridOptionCardView (2-column layout)

private final class GridOptionCardView: UIView {
    private let option: QuizOption
    private let theme: ResolvedTheme
    private let _isSelected: () -> Bool
    private let onTap: () -> Void

    init(option: QuizOption, theme: ResolvedTheme, isSelected: @escaping () -> Bool, onTap: @escaping () -> Void) {
        self.option = option; self.theme = theme; self._isSelected = isSelected; self.onTap = onTap
        super.init(frame: .zero)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        layer.cornerRadius = theme.radius
        layer.borderWidth = 1.5
        updateColors()
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))

        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -20),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
        ])

        if let icon = option.icon, !icon.isEmpty {
            let iconLabel = UILabel()
            iconLabel.text = icon
            iconLabel.font = .systemFont(ofSize: 36)
            iconLabel.textAlignment = .center
            stack.addArrangedSubview(iconLabel)
        }

        let titleLabel = UILabel()
        titleLabel.text = option.label
        titleLabel.font = theme.font(size: 13, weight: .semibold)
        titleLabel.textColor = theme.foreground
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 2
        stack.addArrangedSubview(titleLabel)
    }

    private func updateColors() {
        let selected = _isSelected()
        layer.borderColor = selected ? theme.primary.cgColor : theme.foreground.withAlphaComponent(0.15).cgColor
        backgroundColor = selected ? theme.primary.withAlphaComponent(0.1) : theme.secondary
    }

    @objc private func tapped() {
        onTap()
        UIView.animate(withDuration: 0.18) { self.updateColors() }
    }
}

// MARK: - RadialGlowView

private final class RadialGlowView: UIView {
    private let color: UIColor
    private var glowLayer: CAGradientLayer?

    init(color: UIColor) {
        self.color = color
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if glowLayer == nil {
            let layer = CAGradientLayer()
            layer.type = .radial
            layer.colors = [color.withAlphaComponent(0.4).cgColor, color.withAlphaComponent(0).cgColor]
            layer.startPoint = CGPoint(x: 0.5, y: 0.5)
            layer.endPoint = CGPoint(x: 1.0, y: 1.0)
            self.layer.addSublayer(layer)
            glowLayer = layer
        }
        glowLayer?.frame = bounds
    }
}

// MARK: - ResolvedTheme

struct ResolvedTheme {
    let background: UIColor
    let backgroundGradient: String?
    let foreground: UIColor
    let primary: UIColor
    let primaryForeground: UIColor
    let secondary: UIColor
    let radius: CGFloat
    private let fontDesign: UIFontDescriptor.SystemDesign

    init(from theme: FlowTheme?) {
        background = UIColor(hex: theme?.background ?? "#0a0a0a")
        backgroundGradient = theme?.backgroundGradient
        foreground = UIColor(hex: theme?.foreground ?? "#f5f5f5")
        primary = UIColor(hex: theme?.primary ?? "#7c3aed")
        primaryForeground = UIColor(hex: theme?.primaryForeground ?? "#ffffff")
        secondary = UIColor(hex: theme?.secondary ?? "#1a1a1a")
        radius = theme?.radius ?? 12
        switch theme?.fontFamily {
        case "rounded": fontDesign = .rounded
        case "serif":   fontDesign = .serif
        case "mono", "monospaced": fontDesign = .monospaced
        default:        fontDesign = .default
        }
    }

    func font(size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard fontDesign != .default,
              let descriptor = base.fontDescriptor.withDesign(fontDesign) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

// MARK: - UIColor hex extension

extension UIColor {
    convenience init(hex: String) {
        var str = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.hasPrefix("#") { str = String(str.dropFirst()) }
        var rgb: UInt64 = 0
        Scanner(string: str).scanHexInt64(&rgb)
        let length = str.count
        if length == 6 {
            self.init(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
        } else if length == 8 {
            self.init(red: CGFloat((rgb >> 24) & 0xFF) / 255, green: CGFloat((rgb >> 16) & 0xFF) / 255, blue: CGFloat((rgb >> 8) & 0xFF) / 255, alpha: CGFloat(rgb & 0xFF) / 255)
        } else {
            self.init(white: 0.5, alpha: 1)
        }
    }
}

// MARK: - Array safe subscript

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

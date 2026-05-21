import UIKit

/// Renders an ACO flow schema as a native UIKit view controller.
/// Presented modally, it navigates through screens and calls onComplete/onDismiss.
///
/// Usage:
///   let vc = ACOFlowViewController(flow: flow, onComplete: {
///       // user finished — navigate to main app
///   })
///   present(vc, animated: true)
public final class ACOFlowViewController: UIViewController {

    // MARK: - Properties

    private let flow: ACOFlow
    private let onComplete: () -> Void
    private let onDismiss: (() -> Void)?

    private var screenIndex = 0
    private var quizAnswers: [String: Any] = [:]
    private var theme: ResolvedTheme

    private var screens: [FlowScreen] { flow.schema.screens }
    private var currentScreen: FlowScreen? { screens[safe: screenIndex] }

    // MARK: - UI

    private let progressView = UIProgressView(progressViewStyle: .default)
    private let skipButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private let contentStack = UIStackView()

    // MARK: - Init

    public init(
        flow: ACOFlow,
        onComplete: @escaping () -> Void,
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
        renderCurrentScreen()
    }

    // MARK: - Layout

    private func setupLayout() {
        view.backgroundColor = theme.background

        // Progress bar
        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.progressTintColor = theme.primary
        progressView.trackTintColor = theme.secondary
        progressView.layer.cornerRadius = 2
        progressView.clipsToBounds = true
        view.addSubview(progressView)

        // Skip button
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        skipButton.setTitle("Skip", for: .normal)
        skipButton.setTitleColor(theme.foreground.withAlphaComponent(0.5), for: .normal)
        skipButton.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        skipButton.addTarget(self, action: #selector(didTapSkip), for: .touchUpInside)
        skipButton.isHidden = !(flow.schema.settings?.canSkip ?? false)
        view.addSubview(skipButton)

        // Scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)

        // Content stack
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.axis = .vertical
        contentStack.spacing = 20
        contentStack.alignment = .fill
        scrollView.addSubview(contentStack)

        let safeArea = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            // Progress
            progressView.topAnchor.constraint(equalTo: safeArea.topAnchor, constant: 16),
            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            progressView.heightAnchor.constraint(equalToConstant: 4),

            // Skip button
            skipButton.centerYAnchor.constraint(equalTo: progressView.centerYAnchor),
            skipButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            skipButton.leadingAnchor.constraint(equalTo: progressView.trailingAnchor, constant: 12),
            skipButton.widthAnchor.constraint(equalToConstant: 40),

            // Scroll view
            scrollView.topAnchor.constraint(equalTo: progressView.bottomAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            // Content stack
            contentStack.topAnchor.constraint(equalTo: scrollView.topAnchor),
            contentStack.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -24),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -40),
            contentStack.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -48),
        ])
    }

    // MARK: - Screen rendering

    private func renderCurrentScreen() {
        guard let screen = currentScreen else { return }

        // Update progress
        let progress = Float(screenIndex + 1) / Float(max(screens.count, 1))
        if flow.schema.settings?.showProgress != false {
            progressView.setProgress(progress, animated: screenIndex > 0)
        }

        // Track screen view
        ACO.shared.trackScreenView(screenId: screen.id, flowId: flow.id)

        // Handle loading screen (auto-advance)
        if screen.type == "loading" {
            renderLoadingScreen(screen)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                self?.goNext()
            }
            return
        }

        // Clear and rebuild content
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for component in screen.components {
            if let view = makeComponentView(component: component, screen: screen) {
                contentStack.addArrangedSubview(view)
            }
        }
    }

    private func renderLoadingScreen(_ screen: FlowScreen) {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

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

    // MARK: - Component factory

    private func makeComponentView(component: FlowComponent, screen: FlowScreen) -> UIView? {
        let props = component.props

        switch component.type {

        // ── Text ──────────────────────────────────────────────────────────────

        case "heading":
            return makeLabel(
                text: props["text"]?.stringValue ?? "",
                font: .systemFont(ofSize: 28, weight: .bold),
                color: theme.foreground,
                lines: 0
            )

        case "subheading":
            return makeLabel(
                text: props["text"]?.stringValue ?? "",
                font: .systemFont(ofSize: 17, weight: .semibold),
                color: theme.foreground.withAlphaComponent(0.8),
                lines: 0
            )

        case "body", "text":
            return makeLabel(
                text: props["text"]?.stringValue ?? "",
                font: .systemFont(ofSize: 15, weight: .regular),
                color: theme.foreground.withAlphaComponent(0.6),
                lines: 0
            )

        case "badge", "label":
            return makeBadge(text: props["text"]?.stringValue ?? "")

        // ── Buttons ───────────────────────────────────────────────────────────

        case "button":
            return makePrimaryButton(title: props["text"]?.stringValue ?? "Continue")

        case "secondary_button":
            return makeSecondaryButton(title: props["text"]?.stringValue ?? "Skip")

        // ── Quiz options ──────────────────────────────────────────────────────

        case "options", "quiz_option":
            let quizKey = props["quizKey"]?.stringValue ?? screen.metadata?.quizKey ?? "answer"
            let options = screen.metadata?.quizOptions ?? []
            let multiSelect = screen.metadata?.multiSelect ?? false
            return makeOptionsStack(quizKey: quizKey, options: options, multiSelect: multiSelect)

        // ── Lists ─────────────────────────────────────────────────────────────

        case "list", "feature_list", "benefit_list":
            let rawItems = props["items"]?.arrayValue ?? []
            let items: [(String, String)] = rawItems.compactMap { item in
                if let s = item as? String { return ("✓", s) }
                if let d = item as? [String: Any] {
                    let text = (d["text"] as? String) ?? (d["label"] as? String) ?? ""
                    let icon = (d["icon"] as? String) ?? "✓"
                    return (icon, text)
                }
                return nil
            }
            return makeListView(items: items)

        // ── Social proof ──────────────────────────────────────────────────────

        case "testimonial":
            let quote = props["quote"]?.stringValue ?? props["text"]?.stringValue ?? ""
            let author = props["author"]?.stringValue ?? props["name"]?.stringValue ?? ""
            let rating = props["rating"]?.doubleValue.map { Int($0) }
            return makeTestimonialCard(quote: quote, author: author, rating: rating)

        case "stats", "social_proof":
            let rawItems = props["items"]?.arrayValue as? [[String: Any]] ?? []
            let items = rawItems.compactMap { d -> (String, String)? in
                guard let val = d["value"] as? String, let label = d["label"] as? String else { return nil }
                return (val, label)
            }
            return makeStatsRow(items: items)

        // ── Pricing ───────────────────────────────────────────────────────────

        case "pricing", "price_card", "pricing_option":
            let rawOptions = props["options"]?.arrayValue as? [[String: Any]] ?? []
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
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func makeBadge(text: String) -> UIView {
        let container = UIView()
        container.backgroundColor = theme.primary.withAlphaComponent(0.15)
        container.layer.cornerRadius = 100
        container.clipsToBounds = true

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.textColor = theme.primary
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let wrapper = UIView()
        wrapper.addSubview(container)
        container.translatesAutoresizingMaskIntoConstraints = false

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
        btn.titleLabel?.font = .systemFont(ofSize: 16, weight: .bold)
        btn.setTitleColor(theme.primaryForeground, for: .normal)
        btn.backgroundColor = theme.primary
        btn.layer.cornerRadius = theme.radius
        btn.heightAnchor.constraint(equalToConstant: 54).isActive = true
        btn.addTarget(self, action: #selector(didTapNext), for: .touchUpInside)
        return btn
    }

    private func makeSecondaryButton(title: String) -> UIButton {
        let btn = UIButton(type: .system)
        btn.setTitle(title, for: .normal)
        btn.titleLabel?.font = .systemFont(ofSize: 15, weight: .medium)
        btn.setTitleColor(theme.foreground.withAlphaComponent(0.6), for: .normal)
        btn.backgroundColor = .clear
        btn.layer.cornerRadius = theme.radius
        btn.layer.borderWidth = 1
        btn.layer.borderColor = theme.foreground.withAlphaComponent(0.2).cgColor
        btn.heightAnchor.constraint(equalToConstant: 50).isActive = true
        btn.addTarget(self, action: #selector(didTapNext), for: .touchUpInside)
        return btn
    }

    private func makeOptionsStack(quizKey: String, options: [QuizOption], multiSelect: Bool) -> UIView {
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
                    if multiSelect {
                        var current = self.quizAnswers[quizKey] as? [String] ?? []
                        if current.contains(option.value) {
                            current.removeAll { $0 == option.value }
                        } else {
                            current.append(option.value)
                        }
                        self.quizAnswers[quizKey] = current
                        optView.updateSelection(
                            (self.quizAnswers[quizKey] as? [String] ?? []).contains(option.value)
                        )
                    } else {
                        self.quizAnswers[quizKey] = option.value
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                            self.goNext()
                        }
                    }
                }
            )
            stack.addArrangedSubview(optView)
        }

        if multiSelect {
            let continueBtn = makePrimaryButton(title: "Continue")
            stack.addArrangedSubview(continueBtn)
        }

        return stack
    }

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
            iconLabel.font = .systemFont(ofSize: 15, weight: .bold)
            iconLabel.textColor = theme.primary
            iconLabel.widthAnchor.constraint(equalToConstant: 20).isActive = true
            iconLabel.textAlignment = .center

            let textLabel = UILabel()
            textLabel.text = text
            textLabel.font = .systemFont(ofSize: 15)
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
            stars.font = .systemFont(ofSize: 16)
            stars.textColor = UIColor(hex: "#F59E0B")
            stack.addArrangedSubview(stars)
        }

        let quoteLabel = UILabel()
        quoteLabel.text = ""\(quote)""
        quoteLabel.font = .italicSystemFont(ofSize: 15)
        quoteLabel.textColor = theme.foreground
        quoteLabel.numberOfLines = 0
        stack.addArrangedSubview(quoteLabel)

        if !author.isEmpty {
            let authorLabel = UILabel()
            authorLabel.text = "— \(author)"
            authorLabel.font = .systemFont(ofSize: 13, weight: .medium)
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
            valLabel.font = .systemFont(ofSize: 24, weight: .black)
            valLabel.textColor = theme.primary
            valLabel.textAlignment = .center

            let lblLabel = UILabel()
            lblLabel.text = label
            lblLabel.font = .systemFont(ofSize: 12, weight: .medium)
            lblLabel.textColor = theme.foreground.withAlphaComponent(0.5)
            lblLabel.textAlignment = .center
            lblLabel.numberOfLines = 2

            col.addArrangedSubview(valLabel)
            col.addArrangedSubview(lblLabel)
            stack.addArrangedSubview(col)
        }

        return stack
    }

    private func makePricingStack(options: [[String: Any]]) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 12

        for option in options {
            let highlighted = option["highlighted"] as? Bool ?? false
            let card = UIView()
            card.backgroundColor = highlighted ? theme.primary.withAlphaComponent(0.1) : theme.secondary
            card.layer.cornerRadius = theme.radius
            card.layer.borderWidth = highlighted ? 2 : 1
            card.layer.borderColor = highlighted
                ? theme.primary.cgColor
                : theme.foreground.withAlphaComponent(0.12).cgColor

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

            if let badge = option["badge"] as? String {
                let badgeView = UIView()
                badgeView.backgroundColor = theme.primary
                badgeView.layer.cornerRadius = 100
                badgeView.translatesAutoresizingMaskIntoConstraints = false

                let badgeLabel = UILabel()
                badgeLabel.text = badge
                badgeLabel.font = .systemFont(ofSize: 11, weight: .bold)
                badgeLabel.textColor = .white
                badgeLabel.translatesAutoresizingMaskIntoConstraints = false
                badgeView.addSubview(badgeLabel)

                let badgeWrapper = UIView()
                badgeWrapper.addSubview(badgeView)
                badgeView.translatesAutoresizingMaskIntoConstraints = false

                NSLayoutConstraint.activate([
                    badgeLabel.topAnchor.constraint(equalTo: badgeView.topAnchor, constant: 4),
                    badgeLabel.bottomAnchor.constraint(equalTo: badgeView.bottomAnchor, constant: -4),
                    badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 10),
                    badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -10),
                    badgeView.topAnchor.constraint(equalTo: badgeWrapper.topAnchor),
                    badgeView.bottomAnchor.constraint(equalTo: badgeWrapper.bottomAnchor),
                    badgeView.leadingAnchor.constraint(equalTo: badgeWrapper.leadingAnchor),
                ])
                inner.addArrangedSubview(badgeWrapper)
            }

            let planLabel = UILabel()
            planLabel.text = option["label"] as? String ?? ""
            planLabel.font = .systemFont(ofSize: 14, weight: .medium)
            planLabel.textColor = theme.foreground.withAlphaComponent(0.7)
            inner.addArrangedSubview(planLabel)

            let priceLabel = UILabel()
            priceLabel.text = option["price"] as? String ?? ""
            priceLabel.font = .systemFont(ofSize: 22, weight: .black)
            priceLabel.textColor = highlighted ? theme.primary : theme.foreground
            inner.addArrangedSubview(priceLabel)

            if let perMonth = option["perMonth"] as? String {
                let perMonthLabel = UILabel()
                perMonthLabel.text = perMonth
                perMonthLabel.font = .systemFont(ofSize: 13)
                perMonthLabel.textColor = theme.foreground.withAlphaComponent(0.5)
                inner.addArrangedSubview(perMonthLabel)
            }

            stack.addArrangedSubview(card)
        }

        return stack
    }

    private func makeGuaranteeRow(text: String) -> UIView {
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 8
        stack.alignment = .center

        let iconLabel = UILabel()
        iconLabel.text = "🛡️"
        iconLabel.font = .systemFont(ofSize: 16)

        let textLabel = UILabel()
        textLabel.text = text
        textLabel.font = .systemFont(ofSize: 13, weight: .medium)
        textLabel.textColor = theme.foreground.withAlphaComponent(0.5)
        textLabel.numberOfLines = 0

        stack.addArrangedSubview(iconLabel)
        stack.addArrangedSubview(textLabel)

        let wrapper = UIView()
        wrapper.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor),
            stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: wrapper.leadingAnchor),
        ])
        return wrapper
    }

    // MARK: - Navigation

    @objc private func didTapNext() { goNext() }
    @objc private func didTapSkip() {
        let behavior = flow.schema.settings?.exitBehavior ?? "dismiss"
        if behavior == "block" { return }
        onDismiss?()
        dismiss(animated: true)
    }

    private func goNext() {
        if screenIndex >= screens.count - 1 {
            ACO.shared.trackFlowComplete(flowId: flow.id)
            dismiss(animated: true) { [weak self] in
                self?.onComplete()
            }
        } else {
            screenIndex += 1
            UIView.transition(with: contentStack, duration: 0.25, options: .transitionCrossDissolve) {
                self.renderCurrentScreen()
            }
            scrollView.setContentOffset(.zero, animated: false)
        }
    }
}

// MARK: - Option card view

private final class OptionCardView: UIView {
    private let option: QuizOption
    private let theme: ResolvedTheme
    private var _isSelected: () -> Bool
    private let onTap: () -> Void

    private let borderLayer = CALayer()
    private let checkView = UIView()

    init(option: QuizOption, theme: ResolvedTheme, isSelected: @escaping () -> Bool, onTap: @escaping () -> Void) {
        self.option = option
        self.theme = theme
        self._isSelected = isSelected
        self.onTap = onTap
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        layer.cornerRadius = theme.radius
        layer.borderWidth = 1.5
        updateColors()

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)

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
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = theme.foreground
        textStack.addArrangedSubview(titleLabel)

        if let desc = option.description, !desc.isEmpty {
            let descLabel = UILabel()
            descLabel.text = desc
            descLabel.font = .systemFont(ofSize: 13)
            descLabel.textColor = theme.foreground.withAlphaComponent(0.5)
            descLabel.numberOfLines = 2
            textStack.addArrangedSubview(descLabel)
        }

        row.addArrangedSubview(textStack)
        row.addArrangedSubview(UIView()) // Spacer

        checkView.backgroundColor = theme.primary
        checkView.layer.cornerRadius = 11
        checkView.widthAnchor.constraint(equalToConstant: 22).isActive = true
        checkView.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let checkLabel = UILabel()
        checkLabel.text = "✓"
        checkLabel.font = .systemFont(ofSize: 12, weight: .bold)
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

    func updateSelection(_ selected: Bool) {
        UIView.animate(withDuration: 0.18) {
            self.updateColors()
        }
    }

    private func updateColors() {
        let selected = _isSelected()
        layer.borderColor = selected
            ? theme.primary.cgColor
            : theme.foreground.withAlphaComponent(0.15).cgColor
        backgroundColor = selected
            ? theme.primary.withAlphaComponent(0.1)
            : theme.secondary
        checkView.alpha = selected ? 1 : 0
    }

    @objc private func tapped() { onTap() }
}

// MARK: - ResolvedTheme

struct ResolvedTheme {
    let background: UIColor
    let foreground: UIColor
    let primary: UIColor
    let primaryForeground: UIColor
    let secondary: UIColor
    let radius: CGFloat

    init(from theme: FlowTheme?) {
        background = UIColor(hex: theme?.background ?? "#0a0a0a")
        foreground = UIColor(hex: theme?.foreground ?? "#f5f5f5")
        primary = UIColor(hex: theme?.primary ?? "#7c3aed")
        primaryForeground = UIColor(hex: theme?.primaryForeground ?? "#ffffff")
        secondary = UIColor(hex: theme?.secondary ?? "#1a1a1a")
        radius = theme?.radius ?? 12
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
            self.init(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        } else if length == 8 {
            self.init(
                red: CGFloat((rgb >> 24) & 0xFF) / 255,
                green: CGFloat((rgb >> 16) & 0xFF) / 255,
                blue: CGFloat((rgb >> 8) & 0xFF) / 255,
                alpha: CGFloat(rgb & 0xFF) / 255
            )
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

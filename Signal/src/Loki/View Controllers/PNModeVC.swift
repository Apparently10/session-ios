import PromiseKit

final class PNModeVC : BaseVC, OptionViewDelegate {

    private var optionViews: [OptionView] {
        [ apnsOptionView, backgroundPollingOptionView ]
    }

    private var selectedOptionView: OptionView? {
        return optionViews.first { $0.isSelected }
    }

    // MARK: Components
    private lazy var apnsOptionView = OptionView(title: NSLocalizedString("Apple Push Notification Service", comment: ""), explanation: NSLocalizedString("Session will use the Apple Push Notification Service to receive push notifications. You’ll be notified of new messages reliably and immediately. Using APNs means that this device will communicate directly with Apple’s servers to retrieve push notifications, which will expose your IP address to Apple. Your messages will still be onion-routed and end-to-end encrypted, so the contents of your messages will remain completely private.", comment: ""), delegate: self, isRecommended: true)
    private lazy var backgroundPollingOptionView = OptionView(title: NSLocalizedString("Background Polling", comment: ""), explanation: NSLocalizedString("Session will occasionally check for new messages in the background. This guarantees full privacy protection, but message notifications may be significantly delayed.", comment: ""), delegate: self)

    // MARK: Lifecycle
    override func viewDidLoad() {
        super.viewDidLoad()
        // Set gradient background
        view.backgroundColor = .clear
        let gradient = Gradients.defaultLokiBackground
        view.setGradient(gradient)
        // Set up navigation bar
        let navigationBar = navigationController!.navigationBar
        navigationBar.setBackgroundImage(UIImage(), for: UIBarMetrics.default)
        navigationBar.shadowImage = UIImage()
        navigationBar.isTranslucent = false
        navigationBar.barTintColor = Colors.navigationBarBackground
        // Set up logo image view
        let logoImageView = UIImageView()
        logoImageView.image = #imageLiteral(resourceName: "SessionGreen32")
        logoImageView.contentMode = .scaleAspectFit
        logoImageView.set(.width, to: 32)
        logoImageView.set(.height, to: 32)
        navigationItem.titleView = logoImageView
        // Set up title label
        let titleLabel = UILabel()
        titleLabel.textColor = Colors.text
        titleLabel.font = .boldSystemFont(ofSize: isSmallScreen ? Values.largeFontSize : Values.veryLargeFontSize)
        titleLabel.text = NSLocalizedString("Push Notifications", comment: "")
        titleLabel.numberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        // Set up explanation label
        let explanationLabel = UILabel()
        explanationLabel.textColor = Colors.text
        explanationLabel.font = .systemFont(ofSize: Values.smallFontSize)
        explanationLabel.text = NSLocalizedString("There are two ways Session can handle push notifications. Make sure to read the descriptions carefully before you choose.", comment: "")
        explanationLabel.numberOfLines = 0
        explanationLabel.lineBreakMode = .byWordWrapping
        // Set up spacers
        let topSpacer = UIView.vStretchingSpacer()
        let bottomSpacer = UIView.vStretchingSpacer()
        let registerButtonBottomOffsetSpacer = UIView()
        registerButtonBottomOffsetSpacer.set(.height, to: Values.onboardingButtonBottomOffset)
        // Set up register button
        let registerButton = Button(style: .prominentFilled, size: .large)
        registerButton.setTitle(NSLocalizedString("Continue", comment: ""), for: UIControl.State.normal)
        registerButton.titleLabel!.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        registerButton.addTarget(self, action: #selector(register), for: UIControl.Event.touchUpInside)
        // Set up register button container
        let registerButtonContainer = UIView(wrapping: registerButton, withInsets: UIEdgeInsets(top: 0, leading: Values.massiveSpacing, bottom: 0, trailing: Values.massiveSpacing))
        // Set up options stack view
        let optionsStackView = UIStackView(arrangedSubviews: optionViews)
        optionsStackView.axis = .vertical
        optionsStackView.spacing = Values.smallSpacing
        optionsStackView.alignment = .fill
        // Set up top stack view
        let topStackView = UIStackView(arrangedSubviews: [ titleLabel, explanationLabel, optionsStackView ])
        topStackView.axis = .vertical
        topStackView.spacing = isSmallScreen ? Values.smallSpacing : Values.veryLargeSpacing
        topStackView.alignment = .fill
        // Set up top stack view container
        let topStackViewContainer = UIView(wrapping: topStackView, withInsets: UIEdgeInsets(top: 0, leading: Values.veryLargeSpacing, bottom: 0, trailing: Values.veryLargeSpacing))
        // Set up main stack view
        let mainStackView = UIStackView(arrangedSubviews: [ topSpacer, topStackViewContainer, bottomSpacer, registerButtonContainer, registerButtonBottomOffsetSpacer ])
        mainStackView.axis = .vertical
        mainStackView.alignment = .fill
        view.addSubview(mainStackView)
        mainStackView.pin(to: view)
        topSpacer.heightAnchor.constraint(equalTo: bottomSpacer.heightAnchor, multiplier: 1).isActive = true
    }

    // MARK: Interaction
    func optionViewDidActivate(_ optionView: OptionView) {
        optionViews.filter { $0 != optionView }.forEach { $0.isSelected = false }
    }

    @objc private func register() {
        guard selectedOptionView != nil else {
            let title = NSLocalizedString("Please Pick an Option", comment: "")
            let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default, handler: nil))
            return present(alert, animated: true, completion: nil)
        }
        UserDefaults.standard[.isUsingFullAPNs] = (selectedOptionView == apnsOptionView)
        UserDefaults.standard[.hasSeenPNModeSheet] = true // Shouldn't be shown to users who've done the new onboarding
        TSAccountManager.sharedInstance().didRegister()
        let homeVC = HomeVC()
        navigationController!.setViewControllers([ homeVC ], animated: true)
        let _: Promise<Void> = SyncPushTokensJob.run(accountManager: AppEnvironment.shared.accountManager, preferences: Environment.shared.preferences)
    }
}

// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import MediaPlayer
import AVKit
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

final class CallVC: UIViewController, VideoPreviewDelegate, AVRoutePickerViewDelegate {
    private static let avatarRadius: CGFloat = (isIPhone6OrSmaller ? 100 : 120)
    private static let floatingVideoViewWidth: CGFloat = (UIDevice.current.isIPad ? 160 : 80)
    private static let floatingVideoViewHeight: CGFloat = (UIDevice.current.isIPad ? 346: 173)
    private static let minimizeButtonSize: CGFloat = 60
    
    private let dependencies: Dependencies
    let call: SessionCall
    var latestKnownAudioOutputDeviceName: String?
    var durationTimer: Timer?
    var shouldRestartCamera = true
    weak var conversationVC: ConversationVC? = nil
    
    lazy var cameraManager: CameraManager = {
        let result = CameraManager()
        result.delegate = self
        return result
    }()
    
    enum FloatingViewVideoSource {
        case local
        case remote
    }
    
    var floatingViewVideoSource: FloatingViewVideoSource = .local
    
    // MARK: - UI Components
    
    private lazy var floatingLocalVideoView: LocalVideoView = {
        let result = LocalVideoView()
        result.alpha = 0
        result.themeBackgroundColor = .backgroundSecondary
        result.set(.width, to: Self.floatingVideoViewWidth)
        result.set(.height, to: Self.floatingVideoViewHeight)
        
        return result
    }()
    
    private lazy var floatingRemoteVideoView: RemoteVideoView = {
        let result = RemoteVideoView()
        result.alpha = 0
        result.themeBackgroundColor = .backgroundSecondary
        result.set(.width, to: Self.floatingVideoViewWidth)
        result.set(.height, to: Self.floatingVideoViewHeight)
        
        return result
    }()
    
    private lazy var fullScreenLocalVideoView: LocalVideoView = {
        let result = LocalVideoView()
        result.alpha = 0
        result.themeBackgroundColor = .backgroundPrimary
        result.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleFullScreenVideoViewTapped)))
        
        return result
    }()
    
    private lazy var fullScreenRemoteVideoView: RemoteVideoView = {
        let result = RemoteVideoView()
        result.alpha = 0
        result.themeBackgroundColor = .backgroundPrimary
        result.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleFullScreenVideoViewTapped)))
        
        return result
    }()
    
    private lazy var floatingViewContainer: UIView = {
        let result = UIView()
        result.isHidden = true
        result.clipsToBounds = true
        result.layer.cornerRadius = UIDevice.current.isIPad ? 20 : 10
        result.layer.masksToBounds = true
        result.themeBackgroundColor = .backgroundSecondary
        result.makeViewDraggable()
        
        let noVideoIcon: UIImageView = UIImageView(
            image: UIImage(systemName: "video.slash")?
                .withRenderingMode(.alwaysTemplate)
        )
        noVideoIcon.themeTintColor = .textPrimary
        noVideoIcon.set(.width, to: 34)
        noVideoIcon.set(.height, to: 28)
        result.addSubview(noVideoIcon)
        noVideoIcon.center(in: result)
        
        result.addSubview(floatingLocalVideoView)
        floatingLocalVideoView.pin(to: result)
        
        result.addSubview(floatingRemoteVideoView)
        floatingRemoteVideoView.pin(to: result)
        
        let swappingVideoIcon: UIImageView = UIImageView(
            image: UIImage(systemName: "arrow.2.squarepath")?
                .withRenderingMode(.alwaysTemplate)
        )
        swappingVideoIcon.themeTintColor = .textPrimary
        swappingVideoIcon.set(.width, to: 16)
        swappingVideoIcon.set(.height, to: 12)
        result.addSubview(swappingVideoIcon)
        swappingVideoIcon.pin(.top, to: .top, of: result, withInset: Values.smallSpacing)
        swappingVideoIcon.pin(.trailing, to: .trailing, of: result, withInset: -Values.smallSpacing)
        
        result.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(switchVideo)))
        
        return result
    }()
    
    private lazy var fadeView: GradientView = {
        let height: CGFloat = ((UIApplication.shared.keyWindow?.safeAreaInsets.top)
            .map { $0 + Values.veryLargeSpacing })
            .defaulting(to: 64)

        let result: GradientView = GradientView()
        result.themeBackgroundGradient = [
            .value(.backgroundPrimary, alpha: 0.4),
            .value(.backgroundPrimary, alpha: 0)
        ]
        result.set(.height, to: height)

        return result
    }()
    
    public lazy var profilePictureView: SessionImageView = {
        let result: SessionImageView = SessionImageView(
            dataManager: dependencies[singleton: .imageDataManager]
        )
        result.set(.width, to: CallVC.avatarRadius * 2)
        result.set(.height, to: CallVC.avatarRadius * 2)
        result.layer.cornerRadius = CallVC.avatarRadius
        result.layer.masksToBounds = true
        result.contentMode = .scaleAspectFill
        
        return result
    }()
    
    private lazy var minimizeButton: UIButton = {
        let result = UIButton(type: .custom)
        result.setImage(
            UIImage(named: "Minimize")?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        result.themeTintColor = .textPrimary
        result.addTarget(self, action: #selector(minimize), for: UIControl.Event.touchUpInside)
        
        result.isHidden = !call.hasConnected
        result.set(.width, to: Self.minimizeButtonSize)
        result.set(.height, to: Self.minimizeButtonSize)
        
        return result
    }()
    
    private lazy var answerButton: UIButton = {
        let result = UIButton(type: .custom)
        result.accessibilityIdentifier = "Answer call"
        result.accessibilityLabel = "Answer call"
        result.setImage(
            UIImage(named: "AnswerCall")?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        result.themeTintColor = .white
        result.themeBackgroundColor = .callAccept_background
        result.layer.cornerRadius = 30
        result.addTarget(self, action: #selector(answerCall), for: UIControl.Event.touchUpInside)
        
        result.isHidden = call.hasStartedConnecting
        result.set(.width, to: 60)
        result.set(.height, to: 60)
        
        return result
    }()
    
    private lazy var hangUpButton: UIButton = {
        let result = UIButton(type: .custom)
        result.accessibilityLabel = "End call button"
        result.setImage(
            UIImage(named: "EndCall")?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        result.themeTintColor = .white
        result.themeBackgroundColor = .callDecline_background
        result.layer.cornerRadius = 30
        result.addTarget(self, action: #selector(endCall), for: UIControl.Event.touchUpInside)
        result.set(.width, to: 60)
        result.set(.height, to: 60)
        
        return result
    }()
    
    private lazy var responsePanel: UIStackView = {
        let result = UIStackView(arrangedSubviews: [hangUpButton, answerButton])
        result.axis = .horizontal
        result.spacing = Values.veryLargeSpacing * 2 + 40
        
        return result
    }()

    private lazy var switchCameraButton: UIButton = {
        let result = UIButton(type: .custom)
        result.isEnabled = call.isVideoEnabled
        result.setImage(
            UIImage(named: "SwitchCamera")?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        result.themeTintColor = .textPrimary
        result.themeBackgroundColor = .backgroundSecondary
        result.layer.cornerRadius = 30
        result.addTarget(self, action: #selector(switchCamera), for: UIControl.Event.touchUpInside)
        result.set(.width, to: 60)
        result.set(.height, to: 60)
        
        return result
    }()

    private lazy var switchAudioButton: UIButton = {
        let result = UIButton(type: .custom)
        result.setImage(
            UIImage(named: "AudioOff")?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        result.themeTintColor = (call.isMuted ?
            .white :
            .textPrimary
        )
        result.themeBackgroundColor = (call.isMuted ?
            .danger :
            .backgroundSecondary
        )
        result.layer.cornerRadius = 30
        result.addTarget(self, action: #selector(switchAudio), for: UIControl.Event.touchUpInside)
        result.set(.width, to: 60)
        result.set(.height, to: 60)
        
        return result
    }()
    
    private lazy var videoButton: UIButton = {
        let result = UIButton(type: .custom)
        result.setImage(
            UIImage(named: "VideoCall")?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        result.themeTintColor = .textPrimary
        result.themeBackgroundColor = .backgroundSecondary
        result.layer.cornerRadius = 30
        result.addTarget(self, action: #selector(operateCamera), for: UIControl.Event.touchUpInside)
        result.set(.width, to: 60)
        result.set(.height, to: 60)
        
        return result
    }()
    
    private lazy var routePickerView: AVRoutePickerView = {
        let result = AVRoutePickerView()
        result.delegate = self
        result.alpha = 0
        result.layer.cornerRadius = 30
        result.set(.width, to: 60)
        result.set(.height, to: 60)
        
        return result
    }()
    
    private lazy var routePickerButton: UIButton = {
        let result = UIButton(type: .custom)
        result.setImage(
            UIImage(named: "Speaker")?
                .withRenderingMode(.alwaysTemplate),
            for: .normal
        )
        result.themeTintColor = .textPrimary
        result.themeBackgroundColor = .backgroundSecondary
        result.layer.cornerRadius = 30
        result.addTarget(self, action: #selector(switchRoute), for: UIControl.Event.touchUpInside)
        result.set(.width, to: 60)
        result.set(.height, to: 60)
        
        return result
    }()
    
    private lazy var routePickerContainer: UIView = {
        let result = UIView()
        result.addSubview(routePickerView)
        routePickerView.pin(to: result)
        result.addSubview(routePickerButton)
        routePickerButton.pin(to: result)
        result.layer.cornerRadius = 30
        result.set(.width, to: 60)
        result.set(.height, to: 60)
        
        return result
    }()
    
    private lazy var operationPanel: UIStackView = {
        let result = UIStackView(arrangedSubviews: [switchCameraButton, videoButton, switchAudioButton, routePickerContainer])
        result.axis = .horizontal
        result.spacing = Values.veryLargeSpacing
        
        return result
    }()
    
    private lazy var titleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        
        return result
    }()
    
    private lazy var callInfoLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        
        if call.hasStartedConnecting { result.text = "callsConnecting".localized() }
        
        return result
    }()
    
    private lazy var callDetailedInfoLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        
        return result
    }()
    
    private lazy var callInfoLabelStackView: UIStackView = {
        let result: UIStackView = UIStackView(arrangedSubviews: [callInfoLabel, callDetailedInfoLabel])
        result.axis = .vertical
        result.spacing = Values.mediumSpacing
        result.isHidden = call.hasConnected
        
        return result
    }()
    
    private lazy var callDurationLabel: UILabel = {
        let result = UILabel()
        result.font = .boldSystemFont(ofSize: Values.veryLargeFontSize)
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.isHidden = true
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    init(for call: SessionCall, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.call = call
        
        super.init(nibName: nil, bundle: nil)
        
        setUpStateChangeCallbacks()
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
    }
    
    func setUpStateChangeCallbacks() {
        self.call.remoteVideoStateDidChange = { isEnabled in
            DispatchQueue.main.async {
                UIView.animate(withDuration: 0.25) {
                    let remoteVideoView: RemoteVideoView = self.floatingViewVideoSource == .remote ? self.floatingRemoteVideoView : self.fullScreenRemoteVideoView
                    remoteVideoView.alpha = isEnabled ? 1 : 0
                }
                
                if self.callInfoLabelStackView.alpha < 0.5 {
                    UIView.animate(withDuration: 0.25) {
                        self.operationPanel.alpha = 1
                        self.responsePanel.alpha = 1
                        self.callInfoLabelStackView.alpha = 1
                    }
                }
            }
        }
        
        self.call.hasStartedConnectingDidChange = {
            DispatchQueue.main.async {
                self.callInfoLabel.text = "callsConnecting".localized()
                self.answerButton.alpha = 0
                
                UIView.animate(
                    withDuration: 0.5,
                    delay: 0,
                    usingSpringWithDamping: 1,
                    initialSpringVelocity: 1,
                    options: .curveEaseIn,
                    animations: { [weak self] in
                        self?.answerButton.isHidden = true
                    },
                    completion: nil
                )
            }
        }
        
        self.call.hasConnectedDidChange = { [weak self] in
            DispatchQueue.main.async {
                CallRingTonePlayer.shared.stopPlayingRingTone()
                
                self?.minimizeButton.isHidden = false
                self?.durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    self?.updateDuration()
                }
                self?.callInfoLabelStackView.isHidden = true
                self?.callDurationLabel.isHidden = false
            }
        }
        
        self.call.hasEndedDidChange = { [weak self] in
            DispatchQueue.main.async {
                self?.durationTimer?.invalidate()
                self?.durationTimer = nil
                self?.handleEndCallMessage()
            }
        }
        
        self.call.hasStartedReconnecting = { [weak self] in
            DispatchQueue.main.async {
                self?.callInfoLabelStackView.isHidden = false
                self?.callDurationLabel.isHidden = true
                self?.callInfoLabel.text = "callsReconnecting".localized()
            }
        }
        
        self.call.hasReconnected = { [weak self] in
            DispatchQueue.main.async {
                self?.callInfoLabelStackView.isHidden = true
                self?.callDurationLabel.isHidden = false
            }
        }
        
        self.call.updateCallDetailedStatus = { [weak self] status in
            DispatchQueue.main.async {
                self?.callDetailedInfoLabel.text = status
            }
        }
    }
    
    required init(coder: NSCoder) { preconditionFailure("Use init(for:) instead.") }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.themeBackgroundColor = .backgroundPrimary
        
        setUpViewHierarchy()
        setUpProfilePictureImage()
        
        if shouldRestartCamera { cameraManager.prepare() }
        
        _ = call.videoCapturer // Force the lazy var to instantiate
        titleLabel.text = self.call.contactName
        if self.call.hasConnected {
            callDurationLabel.isHidden = false
            durationTimer?.invalidate()
            durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.updateDuration()
            }
        } else {
            callDurationLabel.isHidden = true
            dependencies[singleton: .callManager].startCall(call) { [weak self] error in
                DispatchQueue.main.async {
                    if let _ = error {
                        self?.callInfoLabel.text = "callsErrorStart".localized()
                        self?.endCall()
                    }
                    else {
                        self?.callInfoLabel.text = "callsRinging".localized()
                        self?.answerButton.isHidden = true
                    }
                }
            }
        }
        
        setUpOrientationMonitoring()
        NotificationCenter.default.addObserver(self, selector: #selector(audioRouteDidChange), name: AVAudioSession.routeChangeNotification, object: nil)
    }
    
    deinit {
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.removeObserver(self)
    }
    
    func setUpViewHierarchy() {
        // Profile picture container
        let profilePictureContainer = UIView()
        view.addSubview(profilePictureContainer)
        
        // Remote video view
        call.attachRemoteVideoRenderer(fullScreenRemoteVideoView)
        view.addSubview(fullScreenRemoteVideoView)
        fullScreenRemoteVideoView.translatesAutoresizingMaskIntoConstraints = false
        fullScreenRemoteVideoView.pin(to: view)
        
        // Local video view
        call.attachLocalVideoRenderer(floatingLocalVideoView)
        view.addSubview(fullScreenLocalVideoView)
        fullScreenLocalVideoView.translatesAutoresizingMaskIntoConstraints = false
        fullScreenLocalVideoView.pin(to: view)
        
        // Fade view
        view.addSubview(fadeView)
        fadeView.translatesAutoresizingMaskIntoConstraints = false
        fadeView.pin([ UIView.HorizontalEdge.left, UIView.VerticalEdge.top, UIView.HorizontalEdge.right ], to: view)
        
        // Minimize button
        view.addSubview(minimizeButton)
        minimizeButton.translatesAutoresizingMaskIntoConstraints = false
        minimizeButton.pin(.left, to: .left, of: view)
        minimizeButton.pin(.top, to: .top, of: view, withInset: 32)
        
        // Title label
        view.addSubview(titleLabel)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.center(.vertical, in: minimizeButton)
        titleLabel.pin(.leading, to: .trailing, of: minimizeButton, withInset: Values.smallSpacing)
        titleLabel.pin(.trailing, to: .trailing, of: view, withInset: -(Values.smallSpacing + Self.minimizeButtonSize))
        
        // Response Panel
        view.addSubview(responsePanel)
        responsePanel.center(.horizontal, in: view)
        responsePanel.pin(.bottom, to: .bottom, of: view.safeAreaLayoutGuide, withInset: -Values.smallSpacing)
        
        // Operation Panel
        view.addSubview(operationPanel)
        operationPanel.center(.horizontal, in: view)
        operationPanel.pin(.bottom, to: .top, of: responsePanel, withInset: -Values.veryLargeSpacing)
        
        // Profile picture view
        profilePictureContainer.pin(.top, to: .bottom, of: fadeView)
        profilePictureContainer.pin(.bottom, to: .top, of: operationPanel)
        profilePictureContainer.pin([ UIView.HorizontalEdge.left, UIView.HorizontalEdge.right ], to: view)
        profilePictureContainer.addSubview(profilePictureView)
        profilePictureView.center(in: profilePictureContainer)
        
        // Call info label
        let callInfoLabelContainer = UIView()
        view.addSubview(callInfoLabelContainer)
        callInfoLabelContainer.pin(.top, to: .bottom, of: profilePictureView)
        callInfoLabelContainer.pin(.bottom, to: .bottom, of: profilePictureContainer)
        callInfoLabelContainer.pin([ UIView.HorizontalEdge.left, UIView.HorizontalEdge.right ], to: view)
        callInfoLabelContainer.addSubview(callInfoLabelStackView)
        callInfoLabelContainer.addSubview(callDurationLabel)
        callInfoLabelStackView.translatesAutoresizingMaskIntoConstraints = false
        callInfoLabelStackView.center(in: callInfoLabelContainer)
        callDurationLabel.translatesAutoresizingMaskIntoConstraints = false
        callDurationLabel.center(in: callInfoLabelContainer)
    }
    
    func setUpProfilePictureImage() {
        let profile: Profile? = dependencies[singleton: .storage].read { [call] db in
            try Profile.fetchOne(db, id: call.sessionId)
        }
        
        switch profile?.profilePictureFileName {
            case .some(let fileName): profilePictureView.loadImage(from: fileName)
            case .none:
                profilePictureView.image = PlaceholderIcon.generate(
                    seed: call.sessionId,
                    text: call.contactName,
                    size: 300
                )
        }
    }
    
    private func addFloatingVideoView() {
        guard let window: UIWindow = dependencies[singleton: .appContext].mainWindow else { return }
        
        window.addSubview(floatingViewContainer)
        floatingViewContainer.pin(.top, to: .top, of: window, withInset: (window.safeAreaInsets.top + Values.veryLargeSpacing))
        floatingViewContainer.pin(.right, to: .right, of: window, withInset: -Values.smallSpacing)
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if (call.isVideoEnabled && shouldRestartCamera) { cameraManager.start() }
        
        shouldRestartCamera = true
        addFloatingVideoView()
        let remoteVideoView: RemoteVideoView = self.floatingViewVideoSource == .remote ? self.floatingRemoteVideoView : self.fullScreenRemoteVideoView
        remoteVideoView.alpha = (call.isRemoteVideoEnabled ? 1 : 0)
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        
        if (call.isVideoEnabled && shouldRestartCamera) { cameraManager.stop() }
        
        floatingViewContainer.removeFromSuperview()
    }
    
    // MARK: - Orientation

    private func setUpOrientationMonitoring() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(didChangeDeviceOrientation), name: UIDevice.orientationDidChangeNotification, object: UIDevice.current)
    }
    
    @objc func didChangeDeviceOrientation(notification: Notification) {
        if UIDevice.current.isIPad { return }

        func rotateAllButtons(rotationAngle: CGFloat) {
            let transform = CGAffineTransform(rotationAngle: rotationAngle)
            
            UIView.animate(withDuration: 0.2) {
                self.answerButton.transform = transform
                self.hangUpButton.transform = transform
                self.switchAudioButton.transform = transform
                self.switchCameraButton.transform = transform
                self.videoButton.transform = transform
                self.routePickerContainer.transform = transform
            }
        }
        
        switch UIDevice.current.orientation {
            case .portrait: rotateAllButtons(rotationAngle: 0)
            case .portraitUpsideDown: rotateAllButtons(rotationAngle: .pi)
            case .landscapeLeft: rotateAllButtons(rotationAngle: .pi * 0.5)
            case .landscapeRight: rotateAllButtons(rotationAngle: .pi * 1.5)
            default: break
        }
    }
    
    // MARK: Call signalling
    func handleAnswerMessage(_ message: CallMessage) {
        callInfoLabel.text = "callsConnecting".localized()
    }
    
    func handleEndCallMessage() {
        Log.info(.calls, "Ending call.")
        self.callInfoLabelStackView.isHidden = false
        self.callDurationLabel.isHidden = true
        self.callInfoLabel.text = "callsEnded".localized()
        
        UIView.animate(withDuration: 0.25) {
            let remoteVideoView: RemoteVideoView = self.floatingViewVideoSource == .remote ? self.floatingRemoteVideoView : self.fullScreenRemoteVideoView
            remoteVideoView.alpha = 0
            self.operationPanel.alpha = 1
            self.responsePanel.alpha = 1
            self.callInfoLabelStackView.alpha = 1
        }
        
        Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
            DispatchQueue.main.async {
                self?.dismiss(animated: true, completion: {
                    self?.conversationVC?.becomeFirstResponder()
                    self?.conversationVC?.showInputAccessoryView()
                })
            }
        }
    }
    
    @objc private func answerCall() {
        dependencies[singleton: .callManager].answerCall(call) { [weak self] error in
            DispatchQueue.main.async {
                if let _ = error {
                    self?.callInfoLabel.text = "callsErrorAnswer".localized()
                    self?.endCall()
                }
            }
        }
    }
    
    @objc private func endCall() {
        dependencies[singleton: .callManager].endCall(call) { [weak self, dependencies] error in
            if let _ = error {
                self?.call.endSessionCall()
                dependencies[singleton: .callManager].reportCurrentCallEnded(reason: .declinedElsewhere)
            }
            
            Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in
                DispatchQueue.main.async {
                    self?.dismiss(animated: true, completion: {
                        self?.conversationVC?.becomeFirstResponder()
                        self?.conversationVC?.showInputAccessoryView()
                    })
                }
            }
        }
    }
    
    // stringlint:ignore_contents
    @objc private func updateDuration() {
        guard let connectedDate = call.connectedDate else { return }
        let duration = Int(Date().timeIntervalSince1970 - connectedDate.timeIntervalSince1970)
        callDurationLabel.text = String(format: "%.2d:%.2d", duration/60, duration%60)
    }
    
    // MARK: - Minimize to a floating view
    
    @objc private func minimize() {
        self.shouldRestartCamera = false
        self.conversationVC?.becomeFirstResponder()
        self.conversationVC?.showInputAccessoryView()
        
        let miniCallView = MiniCallView(from: self, using: dependencies)
        miniCallView.show()
        
        presentingViewController?.dismiss(animated: true, completion: nil)
    }
    
    // MARK: - Video and Audio
    
    @objc private func operateCamera() {
        if (call.isVideoEnabled) {
            floatingViewContainer.isHidden = true
            cameraManager.stop()
            videoButton.themeTintColor = .textPrimary
            videoButton.themeBackgroundColor = .backgroundSecondary
            switchCameraButton.isEnabled = false
            call.isVideoEnabled = false
        }
        else {
            guard Permissions.requestCameraPermissionIfNeeded(using: dependencies) else {
                let confirmationModal: ConfirmationModal = ConfirmationModal(
                    info: ConfirmationModal.Info(
                        title: "permissionsRequired".localized(),
                        body: .text("permissionsCameraAccessRequiredCallsIos".localized()),
                        showCondition: .disabled,
                        confirmTitle: "sessionSettings".localized(),
                        onConfirm: { _ in
                            UIApplication.shared.openSystemSettings()
                        }
                    )
                )
                
                self.navigationController?.present(confirmationModal, animated: true, completion: nil)
                return
            }
            let previewVC = VideoPreviewVC()
            previewVC.delegate = self
            present(previewVC, animated: true, completion: nil)
        }
    }
    
    func cameraDidConfirmTurningOn() {
        floatingViewContainer.isHidden = false
        let localVideoView: LocalVideoView = self.floatingViewVideoSource == .local ? self.floatingLocalVideoView : self.fullScreenLocalVideoView
        localVideoView.alpha = 1
        cameraManager.prepare()
        cameraManager.start()
        videoButton.themeTintColor = .backgroundSecondary
        videoButton.themeBackgroundColor = .textPrimary
        switchCameraButton.isEnabled = true
        call.isVideoEnabled = true
    }
    
    @objc private func switchVideo() {
        if self.floatingViewVideoSource == .remote {
            call.removeRemoteVideoRenderer(self.floatingRemoteVideoView)
            call.removeLocalVideoRenderer(self.fullScreenLocalVideoView)
            
            self.floatingRemoteVideoView.alpha = 0
            self.floatingLocalVideoView.alpha = call.isVideoEnabled ? 1 : 0
            self.fullScreenRemoteVideoView.alpha = call.isRemoteVideoEnabled ? 1 : 0
            self.fullScreenLocalVideoView.alpha = 0
            
            self.floatingViewVideoSource = .local
            call.attachRemoteVideoRenderer(self.fullScreenRemoteVideoView)
            call.attachLocalVideoRenderer(self.floatingLocalVideoView)
        } else {
            call.removeRemoteVideoRenderer(self.fullScreenRemoteVideoView)
            call.removeLocalVideoRenderer(self.floatingLocalVideoView)
            
            self.floatingRemoteVideoView.alpha = call.isRemoteVideoEnabled ? 1 : 0
            self.floatingLocalVideoView.alpha = 0
            self.fullScreenRemoteVideoView.alpha = 0
            self.fullScreenLocalVideoView.alpha = call.isVideoEnabled ? 1 : 0
            
            self.floatingViewVideoSource = .remote
            call.attachRemoteVideoRenderer(self.floatingRemoteVideoView)
            call.attachLocalVideoRenderer(self.fullScreenLocalVideoView)
        }
    }
    
    @objc private func switchCamera() {
        cameraManager.switchCamera()
    }
    
    @objc private func switchAudio() {
        if call.isMuted {
            switchAudioButton.themeTintColor = .textPrimary
            switchAudioButton.themeBackgroundColor = .backgroundSecondary
            call.isMuted = false
        }
        else {
            switchAudioButton.themeTintColor = .white
            switchAudioButton.themeBackgroundColor = .danger
            call.isMuted = true
        }
    }
    
    @objc private func switchRoute() {
        simulateRoutePickerViewTapping()
    }
    
    private func simulateRoutePickerViewTapping() {
        guard let routeButton = routePickerView.subviews.first(where: { $0 is UIButton }) as? UIButton else {
            return
        }
        routeButton.sendActions(for: .touchUpInside)
    }
    
    @objc private func audioRouteDidChange() {
        let currentSession = AVAudioSession.sharedInstance()
        let currentRoute = currentSession.currentRoute
        if let currentOutput = currentRoute.outputs.first {
            if let latestKnownAudioOutputDeviceName = latestKnownAudioOutputDeviceName, currentOutput.portName == latestKnownAudioOutputDeviceName { return }
            
            latestKnownAudioOutputDeviceName = currentOutput.portName
            
            switch currentOutput.portType {
                case .builtInSpeaker:
                    let image = UIImage(named: "Speaker")?.withRenderingMode(.alwaysTemplate)
                    routePickerButton.setImage(image, for: .normal)
                    routePickerButton.themeTintColor = .backgroundSecondary
                    routePickerButton.themeBackgroundColor = .textPrimary
                    
                case .headphones:
                    let image = UIImage(named: "Headsets")?.withRenderingMode(.alwaysTemplate)
                    routePickerButton.setImage(image, for: .normal)
                    routePickerButton.themeTintColor = .backgroundSecondary
                    routePickerButton.themeBackgroundColor = .textPrimary
                    
                case .bluetoothLE: fallthrough
                case .bluetoothA2DP:
                    let image = UIImage(named: "Bluetooth")?.withRenderingMode(.alwaysTemplate)
                    routePickerButton.setImage(image, for: .normal)
                    routePickerButton.themeTintColor = .backgroundSecondary
                    routePickerButton.themeBackgroundColor = .textPrimary
                    
                case .bluetoothHFP:
                    let image = UIImage(named: "Airpods")?.withRenderingMode(.alwaysTemplate)
                    routePickerButton.setImage(image, for: .normal)
                    routePickerButton.themeTintColor = .backgroundSecondary
                    routePickerButton.themeBackgroundColor = .textPrimary
                    
                case .builtInReceiver: fallthrough
                default:
                    let image = UIImage(named: "Speaker")?.withRenderingMode(.alwaysTemplate)
                    routePickerButton.setImage(image, for: .normal)
                    routePickerButton.themeTintColor = .textPrimary
                    routePickerButton.themeBackgroundColor = .backgroundSecondary
            }
        }
    }
    
    @objc private func handleFullScreenVideoViewTapped(gesture: UITapGestureRecognizer) {
        let isHidden = callDurationLabel.alpha < 0.5
        
        UIView.animate(withDuration: 0.5) {
            self.operationPanel.alpha = isHidden ? 1 : 0
            self.responsePanel.alpha = isHidden ? 1 : 0
            self.callDurationLabel.alpha = isHidden ? 1 : 0
        }
    }
    
    // MARK: - AVRoutePickerViewDelegate
    
    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        
    }
    
    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
        
    }
}

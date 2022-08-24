// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SessionUIKit

public class ConfirmationModal: Modal {
    public struct Info: Equatable, Hashable {
        enum State {
            case whenEnabled
            case whenDisabled
            case always
            
            func shouldShow(for value: Bool) -> Bool {
                switch self {
                    case .whenEnabled: return (value == true)
                    case .whenDisabled: return (value == false)
                    case .always: return true
                }
            }
        }
        
        let title: String
        let explanation: String?
        let stateToShow: State
        let confirmTitle: String
        let confirmStyle: ThemeValue
        let cancelTitle: String
        let cancelStyle: ThemeValue
        let onConfirm: (() -> ())?
        
        init(
            title: String,
            explanation: String? = nil,
            stateToShow: State = .always,
            confirmTitle: String = "continue_2".localized(),
            confirmStyle: ThemeValue = .textPrimary,
            cancelTitle: String = "TXT_CANCEL_TITLE".localized(),
            cancelStyle: ThemeValue = .danger,
            onConfirm: (() -> ())? = nil
        ) {
            self.title = title
            self.explanation = explanation
            self.stateToShow = stateToShow
            self.confirmTitle = confirmTitle
            self.confirmStyle = confirmStyle
            self.cancelTitle = cancelTitle
            self.cancelStyle = cancelStyle
            self.onConfirm = onConfirm
        }
        
        public static func == (lhs: ConfirmationModal.Info, rhs: ConfirmationModal.Info) -> Bool {
            return (
                lhs.title == rhs.title &&
                lhs.explanation == rhs.explanation &&
                lhs.stateToShow == rhs.stateToShow &&
                lhs.confirmTitle == rhs.confirmTitle &&
                lhs.confirmStyle == rhs.confirmStyle &&
                lhs.cancelTitle == rhs.cancelTitle &&
                lhs.cancelStyle == rhs.cancelStyle
            )
        }
        
        public func hash(into hasher: inout Hasher) {
            title.hash(into: &hasher)
            explanation.hash(into: &hasher)
            stateToShow.hash(into: &hasher)
            confirmTitle.hash(into: &hasher)
            confirmStyle.hash(into: &hasher)
            cancelTitle.hash(into: &hasher)
            cancelStyle.hash(into: &hasher)
        }
    }
    
    private let onConfirm: (UIViewController) -> ()
    
    // MARK: - Components
    
    private lazy var titleLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .boldSystemFont(ofSize: Values.mediumFontSize)
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        
        return result
    }()
    
    private lazy var explanationLabel: UILabel = {
        let result: UILabel = UILabel()
        result.font = .systemFont(ofSize: Values.smallFontSize)
        result.themeTextColor = .textPrimary
        result.textAlignment = .center
        result.lineBreakMode = .byWordWrapping
        result.numberOfLines = 0
        
        return result
    }()
    
    private lazy var confirmButton: UIButton = {
        let result: UIButton = Modal.createButton(
            title: "",
            titleColor: .danger
        )
        result.addTarget(self, action: #selector(confirmationPressed), for: .touchUpInside)
        
        return result
    }()
    
    private lazy var buttonStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ confirmButton, cancelButton ])
        result.axis = .horizontal
        result.distribution = .fillEqually
        
        return result
    }()
    
    private lazy var contentStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ titleLabel, explanationLabel ])
        result.axis = .vertical
        result.spacing = Values.smallSpacing
        result.isLayoutMarginsRelativeArrangement = true
        result.layoutMargins = UIEdgeInsets(
            top: Values.largeSpacing,
            leading: Values.largeSpacing,
            bottom: Values.verySmallSpacing,
            trailing: Values.largeSpacing
        )
        
        return result
    }()
    
    private lazy var mainStackView: UIStackView = {
        let result = UIStackView(arrangedSubviews: [ contentStackView, buttonStackView ])
        result.axis = .vertical
        result.spacing = Values.largeSpacing - Values.smallFontSize / 2
        
        return result
    }()
    
    // MARK: - Lifecycle
    
    init(info: Info, onConfirm: @escaping (UIViewController) -> ()) {
        self.onConfirm = { viewController in
            onConfirm(viewController)
            info.onConfirm?()
        }
        
        super.init(nibName: nil, bundle: nil)
        
        self.modalPresentationStyle = .overFullScreen
        self.modalTransitionStyle = .crossDissolve
        
        // Set the content based on the provided info
        titleLabel.text = info.title
        explanationLabel.text = info.explanation
        explanationLabel.isHidden = (info.explanation == nil)
        confirmButton.setTitle(info.confirmTitle, for: .normal)
        confirmButton.setThemeTitleColor(info.confirmStyle, for: .normal)
        cancelButton.setTitle(info.cancelTitle, for: .normal)
        cancelButton.setThemeTitleColor(info.cancelStyle, for: .normal)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func populateContentView() {
        contentView.addSubview(mainStackView)
        
        mainStackView.pin(to: contentView)
    }
    
    // MARK: - Interaction
    
    @objc private func confirmationPressed() {
        onConfirm(self)
    }
}

// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import YYImage
import DifferenceKit
import SessionUIKit
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit
import SignalUtilitiesKit

class EditGroupViewModel: SessionTableViewModel, NavigatableStateHolder, EditableStateHolder, ObservableTableSource {
    private static let minVersionBannerInfo: InfoBanner.Info = InfoBanner.Info(
        font: .systemFont(ofSize: Values.verySmallFontSize),
        message: "groupInviteVersion".localized(),
        icon: .none,
        tintColor: .black,
        backgroundColor: .warning,
        accessibility: Accessibility(identifier: "Version warning banner")
    )
    
    public let dependencies: Dependencies
    public let navigatableState: NavigatableState = NavigatableState()
    public let editableState: EditableState<TableItem> = EditableState()
    public let state: TableDataState<Section, TableItem> = TableDataState()
    public let observableState: ObservableTableSourceState<Section, TableItem> = ObservableTableSourceState()
    private let selectedIdsSubject: CurrentValueSubject<Set<String>, Never> = CurrentValueSubject([])
    
    private let threadId: String
    private let userSessionId: SessionId
    private lazy var imagePickerHandler: ImagePickerHandler = ImagePickerHandler(
        onTransition: { [weak self] in self?.transitionToScreen($0, transitionType: $1) },
        onImageDataPicked: { [weak self] resultImageData in
            self?.updatedDisplayPictureSelected(update: .groupUploadImageData(resultImageData))
        }
    )
    fileprivate var newDisplayName: String?
    fileprivate var newGroupDescription: String?
    private var editDisplayPictureModal: ConfirmationModal?
    private var editDisplayPictureModalInfo: ConfirmationModal.Info?
    private var inviteByIdValue: String?
    
    // MARK: - Initialization
    
    init(threadId: String, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.threadId = threadId
        self.userSessionId = dependencies[cache: .general].sessionId
    }
    
    // MARK: - Config
    
    public enum Section: SessionTableSection {
        case groupInfo
        case invite
        case members
        
        public var title: String? {
            switch self {
                case .members: return "groupMembers".localized()
                default: return nil
            }
        }
        
        var style: SessionTableSectionStyle {
            switch self {
                case .members: return .titleEdgeToEdgeContent
                default: return .none
            }
        }
    }
    
    public enum TableItem: Equatable, Hashable, Differentiable {
        case avatar
        case groupName
        case groupDescription
        
        case invite
        case inviteById
        
        case member(String)
    }

    // MARK: - Content
    
    private struct State: Equatable {
        let group: ClosedGroup
        let profileFront: Profile?
        let profileBack: Profile?
        let members: [WithProfile<GroupMember>]
        let isValid: Bool
        
        static let invalidState: State = State(
            group: ClosedGroup(threadId: "", name: "", formationTimestamp: 0, shouldPoll: false, invited: false),
            profileFront: nil,
            profileBack: nil,
            members: [],
            isValid: false
        )
    }
    
    let title: String = "groupEdit".localized()
    
    var bannerInfo: AnyPublisher<InfoBanner.Info?, Never> { Just(EditGroupViewModel.minVersionBannerInfo).eraseToAnyPublisher() }
    
    lazy var observation: TargetObservation = ObservationBuilder
        .databaseObservation(self) { [dependencies, threadId, userSessionId] db -> State in
            guard let group: ClosedGroup = try ClosedGroup.fetchOne(db, id: threadId) else {
                return State.invalidState
            }
            
            var profileFront: Profile?
            var profileBack: Profile?
            
            if group.displayPictureFilename == nil {
                let frontProfileId: String? = try GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .filter(GroupMember.Columns.role == GroupMember.Role.standard)
                    .filter(GroupMember.Columns.profileId != userSessionId.hexString)
                    .select(min(GroupMember.Columns.profileId))
                    .asRequest(of: String.self)
                    .fetchOne(db)
                let backProfileId: String? = try GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .filter(GroupMember.Columns.role == GroupMember.Role.standard)
                    .filter(GroupMember.Columns.profileId != userSessionId.hexString)
                    .filter(GroupMember.Columns.profileId != frontProfileId)
                    .select(max(GroupMember.Columns.profileId))
                    .asRequest(of: String.self)
                    .fetchOne(db)
                
                profileFront = try frontProfileId.map { try Profile.fetchOne(db, id: $0) }
                profileBack = try Profile.fetchOne(db, id: backProfileId ?? userSessionId.hexString)
            }
            
            return State(
                group: group,
                profileFront: profileFront,
                profileBack: profileBack,
                members: try GroupMember
                    .filter(GroupMember.Columns.groupId == threadId)
                    .fetchAllWithProfiles(db, using: dependencies),
                isValid: true
            )
        }
        .compactMap { [weak self] state -> [SectionModel]? in self?.content(state) }
    
    private func content(_ state: State) -> [SectionModel] {
        guard state.isValid else {
            return [
                SectionModel(
                    model: .groupInfo,
                    elements: [
                        SessionCell.Info(
                            id: .groupName,
                            title: SessionCell.TextInfo(
                                "errorUnknown".localized(),
                                font: .subtitle,
                                alignment: .center
                            ),
                            styling: SessionCell.StyleInfo(
                                tintColor: .textSecondary,
                                alignment: .centerHugging,
                                customPadding: SessionCell.Padding(top: Values.smallSpacing),
                                backgroundStyle: .noBackground
                            )
                        )
                    ]
                )
            ]
        }
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let isUpdatedGroup: Bool = (((try? SessionId.Prefix(from: threadId)) ?? .group) == .group)
        let editIcon: UIImage? = UIImage(systemName: "pencil")
        let sortedMembers: [WithProfile<GroupMember>] = {
            guard !isUpdatedGroup else { return state.members }
            
            // FIXME: Remove this once legacy groups are deprecated
            /// In legacy groups there would be both `standard` and `admin` `GroupMember` entries for admins so
            /// pre-process the members in order to remove the duplicates
            return Array(state.members
                .sorted(by: { lhs, rhs in lhs.value.role.rawValue < rhs.value.role.rawValue })
                .reduce(into: [:]) { result, next in result[next.profileId] = next }
                .values)
        }()
        .sorted()
        
        return [
            SectionModel(
                model: .groupInfo,
                elements: [
                    SessionCell.Info(
                        id: .avatar,
                        accessory: .profile(
                            id: threadId,
                            size: .hero,
                            threadVariant: (isUpdatedGroup ? .group : .legacyGroup),
                            displayPictureFilename: state.group.displayPictureFilename,
                            profile: state.profileFront,
                            profileIcon: {
                                guard isUpdatedGroup && dependencies[feature: .updatedGroupsAllowDisplayPicture] else {
                                    return .none
                                }
                                
                                // If we already have a display picture then the main profile gets the icon
                                return (state.group.displayPictureFilename != nil ? .rightPlus : .none)
                            }(),
                            additionalProfile: state.profileBack,
                            additionalProfileIcon: {
                                guard isUpdatedGroup && dependencies[feature: .updatedGroupsAllowDisplayPicture] else {
                                    return .none
                                }
                                
                                // No display picture means the dual-profile so the additionalProfile gets the icon
                                return .rightPlus
                            }(),
                            accessibility: nil
                        ),
                        styling: SessionCell.StyleInfo(
                            alignment: .centerHugging,
                            customPadding: SessionCell.Padding(bottom: Values.smallSpacing),
                            backgroundStyle: .noBackground
                        ),
                        accessibility: Accessibility(
                            label: "Profile picture"
                        ),
                        onTap: { [weak self, dependencies] in
                            guard isUpdatedGroup && dependencies[feature: .updatedGroupsAllowDisplayPicture] else {
                                return
                            }
                            
                            self?.updateDisplayPicture(currentFileName: state.group.displayPictureFilename)
                        }
                    ),
                    SessionCell.Info(
                        id: .groupName,
                        leadingAccessory: .icon(
                            editIcon?.withRenderingMode(.alwaysTemplate),
                            size: .medium,
                            customTint: .textSecondary
                        ),
                        title: SessionCell.TextInfo(
                            state.group.name,
                            font: .titleLarge,
                            alignment: .center,
                            editingPlaceholder: "groupNameEnter".localized()
                        ),
                        styling: SessionCell.StyleInfo(
                            alignment: .centerHugging,
                            customPadding: SessionCell.Padding(
                                top: Values.smallSpacing,
                                leading: -((IconSize.medium.size + (Values.smallSpacing * 2)) / 2),
                                bottom: Values.smallSpacing,
                                interItem: 0
                            ),
                            backgroundStyle: .noBackground
                        ),
                        accessibility: Accessibility(
                            identifier: "Group name text field",
                            label: state.group.name
                        ),
                        onTap: { [weak self] in
                            self?.updateGroupNameAndDescription(
                                isUpdatedGroup: isUpdatedGroup,
                                currentName: state.group.name,
                                currentDescription: state.group.groupDescription
                            )
                        }
                    ),
                    ((state.group.groupDescription ?? "").isEmpty ? nil :
                        SessionCell.Info(
                            id: .groupDescription,
                            title: SessionCell.TextInfo(
                                (state.group.groupDescription ?? ""),
                                font: .subtitle,
                                alignment: .center,
                                editingPlaceholder: "groupDescriptionEnter".localized()
                            ),
                            styling: SessionCell.StyleInfo(
                                tintColor: .textSecondary,
                                alignment: .centerHugging,
                                customPadding: SessionCell.Padding(
                                    top: 0,
                                    bottom: Values.smallSpacing
                                ),
                                backgroundStyle: .noBackground
                            ),
                            accessibility: Accessibility(
                                identifier: "Group description text field",
                                label: (state.group.groupDescription ?? "")
                            ),
                            onTap: { [weak self] in
                               self?.updateGroupNameAndDescription(
                                   isUpdatedGroup: isUpdatedGroup,
                                   currentName: state.group.name,
                                   currentDescription: state.group.groupDescription
                               )
                           }
                        )
                     )
                ].compactMap { $0 }
            ),
            SectionModel(
                model: .invite,
                elements: [
                    SessionCell.Info(
                        id: .invite,
                        leadingAccessory:  .icon(UIImage(named: "icon_invite")?.withRenderingMode(.alwaysTemplate)),
                        title: "membersInvite".localized(),
                        accessibility: Accessibility(
                            identifier: "Add members",
                            label: "Add members"
                        ),
                        onTap: { [weak self] in self?.inviteContacts(currentGroupName: state.group.name) }
                    ),
                    (!isUpdatedGroup || !dependencies[feature: .updatedGroupsAllowInviteById] ? nil :
                        SessionCell.Info(
                            id: .inviteById,
                            leadingAccessory:  .icon(UIImage(named: "ic_plus_24")?.withRenderingMode(.alwaysTemplate)),
                            title: "accountIdOrOnsInvite".localized(),
                            accessibility: Accessibility(
                                identifier: "Invite by id",
                                label: "Invite by id"
                            ),
                            onTap: { [weak self] in self?.inviteById() }
                        )
                    )
                ].compactMap { $0 }
            ),
            SectionModel(
                model: .members,
                elements: sortedMembers
                    .map { memberInfo -> SessionCell.Info in
                        SessionCell.Info(
                            id: .member(memberInfo.profileId),
                            leadingAccessory:  .profile(
                                id: memberInfo.profileId,
                                profile: memberInfo.profile,
                                profileIcon: memberInfo.value.profileIcon
                            ),
                            title: SessionCell.TextInfo(
                                {
                                    guard memberInfo.profileId != userSessionId.hexString else { return "you".localized() }
                                    
                                    return (
                                        memberInfo.profile?.displayName() ??
                                        Profile.truncated(id: memberInfo.profileId, truncating: .middle)
                                    )
                                }(),
                                font: .title,
                                accessibility: Accessibility(
                                    identifier: "Contact"
                                )
                            ),
                            subtitle: (!isUpdatedGroup ? nil : SessionCell.TextInfo(
                                memberInfo.value.statusDescription,
                                font: .subtitle,
                                accessibility: Accessibility(
                                    identifier: "Contact status"
                                )
                            )),
                            trailingAccessory: {
                                switch (memberInfo.value.role, memberInfo.value.roleStatus) {
                                    case (.admin, _), (.moderator, _): return nil
                                    case (.standard, .failed), (.standard, .notSentYet), (.standard, .pending):
                                        return .highlightingBackgroundLabelAndRadio(
                                            title: "resend".localized(),
                                            isSelected: selectedIdsSubject.value.contains(memberInfo.profileId),
                                            labelAccessibility: Accessibility(
                                                identifier: "Resend invite button",
                                                label: "Resend invite button"
                                            ),
                                            radioAccessibility: Accessibility(
                                                identifier: "Select contact",
                                                label: "Select contact"
                                            )
                                        )
                                        
                                    case (.standard, .accepted), (.zombie, _):
                                        return .radio(
                                            isSelected: selectedIdsSubject.value.contains(memberInfo.profileId)
                                        )
                                }
                            }(),
                            styling: SessionCell.StyleInfo(
                                subtitleTintColor: (isUpdatedGroup ? memberInfo.value.statusDescriptionColor : nil),
                                allowedSeparators: [],
                                customPadding: SessionCell.Padding(
                                    top: Values.smallSpacing,
                                    bottom: Values.smallSpacing
                                ),
                                backgroundStyle: .noBackgroundEdgeToEdge
                            ),
                            onTapView: { [weak self, selectedIdsSubject] targetView in
                                let didTapResend: Bool = (targetView is SessionHighlightingBackgroundLabel)
                                
                                switch (memberInfo.value.role, memberInfo.value.roleStatus, didTapResend) {
                                    case (.moderator, _, _): return
                                    case (.admin, _, _):
                                        self?.showToast(
                                            text: "adminCannotBeRemoved".localized(),
                                            backgroundColor: .backgroundSecondary
                                        )
                                        
                                    case (.standard, .failed, true), (.standard, .notSentYet, true), (.standard, .pending, true):
                                        self?.resendInvitation(memberId: memberInfo.profileId)

                                    case (.standard, .failed, _), (.standard, .notSentYet, _), (.standard, .pending, _),
                                        (.standard, .accepted, _), (.zombie, _, _):
                                        if !selectedIdsSubject.value.contains(memberInfo.profileId) {
                                            selectedIdsSubject.send(selectedIdsSubject.value.inserting(memberInfo.profileId))
                                        }
                                        else {
                                            selectedIdsSubject.send(selectedIdsSubject.value.removing(memberInfo.profileId))
                                        }
                                        
                                        // Force the table data to be refreshed (the database wouldn't
                                        // have been changed)
                                        self?.forceRefresh(type: .postDatabaseQuery)
                                }
                            }
                        )
                    }
            )
        ]
    }
    
    lazy var footerButtonInfo: AnyPublisher<SessionButton.Info?, Never> = selectedIdsSubject
        .prepend([])
        .map { selectedIds in
            SessionButton.Info(
                style: .destructive,
                title: "remove".localized(),
                isEnabled: !selectedIds.isEmpty,
                accessibility: Accessibility(
                    identifier: "Remove contact button"
                ),
                onTap: { [weak self] in self?.removeMembers(memberIds: selectedIds) }
            )
        }
        .eraseToAnyPublisher()
    
    // MARK: - Functions
    
    private func updateDisplayPicture(currentFileName: String?) {
        guard dependencies[feature: .updatedGroupsAllowDisplayPicture] else { return }
        
        let existingImageData: Data? = dependencies[singleton: .storage].read { [threadId, dependencies] db in
            DisplayPictureManager.displayPicture(db, id: .group(threadId), using: dependencies)
        }
        let editDisplayPictureModalInfo: ConfirmationModal.Info = ConfirmationModal.Info(
            title: "groupSetDisplayPicture".localized(),
            body: .image(
                placeholderData: UIImage(named: "profile_placeholder")?.pngData(),
                valueData: existingImageData,
                icon: .rightPlus,
                style: .circular,
                accessibility: Accessibility(
                    identifier: "Image picker",
                    label: "Image picker"
                ),
                onClick: { [weak self] in self?.showPhotoLibraryForAvatar() }
            ),
            confirmTitle: "save".localized(),
            confirmEnabled: .afterChange { info in
                switch info.body {
                    case .image(_, let valueData, _, _, _, _): return (valueData != nil)
                    default: return false
                }
            },
            cancelTitle: "remove".localized(),
            cancelEnabled: .bool(existingImageData != nil),
            hasCloseButton: true,
            dismissOnConfirm: false,
            onConfirm: { [weak self] modal in
                switch modal.info.body {
                    case .image(_, .some(let valueData), _, _, _, _):
                        self?.updateDisplayPicture(
                            displayPictureUpdate: .groupUploadImageData(valueData),
                            onComplete: { [weak modal] in modal?.close() }
                        )
                        
                    default: modal.close()
                }
            },
            onCancel: { [weak self] modal in
                self?.updateDisplayPicture(
                    displayPictureUpdate: .groupRemove,
                    onComplete: { [weak modal] in modal?.close() }
                )
            },
            afterClosed: { [weak self] in
                self?.editDisplayPictureModal = nil
                self?.editDisplayPictureModalInfo = nil
            }
        )
        let modal: ConfirmationModal = ConfirmationModal(info: editDisplayPictureModalInfo)
            
        self.editDisplayPictureModalInfo = editDisplayPictureModalInfo
        self.editDisplayPictureModal = modal
        self.transitionToScreen(modal, transitionType: .present)
    }

    private func updatedDisplayPictureSelected(update: DisplayPictureManager.Update) {
        guard let info: ConfirmationModal.Info = self.editDisplayPictureModalInfo else { return }
        
        self.editDisplayPictureModal?.updateContent(
            with: info.with(
                body: .image(
                    placeholderData: UIImage(named: "profile_placeholder")?.pngData(),
                    valueData: {
                        switch update {
                            case .groupUploadImageData(let imageData): return imageData
                            default: return nil
                        }
                    }(),
                    icon: .rightPlus,
                    style: .circular,
                    accessibility: Accessibility(
                        identifier: "Image picker",
                        label: "Image picker"
                    ),
                    onClick: { [weak self] in self?.showPhotoLibraryForAvatar() }
                )
            )
        )
    }
    
    private func showPhotoLibraryForAvatar() {
        Permissions.requestLibraryPermissionIfNeeded(isSavingMedia: false, using: dependencies) { [weak self] in
            DispatchQueue.main.async {
                let picker: UIImagePickerController = UIImagePickerController()
                picker.sourceType = .photoLibrary
                picker.mediaTypes = [ "public.image" ]  // stringlint:disable
                picker.delegate = self?.imagePickerHandler
                
                self?.transitionToScreen(picker, transitionType: .present)
            }
        }
    }
    
    private func updateDisplayPicture(
        displayPictureUpdate: DisplayPictureManager.Update,
        onComplete: (() -> ())? = nil
    ) {
        switch displayPictureUpdate {
            case .none: onComplete?()
            default: break
        }
        
        func performChanges(_ viewController: ModalActivityIndicatorViewController, _ displayPictureUpdate: DisplayPictureManager.Update) {
            let existingFileName: String? = dependencies[singleton: .storage].read { [threadId] db in
                try? ClosedGroup
                    .filter(id: threadId)
                    .select(.displayPictureFilename)
                    .asRequest(of: String.self)
                    .fetchOne(db)
            }
            
            MessageSender
                .updateGroup(
                    groupSessionId: threadId,
                    displayPictureUpdate: displayPictureUpdate,
                    using: dependencies
                )
                .sinkUntilComplete(
                    receiveCompletion: { [dependencies] result in
                        // Remove any cached avatar image value
                        if let existingFileName: String = existingFileName {
                            dependencies.mutate(cache: .displayPicture) { $0.imageData[existingFileName] = nil }
                        }
                        
                        DispatchQueue.main.async {
                            viewController.dismiss(completion: {
                                onComplete?()
                            })
                        }
                    }
                )
        }
        
        let viewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self, dependencies] viewController in
            switch displayPictureUpdate {
                case .none, .currentUserRemove, .currentUserUploadImageData, .currentUserUpdateTo,
                    .contactRemove, .contactUpdateTo:
                    viewController.dismiss(animated: true) // Shouldn't get called
                
                case .groupRemove, .groupUpdateTo: performChanges(viewController, displayPictureUpdate)
                case .groupUploadImageData(let data):
                    DisplayPictureManager.prepareAndUploadDisplayPicture(
                        queue: DispatchQueue.global(qos: .background),
                        imageData: data,
                        success: { url, fileName, key in
                            performChanges(viewController, .groupUpdateTo(url: url, key: key, fileName: fileName))
                        },
                        failure: { error in
                            DispatchQueue.main.async {
                                viewController.dismiss {
                                    let message: String = {
                                        switch (displayPictureUpdate, error) {
                                            case (.groupRemove, _): return "profileDisplayPictureRemoveError".localized()
                                            case (_, .uploadMaxFileSizeExceeded):
                                                return "profileDisplayPictureSizeError".localized()
                                            
                                            default: return "profileErrorUpdate".localized()
                                        }
                                    }()
                                    
                                    self?.transitionToScreen(
                                        ConfirmationModal(
                                            info: ConfirmationModal.Info(
                                                title: "deleteAfterLegacyGroupsGroupUpdateErrorTitle".localized(),
                                                body: .text(message),
                                                cancelTitle: "okay".localized(),
                                                cancelStyle: .alert_text,
                                                dismissType: .single
                                            )
                                        ),
                                        transitionType: .present
                                    )
                                }
                            }
                        },
                        using: dependencies
                    )
            }
        }
        self.transitionToScreen(viewController, transitionType: .present)
    }
    
    private func updateGroupNameAndDescription(
        isUpdatedGroup: Bool,
        currentName: String,
        currentDescription: String?
    ) {
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "groupInformationSet".localized(),
                    body: { [weak self, dependencies] in
                        guard isUpdatedGroup && dependencies[feature: .updatedGroupsAllowDescriptionEditing] else {
                            return .input(
                                explanation: NSAttributedString(string: "EDIT_LEGACY_GROUP_INFO_MESSAGE"),//.localized()),
                                info: ConfirmationModal.Info.Body.InputInfo(
                                    placeholder: "groupNameEnter".localized(),
                                    initialValue: currentName
                                ),
                                onChange: { updatedName in
                                    self?.newDisplayName = updatedName
                                }
                            )
                        }
                        
                        return .dualInput(
                            explanation: NSAttributedString(string: "EDIT_GROUP_INFO_MESSAGE"),//.localized()),
                            firstInfo: ConfirmationModal.Info.Body.InputInfo(
                                placeholder: "groupNameEnter".localized(),
                                initialValue: currentName
                            ),
                            secondInfo: ConfirmationModal.Info.Body.InputInfo(
                                placeholder: "groupDescriptionEnter".localized(),
                                initialValue: currentDescription
                            ),
                            onChange: { updatedName, updatedDescription in
                                self?.newDisplayName = updatedName
                                self?.newGroupDescription = updatedDescription
                            }
                        )
                    }(),
                    confirmTitle: "save".localized(),
                    confirmEnabled: .afterChange { [weak self] _ in
                        self?.newDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                    },
                    cancelStyle: .danger,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self, dependencies, threadId] modal in
                        guard
                            let finalName: String = (self?.newDisplayName ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                .nullIfEmpty
                        else { return }
                        
                        let finalDescription: String? = self?.newGroupDescription
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        
                        /// Check if the data violates any of the size constraints
                        let maybeErrorString: String? = {
                            guard !Profile.isTooLong(profileName: finalName) else { return "groupNameEnterShorter".localized() }
                            
                            return "deleteAfterLegacyGroupsGroupUpdateErrorTitle".localized()
                        }()
                        
                        if let errorString: String = maybeErrorString {
                            self?.transitionToScreen(
                                ConfirmationModal(
                                    info: ConfirmationModal.Info(
                                        title: "theError".localized(),
                                        body: .text(errorString),
                                        cancelTitle: "okay".localized(),
                                        cancelStyle: .alert_text,
                                        dismissType: .single
                                    )
                                ),
                                transitionType: .present
                            )
                            return
                        }
                        
                        /// Update the group appropriately
                        MessageSender
                            .updateGroup(
                                groupSessionId: threadId,
                                name: finalName,
                                groupDescription: finalDescription,
                                using: dependencies
                            )
                            .sinkUntilComplete(
                                receiveCompletion: { [weak self] result in
                                    switch result {
                                        case .finished: modal.dismiss(animated: true)
                                        case .failure:
                                            self?.transitionToScreen(
                                                ConfirmationModal(
                                                    info: ConfirmationModal.Info(
                                                        title: "theError".localized(),
                                                        body: .text("deleteAfterLegacyGroupsGroupUpdateErrorTitle".localized()),
                                                        cancelTitle: "okay".localized(),
                                                        cancelStyle: .alert_text
                                                    )
                                                ),
                                                transitionType: .present
                                            )
                                    }
                                }
                            )
                    }
                )
            ),
            transitionType: .present
        )
    }
    
    private func inviteContacts(
        currentGroupName: String
    ) {
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        let currentMemberIds: Set<String> = (tableData
            .first(where: { $0.model == .members })?
            .elements
            .compactMap { item -> String? in
                switch item.id {
                    case .member(let profileId): return profileId
                    default: return nil
                }
            })
            .defaulting(to: [])
            .asSet()
        
        self.transitionToScreen(
            SessionTableViewController(
                viewModel: UserListViewModel<Contact>(
                    title: "membersInvite".localized(),
                    infoBanner: EditGroupViewModel.minVersionBannerInfo,
                    emptyState: "contactNone".localized(),
                    showProfileIcons: true,
                    request: SQLRequest("""
                        SELECT \(contact.allColumns)
                        FROM \(contact)
                        LEFT JOIN \(groupMember) ON (
                            \(groupMember[.groupId]) = \(threadId) AND
                            \(groupMember[.profileId]) = \(contact[.id])
                        )
                        WHERE \(groupMember[.profileId]) IS NULL
                    """),
                    footerTitle: "membersInviteTitle".localized(),
                    onSubmit: { [weak self, threadId, dependencies] in
                        switch try? SessionId.Prefix(from: threadId) {
                            case .group:
                                return .callback { viewModel, selectedMemberInfo in
                                    let updatedMemberIds: Set<String> = currentMemberIds
                                        .inserting(contentsOf: selectedMemberInfo.map { $0.profileId }.asSet())
                                    
                                    guard updatedMemberIds.count <= LibSession.sizeMaxGroupMemberCount else {
                                        throw UserListError.error("groupAddMemberMaximum".localized())
                                    }
                                    
                                    /// Show a toast that we have sent the invitations
                                    self?.showToast(
                                        text: (selectedMemberInfo.count == 1 ?
                                            "groupInviteSending".localized() :
                                            "groupInviteSending".localized()
                                        ),
                                        backgroundColor: .backgroundSecondary
                                    )
                                    
                                    /// Actually trigger the sending
                                    MessageSender
                                        .addGroupMembers(
                                            groupSessionId: threadId,
                                            members: selectedMemberInfo.map { ($0.profileId, $0.profile) },
                                            allowAccessToHistoricMessages: dependencies[feature: .updatedGroupsAllowHistoricAccessOnInvite],
                                            using: dependencies
                                        )
                                        .sinkUntilComplete(
                                            receiveCompletion: { result in
                                                switch result {
                                                    case .finished: break
                                                    case .failure:
                                                        viewModel?.showToast(
                                                            text: GroupInviteMemberJob.failureMessage(
                                                                groupName: currentGroupName,
                                                                memberIds: selectedMemberInfo.map { $0.profileId },
                                                                profileInfo: selectedMemberInfo
                                                                    .reduce(into: [:]) { result, next in
                                                                        result[next.profileId] = next.profile
                                                                    }
                                                            ),
                                                            backgroundColor: .backgroundSecondary
                                                        )
                                                }
                                            }
                                        )
                                }
                                
                            case .standard: // Assume it's a legacy group
                                return .publisher { [dependencies, threadId] _, selectedMemberInfo in
                                    let updatedMemberIds: Set<String> = currentMemberIds
                                        .inserting(contentsOf: selectedMemberInfo.map { $0.profileId }.asSet())
                                    
                                    guard updatedMemberIds.count <= LibSession.sizeMaxGroupMemberCount else {
                                        return Fail(error: .error("groupAddMemberMaximum".localized()))
                                            .eraseToAnyPublisher()
                                    }
                                    
                                    return MessageSender.update(
                                        legacyGroupSessionId: threadId,
                                        with: updatedMemberIds,
                                        name: currentGroupName,
                                        using: dependencies
                                    )
                                    .mapError { _ in UserListError.error("deleteAfterLegacyGroupsGroupUpdateErrorTitle".localized()) }
                                    .eraseToAnyPublisher()
                                }
                                
                            default: return .none
                        }
                    }(),
                    using: dependencies
                )
            ),
            transitionType: .push
        )
    }
    
    private func inviteById() {
        // Convenience functions to avoid duplicate code
        func showError(_ errorString: String) {
            let modal: ConfirmationModal = ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "theError".localized(),
                    body: .text(errorString),
                    cancelTitle: "okay".localized(),
                    cancelStyle: .alert_text,
                    dismissType: .single
                )
            )
            self.transitionToScreen(modal, transitionType: .present)
        }
        func inviteMember(_ accountId: String, _ modal: UIViewController) {
            guard !currentMemberIds.contains(accountId) else {
                // FIXME: Localise this
                return showError("This Account ID or ONS belongs to an existing member")
            }
            
            MessageSender.addGroupMembers(
                groupSessionId: threadId,
                members: [(accountId, nil)],
                allowAccessToHistoricMessages: dependencies[feature: .updatedGroupsAllowHistoricAccessOnInvite],
                using: dependencies
            ).sinkUntilComplete()
            modal.dismiss(animated: true) { [weak self] in
                self?.showToast(
                    text: "groupInviteSending".localized(),
                    backgroundColor: .backgroundSecondary
                )
            }
        }
        
        let currentMemberIds: Set<String> = (tableData
            .first(where: { $0.model == .members })?
            .elements
            .compactMap { item -> String? in
                switch item.id {
                    case .member(let profileId): return profileId
                    default: return nil
                }
            })
            .defaulting(to: [])
            .asSet()
        
        // Make sure inviting another member wouldn't hit the member limit
        guard (currentMemberIds.count + 1) <= LibSession.sizeMaxGroupMemberCount else {
            return showError("groupAddMemberMaximum".localized())
        }
        
        self.transitionToScreen(
            ConfirmationModal(
                info: ConfirmationModal.Info(
                    title: "accountIdOrOnsInvite".localized(),
                    body: .input(
                        explanation: nil,
                        info: ConfirmationModal.Info.Body.InputInfo(
                            placeholder: "accountIdOrOnsEnter".localized()
                        ),
                        onChange: { [weak self] updatedString in self?.inviteByIdValue = updatedString }
                    ),
                    confirmTitle: "membersInviteTitle".localized(),
                    confirmStyle: .danger,
                    cancelStyle: .alert_text,
                    dismissOnConfirm: false,
                    onConfirm: { [weak self, dependencies] modal in
                        // FIXME: Consolidate this with the logic in `NewDMVC`
                        switch Result(catching: { try SessionId(from: self?.inviteByIdValue) }) {
                            case .success(let sessionId) where sessionId.prefix == .standard: inviteMember(sessionId.hexString, modal)
                            case .success: return showError("accountIdErrorInvalid".localized())
                                
                            case .failure:
                                guard let inviteByIdValue: String = self?.inviteByIdValue else {
                                    return showError("accountIdErrorInvalid".localized())
                                }
                                
                                // This could be an ONS name
                                let viewController = ModalActivityIndicatorViewController() { modalActivityIndicator in
                                    SnodeAPI
                                        .getSessionID(for: inviteByIdValue, using: dependencies)
                                        .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                                        .receive(on: DispatchQueue.main)
                                        .sinkUntilComplete(
                                            receiveCompletion: { result in
                                                switch result {
                                                    case .finished: break
                                                    case .failure(let error):
                                                        modalActivityIndicator.dismiss {
                                                            switch error {
                                                                case SnodeAPIError.onsNotFound:
                                                                    return showError("onsErrorNotRecognized".localized())
                                                                default:
                                                                    return showError("onsErrorUnableToSearch".localized())
                                                            }
                                                        }
                                                }
                                            },
                                            receiveValue: { sessionIdHexString in
                                                modalActivityIndicator.dismiss {
                                                    inviteMember(sessionIdHexString, modal)
                                                }
                                            }
                                        )
                                }
                                self?.transitionToScreen(viewController, transitionType: .present)
                        }
                    },
                    afterClosed: { [weak self] in self?.inviteByIdValue = nil }
                )
            ),
            transitionType: .present
        )
    }
    
    private func resendInvitation(memberId: String) {
        MessageSender.resendInvitation(
            groupSessionId: threadId,
            memberId: memberId,
            using: dependencies
        )
        self.showToast(text: "groupInviteSending".localized())
    }
    
    private func removeMembers(memberIds: Set<String>) {
        guard !memberIds.isEmpty else { return }
        
        switch try? SessionId.Prefix(from: threadId) {
            case .group:
                MessageSender
                    .removeGroupMembers(
                        groupSessionId: threadId,
                        memberIds: memberIds,
                        removeTheirMessages: dependencies[feature: .updatedGroupsRemoveMessagesOnKick],
                        sendMemberChangedMessage: true,
                        using: dependencies
                    )
                    .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                    .sinkUntilComplete()
                self.selectedIdsSubject.send([])
            
            case .standard: // Assume it's a legacy group
                let updatedMemberIds: Set<String> = (tableData
                    .first(where: { $0.model == .members })?
                    .elements
                    .compactMap { item -> String? in
                        switch item.id {
                            case .member(let profileId): return profileId
                            default: return nil
                        }
                    })
                    .defaulting(to: [])
                    .asSet()
                    .removing(contentsOf: memberIds)
                
                let viewController = ModalActivityIndicatorViewController(canCancel: false) { [weak self, dependencies, threadId] modalActivityIndicator in
                    let currentGroupName: String = dependencies[singleton: .storage]
                        .read { db in
                            try ClosedGroup
                                .filter(id: threadId)
                                .select(.name)
                                .asRequest(of: String.self)
                                .fetchOne(db)
                        }
                        .defaulting(to: "groupUnknown".localized())
                    
                        MessageSender
                            .update(
                                legacyGroupSessionId: threadId,
                                with: updatedMemberIds,
                                name: currentGroupName,
                                using: dependencies
                            )
                            .eraseToAnyPublisher()
                            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                            .receive(on: DispatchQueue.main)
                            .sinkUntilComplete(
                                receiveCompletion: { [weak self] result in
                                    modalActivityIndicator.dismiss(completion: {
                                        switch result {
                                            case .finished: self?.selectedIdsSubject.send([])
                                            case .failure:
                                                self?.transitionToScreen(
                                                    ConfirmationModal(
                                                        info: ConfirmationModal.Info(
                                                            title: "theError".localized(),
                                                            body: .text("deleteAfterLegacyGroupsGroupUpdateErrorTitle".localized()),
                                                            cancelTitle: "okay".localized(),
                                                            cancelStyle: .alert_text
                                                        )
                                                    ),
                                                    transitionType: .present
                                                )
                                        }
                                    })
                                }
                            )
                }
                self.transitionToScreen(viewController, transitionType: .present)
            
            default:
                self.transitionToScreen(
                    ConfirmationModal(
                        info: ConfirmationModal.Info(
                            title: "theError".localized(),
                            body: .text("deleteAfterLegacyGroupsGroupUpdateErrorTitle".localized()),
                            cancelTitle: "okay".localized(),
                            cancelStyle: .alert_text
                        )
                    ),
                    transitionType: .present
                )
        }
    }
}

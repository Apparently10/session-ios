// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import Quick
import Nimble
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit

@testable import Session

class ThreadDisappearingMessagesSettingsViewModelSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            customMigrationTargets: [
                SNUtilitiesKit.self,
                SNSnodeKit.self,
                SNMessagingKit.self,
                SNUIKit.self
            ],
            initialData: { db in
                try SessionThread(
                    id: "TestId",
                    variant: .contact
                ).insert(db)
            }
        )
        @TestState var dependencies: Dependencies! = Dependencies(
            storage: mockStorage,
            scheduler: .immediate
        )
        @TestState var viewModel: ThreadDisappearingMessagesSettingsViewModel! = ThreadDisappearingMessagesSettingsViewModel(
            threadId: "TestId",
            threadVariant: .contact,
            currentUserIsClosedGroupMember: nil,
            currentUserIsClosedGroupAdmin: nil,
            config: DisappearingMessagesConfiguration.defaultWith("TestId"),
            using: dependencies
        )
        
        @TestState var cancellables: [AnyCancellable]! = [
            viewModel.observableTableData
                .receive(on: ImmediateScheduler.shared)
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { viewModel.updateTableData($0.0) }
                )
        ]
        
        // MARK: - a ThreadDisappearingMessagesSettingsViewModel
        describe("a ThreadDisappearingMessagesSettingsViewModel") {
            // MARK: -- has the correct title
            it("has the correct title") {
                expect(viewModel.title).to(equal("DISAPPEARING_MESSAGES".localized()))
            }
            
            // MARK: -- has the correct number of items
            it("has the correct number of items") {
                // The default disappearing messages configure is Off
                // Should only show one section of Disappearing Messages Type
                expect(viewModel.tableData.count).to(equal(1))
                
                if Features.useNewDisappearingMessagesConfig {
                    // Off
                    // Disappear After Read
                    // Disappear After Send
                    expect(viewModel.tableData.first?.elements.count).to(equal(3))
                } else {
                    // Off
                    // Legacy
                    // Disappear After Read
                    // Disappear After Send
                    expect(viewModel.tableData.first?.elements.count).to(equal(4))
                }
            }
            
            // MARK: -- has the correct default state
            it("has the correct default state") {
                // First option is always Off
                expect(viewModel.tableData.first?.elements.first)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesSettingsViewModel.Item(
                                    title: "DISAPPEARING_MESSAGES_OFF".localized()
                                ),
                                position: .top,
                                title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                rightAccessory: .radio(
                                    isSelected: { true }
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disable disappearing messages (Off option)",
                                    label: "Disable disappearing messages (Off option)"
                                )
                            )
                        )
                    )
                // Last option is always Disappear After Send
                expect(viewModel.tableData.first?.elements.last)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesSettingsViewModel.Item(
                                    title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized()
                                ),
                                position: .bottom,
                                title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_DESCRIPTION".localized(),
                                rightAccessory: .radio(
                                    isSelected: { false }
                                ),
                                isEnabled: Features.useNewDisappearingMessagesConfig,
                                accessibility: Accessibility(
                                    identifier: "Disappear after send option",
                                    label: "Disappear after send option"
                                )
                            )
                        )
                    )
            }
            
            // MARK: -- starts with the correct item active if not default
            it("starts with the correct item active if not default") {
                // Test config: Disappear After Send - 2 weeks
                let config: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration
                    .defaultWith("TestId")
                    .with(
                        isEnabled: true,
                        durationSeconds: DisappearingMessagesConfiguration.validDurationsSeconds(.disappearAfterSend).last,
                        type: .disappearAfterSend
                    )
                mockStorage.write { db in
                    _ = try config.saved(db)
                }
                viewModel = ThreadDisappearingMessagesSettingsViewModel(
                    threadId: "TestId",
                    threadVariant: .contact,
                    currentUserIsClosedGroupMember: nil,
                    currentUserIsClosedGroupAdmin: nil,
                    config: config,
                    using: dependencies
                )
                cancellables.append(
                    viewModel.observableTableData
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { viewModel.updateTableData($0.0) }
                        )
                )
                
                // Should have 2 sections now: Disappearing Messages Type & Timer
                expect(viewModel.tableData.count)
                    .to(equal(2))
                
                expect(viewModel.tableData.first?.elements.first)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesSettingsViewModel.Item(
                                    title: "DISAPPEARING_MESSAGES_OFF".localized()
                                ),
                                position: .top,
                                title: "DISAPPEARING_MESSAGES_OFF".localized(),
                                rightAccessory: .radio(
                                    isSelected: { false }
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disable disappearing messages (Off option)",
                                    label: "Disable disappearing messages (Off option)"
                                )
                            )
                        )
                    )
                
                expect(viewModel.tableData.first?.elements.last)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesSettingsViewModel.Item(
                                    title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized()
                                ),
                                position: .bottom,
                                title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_DESCRIPTION".localized(),
                                rightAccessory: .radio(
                                    isSelected: { true }
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disappear after send option",
                                    label: "Disappear after send option"
                                )
                            )
                        )
                    )
                
                let title: String = (DisappearingMessagesConfiguration.validDurationsSeconds(.disappearAfterSend).last?
                    .formatted(format: .long))
                    .defaulting(to: "")
                expect(viewModel.tableData.last?.elements.last)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesSettingsViewModel.Item(title: title),
                                position: .bottom,
                                title: title,
                                rightAccessory: .radio(
                                    isSelected: { true }
                                ),
                                accessibility: Accessibility(
                                    identifier: "Time option",
                                    label: "Time option"
                                )
                            )
                        )
                    )
            }
            
            it("has no footer button") {
                var footerButtonInfo: SessionButton.Info?
                
                cancellables.append(
                    viewModel.footerButtonInfo
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { info in footerButtonInfo = info }
                        )
                )
                
                expect(footerButtonInfo).to(beNil())
            }
            
            it("change to another setting and change back") {
                // Test config: Disappear After Send - 2 weeks
                let config: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration
                    .defaultWith("TestId")
                    .with(
                        isEnabled: true,
                        durationSeconds: DisappearingMessagesConfiguration.validDurationsSeconds(.disappearAfterSend).last,
                        type: .disappearAfterSend
                    )
                mockStorage.write { db in
                    _ = try config.saved(db)
                }
                viewModel = ThreadDisappearingMessagesSettingsViewModel(
                    threadId: "TestId",
                    threadVariant: .contact,
                    currentUserIsClosedGroupMember: nil,
                    currentUserIsClosedGroupAdmin: nil,
                    config: config,
                    using: dependencies
                )
                cancellables.append(
                    viewModel.observableTableData
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { viewModel.updateTableData($0.0) }
                        )
                )
                
                // Change to another setting
                viewModel.tableData.first?.elements.first?.onTap?()
                // Change back
                viewModel.tableData.first?.elements.last?.onTap?()
                
                expect(viewModel.tableData.first?.elements.last)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesSettingsViewModel.Item(
                                    title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized()
                                ),
                                position: .bottom,
                                title: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_TITLE".localized(),
                                subtitle: "DISAPPERING_MESSAGES_TYPE_AFTER_SEND_DESCRIPTION".localized(),
                                rightAccessory: .radio(
                                    isSelected: { true }
                                ),
                                accessibility: Accessibility(
                                    identifier: "Disappear after send option",
                                    label: "Disappear after send option"
                                )
                            )
                        )
                    )
                
                let title: String = (DisappearingMessagesConfiguration.validDurationsSeconds(.disappearAfterSend).last?
                    .formatted(format: .long))
                    .defaulting(to: "")
                expect(viewModel.tableData.last?.elements.last)
                    .to(
                        equal(
                            SessionCell.Info(
                                id: ThreadDisappearingMessagesSettingsViewModel.Item(title: title),
                                position: .bottom,
                                title: title,
                                rightAccessory: .radio(
                                    isSelected: { true }
                                ),
                                accessibility: Accessibility(
                                    identifier: "Time option",
                                    label: "Time option"
                                )
                            )
                        )
                    )
                
                var footerButtonInfo: SessionButton.Info?
                
                cancellables.append(
                    viewModel.footerButtonInfo
                        .receive(on: ImmediateScheduler.shared)
                        .sink(
                            receiveCompletion: { _ in },
                            receiveValue: { info in footerButtonInfo = info }
                        )
                )
                
                expect(footerButtonInfo).to(beNil())
            }
            
            // MARK: -- when changed from the previous setting
            context("when changed from the previous setting") {
                @TestState var footerButtonInfo: SessionButton.Info?
                
                beforeEach {
                    cancellables.append(
                        viewModel.footerButtonInfo
                            .receive(on: ImmediateScheduler.shared)
                            .sink(
                                receiveCompletion: { _ in },
                                receiveValue: { info in footerButtonInfo = info }
                            )
                    )
                    
                    viewModel.tableData.first?.elements.last?.onTap?()
                }
                
                // MARK: ---- shows the save button
                it("shows the set button") {
                    expect(footerButtonInfo)
                        .to(
                            equal(
                                SessionButton.Info(
                                    style: .bordered,
                                    title: "DISAPPERING_MESSAGES_SAVE_TITLE".localized(),
                                    isEnabled: true,
                                    accessibility: Accessibility(
                                        identifier: "Set button",
                                        label: "Set button"
                                    ),
                                    minWidth: 110,
                                    onTap: {}
                                )
                            )
                        )
                }

                // MARK: ---- and saving
                context("and saving") {
                    // MARK: ------ dismisses the screen
                    it("dismisses the screen") {
                        var didDismissScreen: Bool = false
                        
                        cancellables.append(
                            viewModel.dismissScreen
                                .receive(on: ImmediateScheduler.shared)
                                .sink(
                                    receiveCompletion: { _ in },
                                    receiveValue: { _ in didDismissScreen = true }
                                )
                        )
                        
                        footerButtonInfo?.onTap()
                        
                        expect(didDismissScreen).to(beTrue())
                    }
                    
                    // MARK: ------ saves the updated config
                    it("saves the updated config") {
                        footerButtonInfo?.onTap()
                        
                        let updatedConfig: DisappearingMessagesConfiguration? = mockStorage.read { db in
                            try DisappearingMessagesConfiguration.fetchOne(db, id: "TestId")
                        }
                        
                        expect(updatedConfig?.isEnabled).to(beTrue())
                        expect(updatedConfig?.durationSeconds)
                            .to(equal(DisappearingMessagesConfiguration.DefaultDuration.disappearAfterSend.seconds))
                        expect(updatedConfig?.type).to(equal(.disappearAfterSend))
                    }
                }
            }
        }
    }
}

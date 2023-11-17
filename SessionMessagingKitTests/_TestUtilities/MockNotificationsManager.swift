// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionMessagingKit
import SessionUtilitiesKit

public class MockNotificationsManager: Mock<NotificationsManagerType>, NotificationsManagerType {
    public func registerNotificationSettings() -> AnyPublisher<Void, Never> {
        return mock()
    }
    
    public func notifyUser(
        _ db: Database,
        for interaction: Interaction,
        in thread: SessionThread,
        applicationState: UIApplication.State,
        using dependencies: Dependencies
    ) {
        mockNoReturn(args: [interaction, thread, applicationState], untrackedArgs: [db, dependencies])
    }
    
    public func notifyUser(
        _ db: Database,
        forIncomingCall interaction: Interaction,
        in thread: SessionThread,
        applicationState: UIApplication.State
    ) {
        mockNoReturn(args: [interaction, thread, applicationState], untrackedArgs: [db])
    }
    
    public func notifyUser(
        _ db: Database,
        forReaction reaction: Reaction,
        in thread: SessionThread,
        applicationState: UIApplication.State
    ) {
        mockNoReturn(args: [reaction, thread, applicationState], untrackedArgs: [db])
    }
    
    public func notifyForFailedSend(_ db: Database, in thread: SessionThread, applicationState: UIApplication.State) {
        mockNoReturn(args: [thread, applicationState], untrackedArgs: [db])
    }
    
    public func cancelNotifications(identifiers: [String]) {
        mockNoReturn(args: [identifiers])
    }
    
    public func clearAllNotifications() {
        mockNoReturn()
    }
}

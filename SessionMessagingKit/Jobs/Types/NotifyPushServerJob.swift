// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import PromiseKit
import SessionSnodeKit
import SessionUtilitiesKit

public enum NotifyPushServerJob: JobExecutor {
    public static var maxFailureCount: Int = 20
    public static var requiresThreadId: Bool = false
    public static let requiresInteractionId: Bool = false
    
    public static func run(
        _ job: Job,
        queue: DispatchQueue,
        success: @escaping (Job, Bool, Dependencies) -> (),
        failure: @escaping (Job, Error?, Bool, Dependencies) -> (),
        deferred: @escaping (Job, Dependencies) -> (),
        dependencies: Dependencies = Dependencies()
    ) {
        guard
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder().decode(Details.self, from: detailsData)
        else {
            failure(job, JobRunnerError.missingRequiredDetails, true, dependencies)
            return
        }
        
        PushNotificationAPI
            .notify(
                recipient: details.message.recipient,
                with: details.message.data,
                maxRetryCount: 4,
                queue: queue
            )
            .done(on: queue) { _ in success(job, false, dependencies) }
            .catch(on: queue) { error in failure(job, error, false, dependencies) }
            .retainUntilComplete()
    }
}

// MARK: - NotifyPushServerJob.Details

extension NotifyPushServerJob {
    public struct Details: Codable {
        public let message: SnodeMessage
    }
}

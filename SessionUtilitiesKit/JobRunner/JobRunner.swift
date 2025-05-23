// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB

// MARK: - Singleton

public extension Singleton {
    static let jobRunner: SingletonConfig<JobRunnerType> = Dependencies.create(
        identifier: "jobRunner",
        createInstance: { dependencies in JobRunner(using: dependencies) }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let jobRunner: Log.Category = .create("JobRunner", defaultLevel: .info)
}

// MARK: - JobRunnerType

public protocol JobRunnerType: AnyObject {
    // MARK: - Configuration
    
    func setExecutor(_ executor: JobExecutor.Type, for variant: Job.Variant)
    func canStart(queue: JobQueue?) -> Bool
    func afterBlockingQueue(callback: @escaping () -> ())
    func queue(for variant: Job.Variant) -> DispatchQueue?
        
    // MARK: - State Management
    
    func jobInfoFor(jobs: [Job]?, state: JobRunner.JobState, variant: Job.Variant?) -> [Int64: JobRunner.JobInfo]
    func deferCount(for jobId: Int64?, of variant: Job.Variant) -> Int
    
    func appDidFinishLaunching()
    func appDidBecomeActive()
    func startNonBlockingQueues()
    
    /// Stops and clears any pending jobs except for the specified variant, the `onComplete` closure will be called once complete providing a flag indicating whether any additional
    /// processing was needed before the closure was called (if not then the closure will be called synchronously)
    func stopAndClearPendingJobs(exceptForVariant: Job.Variant?, onComplete: ((Bool) -> ())?)
    
    // MARK: - Job Scheduling
    
    @discardableResult func add(_ db: Database, job: Job?, dependantJob: Job?, canStartJob: Bool) -> Job?
    @discardableResult func upsert(_ db: Database, job: Job?, canStartJob: Bool) -> Job?
    @discardableResult func insert(_ db: Database, job: Job?, before otherJob: Job) -> (Int64, Job)?
    func enqueueDependenciesIfNeeded(_ jobs: [Job])
    func manuallyTriggerResult(_ job: Job?, result: JobRunner.JobResult)
    func afterJob(_ job: Job?, state: JobRunner.JobState) -> AnyPublisher<JobRunner.JobResult, Never>
    func removePendingJob(_ job: Job?)
    
    func registerRecurringJobs(scheduleInfo: [JobRunner.ScheduleInfo])
    func scheduleRecurringJobsIfNeeded()
}

// MARK: - JobRunnerType Convenience

public extension JobRunnerType {
    func allJobInfo() -> [Int64: JobRunner.JobInfo] { return jobInfoFor(jobs: nil, state: .any, variant: nil) }
    
    func jobInfoFor(jobs: [Job]) -> [Int64: JobRunner.JobInfo] {
        return jobInfoFor(jobs: jobs, state: .any, variant: nil)
    }

    func jobInfoFor(jobs: [Job], state: JobRunner.JobState) -> [Int64: JobRunner.JobInfo] {
        return jobInfoFor(jobs: jobs, state: state, variant: nil)
    }

    func jobInfoFor(state: JobRunner.JobState) -> [Int64: JobRunner.JobInfo] {
        return jobInfoFor(jobs: nil, state: state, variant: nil)
    }

    func jobInfoFor(state: JobRunner.JobState, variant: Job.Variant) -> [Int64: JobRunner.JobInfo] {
        return jobInfoFor(jobs: nil, state: state, variant: variant)
    }

    func jobInfoFor(variant: Job.Variant) -> [Int64: JobRunner.JobInfo] {
        return jobInfoFor(jobs: nil, state: .any, variant: variant)
    }
    
    func isCurrentlyRunning(_ job: Job?) -> Bool {
        guard let job: Job = job else { return false }
        
        return !jobInfoFor(jobs: [job], state: .running, variant: nil).isEmpty
    }
    
    func hasJob<T: Encodable>(
        of variant: Job.Variant? = nil,
        inState state: JobRunner.JobState = .any,
        with jobDetails: T
    ) -> Bool {
        guard
            let detailsData: Data = try? JSONEncoder()
                .with(outputFormatting: .sortedKeys)    // Needed for deterministic comparison
                .encode(jobDetails)
        else { return false }
        
        return jobInfoFor(jobs: nil, state: state, variant: variant)
            .values
            .contains(where: { $0.detailsData == detailsData })
    }
    
    func stopAndClearPendingJobs() {
        stopAndClearPendingJobs(exceptForVariant: nil, onComplete: nil)
    }
    
    // MARK: -- Job Scheduling
    
    @discardableResult func add(_ db: Database, job: Job?, canStartJob: Bool) -> Job? {
        return add(db, job: job, dependantJob: nil, canStartJob: canStartJob)
    }
    
    func afterJob(_ job: Job?) -> AnyPublisher<JobRunner.JobResult, Never> {
        return afterJob(job, state: .any)
    }
}

// MARK: - JobExecutor

public protocol JobExecutor {
    /// The maximum number of times the job can fail before it fails permanently
    ///
    /// **Note:** A value of `-1` means it will retry indefinitely
    static var maxFailureCount: Int { get }
    static var requiresThreadId: Bool { get }
    static var requiresInteractionId: Bool { get }

    /// This method contains the logic needed to complete a job
    ///
    /// **Note:** The code in this method should run synchronously and the various
    /// "result" blocks should not be called within a database closure
    ///
    /// - Parameters:
    ///   - job: The job which is being run
    ///   - success: The closure which is called when the job succeeds (with an
    ///   updated `job` and a flag indicating whether the job should forcibly stop running)
    ///   - failure: The closure which is called when the job fails (with an updated
    ///   `job`, an `Error` (if applicable) and a flag indicating whether it was a permanent
    ///   failure)
    ///   - deferred: The closure which is called when the job is deferred (with an
    ///   updated `job`)
    static func run<S: Scheduler>(
        _ job: Job,
        scheduler: S,
        success: @escaping (Job, Bool) -> Void,
        failure: @escaping (Job, Error, Bool) -> Void,
        deferred: @escaping (Job) -> Void,
        using dependencies: Dependencies
    )
}

// MARK: - JobRunner

public final class JobRunner: JobRunnerType {
    public struct JobState: OptionSet, Hashable {
        public let rawValue: UInt8
        
        public init(rawValue: UInt8) {
            self.rawValue = rawValue
        }
        
        public static let pending: JobState = JobState(rawValue: 1 << 0)
        public static let running: JobState = JobState(rawValue: 1 << 1)
        
        public static let any: JobState = [ .pending, .running ]
    }
    
    public enum JobResult: Equatable {
        case succeeded
        case failed(Error, Bool)
        case deferred
        case notFound
        
        public static func == (lhs: JobRunner.JobResult, rhs: JobRunner.JobResult) -> Bool {
            switch (lhs, rhs) {
                case (.succeeded, .succeeded): return true
                case (.failed(let lhsError, let lhsPermanent), .failed(let rhsError, let rhsPermanent)):
                    return (
                        // Not a perfect solution but should be good enough
                        "\(lhsError)" == "\(rhsError)" &&
                        lhsPermanent == rhsPermanent
                    )
                    
                case (.deferred, .deferred): return true
                default: return false
            }
        }
    }

    public struct JobInfo: Equatable, CustomDebugStringConvertible {
        public let variant: Job.Variant
        public let threadId: String?
        public let interactionId: Int64?
        public let detailsData: Data?
        public let uniqueHashValue: Int?
        
        public var debugDescription: String {
            let dataDescription: String = detailsData
                .map { data in "Data(hex: \(data.toHexString()), \(data.bytes.count) bytes" }
                .defaulting(to: "nil")
            
            return [
                "JobRunner.JobInfo(",
                "variant: \(variant),",
                " threadId: \(threadId ?? "nil"),",
                " interactionId: \(interactionId.map { "\($0)" } ?? "nil"),",
                " detailsData: \(dataDescription),",
                " uniqueHashValue: \(uniqueHashValue.map { "\($0)" } ?? "nil")",
                ")"
            ].joined()
        }
    }
    
    public typealias ScheduleInfo = (
        variant: Job.Variant,
        behaviour: Job.Behaviour,
        shouldBlock: Bool,
        shouldSkipLaunchBecomeActive: Bool
    )
    
    private enum Validation {
        case enqueueOnly
        case persist
    }
    
    // MARK: - Variables
    
    private let dependencies: Dependencies
    private let allowToExecuteJobs: Bool
    @ThreadSafeObject private var blockingQueue: JobQueue?
    @ThreadSafeObject private var queues: [Job.Variant: JobQueue]
    @ThreadSafeObject private var blockingQueueDrainCallback: [() -> ()] = []
    @ThreadSafeObject private var registeredRecurringJobs: [JobRunner.ScheduleInfo] = []
    
    @ThreadSafe internal var appReadyToStartQueues: Bool = false
    @ThreadSafe internal var appHasBecomeActive: Bool = false
    @ThreadSafeObject internal var perSessionJobsCompleted: Set<Int64> = []
    @ThreadSafe internal var hasCompletedInitialBecomeActive: Bool = false
    @ThreadSafeObject internal var shutdownBackgroundTask: SessionBackgroundTask? = nil
    
    private var canStartNonBlockingQueue: Bool {
        blockingQueue?.hasStartedAtLeastOnce == true &&
        blockingQueue?.isRunning != true &&
        appHasBecomeActive
    }
    
    // MARK: - Initialization
    
    init(
        isTestingJobRunner: Bool = false,
        variantsToExclude: [Job.Variant] = [],
        using dependencies: Dependencies
    ) {
        var jobVariants: Set<Job.Variant> = Job.Variant.allCases
            .filter { !variantsToExclude.contains($0) }
            .asSet()
        
        self.dependencies = dependencies
        self.allowToExecuteJobs = (
            isTestingJobRunner || (
                dependencies[singleton: .appContext].isMainApp &&
                !SNUtilitiesKit.isRunningTests
            )
        )
        self._blockingQueue = ThreadSafeObject(
            JobQueue(
                type: .blocking,
                executionType: .serial,
                qos: .default,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: [],
                using: dependencies
            )
        )
        self._queues = ThreadSafeObject([
            // MARK: -- Message Send Queue
            
            JobQueue(
                type: .messageSend,
                executionType: .concurrent, // Allow as many jobs to run at once as supported by the device
                qos: .default,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: [
                    jobVariants.remove(.attachmentUpload),
                    jobVariants.remove(.messageSend),
                    jobVariants.remove(.sendReadReceipts),
                    jobVariants.remove(.groupLeaving),
                    jobVariants.remove(.configurationSync),
                    jobVariants.remove(.groupInviteMember),
                    jobVariants.remove(.groupPromoteMember),
                    jobVariants.remove(.processPendingGroupMemberRemovals)
                ].compactMap { $0 },
                using: dependencies
            ),
            
            // MARK: -- Message Receive Queue
            
            JobQueue(
                type: .messageReceive,
                // Explicitly serial as executing concurrently means message receives getting processed at
                // different speeds which can result in:
                // • Small batches of messages appearing in the UI before larger batches
                // • Closed group messages encrypted with updated keys could start parsing before it's key
                //   update message has been processed (ie. guaranteed to fail)
                executionType: .serial,
                qos: .default,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: [
                    jobVariants.remove(.messageReceive),
                    jobVariants.remove(.configMessageReceive)
                ].compactMap { $0 },
                using: dependencies
            ),
            
            // MARK: -- Attachment Download Queue
            
            JobQueue(
                type: .attachmentDownload,
                executionType: .serial,
                qos: .utility,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: [
                    jobVariants.remove(.attachmentDownload)
                ].compactMap { $0 },
                using: dependencies
            ),
            
            // MARK: -- Expiration Update Queue
            
            JobQueue(
                type: .expirationUpdate,
                executionType: .concurrent, // Allow as many jobs to run at once as supported by the device
                qos: .default,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: [
                    jobVariants.remove(.expirationUpdate),
                    jobVariants.remove(.getExpiration),
                    jobVariants.remove(.disappearingMessages),
                    jobVariants.remove(.checkForAppUpdates) // Don't want this to block other jobs
                ].compactMap { $0 },
                using: dependencies
            ),
            
            // MARK: -- Display Picture Download Queue
            
            JobQueue(
                type: .displayPictureDownload,
                executionType: .serial,
                qos: .utility,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: [
                    jobVariants.remove(.displayPictureDownload)
                ].compactMap { $0 },
                using: dependencies
            ),
            
            // MARK: -- General Queue
            
            JobQueue(
                type: .general(number: 0),
                executionType: .serial,
                qos: .utility,
                isTestingJobRunner: isTestingJobRunner,
                jobVariants: Array(jobVariants),
                using: dependencies
            )
        ].reduce(into: [:]) { prev, next in
            next.jobVariants.forEach { variant in
                prev[variant] = next
            }
        })
        
        // Now that we've finished setting up the JobRunner, update the queue closures
        self._blockingQueue.perform {
            $0?.canStart = { [weak self] queue -> Bool in (self?.canStart(queue: queue) == true) }
            $0?.onQueueDrained = { [weak self] in
                // Once all blocking jobs have been completed we want to start running
                // the remaining job queues
                self?.startNonBlockingQueues()
                
                self?._blockingQueueDrainCallback.performUpdate {
                    $0.forEach { $0() }
                    return []
                }
            }
        }
        
        self._queues.perform {
            $0.values.forEach { queue in
                queue.canStart = { [weak self] targetQueue -> Bool in (self?.canStart(queue: targetQueue) == true) }
            }
        }
    }
    
    // MARK: - Configuration
    
    public func setExecutor(_ executor: JobExecutor.Type, for variant: Job.Variant) {
        blockingQueue?.setExecutor(executor, for: variant) // The blocking queue can run any job
        queues[variant]?.setExecutor(executor, for: variant)
    }
    
    public func canStart(queue: JobQueue?) -> Bool {
        return (
            allowToExecuteJobs &&
            appReadyToStartQueues && (
                queue?.type == .blocking ||
                canStartNonBlockingQueue
            )
        )
    }

    public func afterBlockingQueue(callback: @escaping () -> ()) {
        guard
            (blockingQueue?.hasStartedAtLeastOnce != true) ||
            (blockingQueue?.isRunning == true)
        else { return callback() }
    
        _blockingQueueDrainCallback.performUpdate { $0.appending(callback) }
    }
    
    public func queue(for variant: Job.Variant) -> DispatchQueue? {
        return queues[variant]?.targetQueue()
    }
    
    // MARK: - State Management

    public func jobInfoFor(
        jobs: [Job]?,
        state: JobRunner.JobState,
        variant: Job.Variant?
    ) -> [Int64: JobRunner.JobInfo] {
        var result: [(Int64, JobRunner.JobInfo)] = []
        let targetKeys: [JobQueue.JobKey] = (jobs?.compactMap { JobQueue.JobKey($0) } ?? [])
        let targetVariants: [Job.Variant] = (variant.map { [$0] } ?? jobs?.map { $0.variant })
            .defaulting(to: [])
        
        // Insert the state of any pending jobs
        if state.contains(.pending) {
            func infoFor(queue: JobQueue?, variants: [Job.Variant]) -> [(Int64, JobRunner.JobInfo)] {
                return (queue?.pendingJobsQueue
                    .filter { variants.isEmpty || variants.contains($0.variant) }
                    .compactMap { job -> (Int64, JobRunner.JobInfo)? in
                        guard let jobKey: JobQueue.JobKey = JobQueue.JobKey(job) else { return nil }
                        guard
                            targetKeys.isEmpty ||
                            targetKeys.contains(jobKey)
                        else { return nil }
                        
                        return (
                            jobKey.id,
                            JobRunner.JobInfo(
                                variant: job.variant,
                                threadId: job.threadId,
                                interactionId: job.interactionId,
                                detailsData: job.details,
                                uniqueHashValue: job.uniqueHashValue
                            )
                        )
                    })
                    .defaulting(to: [])
            }
            
            result.append(contentsOf: infoFor(queue: blockingQueue, variants: targetVariants))
            queues
                .filter { key, _ -> Bool in targetVariants.isEmpty || targetVariants.contains(key) }
                .map { _, queue in queue }
                .asSet()
                .forEach { queue in result.append(contentsOf: infoFor(queue: queue, variants: targetVariants)) }
        }
        
        // Insert the state of any running jobs
        if state.contains(.running) {
            func infoFor(queue: JobQueue?, variants: [Job.Variant]) -> [(Int64, JobRunner.JobInfo)] {
                return (queue?.infoForAllCurrentlyRunningJobs()
                    .filter { variants.isEmpty || variants.contains($0.value.variant) }
                    .compactMap { jobId, info -> (Int64, JobRunner.JobInfo)? in
                        guard
                            targetKeys.isEmpty ||
                            targetKeys.contains(JobQueue.JobKey(id: jobId, variant: info.variant))
                        else { return nil }
                        
                        return (jobId, info)
                    })
                    .defaulting(to: [])
            }
            
            result.append(contentsOf: infoFor(queue: blockingQueue, variants: targetVariants))
            queues
                .filter { key, _ -> Bool in targetVariants.isEmpty || targetVariants.contains(key) }
                .map { _, queue in queue }
                .asSet()
                .forEach { queue in result.append(contentsOf: infoFor(queue: queue, variants: targetVariants)) }
        }
        
        return result
            .reduce(into: [:]) { result, next in
                result[next.0] = next.1
            }
    }
    
    public func deferCount(for jobId: Int64?, of variant: Job.Variant) -> Int {
        guard let jobId: Int64 = jobId else { return 0 }
        
        return (queues[variant]?.deferLoopTracker[jobId]?.count ?? 0)
    }
    
    public func appDidFinishLaunching() {
        // Flag that the JobRunner can start it's queues
        appReadyToStartQueues = true
        
        // Note: 'appDidBecomeActive' will run on first launch anyway so we can
        // leave those jobs out and can wait until then to start the JobRunner
        let jobsToRun: (blocking: [Job], nonBlocking: [Job]) = dependencies[singleton: .storage]
            .read { db in
                let blockingJobs: [Job] = try Job
                    .filter(
                        [
                            Job.Behaviour.recurringOnLaunch,
                            Job.Behaviour.runOnceNextLaunch
                        ].contains(Job.Columns.behaviour)
                    )
                    .filter(Job.Columns.shouldBlock == true)
                    .order(
                        Job.Columns.priority.desc,
                        Job.Columns.id
                    )
                    .fetchAll(db)
                let nonblockingJobs: [Job] = try Job
                    .filter(
                        [
                            Job.Behaviour.recurringOnLaunch,
                            Job.Behaviour.runOnceNextLaunch
                        ].contains(Job.Columns.behaviour)
                    )
                    .filter(Job.Columns.shouldBlock == false)
                    .order(
                        Job.Columns.priority.desc,
                        Job.Columns.id
                    )
                    .fetchAll(db)
                
                return (blockingJobs, nonblockingJobs)
            }
            .defaulting(to: ([], []))
        
        // Add and start any blocking jobs
        blockingQueue?.appDidFinishLaunching(
            with: jobsToRun.blocking.map { job -> Job in
                guard job.behaviour == .recurringOnLaunch else { return job }
                
                // If the job is a `recurringOnLaunch` job then we reset the `nextRunTimestamp`
                // value on the instance because the assumption is that `recurringOnLaunch` will
                // run a job regardless of how many times it previously failed
                return job.with(nextRunTimestamp: 0)
            },
            canStart: true
        )
        
        // Add any non-blocking jobs (we don't start these incase there are blocking "on active"
        // jobs as well)
        let jobsByVariant: [Job.Variant: [Job]] = jobsToRun.nonBlocking.grouped(by: \.variant)
        let jobQueues: [Job.Variant: JobQueue] = queues
        
        jobsByVariant.forEach { variant, jobs in
            jobQueues[variant]?.appDidFinishLaunching(
                with: jobs.map { job -> Job in
                    guard job.behaviour == .recurringOnLaunch else { return job }
                    
                    // If the job is a `recurringOnLaunch` job then we reset the `nextRunTimestamp`
                    // value on the instance because the assumption is that `recurringOnLaunch` will
                    // run a job regardless of how many times it previously failed
                    return job.with(nextRunTimestamp: 0)
                },
                canStart: false
            )
        }
    }
    
    public func appDidBecomeActive() {
        // Flag that the JobRunner can start it's queues and start queueing non-launch jobs
        appReadyToStartQueues = true
        appHasBecomeActive = true
        
        // If we have a running "sutdownBackgroundTask" then we want to cancel it as otherwise it
        // can result in the database being suspended and us being unable to interact with it at all
        _shutdownBackgroundTask.performUpdate {
            $0?.cancel()
            return nil
        }
        
        // Retrieve any jobs which should run when becoming active
        let hasCompletedInitialBecomeActive: Bool = self.hasCompletedInitialBecomeActive
        let jobsToRun: [Job] = dependencies[singleton: .storage]
            .read { db in
                return try Job
                    .filter(Job.Columns.behaviour == Job.Behaviour.recurringOnActive)
                    .order(
                        Job.Columns.priority.desc,
                        Job.Columns.id
                    )
                    .fetchAll(db)
            }
            .defaulting(to: [])
            .filter { hasCompletedInitialBecomeActive || !$0.shouldSkipLaunchBecomeActive }
        
        // Store the current queue state locally to avoid multiple atomic retrievals
        let jobQueues: [Job.Variant: JobQueue] = queues
        let blockingQueueIsRunning: Bool = (blockingQueue?.isRunning == true)
        
        // Reset the 'isRunningInBackgroundTask' flag just in case (since we aren't in the background anymore)
        jobQueues.forEach { _, queue in
            queue.setIsRunningBackgroundTask(false)
        }
        
        guard !jobsToRun.isEmpty else {
            if !blockingQueueIsRunning {
                jobQueues.map { _, queue in queue }.asSet().forEach { $0.start() }
            }
            return
        }
        
        // Add and start any non-blocking jobs (if there are no blocking jobs)
        //
        // We only want to trigger the queue to start once so we need to consolidate the
        // queues to list of jobs (as queues can handle multiple job variants), this means
        // that 'onActive' jobs will be queued before any standard jobs
        let jobsByVariant: [Job.Variant: [Job]] = jobsToRun.grouped(by: \.variant)
        jobQueues
            .reduce(into: [:]) { result, variantAndQueue in
                result[variantAndQueue.value] = (result[variantAndQueue.value] ?? [])
                    .appending(contentsOf: (jobsByVariant[variantAndQueue.key] ?? []))
            }
            .forEach { queue, jobs in
                queue.appDidBecomeActive(
                    with: jobs.map { job -> Job in
                        // We reset the `nextRunTimestamp` value on the instance because the
                        // assumption is that `recurringOnActive` will run a job regardless
                        // of how many times it previously failed
                        job.with(nextRunTimestamp: 0)
                    },
                    canStart: !blockingQueueIsRunning
                )
            }
        
        self.hasCompletedInitialBecomeActive = true
    }
    
    public func startNonBlockingQueues() {
        queues.map { _, queue in queue }.asSet().forEach { queue in
            queue.start()
        }
    }
    
    public func stopAndClearPendingJobs(
        exceptForVariant: Job.Variant?,
        onComplete: ((Bool) -> ())?
    ) {
        // Inform the JobRunner that it can't start any queues (this is to prevent queues from
        // rescheduling themselves while in the background, when the app restarts or becomes active
        // the JobRunenr will update this flag)
        appReadyToStartQueues = false
        appHasBecomeActive = false
        
        // Stop all queues except for the one containing the `exceptForVariant`
        queues
            .map { _, queue in queue }
            .asSet()
            .filter { queue -> Bool in
                guard let exceptForVariant: Job.Variant = exceptForVariant else { return true }
                
                return !queue.jobVariants.contains(exceptForVariant)
            }
            .forEach { $0.stopAndClearPendingJobs() }
        
        // Ensure the queue is actually running (if not the trigger the callback immediately)
        guard
            let exceptForVariant: Job.Variant = exceptForVariant,
            let queue: JobQueue = queues[exceptForVariant],
            queue.isRunning == true
        else {
            onComplete?(false)
            return
        }
        
        let oldQueueDrained: (() -> ())? = queue.onQueueDrained
        queue.setIsRunningBackgroundTask(true)
        
        // Create a backgroundTask to give the queue the chance to properly be drained
        _shutdownBackgroundTask.performUpdate { _ in
            SessionBackgroundTask(label: #function, using: dependencies) { [weak queue] state in
                // If the background task didn't succeed then trigger the onComplete (and hope we have
                // enough time to complete it's logic)
                guard state != .cancelled else {
                    queue?.setIsRunningBackgroundTask(false)
                    queue?.onQueueDrained = oldQueueDrained
                    return
                }
                guard state != .success else { return }
                
                onComplete?(true)
                queue?.setIsRunningBackgroundTask(false)
                queue?.onQueueDrained = oldQueueDrained
                queue?.stopAndClearPendingJobs()
            }
        }
        
        // Add a callback to be triggered once the queue is drained
        queue.onQueueDrained = { [weak self, weak queue] in
            oldQueueDrained?()
            queue?.setIsRunningBackgroundTask(false)
            queue?.onQueueDrained = oldQueueDrained
            onComplete?(true)
            
            self?._shutdownBackgroundTask.performUpdate { _ in nil }
        }
    }
    
    // MARK: - Execution
    
    @discardableResult public func add(
        _ db: Database,
        job: Job?,
        dependantJob: Job?,
        canStartJob: Bool
    ) -> Job? {
        guard let updatedJob: Job = validatedJob(db, job: job, validation: .persist) else { return nil }
        
        // If we are adding a job that's dependant on another job then create the dependency between them
        if let jobId: Int64 = updatedJob.id, let dependantJobId: Int64 = dependantJob?.id {
            try? JobDependencies(
                jobId: jobId,
                dependantId: dependantJobId
            )
            .insert(db)
        }
        
        // Get the target queue
        let jobQueue: JobQueue? = queues[updatedJob.variant]
        
        // Don't add to the queue if it should only run after the next config sync or the JobRunner
        // isn't ready (it's been saved to the db so it'll be loaded once the queue actually get
        // started later)
        guard
            job?.behaviour != .runOnceAfterConfigSyncIgnoringPermanentFailure && (
                canAddToQueue(updatedJob) ||
                jobQueue?.isRunningInBackgroundTask == true
            )
        else { return updatedJob }
        
        // The queue is ready or running in a background task so we can add the job
        jobQueue?.add(db, job: updatedJob, canStartJob: canStartJob)
        
        // Don't start the queue if the job can't be started
        guard canStartJob else { return updatedJob }
        
        // Start the job runner if needed
        db.afterNextTransactionNestedOnce(dedupeId: "JobRunner-Start: \(jobQueue?.queueContext ?? "N/A")", using: dependencies) { _ in
            jobQueue?.start()
        }
        
        return updatedJob
    }
    
    public func upsert(
        _ db: Database,
        job: Job?,
        canStartJob: Bool
    ) -> Job? {
        guard let job: Job = job else { return nil }    // Ignore null jobs
        guard job.id != nil else {
            // When we upsert a job that should be unique we want to return the existing job (if it exists)
            switch job.uniqueHashValue {
                case .none: return add(db, job: job, canStartJob: canStartJob)
                case .some:
                    let existingJob: Job? = try? Job
                        .filter(Job.Columns.variant == job.variant)
                        .filter(Job.Columns.uniqueHashValue == job.uniqueHashValue)
                        .fetchOne(db)
                    
                    return (existingJob ?? add(db, job: job, canStartJob: canStartJob))
            }
        }
        guard let updatedJob: Job = validatedJob(db, job: job, validation: .enqueueOnly) else { return nil }
        
        // Don't add to the queue if the JobRunner isn't ready (it's been saved to the db so it'll be loaded
        // once the queue actually get started later)
        guard canAddToQueue(updatedJob) else { return updatedJob }
        
        let jobQueue: JobQueue? = queues[updatedJob.variant]
        guard jobQueue?.upsert(db, job: updatedJob, canStartJob: canStartJob) == true else { return nil }
        
        // Don't start the queue if the job can't be started
        guard canStartJob else { return updatedJob }
        
        // Start the job runner if needed
        db.afterNextTransactionNestedOnce(dedupeId: "JobRunner-Start: \(jobQueue?.queueContext ?? "N/A")", using: dependencies) { _ in
            jobQueue?.start()
        }
        
        return updatedJob
    }
    
    @discardableResult public func insert(
        _ db: Database,
        job: Job?,
        before otherJob: Job
    ) -> (Int64, Job)? {
        switch job?.behaviour {
            case .recurringOnActive, .recurringOnLaunch, .runOnceNextLaunch,
                .runOnceAfterConfigSyncIgnoringPermanentFailure:
                Log.info(.jobRunner, "Attempted to insert \(job) before the current one even though it's behaviour is \(job?.behaviour)")
                return nil
                
            default: break
        }
        
        guard
            let updatedJob: Job = validatedJob(db, job: job, validation: .persist),
            let jobId: Int64 = updatedJob.id
        else { return nil }
        
        queues[updatedJob.variant]?.insert(updatedJob, before: otherJob)
        
        return (jobId, updatedJob)
    }
    
    /// Job dependencies can be quite messy as they might already be running or scheduled on different queues from the related job, this could result
    /// in some odd inter-dependencies between the JobQueues. Instead of this we want all jobs to run on their original assigned queues (so the
    /// concurrency rules remain consistent and easy to reason with), the only downside to this approach is serial queues could potentially be blocked
    /// waiting on unrelated dependencies to be run as this method will insert jobs at the start of the `pendingJobsQueue`
    public func enqueueDependenciesIfNeeded(_ jobs: [Job]) {
        /// Do nothing if we weren't given any jobs
        guard !jobs.isEmpty else { return }
        
        /// Ignore any dependencies which are already running or scheduled
        let dependencyJobQueues: Set<JobQueue> = jobs
            .compactMap { queues[$0.variant] }
            .asSet()
        let allCurrentlyRunningJobIds: [Int64] = dependencyJobQueues
            .flatMap { $0.currentlyRunningJobIds }
        let jobsToEnqueue: [JobQueue: [Job]] = jobs
            .compactMap { job in job.id.map { ($0, job) } }
            .filter { jobId, _ in !allCurrentlyRunningJobIds.contains(jobId) }
            .compactMap { _, job in queues[job.variant].map { (job, $0) } }
            .grouped(by: { _, queue in queue })
            .mapValues { data in data.map { job, _ in job } }
        
        /// Regardless of whether the jobs are dependant jobs or dependencies we want them to be moved to the start of the
        /// `pendingJobsQueue` because at least one job in the job chain has been triggered so we want to try to complete
        /// the entire job chain rather than worry about deadlocks between different job chains
        ///
        /// **Note:** If any of these `dependantJobs` have other dependencies then when they attempt to start they will be
        /// removed from the queue, replaced by their dependencies
        jobsToEnqueue.forEach { queue, jobs in
            queue.insertJobsIfNeeded(jobs, index: 0)
            
            // Start the job queue if needed (might be a different queue from the currently executing one)
            queue.start()
        }
    }
    
    public func manuallyTriggerResult(_ job: Job?, result: JobRunner.JobResult) {
        guard let job: Job = job, let queue: JobQueue = queues[job.variant] else { return }
        
        switch result {
            case .notFound: return
            case .succeeded: queue.handleJobSucceeded(job, shouldStop: false)
            case .deferred: queue.handleJobDeferred(job)
            case .failed(let error, let permanent): queue.handleJobFailed(job, error: error, permanentFailure: permanent)
        }
    }
    
    public func afterJob(_ job: Job?, state: JobRunner.JobState) -> AnyPublisher<JobRunner.JobResult, Never> {
        guard let job: Job = job, let jobId: Int64 = job.id, let queue: JobQueue = queues[job.variant] else {
            return Just(.notFound).eraseToAnyPublisher()
        }
        
        return queue.afterJob(jobId, state: state)
    }
    
    public func removePendingJob(_ job: Job?) {
        guard let job: Job = job, let jobId: Int64 = job.id else { return }
        
        queues[job.variant]?.removePendingJob(jobId)
    }
    
    public func registerRecurringJobs(scheduleInfo: [JobRunner.ScheduleInfo]) {
        _registeredRecurringJobs.performUpdate { $0.appending(contentsOf: scheduleInfo) }
    }
    
    public func scheduleRecurringJobsIfNeeded() {
        let scheduleInfo: [ScheduleInfo] = registeredRecurringJobs
        let variants: Set<Job.Variant> = Set(scheduleInfo.map { $0.variant })
        let maybeExistingJobs: [Job]? = dependencies[singleton: .storage].read { db in
            try Job
                .filter(variants.contains(Job.Columns.variant))
                .fetchAll(db)
        }
        
        guard let existingJobs: [Job] = maybeExistingJobs else {
            Log.warn(.jobRunner, "Failed to load existing recurring jobs from the database")
            return
        }
        
        let missingScheduledJobs: [ScheduleInfo] = scheduleInfo
            .filter { scheduleInfo in
                !existingJobs.contains { existingJob in
                    existingJob.variant == scheduleInfo.variant &&
                    existingJob.behaviour == scheduleInfo.behaviour &&
                    existingJob.shouldBlock == scheduleInfo.shouldBlock &&
                    existingJob.shouldSkipLaunchBecomeActive == scheduleInfo.shouldSkipLaunchBecomeActive
                }
            }
        
        guard !missingScheduledJobs.isEmpty else { return }
        
        var numScheduledJobs: Int = 0
        dependencies[singleton: .storage].write { db in
            try missingScheduledJobs.forEach { variant, behaviour, shouldBlock, shouldSkipLaunchBecomeActive in
                _ = try Job(
                    variant: variant,
                    behaviour: behaviour,
                    shouldBlock: shouldBlock,
                    shouldSkipLaunchBecomeActive: shouldSkipLaunchBecomeActive
                ).inserted(db)
                numScheduledJobs += 1
            }
        }
        
        switch numScheduledJobs == missingScheduledJobs.count {
            case true: Log.info(.jobRunner, "Scheduled \(numScheduledJobs) missing recurring job(s)")
            case false: Log.error(.jobRunner, "Failed to schedule \(missingScheduledJobs.count - numScheduledJobs) recurring job(s)")
        }
    }
    
    // MARK: - Convenience

    fileprivate static func getRetryInterval(for job: Job) -> TimeInterval {
        // Arbitrary backoff factor...
        // try  1 delay: 0.5s
        // try  2 delay: 1s
        // ...
        // try  5 delay: 16s
        // ...
        // try 11 delay: 512s
        let maxBackoff: Double = 10 * 60 // 10 minutes
        return 0.25 * min(maxBackoff, pow(2, Double(job.failureCount)))
    }
    
    fileprivate func canAddToQueue(_ job: Job) -> Bool {
        // We can only start the job if it's an "on launch" job or the app has become active
        return (
            job.behaviour == .runOnceNextLaunch ||
            job.behaviour == .recurringOnLaunch ||
            appHasBecomeActive
        )
    }
    
    private func validatedJob(_ db: Database, job: Job?, validation: Validation) -> Job? {
        guard let job: Job = job else { return nil }
        
        switch (validation, job.uniqueHashValue) {
            case (.enqueueOnly, .none): return job
            case (.enqueueOnly, .some(let uniqueHashValue)):
                // Nothing currently running or sitting in a JobQueue
                guard !allJobInfo().contains(where: { _, info -> Bool in info.uniqueHashValue == uniqueHashValue }) else {
                    Log.info(.jobRunner, "Unable to add \(job) due to unique constraint")
                    return nil
                }
                
                return job
                
            case (.persist, .some(let uniqueHashValue)):
                guard
                    // Nothing currently running or sitting in a JobQueue
                    !allJobInfo().contains(where: { _, info -> Bool in info.uniqueHashValue == uniqueHashValue }) &&
                    // Nothing in the database
                    !Job.filter(Job.Columns.uniqueHashValue == uniqueHashValue).isNotEmpty(db)
                else {
                    Log.info(.jobRunner, "Unable to add \(job) due to unique constraint")
                    return nil
                }
                
                fallthrough // Validation passed so try to persist the job
                
            case (.persist, .none):
                guard let updatedJob: Job = try? job.inserted(db), updatedJob.id != nil else {
                    Log.info(.jobRunner, "Unable to add \(job)\(job.id == nil ? " due to missing id" : "")")
                    return nil
                }
                
                return updatedJob
        }
    }
}

// MARK: - JobQueue

public final class JobQueue: Hashable {
    fileprivate enum QueueType: Hashable {
        case blocking
        case general(number: Int)
        case messageSend
        case messageReceive
        case attachmentDownload
        case displayPictureDownload
        case expirationUpdate
        
        var name: String {
            switch self {
                case .blocking: return "Blocking"
                case .general(let number): return "General-\(number)"
                case .messageSend: return "MessageSend"
                case .messageReceive: return "MessageReceive"
                case .attachmentDownload: return "AttachmentDownload"
                case .displayPictureDownload: return "DisplayPictureDownload"
                case .expirationUpdate: return "ExpirationUpdate"
            }
        }
    }
    
    fileprivate enum ExecutionType {
        /// A serial queue will execute one job at a time until the queue is empty, then will load any new/deferred
        /// jobs and run those one at a time
        case serial
        
        /// A concurrent queue will execute as many jobs as the device supports at once until the queue is empty,
        /// then will load any new/deferred jobs and try to start them all
        case concurrent
    }
    
    private class Trigger {
        private var timer: Timer?
        fileprivate var fireTimestamp: TimeInterval = 0
        
        static func create(
            queue: JobQueue,
            timestamp: TimeInterval,
            using dependencies: Dependencies
        ) -> Trigger? {
            /// Setup the trigger (wait at least 1 second before triggering)
            ///
            /// **Note:** We use the `Timer.scheduledTimerOnMainThread` method because running a timer
            /// on our random queue threads results in the timer never firing, the `start` method will redirect itself to
            /// the correct thread
            let trigger: Trigger = Trigger()
            trigger.fireTimestamp = max(1, (timestamp - dependencies.dateNow.timeIntervalSince1970))
            trigger.timer = Timer.scheduledTimerOnMainThread(
                withTimeInterval: trigger.fireTimestamp,
                repeats: false,
                using: dependencies,
                block: { [weak queue] _ in
                    queue?.start(forceWhenAlreadyRunning: (queue?.executionType == .concurrent))
                }
            )
            return trigger
        }
        
        func invalidate() {
            // Need to do this to prevent a strong reference cycle
            timer?.invalidate()
            timer = nil
        }
    }
    
    fileprivate struct JobKey: Equatable, Hashable {
        fileprivate let id: Int64
        fileprivate let variant: Job.Variant
        
        fileprivate init(id: Int64, variant: Job.Variant) {
            self.id = id
            self.variant = variant
        }
        
        fileprivate init?(_ job: Job?) {
            guard let id: Int64 = job?.id, let variant: Job.Variant = job?.variant else { return nil }
            
            self.id = id
            self.variant = variant
        }
    }
    
    private static let deferralLoopThreshold: Int = 3
    
    private let dependencies: Dependencies
    private let id: UUID = UUID()
    fileprivate let type: QueueType
    private let executionType: ExecutionType
    private let qosClass: DispatchQoS
    private let queueKey: DispatchSpecificKey = DispatchSpecificKey<String>()
    fileprivate let queueContext: String
    fileprivate let jobVariants: [Job.Variant]
    
    private lazy var internalQueue: DispatchQueue = {
        let result: DispatchQueue = DispatchQueue(
            label: self.queueContext,
            qos: self.qosClass,
            attributes: (self.executionType == .concurrent ? [.concurrent] : []),
            autoreleaseFrequency: .inherit,
            target: nil
        )
        result.setSpecific(key: queueKey, value: queueContext)
        
        return result
    }()
    
    @ThreadSafeObject private var executorMap: [Job.Variant: JobExecutor.Type] = [:]
    fileprivate var canStart: ((JobQueue?) -> Bool)?
    fileprivate var onQueueDrained: (() -> ())?
    @ThreadSafe fileprivate var hasStartedAtLeastOnce: Bool = false
    @ThreadSafe fileprivate var isRunning: Bool = false
    @ThreadSafeObject fileprivate var pendingJobsQueue: [Job] = []
    @ThreadSafe fileprivate var isRunningInBackgroundTask: Bool = false
    
    @ThreadSafeObject private var nextTrigger: Trigger? = nil
    @ThreadSafeObject fileprivate var currentlyRunningJobIds: Set<Int64> = []
    @ThreadSafeObject private var currentlyRunningJobInfo: [Int64: JobRunner.JobInfo] = [:]
    @ThreadSafeObject fileprivate var deferLoopTracker: [Int64: (count: Int, times: [TimeInterval])] = [:]
    private let maxDeferralsPerSecond: Int
    private let jobCompletedSubject: PassthroughSubject<(Int64?, JobRunner.JobResult), Never> = PassthroughSubject()
    
    fileprivate var hasPendingJobs: Bool { !pendingJobsQueue.isEmpty }
    
    // MARK: - Initialization
    
    fileprivate init(
        type: QueueType,
        executionType: ExecutionType,
        qos: DispatchQoS,
        isTestingJobRunner: Bool,
        jobVariants: [Job.Variant],
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.type = type
        self.executionType = executionType
        self.queueContext = "JobQueue-\(type.name)"
        self.qosClass = qos
        self.maxDeferralsPerSecond = (isTestingJobRunner ? 10 : 1)  // Allow for tripping the defer loop in tests
        self.jobVariants = jobVariants
    }
    
    // MARK: - Hashable
    
    public func hash(into hasher: inout Hasher) {
        id.hash(into: &hasher)
    }
    
    public static func == (lhs: JobQueue, rhs: JobQueue) -> Bool {
        return (lhs.id == rhs.id)
    }
    
    // MARK: - Configuration
    
    fileprivate func setExecutor(_ executor: JobExecutor.Type, for variant: Job.Variant) {
        _executorMap.performUpdate { $0.setting(variant, executor) }
    }
    
    fileprivate func setIsRunningBackgroundTask(_ value: Bool) {
        isRunningInBackgroundTask = value
    }
    
    fileprivate func insertJobsIfNeeded(_ jobs: [Job], index: Int) {
        _pendingJobsQueue.performUpdate { pendingJobs in
            pendingJobs
                .filter { !jobs.contains($0) }
                .inserting(contentsOf: jobs, at: 0)
        }
    }
    
    // MARK: - Execution
    
    fileprivate func targetQueue() -> DispatchQueue {
        /// As it turns out Combine doesn't play too nicely with concurrent Dispatch Queues, in Combine events are dispatched asynchronously to
        /// the queue which means an odd situation can occasionally occur where the `finished` event can actually run before the `output`
        /// event - this can result in unexpected behaviours (for more information see https://github.com/groue/GRDB.swift/issues/1334)
        ///
        /// Due to this if a job is meant to run on a concurrent queue then we actually want to create a temporary serial queue just for the execution
        /// of that job
        guard executionType == .concurrent else { return internalQueue }
        
        return DispatchQueue(
            label: "\(self.queueContext)-serial",
            qos: self.qosClass,
            attributes: [],
            autoreleaseFrequency: .inherit,
            target: nil
        )
    }

    fileprivate func add(
        _ db: Database,
        job: Job,
        canStartJob: Bool
    ) {
        // Check if the job should be added to the queue
        guard
            canStartJob,
            job.behaviour != .runOnceNextLaunch,
            job.nextRunTimestamp <= dependencies.dateNow.timeIntervalSince1970
        else { return }
        guard job.id != nil else {
            Log.info(.jobRunner, "Prevented attempt to add \(job) without id to queue")
            return
        }
        
        _pendingJobsQueue.performUpdate { $0.appending(job) }
        
        // If this is a concurrent queue then we should immediately start the next job
        guard executionType == .concurrent else { return }
        
        // Ensure that the database commit has completed and then trigger the next job to run (need
        // to ensure any interactions have been correctly inserted first)
        db.afterNextTransactionNestedOnce(dedupeId: "JobRunner-Add: \(job.variant)", using: dependencies) { [weak self] _ in
            self?.runNextJob()
        }
    }
    
    /// Upsert a job onto the queue, if the queue isn't currently running and 'canStartJob' is true then this will start
    /// the JobRunner
    ///
    /// **Note:** If the job has a `behaviour` of `runOnceNextLaunch` or the `nextRunTimestamp`
    /// is in the future then the job won't be started
    fileprivate func upsert(
        _ db: Database,
        job: Job,
        canStartJob: Bool
    ) -> Bool {
        guard let jobId: Int64 = job.id else {
            Log.warn(.jobRunner, "Prevented attempt to upsert \(job) without id to queue")
            return false
        }
        
        // Lock the pendingJobsQueue while checking the index and inserting to ensure we don't run into
        // any multi-threading shenanigans
        //
        // Note: currently running jobs are removed from the pendingJobsQueue so we don't need to check
        // the 'jobsCurrentlyRunning' set
        var didUpdateExistingJob: Bool = false
        
        _pendingJobsQueue.performUpdate { queue in
            if let jobIndex: Array<Job>.Index = queue.firstIndex(where: { $0.id == jobId }) {
                didUpdateExistingJob = true
                return queue.setting(jobIndex, job)
            }
            
            return queue
        }
        
        // If we didn't update an existing job then we need to add it to the pendingJobsQueue
        guard !didUpdateExistingJob else { return true }
        
        // Make sure the job isn't already running before we add it to the queue
        guard !currentlyRunningJobIds.contains(jobId) else {
            Log.warn(.jobRunner, "Prevented attempt to upsert \(job) which is currently running")
            return false
        }
        
        add(db, job: job, canStartJob: canStartJob)
        return true
    }
    
    fileprivate func insert(_ job: Job, before otherJob: Job) {
        guard job.id != nil else {
            Log.info(.jobRunner, "Prevented attempt to insert \(job) without id to queue")
            return
        }
        
        // Insert the job before the current job (re-adding the current job to
        // the start of the pendingJobsQueue if it's not in there) - this will mean the new
        // job will run and then the otherJob will run (or run again) once it's
        // done
        _pendingJobsQueue.performUpdate {
            guard let otherJobIndex: Int = $0.firstIndex(of: otherJob) else {
                return $0.inserting(contentsOf: [job, otherJob], at: 0)
            }
            
            return $0.inserting(job, at: otherJobIndex)
        }
    }
    
    fileprivate func appDidFinishLaunching(with jobs: [Job], canStart: Bool) {
        _pendingJobsQueue.performUpdate { $0.appending(contentsOf: jobs) }
        
        // Start the job runner if needed
        if canStart && !isRunning {
            start()
        }
    }
    
    fileprivate func appDidBecomeActive(with jobs: [Job], canStart: Bool) {
        let currentlyRunningJobIds: Set<Int64> = currentlyRunningJobIds
        
        _pendingJobsQueue.performUpdate { queue in
            // Avoid re-adding jobs to the queue that are already in it (this can
            // happen if the user sends the app to the background before the 'onActive'
            // jobs and then brings it back to the foreground)
            let jobsNotAlreadyInQueue: [Job] = jobs
                .filter { job in
                    !currentlyRunningJobIds.contains(job.id ?? -1) &&
                    !queue.contains(where: { $0.id == job.id })
                }
            
            return queue.appending(contentsOf: jobsNotAlreadyInQueue)
        }
        
        // Start the job runner if needed
        if canStart && !isRunning {
            start()
        }
    }
    
    fileprivate func infoForAllCurrentlyRunningJobs() -> [Int64: JobRunner.JobInfo] {
        return currentlyRunningJobInfo
    }
    
    fileprivate func afterJob(_ jobId: Int64, state: JobRunner.JobState) -> AnyPublisher<JobRunner.JobResult, Never> {
        /// Check if the current job state matches the requested state (if not then the job in the requested state can't be found so stop here)
        switch (state, currentlyRunningJobIds.contains(jobId)) {
            case (.running, false): return Just(.notFound).eraseToAnyPublisher()
            case (.pending, true): return Just(.notFound).eraseToAnyPublisher()
            default: break
        }
        
        return jobCompletedSubject
            .filter { $0.0 == jobId }
            .map { $0.1 }
            .eraseToAnyPublisher()
    }
    
    fileprivate func hasPendingOrRunningJobWith(
        threadId: String? = nil,
        interactionId: Int64? = nil,
        detailsData: Data? = nil
    ) -> Bool {
        let pendingJobs: [Job] = pendingJobsQueue
        let currentlyRunningJobInfo: [Int64: JobRunner.JobInfo] = currentlyRunningJobInfo
        var possibleJobIds: Set<Int64> = Set(currentlyRunningJobInfo.keys)
            .inserting(contentsOf: pendingJobs.compactMap { $0.id }.asSet())
        
        // Remove any which don't have the matching threadId (if provided)
        if let targetThreadId: String = threadId {
            let pendingJobIdsWithWrongThreadId: Set<Int64> = pendingJobs
                .filter { $0.threadId != targetThreadId }
                .compactMap { $0.id }
                .asSet()
            let runningJobIdsWithWrongThreadId: Set<Int64> = currentlyRunningJobInfo
                .filter { _, info -> Bool in info.threadId != targetThreadId }
                .map { key, _ in key }
                .asSet()
            
            possibleJobIds = possibleJobIds
                .subtracting(pendingJobIdsWithWrongThreadId)
                .subtracting(runningJobIdsWithWrongThreadId)
        }
        
        // Remove any which don't have the matching interactionId (if provided)
        if let targetInteractionId: Int64 = interactionId {
            let pendingJobIdsWithWrongInteractionId: Set<Int64> = pendingJobs
                .filter { $0.interactionId != targetInteractionId }
                .compactMap { $0.id }
                .asSet()
            let runningJobIdsWithWrongInteractionId: Set<Int64> = currentlyRunningJobInfo
                .filter { _, info -> Bool in info.interactionId != targetInteractionId }
                .map { key, _ in key }
                .asSet()
            
            possibleJobIds = possibleJobIds
                .subtracting(pendingJobIdsWithWrongInteractionId)
                .subtracting(runningJobIdsWithWrongInteractionId)
        }
        
        // Remove any which don't have the matching details (if provided)
        if let targetDetailsData: Data = detailsData {
            let pendingJobIdsWithWrongDetailsData: Set<Int64> = pendingJobs
                .filter { $0.details != targetDetailsData }
                .compactMap { $0.id }
                .asSet()
            let runningJobIdsWithWrongDetailsData: Set<Int64> = currentlyRunningJobInfo
                .filter { _, info -> Bool in info.detailsData != detailsData }
                .map { key, _ in key }
                .asSet()
            
            possibleJobIds = possibleJobIds
                .subtracting(pendingJobIdsWithWrongDetailsData)
                .subtracting(runningJobIdsWithWrongDetailsData)
        }
        
        return !possibleJobIds.isEmpty
    }
    
    fileprivate func removePendingJob(_ jobId: Int64) {
        _pendingJobsQueue.performUpdate { queue in
            queue.filter { $0.id != jobId }
        }
    }
    
    // MARK: - Job Running
    
    fileprivate func start(forceWhenAlreadyRunning: Bool = false) {
        // Only start if the JobRunner is allowed to start the queue or if this queue is running in
        // a background task
        let isRunningInBackgroundTask: Bool = self.isRunningInBackgroundTask
        
        guard canStart?(self) == true || isRunningInBackgroundTask else { return }
        guard forceWhenAlreadyRunning || !isRunning || isRunningInBackgroundTask else { return }
        
        // The JobRunner runs synchronously so we need to ensure this doesn't start on the main
        // thread and do so by creating a number of background queues to run the jobs on, if this
        // function was called on the wrong queue then we need to dispatch to the correct one
        guard DispatchQueue.with(key: queueKey, matches: queueContext, using: dependencies) else {
            internalQueue.async(using: dependencies) { [weak self] in
                self?.start(forceWhenAlreadyRunning: forceWhenAlreadyRunning)
            }
            return
        }
        
        // Flag the JobRunner as running (to prevent something else from trying to start it
        // and messing with the execution behaviour)
        let wasAlreadyRunning: Bool = _isRunning.performUpdateAndMap { (true, $0) }
        hasStartedAtLeastOnce = true
        
        // Get any pending jobs
        
        let jobVariants: [Job.Variant] = self.jobVariants
        let jobIdsAlreadyRunning: Set<Int64> = currentlyRunningJobIds
        let jobsAlreadyInQueue: Set<Int64> = pendingJobsQueue.compactMap { $0.id }.asSet()
        let jobsToRun: [Job]
        
        switch isRunningInBackgroundTask {
            case true: jobsToRun = []   // When running in a background task we don't want to schedule extra jobs
            case false:
                jobsToRun = dependencies[singleton: .storage].read { db in
                    try Job
                        .filterPendingJobs(
                            variants: jobVariants,
                            excludeFutureJobs: true,
                            includeJobsWithDependencies: false
                        )
                        .filter(!jobIdsAlreadyRunning.contains(Job.Columns.id)) // Exclude jobs already running
                        .filter(!jobsAlreadyInQueue.contains(Job.Columns.id))   // Exclude jobs already in the queue
                        .fetchAll(db)
                }
                .defaulting(to: [])
        }
        
        // Determine the number of jobs to run
        let jobCount: Int = _pendingJobsQueue.performUpdateAndMap { queue in
            let updatedQueue: [Job] = queue.appending(contentsOf: jobsToRun)
            return (updatedQueue, updatedQueue.count)
        }
        
        // If there are no pending jobs and nothing in the queue then schedule the JobRunner
        // to start again when the next scheduled job should start
        guard jobCount > 0 else {
            if jobIdsAlreadyRunning.isEmpty {
                isRunning = false
                scheduleNextSoonestJob()
            }
            return
        }
        
        // Run the first job in the pendingJobsQueue
        if !wasAlreadyRunning {
            Log.info(.jobRunner, "Starting \(queueContext) with \(jobCount) jobs")
        }
        runNextJob()
    }
    
    fileprivate func stopAndClearPendingJobs() {
        isRunning = false
        _pendingJobsQueue.set(to: [])
        _deferLoopTracker.set(to: [:])
    }
    
    private func runNextJob() {
        // Ensure the queue is running (if we've stopped the queue then we shouldn't start the next job)
        guard isRunning else { return }
        
        // Ensure this is running on the correct queue
        guard DispatchQueue.with(key: queueKey, matches: queueContext, using: dependencies) else {
            internalQueue.async(using: dependencies) { [weak self] in
                self?.runNextJob()
            }
            return
        }
        guard executionType == .concurrent || currentlyRunningJobIds.isEmpty else {
            return Log.info(.jobRunner, "\(queueContext) Ignoring 'runNextJob' due to currently running job in serial queue")
        }
        guard
            let (nextJob, numJobsRemaining): (Job, Int) = _pendingJobsQueue.performUpdateAndMap({ queue in
                var updatedQueue: [Job] = queue
                let nextJob: Job? = updatedQueue.popFirst()
                
                return (updatedQueue, nextJob.map { ($0, updatedQueue.count) })
            })
        else {
            // If it's a serial queue, or there are no more jobs running then update the 'isRunning' flag
            if executionType != .concurrent || currentlyRunningJobIds.isEmpty {
                isRunning = false
            }
            
            // Always attempt to schedule the next soonest job (otherwise if enough jobs get started in rapid
            // succession then pending/failed jobs in the database may never get re-started in a concurrent queue)
            scheduleNextSoonestJob()
            return
        }
        guard let jobExecutor: JobExecutor.Type = executorMap[nextJob.variant] else {
            Log.info(.jobRunner, "\(queueContext) Unable to run \(nextJob) due to missing executor")
            return handleJobFailed(
                nextJob,
                error: JobRunnerError.executorMissing,
                permanentFailure: true
            )
        }
        guard !jobExecutor.requiresThreadId || nextJob.threadId != nil else {
            Log.info(.jobRunner, "\(queueContext) Unable to run \(nextJob) due to missing required threadId")
            return handleJobFailed(
                nextJob,
                error: JobRunnerError.requiredThreadIdMissing,
                permanentFailure: true
            )
        }
        guard !jobExecutor.requiresInteractionId || nextJob.interactionId != nil else {
            Log.info(.jobRunner, "\(queueContext) Unable to run \(nextJob) due to missing required interactionId")
            return handleJobFailed(
                nextJob,
                error: JobRunnerError.requiredInteractionIdMissing,
                permanentFailure: true
            )
        }
        guard nextJob.id != nil else {
            Log.info(.jobRunner, "\(queueContext) Unable to run \(nextJob) due to missing id")
            return handleJobFailed(
                nextJob,
                error: JobRunnerError.jobIdMissing,
                permanentFailure: false
            )
        }
        
        // If the 'nextRunTimestamp' for the job is in the future then don't run it yet
        guard nextJob.nextRunTimestamp <= dependencies.dateNow.timeIntervalSince1970 else {
            handleJobDeferred(nextJob)
            return
        }
        
        // Check if the next job has any dependencies
        let dependencyInfo: (expectedCount: Int, jobs: Set<Job>) = dependencies[singleton: .storage].read { db in
            let expectedDependencies: Set<JobDependencies> = try JobDependencies
                .filter(JobDependencies.Columns.jobId == nextJob.id)
                .fetchSet(db)
            let jobDependencies: Set<Job> = try Job
                .filter(ids: expectedDependencies.compactMap { $0.dependantId })
                .fetchSet(db)
            
            return (expectedDependencies.count, jobDependencies)
        }
        .defaulting(to: (0, []))
        
        guard dependencyInfo.jobs.count == dependencyInfo.expectedCount else {
            Log.info(.jobRunner, "\(queueContext) Removing \(nextJob) due to missing dependencies")
            return handleJobFailed(
                nextJob,
                error: JobRunnerError.missingDependencies,
                permanentFailure: true
            )
        }
        guard dependencyInfo.jobs.isEmpty else {
            Log.info(.jobRunner, "\(queueContext) Deferring \(nextJob) until \(dependencyInfo.jobs.count) dependencies are completed")
            
            // Enqueue the dependencies then defer the current job
            dependencies[singleton: .jobRunner].enqueueDependenciesIfNeeded(Array(dependencyInfo.jobs))
            handleJobDeferred(nextJob)
            return
        }
        
        // Update the state to indicate the particular job is running
        //
        // Note: We need to store 'numJobsRemaining' in it's own variable because
        // the 'Log.info' seems to dispatch to it's own queue which ends up getting
        // blocked by the JobRunner's queue becuase 'jobQueue' is Atomic
        var numJobsRunning: Int = 0
        _nextTrigger.performUpdate { trigger in
            trigger?.invalidate()   // Need to invalidate to prevent a memory leak
            return nil
        }
        _currentlyRunningJobIds.performUpdate { currentlyRunningJobIds in
            let result: Set<Int64> = currentlyRunningJobIds.inserting(nextJob.id)
            numJobsRunning = currentlyRunningJobIds.count
            return result
        }
        _currentlyRunningJobInfo.performUpdate { currentlyRunningJobInfo in
            currentlyRunningJobInfo.setting(
                nextJob.id,
                JobRunner.JobInfo(
                    variant: nextJob.variant,
                    threadId: nextJob.threadId,
                    interactionId: nextJob.interactionId,
                    detailsData: nextJob.details,
                    uniqueHashValue: nextJob.uniqueHashValue
                )
            )
        }
        Log.info(.jobRunner, "\(queueContext) started \(nextJob) (\(executionType == .concurrent ? "\(numJobsRunning) currently running, " : "")\(numJobsRemaining) remaining)")
        
        jobExecutor.run(
            nextJob,
            scheduler: targetQueue(),
            success: handleJobSucceeded,
            failure: handleJobFailed,
            deferred: handleJobDeferred,
            using: dependencies
        )
        
        // If this queue executes concurrently and there are still jobs remaining then immediately attempt
        // to start the next job
        if executionType == .concurrent && numJobsRemaining > 0 {
            internalQueue.async(using: dependencies) { [weak self] in
                self?.runNextJob()
            }
        }
    }
    
    private func scheduleNextSoonestJob() {
        // Retrieve any pending jobs from the database
        let jobVariants: [Job.Variant] = self.jobVariants
        let jobIdsAlreadyRunning: Set<Int64> = currentlyRunningJobIds
        let nextJobTimestamp: TimeInterval? = dependencies[singleton: .storage].read { db in
            try Job
                .filterPendingJobs(
                    variants: jobVariants,
                    excludeFutureJobs: false,
                    includeJobsWithDependencies: false
                )
                .select(.nextRunTimestamp)
                .filter(!jobIdsAlreadyRunning.contains(Job.Columns.id)) // Exclude jobs already running
                .asRequest(of: TimeInterval.self)
                .fetchOne(db)
        }
        
        // If there are no remaining jobs or the JobRunner isn't allowed to start any queues then trigger
        // the 'onQueueDrained' callback and stop
        guard let nextJobTimestamp: TimeInterval = nextJobTimestamp, canStart?(self) == true else {
            if executionType != .concurrent || currentlyRunningJobIds.isEmpty {
                self.onQueueDrained?()
            }
            return
        }
        
        // If the next job isn't scheduled in the future then just restart the JobRunner immediately
        let secondsUntilNextJob: TimeInterval = (nextJobTimestamp - dependencies.dateNow.timeIntervalSince1970)
        
        guard secondsUntilNextJob > 0 else {
            // Only log that the queue is getting restarted if this queue had actually been about to stop
            if executionType != .concurrent || currentlyRunningJobIds.isEmpty {
                let timingString: String = (nextJobTimestamp == 0 ?
                    "that should be in the queue" :
                    "scheduled \(.seconds(secondsUntilNextJob), unit: .s) ago"
                )
                Log.info(.jobRunner, "Restarting \(queueContext) immediately for job \(timingString)")
            }
            
            // Trigger the 'start' function to load in any pending jobs that aren't already in the
            // queue (for concurrent queues we want to force them to load in pending jobs and add
            // them to the queue regardless of whether the queue is already running)
            internalQueue.async(using: dependencies) { [weak self] in
                self?.start(forceWhenAlreadyRunning: (self?.executionType != .concurrent))
            }
            return
        }
        
        // Only schedule a trigger if the queue is concurrent, or it has actually completed
        guard executionType == .concurrent || currentlyRunningJobIds.isEmpty else { return }
        
        // Setup a trigger
        Log.info(.jobRunner, "Stopping \(queueContext) until next job in \(.seconds(secondsUntilNextJob), unit: .s)")
        _nextTrigger.performUpdate { trigger in
            trigger?.invalidate()   // Need to invalidate the old trigger to prevent a memory leak
            return Trigger.create(queue: self, timestamp: nextJobTimestamp, using: dependencies)
        }
    }
    
    // MARK: - Handling Results

    /// This function is called when a job succeeds
    fileprivate func handleJobSucceeded(_ job: Job, shouldStop: Bool) {
        /// Retrieve the dependant jobs first (the `JobDependecies` table has cascading deletion when the original `Job` is
        /// removed so we need to retrieve these records before that happens)
        let dependantJobs: [Job] = dependencies[singleton: .storage]
            .read { db in try job.dependantJobs.fetchAll(db) }
            .defaulting(to: [])
        
        switch job.behaviour {
            case .runOnce, .runOnceNextLaunch, .runOnceAfterConfigSyncIgnoringPermanentFailure:
                dependencies[singleton: .storage].write { db in
                    /// Since this job has been completed we can update the dependencies so other job that were dependant
                    /// on this one can be run
                    _ = try JobDependencies
                        .filter(JobDependencies.Columns.dependantId == job.id)
                        .deleteAll(db)
                    
                    _ = try job.delete(db)
                }
                
            case .recurring where shouldStop == true:
                dependencies[singleton: .storage].write { db in
                    /// Since this job has been completed we can update the dependencies so other job that were dependant
                    /// on this one can be run
                    _ = try JobDependencies
                        .filter(JobDependencies.Columns.dependantId == job.id)
                        .deleteAll(db)
                    
                    _ = try job.delete(db)
                }
                
            /// For `recurring` jobs which have already run, they should automatically run again but we want at least 1 second
            /// to pass before doing so - the job itself should really update it's own `nextRunTimestamp` (this is just a safety net)
            case .recurring where job.nextRunTimestamp <= dependencies.dateNow.timeIntervalSince1970:
                guard let jobId: Int64 = job.id else { break }
                
                dependencies[singleton: .storage].write { [dependencies] db in
                    _ = try Job
                        .filter(id: jobId)
                        .updateAll(
                            db,
                            Job.Columns.failureCount.set(to: 0),
                            Job.Columns.nextRunTimestamp.set(to: (dependencies.dateNow.timeIntervalSince1970 + 1))
                        )
                }
                
            /// For `recurringOnLaunch/Active` jobs which have already run but failed once, we need to clear their
            /// `failureCount` and `nextRunTimestamp` to prevent them from endlessly running over and over again
            case .recurringOnLaunch, .recurringOnActive:
                guard
                    let jobId: Int64 = job.id,
                    job.failureCount != 0 &&
                    job.nextRunTimestamp > TimeInterval.leastNonzeroMagnitude
                else { break }
                
                dependencies[singleton: .storage].write { db in
                    _ = try Job
                        .filter(id: jobId)
                        .updateAll(
                            db,
                            Job.Columns.failureCount.set(to: 0),
                            Job.Columns.nextRunTimestamp.set(to: 0)
                        )
                }
            
            default: break
        }
        
        /// Now that the job has been completed we want to enqueue any jobs that were dependant on it
        dependencies[singleton: .jobRunner].enqueueDependenciesIfNeeded(dependantJobs)
        
        // Perform job cleanup and start the next job
        performCleanUp(for: job, result: .succeeded)
        internalQueue.async(using: dependencies) { [weak self] in
            self?.runNextJob()
        }
    }

    /// This function is called when a job fails, if it's wasn't a permanent failure then the 'failureCount' for the job will be incremented and it'll
    /// be re-run after a retry interval has passed
    fileprivate func handleJobFailed(
        _ job: Job,
        error: Error,
        permanentFailure: Bool
    ) {
        guard dependencies[singleton: .storage].read({ db in try Job.exists(db, id: job.id ?? -1) }) == true else {
            Log.info(.jobRunner, "\(queueContext) \(job) canceled")
            performCleanUp(for: job, result: .failed(error, permanentFailure))
            
            internalQueue.async(using: dependencies) { [weak self] in
                self?.runNextJob()
            }
            return
        }
        
        // If this is the blocking queue and a "blocking" job failed then rerun it
        // immediately (in this case we don't trigger any job callbacks because the
        // job isn't actually done, it's going to try again immediately)
        if self.type == .blocking && job.shouldBlock {
            Log.info(.jobRunner, "\(queueContext) \(job) failed due to error: \(error); retrying immediately")
            
            // If it was a possible deferral loop then we don't actually want to
            // retry the job (even if it's a blocking one, this gives a small chance
            // that the app could continue to function)
            performCleanUp(
                for: job,
                result: .failed(error, permanentFailure),
                shouldTriggerCallbacks: ((error as? JobRunnerError)?.wasPossibleDeferralLoop == true)
            )
            
            // Only add it back to the queue if it wasn't a deferral loop
            if (error as? JobRunnerError)?.wasPossibleDeferralLoop != true {
                _pendingJobsQueue.performUpdate { $0.inserting(job, at: 0) }
            }
            
            internalQueue.async(using: dependencies) { [weak self] in
                self?.runNextJob()
            }
            return
        }
        
        // Get the max failure count for the job (a value of '-1' means it will retry indefinitely)
        let maxFailureCount: Int = (executorMap[job.variant]?.maxFailureCount ?? 0)
        let nextRunTimestamp: TimeInterval = (dependencies.dateNow.timeIntervalSince1970 + JobRunner.getRetryInterval(for: job))
        var dependantJobIds: [Int64] = []
        var failureText: String = "failed due to error: \(error)"
        
        dependencies[singleton: .storage].write { db in
            /// Retrieve a list of dependant jobs so we can clear them from the queue
            dependantJobIds = try job.dependantJobs
                .select(.id)
                .asRequest(of: Int64.self)
                .fetchAll(db)

            /// Delete/update the failed jobs and any dependencies
            let updatedFailureCount: UInt = (job.failureCount + 1)
        
            guard
                !permanentFailure && (
                    maxFailureCount < 0 ||
                    updatedFailureCount <= maxFailureCount ||
                    job.behaviour == .runOnceAfterConfigSyncIgnoringPermanentFailure
                )
            else {
                failureText = (maxFailureCount >= 0 && updatedFailureCount > maxFailureCount ?
                    "failed permanently due to error: \(error); too many retries" :
                    "failed permanently due to error: \(error)"
                )
                
                // If the job permanently failed or we have performed all of our retry attempts
                // then delete the job and all of it's dependant jobs (it'll probably never succeed)
                _ = try job.dependantJobs
                    .deleteAll(db)

                _ = try job.delete(db)
                return
            }
            
            failureText = "failed due to error: \(error); scheduling retry (failure count is \(updatedFailureCount))"
            
            try job
                .with(
                    failureCount: updatedFailureCount,
                    nextRunTimestamp: nextRunTimestamp
                )
                .upserted(db)
            
            // Update the failureCount and nextRunTimestamp on dependant jobs as well (update the
            // 'nextRunTimestamp' value to be 1ms later so when the queue gets regenerated they'll
            // come after the dependency)
            try job.dependantJobs
                .updateAll(
                    db,
                    Job.Columns.failureCount.set(to: updatedFailureCount),
                    Job.Columns.nextRunTimestamp.set(to: (nextRunTimestamp + (1 / 1000)))
                )
        }
        
        /// Remove any dependant jobs from the queue (shouldn't be in there but filter the queue just in case so we don't try
        /// to run a deleted job or get stuck in a loop of trying to run dependencies indefinitely)
        if !dependantJobIds.isEmpty {
            _pendingJobsQueue.performUpdate { queue in
                queue.filter { !dependantJobIds.contains($0.id ?? -1) }
            }
        }
        
        Log.error(.jobRunner, "\(queueContext) \(job) \(failureText)")
        performCleanUp(for: job, result: .failed(error, permanentFailure))
        internalQueue.async(using: dependencies) { [weak self] in
            self?.runNextJob()
        }
    }
    
    /// This function is called when a job neither succeeds or fails (this should only occur if the job has specific logic that makes it dependant
    /// on other jobs, and it should automatically manage those dependencies)
    fileprivate func handleJobDeferred(_ job: Job) {
        var stuckInDeferLoop: Bool = false
        
        _deferLoopTracker.performUpdate {
            guard let lastRecord: (count: Int, times: [TimeInterval]) = $0[job.id] else {
                return $0.setting(
                    job.id,
                    (1, [dependencies.dateNow.timeIntervalSince1970])
                )
            }
            
            let timeNow: TimeInterval = dependencies.dateNow.timeIntervalSince1970
            stuckInDeferLoop = (
                lastRecord.count >= JobQueue.deferralLoopThreshold &&
                (timeNow - lastRecord.times[0]) < CGFloat(lastRecord.count * maxDeferralsPerSecond)
            )
            
            return $0.setting(
                job.id,
                (
                    lastRecord.count + 1,
                    // Only store the last 'deferralLoopThreshold' times to ensure we aren't running faster
                    // than one loop per second
                    lastRecord.times.suffix(JobQueue.deferralLoopThreshold - 1) + [timeNow]
                )
            )
        }
        
        // It's possible (by introducing bugs) to create a loop where a Job tries to run and immediately
        // defers itself but then attempts to run again (resulting in an infinite loop); this won't block
        // the app since it's on a background thread but can result in 100% of a CPU being used (and a
        // battery drain)
        //
        // This code will maintain an in-memory store for any jobs which are deferred too quickly (ie.
        // more than 'deferralLoopThreshold' times within 'deferralLoopThreshold' seconds)
        guard !stuckInDeferLoop else {
            _deferLoopTracker.performUpdate { $0.removingValue(forKey: job.id) }
            handleJobFailed(
                job,
                error: JobRunnerError.possibleDeferralLoop,
                permanentFailure: false
            )
            return
        }
        
        performCleanUp(for: job, result: .deferred)
        internalQueue.async(using: dependencies) { [weak self] in
            self?.runNextJob()
        }
    }
    
    fileprivate func performCleanUp(
        for job: Job,
        result: JobRunner.JobResult,
        shouldTriggerCallbacks: Bool = true
    ) {
        // The job is removed from the queue before it runs so all we need to to is remove it
        // from the 'currentlyRunning' set
        _currentlyRunningJobIds.performUpdate { $0.removing(job.id) }
        _currentlyRunningJobInfo.performUpdate { $0.removingValue(forKey: job.id) }
        
        guard shouldTriggerCallbacks else { return }
        
        // Notify any listeners of the job result
        jobCompletedSubject.send((job.id, result))
    }
}

// MARK: - Formatting

private extension String.StringInterpolation {
    mutating func appendInterpolation(_ job: Job) {
        appendLiteral("\(job.variant) job (id: \(job.id ?? -1))")
    }
    
    mutating func appendInterpolation(_ job: Job?) {
        switch job {
            case .some(let job): appendInterpolation(job)
            case .none: appendLiteral("null job")
        }
    }
}

extension String.StringInterpolation {
    mutating func appendInterpolation(_ variant: Job.Variant?) {
        appendLiteral(variant.map { "\($0)" } ?? "unknown")
    }
    
    mutating func appendInterpolation(_ behaviour: Job.Behaviour?) {
        appendLiteral(behaviour.map { "\($0)" } ?? "unknown")
    }
}

// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - KeychainStorage

public extension KeychainStorage.DataKey { static let pushNotificationEncryptionKey: Self = "PNEncryptionKeyKey" }

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("PushNotificationAPI", defaultLevel: .info)
}

// MARK: - PushNotificationAPI

public enum PushNotificationAPI {
    internal static let encryptionKeyLength: Int = 32
    private static let maxRetryCount: Int = 4
    private static let tokenExpirationInterval: TimeInterval = (12 * 60 * 60)
    
    public static let server: String = "https://push.getsession.org"
    public static let serverPublicKey = "d7557fe563e2610de876c0ac7341b62f3c82d5eea4b62c702392ea4368f51b3b"
        
    // MARK: - Batch Requests
    
    public static func subscribeAll(
        token: Data,
        isForcedUpdate: Bool,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        let hexEncodedToken: String = token.toHexString()
        let oldToken: String? = dependencies[defaults: .standard, key: .deviceToken]
        let lastUploadTime: Double = dependencies[defaults: .standard, key: .lastDeviceTokenUpload]
        let now: TimeInterval = dependencies.dateNow.timeIntervalSince1970
        
        guard isForcedUpdate || hexEncodedToken != oldToken || now - lastUploadTime > tokenExpirationInterval else {
            Log.info(.cat, "Device token hasn't changed or expired; no need to re-upload.")
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        return dependencies[singleton: .storage]
            .readPublisher { db -> Network.PreparedRequest<PushNotificationAPI.SubscribeResponse> in
                let userSessionId: SessionId = dependencies[cache: .general].sessionId
                
                return try PushNotificationAPI
                    .preparedSubscribe(
                        db,
                        token: token,
                        sessionIds: [userSessionId]
                            .appending(contentsOf: try ClosedGroup
                                .select(.threadId)
                                .filter(
                                    ClosedGroup.Columns.threadId > SessionId.Prefix.group.rawValue &&
                                    ClosedGroup.Columns.threadId < SessionId.Prefix.group.endOfRangeString
                                )
                                .filter(ClosedGroup.Columns.shouldPoll)
                                .asRequest(of: String.self)
                                .fetchSet(db)
                                .map { SessionId(.group, hex: $0) }
                            ),
                        using: dependencies
                    )
                    .handleEvents(
                        receiveOutput: { _, response in
                            guard response.subResponses.first?.success == true else { return }
                            
                            dependencies[defaults: .standard, key: .deviceToken] = hexEncodedToken
                            dependencies[defaults: .standard, key: .lastDeviceTokenUpload] = now
                            dependencies[defaults: .standard, key: .isUsingFullAPNs] = true
                        }
                    )
            }
            .flatMap { $0.send(using: dependencies) }
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    public static func unsubscribeAll(
        token: Data,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        return dependencies[singleton: .storage]
            .readPublisher { db -> Network.PreparedRequest<PushNotificationAPI.UnsubscribeResponse> in
                let userSessionId: SessionId = dependencies[cache: .general].sessionId
                
                return try PushNotificationAPI
                    .preparedUnsubscribe(
                        db,
                        token: token,
                        sessionIds: [userSessionId]
                            .appending(contentsOf: (try? ClosedGroup
                                .select(.threadId)
                                .filter(
                                    ClosedGroup.Columns.threadId > SessionId.Prefix.group.rawValue &&
                                    ClosedGroup.Columns.threadId < SessionId.Prefix.group.endOfRangeString
                                )
                                .asRequest(of: String.self)
                                .fetchSet(db))
                                .defaulting(to: [])
                                .map { SessionId(.group, hex: $0) }),
                        using: dependencies
                    )
                    .handleEvents(
                        receiveOutput: { _, response in
                            guard response.subResponses.first?.success == true else { return }
                            
                            dependencies[defaults: .standard, key: .deviceToken] = nil
                        }
                    )
            }
            .flatMap { $0.send(using: dependencies) }
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Prepared Requests
    
    public static func preparedSubscribe(
        _ db: Database,
        token: Data,
        sessionIds: [SessionId],
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<SubscribeResponse> {
        guard dependencies[defaults: .standard, key: .isUsingFullAPNs] else {
            throw NetworkError.invalidPreparedRequest
        }
        
        guard let notificationsEncryptionKey: Data = try? getOrGenerateEncryptionKey(using: dependencies) else {
            Log.error(.cat, "Unable to retrieve PN encryption key.")
            throw StorageError.invalidKeySpec
        }
        
        return try Network.PreparedRequest(
            request: Request(
                method: .post,
                endpoint: Endpoint.subscribe,
                body: SubscribeRequest(
                    subscriptions: sessionIds.map { sessionId -> SubscribeRequest.Subscription in
                        SubscribeRequest.Subscription(
                            namespaces: {
                                switch sessionId.prefix {
                                    case .group: return [
                                        .groupMessages,
                                        .configGroupKeys,
                                        .configGroupInfo,
                                        .configGroupMembers,
                                        .revokedRetrievableGroupMessages
                                    ]
                                    default: return [.default, .configConvoInfoVolatile]
                                }
                            }(),
                            /// Note: Unfortunately we always need the message content because without the content
                            /// control messages can't be distinguished from visible messages which results in the
                            /// 'generic' notification being shown when receiving things like typing indicator updates
                            includeMessageData: true,
                            serviceInfo: ServiceInfo(
                                token: token.toHexString()
                            ),
                            notificationsEncryptionKey: notificationsEncryptionKey,
                            authMethod: try Authentication.with(
                                db,
                                swarmPublicKey: sessionId.hexString,
                                using: dependencies
                            ),
                            timestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000) // Seconds
                        )
                    }
                )
            ),
            responseType: SubscribeResponse.self,
            retryCount: PushNotificationAPI.maxRetryCount,
            using: dependencies
        )
        .handleEvents(
            receiveOutput: { _, response in
                zip(response.subResponses, sessionIds).forEach { subResponse, sessionId in
                    guard subResponse.success != true else { return }
                    
                    Log.error(.cat, "Couldn't subscribe for push notifications for: \(sessionId) due to error (\(subResponse.error ?? -1)): \(subResponse.message ?? "nil").")
                }
            },
            receiveCompletion: { result in
                switch result {
                    case .finished: break
                    case .failure: Log.error(.cat, "Couldn't subscribe for push notifications.")
                }
            }
        )
    }
    
    public static func preparedUnsubscribe(
        _ db: Database,
        token: Data,
        sessionIds: [SessionId],
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<UnsubscribeResponse> {
        return try Network.PreparedRequest(
            request: Request(
                method: .post,
                endpoint: Endpoint.unsubscribe,
                body: UnsubscribeRequest(
                    subscriptions: sessionIds.map { sessionId -> UnsubscribeRequest.Subscription in
                        UnsubscribeRequest.Subscription(
                            serviceInfo: ServiceInfo(
                                token: token.toHexString()
                            ),
                            authMethod: try Authentication.with(
                                db,
                                swarmPublicKey: sessionId.hexString,
                                using: dependencies
                            ),
                            timestamp: (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000) // Seconds
                        )
                    }
                )
            ),
            responseType: UnsubscribeResponse.self,
            retryCount: PushNotificationAPI.maxRetryCount,
            using: dependencies
        )
        .handleEvents(
            receiveOutput: { _, response in
                zip(response.subResponses, sessionIds).forEach { subResponse, sessionId in
                    guard subResponse.success != true else { return }
                    
                    Log.error(.cat, "Couldn't unsubscribe for push notifications for: \(sessionId) due to error (\(subResponse.error ?? -1)): \(subResponse.message ?? "nil").")
                }
            },
            receiveCompletion: { result in
                switch result {
                    case .finished: break
                    case .failure: Log.error(.cat, "Couldn't unsubscribe for push notifications.")
                }
            }
        )
    }
    
    // MARK: - Notification Handling
    
    public static func processNotification(
        notificationContent: UNNotificationContent,
        using dependencies: Dependencies
    ) -> (data: Data?, metadata: NotificationMetadata, result: ProcessResult) {
        // Make sure the notification is from the updated push server
        guard notificationContent.userInfo["spns"] != nil else {
            return (nil, .invalid, .legacyFailure)
        }
        
        guard let base64EncodedEncString: String = notificationContent.userInfo["enc_payload"] as? String else {
            return (nil, .invalid, .failureNoContent)
        }
        
        // Decrypt and decode the payload
        guard
            let encryptedData: Data = Data(base64Encoded: base64EncodedEncString),
            let notificationsEncryptionKey: Data = try? getOrGenerateEncryptionKey(using: dependencies),
            let decryptedData: Data = dependencies[singleton: .crypto].generate(
                .plaintextWithPushNotificationPayload(
                    payload: encryptedData,
                    encKey: notificationsEncryptionKey
                )
            ),
            let notification: BencodeResponse<NotificationMetadata> = try? BencodeDecoder(using: dependencies)
                .decode(BencodeResponse<NotificationMetadata>.self, from: decryptedData)
        else {
            Log.error(.cat, "Failed to decrypt or decode notification")
            return (nil, .invalid, .failure)
        }
        
        // If the metadata says that the message was too large then we should show the generic
        // notification (this is a valid case)
        guard !notification.info.dataTooLong else { return (nil, notification.info, .successTooLong) }
        
        // Check that the body we were given is valid and not empty
        guard
            let notificationData: Data = notification.data,
            notification.info.dataLength == notificationData.count,
            !notificationData.isEmpty
        else {
            Log.error(.cat, "Get notification data failed")
            return (nil, notification.info, .failureNoContent)
        }
        
        // Success, we have the notification content
        return (notificationData, notification.info, .success)
    }
                        
    // MARK: - Security
    
    @discardableResult private static func getOrGenerateEncryptionKey(using dependencies: Dependencies) throws -> Data {
        do {
            try dependencies[singleton: .keychain].migrateLegacyKeyIfNeeded(
                legacyKey: "PNEncryptionKeyKey",
                legacyService: "PNKeyChainService",
                toKey: .pushNotificationEncryptionKey
            )
            var encryptionKey: Data = try dependencies[singleton: .keychain].data(forKey: .pushNotificationEncryptionKey)
            defer { encryptionKey.resetBytes(in: 0..<encryptionKey.count) }
            
            guard encryptionKey.count == encryptionKeyLength else { throw StorageError.invalidKeySpec }
            
            return encryptionKey
        }
        catch {
            switch (error, (error as? KeychainStorageError)?.code) {
                case (StorageError.invalidKeySpec, _), (_, errSecItemNotFound):
                    // No keySpec was found so we need to generate a new one
                    do {
                        var keySpec: Data = try dependencies[singleton: .crypto]
                            .tryGenerate(.randomBytes(encryptionKeyLength))
                        defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
                        
                        try dependencies[singleton: .keychain].set(data: keySpec, forKey: .pushNotificationEncryptionKey)
                        return keySpec
                    }
                    catch {
                        Log.error(.cat, "Setting keychain value failed with error: \(error.localizedDescription)")
                        throw StorageError.keySpecCreationFailed
                    }
                    
                default:
                    // Because we use kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, the keychain will be inaccessible
                    // after device restart until device is unlocked for the first time. If the app receives a push
                    // notification, we won't be able to access the keychain to process that notification, so we should
                    // just terminate by throwing an uncaught exception
                    if dependencies[singleton: .appContext].isMainApp || dependencies[singleton: .appContext].isInBackground {
                        let appState: UIApplication.State = dependencies[singleton: .appContext].reportedApplicationState
                        Log.error(.cat, "CipherKeySpec inaccessible. New install or no unlock since device restart?, ApplicationState: \(appState.name)")
                        throw StorageError.keySpecInaccessible
                    }
                    
                    Log.error(.cat, "CipherKeySpec inaccessible; not main app.")
                    throw StorageError.keySpecInaccessible
            }
        }
    }
}

import PromiseKit

@objc(LKGroupChatAPI)
public final class LokiGroupChatAPI : LokiDotNetAPI {
    private static var moderators: [String:[UInt64:Set<String>]] = [:] // Server URL to (channel ID to set of moderator IDs)
    
    // MARK: Settings
    private static let fallbackBatchCount = 20
    private static let maxRetryCount: UInt = 8
    
    // MARK: Public Chat
    #if DEBUG
    @objc public static let publicChatServer = "https://chat-dev.lokinet.org"
    #else
    @objc public static let publicChatServer = "https://chat.lokinet.org"
    #endif
    @objc public static let publicChatMessageType = "network.loki.messenger.publicChat"
    @objc public static let publicChatServerID: UInt64 = 1
    
    // MARK: Convenience
    private static var userDisplayName: String {
        return SSKEnvironment.shared.contactsManager.displayName(forPhoneIdentifier: userHexEncodedPublicKey) ?? "Anonymous"
    }
    
    // MARK: Database
    override internal class var authTokenCollection: String { "LokiGroupChatAuthTokenCollection" }
    private static let lastMessageServerIDCollection = "LokiGroupChatLastMessageServerIDCollection"
    private static let lastDeletionServerIDCollection = "LokiGroupChatLastDeletionServerIDCollection"
    
    private static func getLastMessageServerID(for group: UInt64, on server: String) -> UInt? {
        var result: UInt? = nil
        storage.dbReadConnection.read { transaction in
            result = transaction.object(forKey: "\(server).\(group)", inCollection: lastMessageServerIDCollection) as! UInt?
        }
        return result
    }
    
    private static func setLastMessageServerID(for group: UInt64, on server: String, to newValue: UInt64) {
        storage.dbReadWriteConnection.readWrite { transaction in
            transaction.setObject(newValue, forKey: "\(server).\(group)", inCollection: lastMessageServerIDCollection)
        }
    }
    
    private static func getLastDeletionServerID(for group: UInt64, on server: String) -> UInt? {
        var result: UInt? = nil
        storage.dbReadConnection.read { transaction in
            result = transaction.object(forKey: "\(server).\(group)", inCollection: lastDeletionServerIDCollection) as! UInt?
        }
        return result
    }
    
    private static func setLastDeletionServerID(for group: UInt64, on server: String, to newValue: UInt64) {
        storage.dbReadWriteConnection.readWrite { transaction in
            transaction.setObject(newValue, forKey: "\(server).\(group)", inCollection: lastDeletionServerIDCollection)
        }
    }
    
    // MARK: Public API
    public static func getMessages(for group: UInt64, on server: String) -> Promise<[LokiGroupMessage]> {
        print("[Loki] Getting messages for group chat with ID: \(group) on server: \(server).")
        var queryParameters = "include_annotations=1"
        if let lastMessageServerID = getLastMessageServerID(for: group, on: server) {
            queryParameters += "&since_id=\(lastMessageServerID)"
        } else {
            queryParameters += "&count=-\(fallbackBatchCount)"
        }
        let url = URL(string: "\(server)/channels/\(group)/messages?\(queryParameters)")!
        let request = TSRequest(url: url)
        return TSNetworkManager.shared().makePromise(request: request).map { $0.responseObject }.map { rawResponse in
            guard let json = rawResponse as? JSON, let rawMessages = json["data"] as? [JSON] else {
                print("[Loki] Couldn't parse messages for group chat with ID: \(group) on server: \(server) from: \(rawResponse).")
                throw Error.parsingFailed
            }
            return rawMessages.flatMap { message in
                let isDeleted = (message["is_deleted"] as? Int == 1)
                guard !isDeleted else { return nil }
                guard let annotations = message["annotations"] as? [JSON], let annotation = annotations.first, let value = annotation["value"] as? JSON,
                    let serverID = message["id"] as? UInt64, let hexEncodedSignatureData = value["sig"] as? String, let signatureVersion = value["sigver"] as? UInt64,
                    let body = message["text"] as? String, let user = message["user"] as? JSON, let hexEncodedPublicKey = user["username"] as? String,
                    let timestamp = value["timestamp"] as? UInt64 else {
                        print("[Loki] Couldn't parse message for group chat with ID: \(group) on server: \(server) from: \(message).")
                        return nil
                }
                let displayName = user["name"] as? String ?? NSLocalizedString("Anonymous", comment: "")
                let lastMessageServerID = getLastMessageServerID(for: group, on: server)
                if serverID > (lastMessageServerID ?? 0) { setLastMessageServerID(for: group, on: server, to: serverID) }
                let quote: LokiGroupMessage.Quote?
                if let quoteAsJSON = value["quote"] as? JSON, let quotedMessageTimestamp = quoteAsJSON["id"] as? UInt64, let quoteeHexEncodedPublicKey = quoteAsJSON["author"] as? String, let quotedMessageBody = quoteAsJSON["text"] as? String {
                    let quotedMessageServerID = message["reply_to"] as? UInt64
                    quote = LokiGroupMessage.Quote(quotedMessageTimestamp: quotedMessageTimestamp, quoteeHexEncodedPublicKey: quoteeHexEncodedPublicKey, quotedMessageBody: quotedMessageBody, quotedMessageServerID: quotedMessageServerID)
                } else {
                    quote = nil
                }
                let signature = LokiGroupMessage.Signature(data: Data(hex: hexEncodedSignatureData), version: signatureVersion)
                let result = LokiGroupMessage(serverID: serverID, hexEncodedPublicKey: hexEncodedPublicKey, displayName: displayName, body: body, type: publicChatMessageType, timestamp: timestamp, quote: quote, signature: signature)
                guard result.hasValidSignature() else {
                    print("[Loki] Ignoring group chat message with invalid signature.")
                    return nil
                }
                return result
            }.sorted { $0.timestamp < $1.timestamp }
        }
    }
    
    public static func sendMessage(_ message: LokiGroupMessage, to group: UInt64, on server: String) -> Promise<LokiGroupMessage> {
        guard let signedMessage = message.sign(with: userKeyPair.privateKey) else { return Promise(error: Error.signingFailed) }
        return getAuthToken(for: server).then { token -> Promise<LokiGroupMessage> in
            print("[Loki] Sending message to group chat with ID: \(group) on server: \(server).")
            let url = URL(string: "\(server)/channels/\(group)/messages")!
            let parameters = signedMessage.toJSON()
            let request = TSRequest(url: url, method: "POST", parameters: parameters)
            request.allHTTPHeaderFields = [ "Content-Type" : "application/json", "Authorization" : "Bearer \(token)" ]
            let displayName = userDisplayName
            return TSNetworkManager.shared().makePromise(request: request).map { $0.responseObject }.map { rawResponse in
                // ISO8601DateFormatter doesn't support milliseconds before iOS 11
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
                guard let json = rawResponse as? JSON, let messageAsJSON = json["data"] as? JSON, let serverID = messageAsJSON["id"] as? UInt64, let body = messageAsJSON["text"] as? String,
                    let dateAsString = messageAsJSON["created_at"] as? String, let date = dateFormatter.date(from: dateAsString) else {
                    print("[Loki] Couldn't parse message for group chat with ID: \(group) on server: \(server) from: \(rawResponse).")
                    throw Error.parsingFailed
                }
                let timestamp = UInt64(date.timeIntervalSince1970) * 1000
                return LokiGroupMessage(serverID: serverID, hexEncodedPublicKey: userHexEncodedPublicKey, displayName: displayName, body: body, type: publicChatMessageType, timestamp: timestamp, quote: signedMessage.quote, signature: signedMessage.signature)
            }
        }.recover { error -> Promise<LokiGroupMessage> in
            if let error = error as? NetworkManagerError, error.statusCode == 401 {
                print("[Loki] Group chat auth token for: \(server) expired; dropping it.")
                storage.dbReadWriteConnection.removeObject(forKey: server, inCollection: authTokenCollection)
            }
            throw error
        }.retryingIfNeeded(maxRetryCount: maxRetryCount).map { message in
            Analytics.shared.track("Group Message Sent")
            return message
        }.recover { error -> Promise<LokiGroupMessage> in
            Analytics.shared.track("Failed to Send Group Message")
            throw error
        }
    }
    
    public static func getDeletedMessageServerIDs(for group: UInt64, on server: String) -> Promise<[UInt64]> {
        print("[Loki] Getting deleted messages for group chat with ID: \(group) on server: \(server).")
        let queryParameters: String
        if let lastDeletionServerID = getLastDeletionServerID(for: group, on: server) {
            queryParameters = "since_id=\(lastDeletionServerID)"
        } else {
            queryParameters = "count=\(fallbackBatchCount)"
        }
        let url = URL(string: "\(server)/loki/v1/channel/\(group)/deletes?\(queryParameters)")!
        let request = TSRequest(url: url)
        return TSNetworkManager.shared().makePromise(request: request).map { $0.responseObject }.map { rawResponse in
            guard let json = rawResponse as? JSON, let deletions = json["data"] as? [JSON] else {
                print("[Loki] Couldn't parse deleted messages for group chat with ID: \(group) on server: \(server) from: \(rawResponse).")
                throw Error.parsingFailed
            }
            return deletions.flatMap { deletion in
                guard let serverID = deletion["id"] as? UInt64, let messageServerID = deletion["message_id"] as? UInt64 else {
                    print("[Loki] Couldn't parse deleted message for group chat with ID: \(group) on server: \(server) from: \(deletion).")
                    return nil
                }
                let lastDeletionServerID = getLastDeletionServerID(for: group, on: server)
                if serverID > (lastDeletionServerID ?? 0) { setLastDeletionServerID(for: group, on: server, to: serverID) }
                return messageServerID
            }
        }
    }
    
    public static func deleteMessage(with messageID: UInt, for group: UInt64, on server: String, isSentByUser: Bool) -> Promise<Void> {
        return getAuthToken(for: server).then { token -> Promise<Void> in
            let isModerationRequest = !isSentByUser
            print("[Loki] Deleting message with ID: \(messageID) for group chat with ID: \(group) on server: \(server) (isModerationRequest = \(isModerationRequest)).")
            let urlAsString = isSentByUser ? "\(server)/channels/\(group)/messages/\(messageID)" : "\(server)/loki/v1/moderation/message/\(messageID)"
            let url = URL(string: urlAsString)!
            let request = TSRequest(url: url, method: "DELETE", parameters: [:])
            request.allHTTPHeaderFields = [ "Content-Type" : "application/json", "Authorization" : "Bearer \(token)" ]
            return TSNetworkManager.shared().makePromise(request: request).done { result -> Void in
                print("[Loki] Deleted message with ID: \(messageID) on server: \(server).")
            }.retryingIfNeeded(maxRetryCount: maxRetryCount)
        }
    }
    
    public static func getModerators(for group: UInt64, on server: String) -> Promise<Set<String>> {
        let url = URL(string: "\(server)/loki/v1/channel/\(group)/get_moderators")!
        let request = TSRequest(url: url)
        return TSNetworkManager.shared().makePromise(request: request).map { $0.responseObject }.map { rawResponse in
            guard let json = rawResponse as? JSON, let moderators = json["moderators"] as? [String] else {
                print("[Loki] Couldn't parse moderators for group chat with ID: \(group) on server: \(server) from: \(rawResponse).")
                throw Error.parsingFailed
            }
            let moderatorAsSet = Set(moderators);
            if self.moderators.keys.contains(server) {
                self.moderators[server]![group] = moderatorAsSet
            } else {
                self.moderators[server] = [ group : moderatorAsSet ]
            }
            return moderatorAsSet
        }
    }
    
    @objc (isUserModerator:forGroup:onServer:)
    public static func isUserModerator(_ hexEncodedPublicString: String, for group: UInt64, on server: String) -> Bool {
        return moderators[server]?[group]?.contains(hexEncodedPublicString) ?? false
    }
    
    public static func setDisplayName(to newDisplayName: String?, on server: String) -> Promise<Void> {
        print("[Loki] Updating display name on server: \(server).")
        return getAuthToken(for: server).then { token -> Promise<Void> in
            let parameters: JSON = [ "name" : newDisplayName ]
            let url = URL(string: "\(server)/users/me")!
            let request = TSRequest(url: url, method: "PATCH", parameters: parameters)
            request.allHTTPHeaderFields = [ "Content-Type" : "application/json", "Authorization" : "Bearer \(token)" ]
            return TSNetworkManager.shared().makePromise(request: request).map { _ in }.recover { error in
                print("Couldn't update display name due to error: \(error).")
                throw error
            }
        }
    }
    
    // MARK: Public API (Obj-C)
    @objc(getMessagesForGroup:onServer:)
    public static func objc_getMessages(for group: UInt64, on server: String) -> AnyPromise {
        return AnyPromise.from(getMessages(for: group, on: server))
    }
    
    @objc(sendMessage:toGroup:onServer:)
    public static func objc_sendMessage(_ message: LokiGroupMessage, to group: UInt64, on server: String) -> AnyPromise {
        return AnyPromise.from(sendMessage(message, to: group, on: server))
    }
    
    @objc(deleteMessageWithID:forGroup:onServer:isSentByUser:)
    public static func objc_deleteMessage(with messageID: UInt, for group: UInt64, on server: String, isSentByUser: Bool) -> AnyPromise {
        return AnyPromise.from(deleteMessage(with: messageID, for: group, on: server, isSentByUser: isSentByUser))
    }
    
    @objc(setDisplayName:on:)
    public static func objc_setDisplayName(to newDisplayName: String?, on server: String) -> AnyPromise {
        return AnyPromise.from(setDisplayName(to: newDisplayName, on: server))
    }
}

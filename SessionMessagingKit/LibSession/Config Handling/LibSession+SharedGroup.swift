// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import SessionUIKit
import SessionSnodeKit
import SessionUtil
import SessionUtilitiesKit

// MARK: - Group Domains

public extension LibSession.Crypto.Domain {
    static var kickedMessage: LibSession.Crypto.Domain = "SessionGroupKickedMessage"   // stringlint:disable
}

// MARK: - Convenience

internal extension LibSession {
    typealias CreatedGroupInfo = (
        groupSessionId: SessionId,
        identityKeyPair: KeyPair,
        groupState: [ConfigDump.Variant: Config],
        group: ClosedGroup,
        members: [GroupMember]
    )
    
    static func createGroup(
        _ db: Database,
        name: String,
        description: String?,
        displayPictureUrl: String?,
        displayPictureFilename: String?,
        displayPictureEncryptionKey: Data?,
        members: [(id: String, profile: Profile?)],
        using dependencies: Dependencies
    ) throws -> CreatedGroupInfo {
        guard
            let groupIdentityKeyPair: KeyPair = dependencies[singleton: .crypto].generate(.ed25519KeyPair()),
            let userED25519KeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db)
        else { throw MessageSenderError.noKeyPair }
        
        // Prep the relevant details (reduce the members to ensure we don't accidentally insert duplicates)
        let groupSessionId: SessionId = SessionId(.group, publicKey: groupIdentityKeyPair.publicKey)
        let creationTimestamp: TimeInterval = TimeInterval(dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let currentUserProfile: Profile? = Profile.fetchOrCreateCurrentUser(db, using: dependencies)
        
        // Create the new config objects
        let groupState: [ConfigDump.Variant: Config] = try createGroupState(
            groupSessionId: groupSessionId,
            userED25519KeyPair: userED25519KeyPair,
            groupIdentityPrivateKey: Data(groupIdentityKeyPair.secretKey),
            shouldLoadState: false, // We manually load the state after populating the configs
            using: dependencies
        )
        
        // Extract the conf objects from the state to load in the initial data
        guard case .groupKeys(let groupKeysConf, let groupInfoConf, let groupMembersConf) = groupState[.groupKeys] else {
            SNLog("[LibSession] Group config objects were null")
            throw LibSessionError.unableToCreateConfigObject
        }
        
        // Set the initial values in the confs
        var cName: [CChar] = try name.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
        groups_info_set_name(groupInfoConf, &cName)
        groups_info_set_created(groupInfoConf, Int64(floor(creationTimestamp)))
        
        if let groupDescription: String = description {
            var cDesc: [CChar] = try groupDescription.cString(using: .utf8) ?? { throw LibSessionError.invalidCConversion }()
            groups_info_set_description(groupInfoConf, &cDesc)
        }
        
        if
            let displayPictureUrl: String = displayPictureUrl,
            let displayPictureEncryptionKey: Data = displayPictureEncryptionKey
        {
            var displayPic: user_profile_pic = user_profile_pic()
            displayPic.url = displayPictureUrl.toLibSession()
            displayPic.key = displayPictureEncryptionKey.toLibSession()
            groups_info_set_pic(groupInfoConf, displayPic)
        }
        
        // Throw if there was an error setting up the group info
        try LibSessionError.throwIfNeeded(groupInfoConf)
        
        // Load in the initial admin & members
        struct MemberInfo: Hashable {
            let id: String
            let isAdmin: Bool
            let profile: Profile?
        }
        
        try members
            .filter { $0.id != userSessionId.hexString }
            .map { id, profile in MemberInfo(id: id, isAdmin: false, profile: profile) }
            .appending(MemberInfo(id: userSessionId.hexString, isAdmin: true, profile: currentUserProfile))
            .asSet()
            .forEach { memberInfo in
                var profilePic: user_profile_pic = user_profile_pic()
                
                if
                    let picUrl: String = memberInfo.profile?.profilePictureUrl,
                    let picKey: Data = memberInfo.profile?.profileEncryptionKey,
                    !picUrl.isEmpty,
                    picKey.count == DisplayPictureManager.aes256KeyByteLength
                {
                    profilePic.url = picUrl.toLibSession()
                    profilePic.key = picKey.toLibSession()
                }
                
                var member: config_group_member = config_group_member(
                    session_id: memberInfo.id.toLibSession(),
                    name: (memberInfo.profile?.name ?? "").toLibSession(),
                    profile_pic: profilePic,
                    admin: memberInfo.isAdmin,
                    invited: (memberInfo.isAdmin ? 0 : 1),  // The current user (admin) isn't invited
                    promoted: 0,
                    removed: 0,
                    supplement: false
                )
                
                groups_members_set(groupMembersConf, &member)
                try LibSessionError.throwIfNeeded(groupMembersConf)
            }
        
        // Now that the members have been loaded we need to trigger the initial key generation for the group
        var pushResult: UnsafePointer<UInt8>? = nil
        var pushResultLen: Int = 0
        guard groups_keys_rekey(groupKeysConf, groupInfoConf, groupMembersConf, &pushResult, &pushResultLen) else {
            throw LibSessionError.failedToRekeyGroup
        }
        
        // Now that everything has been populated correctly we can load the state into memory
        dependencies.mutate(cache: .libSession) { cache in
            groupState.forEach { variant, config in
                cache.setConfig(for: variant, sessionId: groupSessionId, to: config)
            }
        }
        
        return (
            groupSessionId,
            groupIdentityKeyPair,
            groupState,
            ClosedGroup(
                threadId: groupSessionId.hexString,
                name: name,
                formationTimestamp: creationTimestamp,
                displayPictureUrl: displayPictureUrl,
                displayPictureFilename: displayPictureFilename,
                displayPictureEncryptionKey: displayPictureEncryptionKey,
                lastDisplayPictureUpdate: creationTimestamp,
                shouldPoll: true,
                groupIdentityPrivateKey: Data(groupIdentityKeyPair.secretKey),
                invited: false
            ),
            members
                .filter { $0.id != userSessionId.hexString }
                .map { memberId, info -> GroupMember in
                    GroupMember(
                        groupId: groupSessionId.hexString,
                        profileId: memberId,
                        role: .standard,
                        roleStatus: .pending,
                        isHidden: false
                    )
                }
                .appending(
                    GroupMember(
                        groupId: groupSessionId.hexString,
                        profileId: userSessionId.hexString,
                        role: .admin,
                        roleStatus: .accepted,
                        isHidden: false
                    )
                )
        )
    }
    
    static func removeGroupStateIfNeeded(
        _ db: Database,
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) {
        dependencies.mutate(cache: .libSession) { cache in
            cache.setConfig(for: .groupKeys, sessionId: groupSessionId, to: nil)
            cache.setConfig(for: .groupInfo, sessionId: groupSessionId, to: nil)
            cache.setConfig(for: .groupMembers, sessionId: groupSessionId, to: nil)
        }
        
        _ = try? ConfigDump
            .filter(ConfigDump.Columns.sessionId == groupSessionId.hexString)
            .deleteAll(db)
    }
    
    static func saveCreatedGroup(
        _ db: Database,
        group: ClosedGroup,
        groupState: [ConfigDump.Variant: Config],
        using dependencies: Dependencies
    ) throws {
        // Create and save dumps for the configs
        try groupState.forEach { variant, config in
            try LibSession.createDump(
                config: config,
                for: variant,
                sessionId: SessionId(.group, hex: group.id),
                timestampMs: Int64(floor(group.formationTimestamp * 1000)),
                using: dependencies
            )?.upsert(db)
        }
        
        // Add the new group to the USER_GROUPS config message
        try LibSession.add(
            db,
            groupSessionId: group.id,
            groupIdentityPrivateKey: group.groupIdentityPrivateKey,
            name: group.name,
            authData: group.authData,
            joinedAt: group.formationTimestamp,
            invited: (group.invited == true),
            using: dependencies
        )
    }
    
    @discardableResult static func createGroupState(
        groupSessionId: SessionId,
        userED25519KeyPair: KeyPair,
        groupIdentityPrivateKey: Data?,
        shouldLoadState: Bool,
        using dependencies: Dependencies
    ) throws -> [ConfigDump.Variant: Config] {
        var secretKey: [UInt8] = userED25519KeyPair.secretKey
        var groupIdentityPublicKey: [UInt8] = groupSessionId.publicKey
        
        // Create the new config objects
        var groupKeysConf: UnsafeMutablePointer<config_group_keys>? = nil
        var groupInfoConf: UnsafeMutablePointer<config_object>? = nil
        var groupMembersConf: UnsafeMutablePointer<config_object>? = nil
        var error: [CChar] = [CChar](repeating: 0, count: 256)
        
        // It looks like C doesn't deal will passing pointers to null variables well so we need
        // to explicitly pass 'nil' for the admin key in this case
        switch groupIdentityPrivateKey {
            case .some(let privateKeyData):
                var groupIdentityPrivateKey: [UInt8] = Array(privateKeyData)
                
                try groups_info_init(
                    &groupInfoConf,
                    &groupIdentityPublicKey,
                    &groupIdentityPrivateKey,
                    nil,
                    0,
                    &error
                ).orThrow(error: error)
                try groups_members_init(
                    &groupMembersConf,
                    &groupIdentityPublicKey,
                    &groupIdentityPrivateKey,
                    nil,
                    0,
                    &error
                ).orThrow(error: error)
                
                try groups_keys_init(
                    &groupKeysConf,
                    &secretKey,
                    &groupIdentityPublicKey,
                    &groupIdentityPrivateKey,
                    groupInfoConf,
                    groupMembersConf,
                    nil,
                    0,
                    &error
                ).orThrow(error: error)
                
            case .none:
                try groups_info_init(
                    &groupInfoConf,
                    &groupIdentityPublicKey,
                    nil,
                    nil,
                    0,
                    &error
                ).orThrow(error: error)
                try groups_members_init(
                    &groupMembersConf,
                    &groupIdentityPublicKey,
                    nil,
                    nil,
                    0,
                    &error
                ).orThrow(error: error)
                
                try groups_keys_init(
                    &groupKeysConf,
                    &secretKey,
                    &groupIdentityPublicKey,
                    nil,
                    groupInfoConf,
                    groupMembersConf,
                    nil,
                    0,
                    &error
                ).orThrow(error: error)
        }
        
        guard
            let keysConf: UnsafeMutablePointer<config_group_keys> = groupKeysConf,
            let infoConf: UnsafeMutablePointer<config_object> = groupInfoConf,
            let membersConf: UnsafeMutablePointer<config_object> = groupMembersConf
        else {
            SNLog("[LibSession] Group config objects were null")
            throw LibSessionError.unableToCreateConfigObject
        }
        
        // Define the config state map and load it into memory
        let groupState: [ConfigDump.Variant: Config] = [
            .groupKeys: .groupKeys(keysConf, info: infoConf, members: membersConf),
            .groupInfo: .object(infoConf),
            .groupMembers: .object(membersConf),
        ]
        
        // Only load the state if specified (during initial group creation we want to
        // load the state after populating the different configs incase invalid data
        // was provided)
        if shouldLoadState {
            dependencies.mutate(cache: .libSession) { cache in
                groupState.forEach { variant, config in
                    cache.setConfig(for: variant, sessionId: groupSessionId, to: config)
                }
            }
        }
        
        return groupState
    }
    
    static func isAdmin(
        groupSessionId: SessionId,
        using dependencies: Dependencies
    ) -> Bool {
        return (try? dependencies[cache: .libSession]
            .config(for: .groupKeys, sessionId: groupSessionId)
            .wrappedValue
            .map { config in
                guard case .groupKeys(let conf, _, _) = config else { throw LibSessionError.invalidConfigObject }
                
                return groups_keys_is_admin(conf)
            })
            .defaulting(to: false)
    }
}

private extension Int32 {
    func orThrow(error: [CChar]) throws {
        guard self != 0 else { return }
        
        SNLog("[LibSession] Unable to create group config objects: \(String(cString: error))")
        throw LibSessionError.unableToCreateConfigObject
    }
}

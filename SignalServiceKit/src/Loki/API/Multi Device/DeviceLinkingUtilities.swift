
public enum DeviceLinkingUtilities {
    
    // When requesting a device link, the slave device signs the master device's public key. When authorizing
    // a device link, the master device signs the slave device's public key.
    
    public static func getLinkingRequestMessage(for masterHexEncodedPublicKey: String) -> DeviceLinkMessage {
        let slaveKeyPair = OWSIdentityManager.shared().identityKeyPair()!
        let slaveHexEncodedPublicKey = slaveKeyPair.hexEncodedPublicKey
        var kind = UInt8(LKDeviceLinkMessageKind.request.rawValue)
        let data = Data(hex: masterHexEncodedPublicKey) + Data(bytes: &kind, count: MemoryLayout.size(ofValue: kind))
        let slaveSignature = try! Ed25519.sign(data, with: slaveKeyPair)
        let thread = TSContactThread.getOrCreateThread(contactId: masterHexEncodedPublicKey)
        return DeviceLinkMessage(in: thread, masterHexEncodedPublicKey: masterHexEncodedPublicKey, slaveHexEncodedPublicKey: slaveHexEncodedPublicKey, masterSignature: nil, slaveSignature: slaveSignature)
    }
    
    public static func getLinkingAuthorizationMessage(for deviceLink: DeviceLink) -> DeviceLinkMessage {
        let masterKeyPair = OWSIdentityManager.shared().identityKeyPair()!
        let masterHexEncodedPublicKey = masterKeyPair.hexEncodedPublicKey
        let slaveHexEncodedPublicKey = deviceLink.slave.hexEncodedPublicKey
        var kind = UInt8(LKDeviceLinkMessageKind.authorization.rawValue)
        let data = Data(hex: slaveHexEncodedPublicKey) + Data(bytes: &kind, count: MemoryLayout.size(ofValue: kind))
        let masterSignature = try! Ed25519.sign(data, with: masterKeyPair)
        let slaveSignature = deviceLink.slave.signature!
        let thread = TSContactThread.getOrCreateThread(contactId: slaveHexEncodedPublicKey)
        return DeviceLinkMessage(in: thread, masterHexEncodedPublicKey: masterHexEncodedPublicKey, slaveHexEncodedPublicKey: slaveHexEncodedPublicKey, masterSignature: masterSignature, slaveSignature: slaveSignature)
    }

    public static func hasValidSlaveSignature(_ deviceLink: DeviceLink) -> Bool {
        guard let slaveSignature = deviceLink.slave.signature else { return false }
        let slavePublicKey = Data(hex: deviceLink.slave.hexEncodedPublicKey.removing05PrefixIfNeeded())
        var kind = UInt8(LKDeviceLinkMessageKind.request.rawValue)
        let data = Data(hex: deviceLink.master.hexEncodedPublicKey) + Data(bytes: &kind, count: MemoryLayout.size(ofValue: kind))
        return (try? Ed25519.verifySignature(slaveSignature, publicKey: slavePublicKey, data: data)) ?? false
    }

    public static func hasValidMasterSignature(_ deviceLink: DeviceLink) -> Bool {
        guard let masterSignature = deviceLink.master.signature else { return false }
        let masterPublicKey = Data(hex: deviceLink.master.hexEncodedPublicKey.removing05PrefixIfNeeded())
        var kind = UInt8(LKDeviceLinkMessageKind.authorization.rawValue)
        let data = Data(hex: deviceLink.slave.hexEncodedPublicKey) + Data(bytes: &kind, count: MemoryLayout.size(ofValue: kind))
        return (try? Ed25519.verifySignature(masterSignature, publicKey: masterPublicKey, data: data)) ?? false
    }
}

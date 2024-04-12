// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public enum SnodeAPIError: Error, CustomStringConvertible {
    case clockOutOfSync
    case snodePoolUpdatingFailed
    case inconsistentSnodePools
    case noKeyPair
    case signingFailed
    case signatureVerificationFailed
    case invalidIP
    case responseFailedValidation
    case rateLimited
    case missingSnodeVersion
    case unsupportedSnodeVersion(String)
    
    // Onion Request Errors
    case emptySnodePool
    case insufficientSnodes
    case ranOutOfRandomSnodes(Error?)
    
    // ONS
    case onsDecryptionFailed
    case onsHashingFailed
    case onsValidationFailed
    
    // Quic
    case invalidPayload
    case missingSecretKey
    case unreachable
    case unassociatedPubkey

    public var description: String {
        switch self {
            case .clockOutOfSync: return "Your clock is out of sync with the Service Node network. Please check that your device's clock is set to automatic time (SnodeAPIError.clockOutOfSync)."
            case .snodePoolUpdatingFailed: return "Failed to update the Service Node pool (SnodeAPIError.snodePoolUpdatingFailed)."
            case .inconsistentSnodePools: return "Received inconsistent Service Node pool information from the Service Node network (SnodeAPIError.inconsistentSnodePools)."
            case .noKeyPair: return "Missing user key pair (SnodeAPIError.noKeyPair)."
            case .signingFailed: return "Couldn't sign message (SnodeAPIError.signingFailed)."
            case .signatureVerificationFailed: return "Failed to verify the signature (SnodeAPIError.signatureVerificationFailed)."
            case .invalidIP: return "Invalid IP (SnodeAPIError.invalidIP)."
            case .responseFailedValidation: return "Response failed validation (SnodeAPIError.responseFailedValidation)."
            case .rateLimited: return "Rate limited (SnodeAPIError.rateLimited)."
            case .missingSnodeVersion: return "Missing Service Node version (SnodeAPIError.missingSnodeVersion)."
            case .unsupportedSnodeVersion(let version): return "Unsupported Service Node version: \(version) (SnodeAPIError.unsupportedSnodeVersion)."
                
            // Onion Request Errors
            case .emptySnodePool: return "Service Node pool is empty (SnodeAPIError.emptySnodePool)."
            case .insufficientSnodes: return "Couldn't find enough Service Nodes to build a path (SnodeAPIError.insufficientSnodes)."
            case .ranOutOfRandomSnodes(let maybeError):
                switch maybeError {
                    case .none: return "Ran out of random snodes (SnodeAPIError.ranOutOfRandomSnodes(nil))."
                    case .some(let error):
                        let errorDesc = "\(error)".trimmingCharacters(in: CharacterSet(["."]))
                        return "Ran out of random snodes (SnodeAPIError.ranOutOfRandomSnodes(\(errorDesc))."
                }
                
            // ONS
            case .onsDecryptionFailed: return "Couldn't decrypt ONS name (SnodeAPIError.onsDecryptionFailed)."
            case .onsHashingFailed: return "Couldn't compute ONS name hash (SnodeAPIError.onsHashingFailed)."
            case .onsValidationFailed: return "ONS name validation failed (SnodeAPIError.onsValidationFailed)."
                
            // Quic
            case .invalidPayload: return "Invalid payload (SnodeAPIError.invalidPayload)."
            case .missingSecretKey: return "Missing secret key (SnodeAPIError.missingSecretKey)."
            case .unreachable: return "The service node is unreachable (SnodeAPIError.unreachable)."
            case .unassociatedPubkey: return "The service node is no longer associated with the public key (SnodeAPIError.unassociatedPubkey)."
        }
    }
}

// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension OpenGroupAPIV2 {
    struct PublicKeyBody: Codable {
        enum CodingKeys: String, CodingKey {
            case publicKey = "public_key"
        }
        
        let publicKey: String
    }
}

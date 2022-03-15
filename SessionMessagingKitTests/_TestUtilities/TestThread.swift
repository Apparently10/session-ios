// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionMessagingKit

// FIXME: Turn this into a protocol to make mocking possible
class TestThread: TSThread, Mockable {
    // MARK: - Mockable
    
    enum DataKey: Hashable {
        case interactions
    }
    
    typealias Key = DataKey
    
    var mockData: [DataKey: Any] = [:]
    var didCallSave: Bool = false
    
    // MARK: - TSThread
    
    override func enumerateInteractions(_ block: @escaping (TSInteraction) -> Void) {
        ((mockData[.interactions] as? [TSInteraction]) ?? []).forEach(block)
    }
    
    override func save(with transaction: YapDatabaseReadWriteTransaction) { didCallSave = true }
}

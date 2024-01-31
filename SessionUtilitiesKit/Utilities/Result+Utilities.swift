// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Result where Failure == Error {
    func onFailure(closure: (Failure) -> ()) -> Result<Success, Failure> {
        switch self {
            case .success: break
            case .failure(let failure): closure(failure)
        }
        
        return self
    }
    
    func successOrThrow() throws -> Success {
        switch self {
            case .success(let value): return value
            case .failure(let error): throw error
        }
    }
}

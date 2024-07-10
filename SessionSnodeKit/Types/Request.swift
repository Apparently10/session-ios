// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

// MARK: - Convenience Types

public struct Empty: Codable {
    public static let null: Empty? = nil
    
    public init() {}
}

public typealias NoBody = Empty
public typealias NoResponse = Empty
public typealias NoSignature = Empty

public protocol EndpointType: Hashable {
    static var name: String { get }
    static var batchRequestVariant: Network.BatchRequest.Child.Variant { get }
    static var excludedSubRequestHeaders: [HTTPHeader] { get }
    
    var path: String { get }
}

public extension EndpointType {
    static var batchRequestVariant: Network.BatchRequest.Child.Variant { .unsupported }
    static var excludedSubRequestHeaders: [HTTPHeader] { [] }
}

// MARK: - Request

public struct Request<T: Encodable, Endpoint: EndpointType> {
    public let method: HTTPMethod
    public let endpoint: Endpoint
    public let destination: Network.Destination
    public let headers: [HTTPHeader: String]
    
    /// This is the body value sent during the request
    ///
    /// **Warning:** The `bodyData` value should be used to when making the actual request instead of this as there
    /// is custom handling for certain data types
    public let body: T?
    
    // MARK: - Initialization

    public init(
        method: HTTPMethod = .get,
        endpoint: Endpoint,
        destination: Network.Destination,
        headers: [HTTPHeader: String] = [:],
        body: T? = nil
    ) {
        self.method = method
        self.endpoint = endpoint
        self.destination = destination
        self.headers = headers
        self.body = body
    }
    
    // MARK: - Internal Methods
    
    internal func bodyData(using dependencies: Dependencies) throws -> Data? {
        // Note: Need to differentiate between JSON, b64 string and bytes body values to ensure they are
        // encoded correctly so the server knows how to handle them
        switch body {
            case let bodyString as String:
                // The only acceptable string body is a base64 encoded one
                guard let encodedData: Data = Data(base64Encoded: bodyString) else {
                    throw NetworkError.parsingFailed
                }
                
                return encodedData
                
            case let bodyBytes as [UInt8]:
                return Data(bodyBytes)
            
            case let bodyDirectData as Data:
                return bodyDirectData
                
            case let bodyDirectData as Data:
                return bodyDirectData
                
            default:
                // Having no body is fine so just return nil
                guard let body: T = body else { return nil }

                return try JSONEncoder(using: dependencies).encode(body)
        }
    }
}

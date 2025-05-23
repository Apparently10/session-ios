// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVFoundation
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let thumbnailService: SingletonConfig<ThumbnailService> = Dependencies.create(
        identifier: "thumbnailService",
        createInstance: { dependencies in ThumbnailService(using: dependencies) }
    )
}

// MARK: - ThumbnailService

public class ThumbnailService {
    public typealias SuccessBlock = (LoadedThumbnail) -> Void
    public typealias FailureBlock = (Error) -> Void

    private let dependencies: Dependencies
    private let serialQueue = DispatchQueue(label: "ThumbnailService")

    // This property should only be accessed on the serialQueue.
    //
    // We want to process requests in _reverse_ order in which they
    // arrive so that we prioritize the most recent view state.
    private var requestStack = [Request]()
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Functions

    private func canThumbnailAttachment(attachment: Attachment) -> Bool {
        return attachment.isImage || attachment.isAnimated || attachment.isVideo
    }

    public func ensureThumbnail(
        for attachment: Attachment,
        dimensions: UInt,
        success: @escaping SuccessBlock,
        failure: @escaping FailureBlock
    ) {
        serialQueue.async {
            self.requestStack.append(
                Request(
                    attachment: attachment,
                    dimensions: dimensions,
                    success: success,
                    failure: failure
                )
            )

            self.processNextRequestSync()
        }
    }

    private func processNextRequestAsync() {
        serialQueue.async {
            self.processNextRequestSync()
        }
    }

    // This should only be called on the serialQueue.
    private func processNextRequestSync() {
        guard let thumbnailRequest = requestStack.popLast() else { return }

        do {
            let loadedThumbnail = try process(thumbnailRequest: thumbnailRequest)
            DispatchQueue.global().async {
                thumbnailRequest.success(loadedThumbnail)
            }
        }
        catch {
            DispatchQueue.global().async {
                thumbnailRequest.failure(error)
            }
        }
    }

    // This should only be called on the serialQueue.
    //
    // It should be safe to assume that an attachment will never end up with two thumbnails of
    // the same size since:
    //
    // * Thumbnails are only added by this method.
    // * This method checks for an existing thumbnail using the same connection.
    // * This method is performed on the serial queue.
    private func process(thumbnailRequest: Request) throws -> LoadedThumbnail {
        let attachment = thumbnailRequest.attachment
        
        guard canThumbnailAttachment(attachment: attachment) else {
            throw ThumbnailError.failure(description: "Cannot thumbnail attachment.")
        }
        
        let thumbnailPath = attachment.thumbnailPath(for: thumbnailRequest.dimensions)
        
        if dependencies[singleton: .fileManager].fileExists(atPath: thumbnailPath) {
            return LoadedThumbnail(filePath: thumbnailPath)
        }

        let thumbnailDirPath = (thumbnailPath as NSString).deletingLastPathComponent
        
        guard case .success = Result(try dependencies[singleton: .fileManager].ensureDirectoryExists(at: thumbnailDirPath)) else {
            throw ThumbnailError.failure(description: "Could not create attachment's thumbnail directory.")
        }
        guard let originalFilePath = attachment.originalFilePath(using: dependencies) else {
            throw ThumbnailError.failure(description: "Missing original file path.")
        }
        
        let maxDimension = CGFloat(thumbnailRequest.dimensions)
        let thumbnailImage: UIImage
        
        if attachment.isImage || attachment.isAnimated {
            thumbnailImage = try MediaUtils.thumbnail(forImageAtPath: originalFilePath, maxDimension: maxDimension, type: attachment.contentType, using: dependencies)
        }
        else if attachment.isVideo {
            thumbnailImage = try MediaUtils.thumbnail(forVideoAtPath: originalFilePath, maxDimension: maxDimension, using: dependencies)
        }
        else {
            throw ThumbnailError.assertionFailure(description: "Invalid attachment type.")
        }
        
        guard let thumbnailData = thumbnailImage.jpegData(compressionQuality: 0.85) else {
            throw ThumbnailError.failure(description: "Could not convert thumbnail to JPEG.")
        }
        
        do {
            try thumbnailData.write(to: URL(fileURLWithPath: thumbnailPath, isDirectory: false), options: .atomic)
        }
        catch let error as NSError {
            throw ThumbnailError.externalError(description: "File write failed: \(thumbnailPath), \(error)", underlyingError: error)
        }
        
        try? dependencies[singleton: .fileManager].protectFileOrFolder(at: thumbnailPath)
        
        return LoadedThumbnail(image: thumbnailImage, data: thumbnailData)
    }
}

public extension ThumbnailService {
    enum ThumbnailError: Error {
        case failure(description: String)
        case assertionFailure(description: String)
        case externalError(description: String, underlyingError: Error)
    }
    
    struct LoadedThumbnail {
        public typealias ImageSourceBlock = () -> UIImage?
        public typealias DataSourceBlock = () throws -> Data

        public let imageSourceBlock: ImageSourceBlock
        public let dataSourceBlock: DataSourceBlock

        public init(filePath: String) {
            self.imageSourceBlock = {
                return UIImage(contentsOfFile: filePath)
            }
            self.dataSourceBlock = {
                return try Data(contentsOf: URL(fileURLWithPath: filePath))
            }
        }

        public init(image: UIImage, data: Data) {
            self.imageSourceBlock = { image }
            self.dataSourceBlock = { data }
        }
        
        public func image() -> UIImage? {
            return imageSourceBlock()
        }

        public func data() throws -> Data {
            return try dataSourceBlock()
        }
    }
    
    private struct Request {
        public typealias SuccessBlock = (LoadedThumbnail) -> Void
        public typealias FailureBlock = (Error) -> Void

        let attachment: Attachment
        let dimensions: UInt
        let success: SuccessBlock
        let failure: FailureBlock
    }
}

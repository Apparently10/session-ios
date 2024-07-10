// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Cache

public extension Cache {
    static let ip2Country: CacheConfig<IP2CountryCacheType, IP2CountryImmutableCacheType> = Dependencies.create(
        identifier: "ip2Country",
        createInstance: { dependencies in IP2Country(using: dependencies) },
        mutableInstance: { $0 },
        immutableInstance: { $0 }
    )
}

// MARK: - IP2Country

fileprivate class IP2Country: IP2CountryCacheType {
    private var countryNamesCache: [String: String] = [:]
    private var cacheLoadedCallbacks: [UUID: () -> ()] = [:]
    private var pathsChangedCallbackId: UUID? = nil
    public var hasFinishedLoading: Bool = false
    
    // MARK: - Tables
    
    /// This table has two columns: the "network" column and the "registered_country_geoname_id" column. The network column contains
    /// the **lower** bound of an IP range and the "registered_country_geoname_id" column contains the ID of the country corresponding
    /// to that range. We look up an IP by finding the first index in the network column where the value is greater than the IP we're looking
    /// up (converted to an integer). The IP we're looking up must then be in the range **before** that range.
    private lazy var ipv4Table: [String: [Int]] = {
        let url = Bundle.main.url(
            forResource: "GeoLite2-Country-Blocks-IPv4",        // stringlint:disable
            withExtension: nil
        )!
        let data = try! Data(contentsOf: url)
        return try! NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as! [String: [Int]]
    }()
    
    private lazy var countryNamesTable: [String: [String]] = {
        let url = Bundle.main.url(
            forResource: "GeoLite2-Country-Locations-English",  // stringlint:disable
            withExtension: nil
        )!
        let data = try! Data(contentsOf: url)
        return try! NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data) as! [String: [String]]
    }()
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        /// Start by loading the two tables into memory on a background thread
        DispatchQueue.global(qos: .utility).async { [weak self] in
            _ = self?.ipv4Table
            _ = self?.countryNamesTable
            Log.info("[IP2Country] Loaded IP country cache.")
            
            /// Then register for path change callbacks which will be used to update the country name cache
            self?.pathsChangedCallbackId = LibSession.onPathsChanged(callback: { paths, _ in
                /// When a path change occurs we dispatch to the background again to prevent blocking any other path chagne listeners and
                /// mutate the cache via dependencies so it blocks other access
                DispatchQueue.global(qos: .utility).async { [weak self, dependencies] in
                    dependencies.mutate(cache: .ip2Country) { _ in
                        self?.populateCacheIfNeeded(paths: paths)
                    }
                }
            })
        }
    }

    private func populateCacheIfNeeded(paths: [[LibSession.Snode]]) {
        guard !paths.isEmpty else { return }
        
        paths.forEach { path in
            path.forEach { snode in
                guard countryNamesCache[snode.ip] == nil || countryNamesCache[snode.ip] == "Unknown Country" else { return }
                
                guard
                    let ipAsInt: Int = IPv4.toInt(snode.ip),
                    let ipv4TableIndex: Int = ipv4Table["network"]?                                     // stringlint:disable
                        .firstIndex(where: { $0 > ipAsInt })
                        .map({ $0 - 1 }),
                    let countryID: Int = ipv4Table["registered_country_geoname_id"]?[ipv4TableIndex],   // stringlint:disable
                    let countryNamesTableIndex = countryNamesTable["geoname_id"]?                       // stringlint:disable
                        .firstIndex(of: String(countryID)),
                    let result: String = countryNamesTable["country_name"]?[countryNamesTableIndex]     // stringlint:disable
                else {
                    countryNamesCache[snode.ip] = "Unknown Country" // Relies on the array being sorted
                    return
                }
                
                countryNamesCache[snode.ip] = result
            }
        }
        
        self.hasFinishedLoading = true
        Log.info("[IP2Country] Update onion request path countries.")
    }
    
    // MARK: - Functions
    
    public func onCacheLoaded(callback: @escaping () -> ()) -> UUID {
        let id: UUID = UUID()
        cacheLoadedCallbacks[id] = callback
        return id
    }
    
    public func removeCacheLoadedCallback(id: UUID?) {
        guard let id: UUID = id else { return }
        
        cacheLoadedCallbacks.removeValue(forKey: id)
    }
    
    public func country(for ip: String) -> String {
        let fallback: String = "Resolving..."
        
        guard hasFinishedLoading else { return fallback }
        
        return (countryNamesCache[ip] ?? fallback)
    }
}

// MARK: - IP2CountryCacheType

/// This is a read-only version of the Cache designed to avoid unintentionally mutating the instance in a non-thread-safe way
public protocol IP2CountryImmutableCacheType: ImmutableCacheType {
    var hasFinishedLoading: Bool { get }
    
    func country(for ip: String) -> String
}

public protocol IP2CountryCacheType: IP2CountryImmutableCacheType, MutableCacheType {
    var hasFinishedLoading: Bool { get }
    
    func onCacheLoaded(callback: @escaping () -> ()) -> UUID
    func removeCacheLoadedCallback(id: UUID?)
    func country(for ip: String) -> String
}

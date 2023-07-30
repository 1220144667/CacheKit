//
//  CacheManager.swift
//  CacheKit
//
//  Created by hp on 2023/7/27.
//

import Foundation

public class CacheManager {
    
    public static let shared = CacheManager()
    
    private var cache: Cache?
        
    struct Constant {
        static let memoryCostLimit: UInt = 200 * 1024 * 1024
        static let diskCostLimit: UInt = 500 * 1024 * 1024
    }
    
    private init() {
        let cache = Cache.init()
        cache?.memoryCache.costLimit = Constant.memoryCostLimit
        cache?.diskCache.costLimit = Constant.diskCostLimit
        self.cache = cache
    }
}

extension CacheManager: Cachable, CacheSize {
    
    public var totalCost: UInt {
        return self.cache?.diskCache.totalCost ?? 0
    }
    
    public var totalCount: Int {
        return self.cache?.diskCache.totalCount ?? 0
    }
    
    public func set<T>(object: T, forKey key: String, cost: UInt = 0) where T : Decodable, T : Encodable {
        self.cache?.set(object: object, forKey: key, cost: cost)
    }
    
    public func set<T>(object: T, forKey key: String, cost: UInt = 0, completion: ((String) -> Void)?) where T : Decodable, T : Encodable {
        self.cache?.set(object: object, forKey: key, cost: cost, completion: completion)
    }
    
    public func object<T>(forKey key: String, type: T.Type) -> T? where T : Decodable, T : Encodable {
        return self.cache?.object(forKey: key, type: type)
    }
    
    public func object<T>(forKey key: String, type: T.Type, completion: ((String, T?) -> Void)?) where T : Decodable, T : Encodable {
        self.cache?.object(forKey: key, type: type, completion: completion)
    }
    
    public func containsObject(forKey key: String) -> Bool {
        guard let cache = self.cache else { return false }
        return cache.containsObject(forKey: key)
    }
    
    public func containsObject(forKey key: String, completion: ((String, Bool) -> Void)?) {
        self.cache?.containsObject(forKey: key, completion: completion)
    }
    
    public func removeAll() {
        self.cache?.removeAll()
    }
    
    public func removeAll(completion: (() -> Void)?) {
        self.cache?.removeAll(completion: completion)
    }
    
    public func removeObject(forKey key: String) {
        self.cache?.removeObject(forKey: key)
    }
    
    public func removeObject(forKey key: String, completion: (() -> Void)?) {
        self.cache?.removeObject(forKey: key, completion: completion)
    }
}

extension CacheManager {
    class subscript<T: Codable>(_ key: String, _ type: T.Type) -> T? {
        set {
            CacheManager.shared.set(object: newValue, forKey: key)
        }
        get {
            CacheManager.shared.object(forKey: key, type: type)
        }
    }
}

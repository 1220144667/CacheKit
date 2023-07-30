//
//  CacheExtension.swift
//  CacheKit
//
//  Created by hp on 2023/7/27.
//

import Foundation

protocol CacheExtension where Self: Codable {
    static func cachedObject(forKey key: String) -> Self?
    func cache(forKey key: String) -> Void
}

extension CacheExtension {
    
    static func cachedObject(forKey key: String) -> Self? {
        CacheManager[key, Self.self]
    }
    
    func cache(forKey key: String) -> Void {
        CacheManager[key, Self.self] = self
    }
}

extension Int: CacheExtension {}

extension Int8: CacheExtension {}

extension Int16: CacheExtension {}

extension Int32: CacheExtension {}

extension Int64: CacheExtension {}

extension UInt: CacheExtension {}

extension UInt8: CacheExtension {}

extension UInt16: CacheExtension {}

extension UInt32: CacheExtension {}

extension UInt64: CacheExtension {}

extension Float: CacheExtension {}

@available(iOS 14.0, *)
extension Float16: CacheExtension {}

extension Float64: CacheExtension {}

extension Bool: CacheExtension {}

extension String: CacheExtension {}



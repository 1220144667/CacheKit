//
//  Cache.swift
//  CacheKit
//
//  Created by hp on 2023/7/27.
//

import Foundation
import SQLite3
import CommonCrypto
import UIKit

protocol MemoryCachable {
    
    func set<T: Codable>(object: T, forKey key: String, cost: UInt)
    
    func object<T: Codable>(forKey key: String, type: T.Type) -> T?
    
    func containsObject(forKey key: String) -> Bool
    
    func removeObject(forKey key: String)
    
    func removeAll()
}

protocol Cachable: MemoryCachable {
        
    func set<T: Codable>(object: T, forKey key: String, cost: UInt, completion: ((_ key: String) -> Void)?)
    
    func object<T: Codable>(forKey key: String, type: T.Type, completion: ((_ key: String, _ object: T?) -> Void)?)
    
    func containsObject(forKey key: String, completion: ((_ key: String, _ contain: Bool) -> Void)?)
    
    func removeObject(forKey key: String, completion: (() -> Void)?)
    
    func removeAll(completion: (() -> Void)?)
}

protocol CacheSize {
    var totalCost: UInt {
        get
    }
    var totalCount: Int {
        get
    }
}

protocol CacheLock {
    func lock()
    func unlock()
}

protocol Trimable {
    func trimCount()
    func trimCost()
}

enum CacheType: String {
    case hybrid
    case memory
    case disk
}

class Cache {
    
    let memoryCache: MemoryCache
    let diskCache: DiskCache
        
    init?(path filePath: String = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0], inlineThreshold: UInt = 20 * 1024) {
        self.memoryCache = MemoryCache()
        guard let diskCache = DiskCache.init(path: filePath, inlineThreshold: inlineThreshold) else { return nil }
        self.diskCache = diskCache
    }
}

extension Cache: Cachable {

    func set<T>(object: T, forKey key: String, cost: UInt = 0) where T : Decodable, T : Encodable {
        self.memoryCache.set(object: object, forKey: key, cost: cost)
        self.diskCache.set(object: object, forKey: key, cost: cost)
    }
    
    func set<T>(object: T, forKey key: String, cost: UInt = 0, completion: ((String) -> Void)?) where T : Decodable, T : Encodable {
        self.memoryCache.set(object: object, forKey: key, cost: cost)
        self.diskCache.set(object: object, forKey: key, cost: cost, completion: completion)
    }
    
    func object<T>(forKey key: String, type: T.Type) -> T? where T : Decodable, T : Encodable {
        var currentObject: T?
        if let object = self.memoryCache.object(forKey: key, type: type)  {
            currentObject = object
        } else if let object = self.diskCache.object(forKey: key, type: type) {
            self.memoryCache.set(object: object, forKey: key)
            currentObject = object
        }
        return currentObject
    }
    
    func object<T>(forKey key: String, type: T.Type, completion: ((String, T?) -> Void)?) where T : Decodable, T : Encodable {
        var currentObject: T?
        if let object = self.memoryCache.object(forKey: key, type: type)  {
            currentObject = object
            completion?(key, currentObject)
        } else {
            self.diskCache.object(forKey: key, type: type) { key, object in
                if let object = object {
                    self.memoryCache.set(object: object, forKey: key)
                }
                completion?(key, currentObject)
            }
        }
    }
    
    func containsObject(forKey key: String) -> Bool {
        return self.memoryCache.containsObject(forKey: key) || self.diskCache.containsObject(forKey: key)
    }
    
    func containsObject(forKey key: String, completion: ((String, Bool) -> Void)?) {
        if self.memoryCache.containsObject(forKey: key) {
            completion?(key, true)
        } else {
            self.diskCache.containsObject(forKey: key, completion: completion)
        }
    }
    
    func removeAll() {
        self.memoryCache.removeAll()
        self.diskCache.removeAll()
    }
    
    func removeAll(completion: (() -> Void)?) {
        self.memoryCache.removeAll()
        self.diskCache.removeAll(completion: completion)
    }
    
    func removeObject(forKey key: String) {
        self.memoryCache.removeObject(forKey: key)
        self.diskCache.removeObject(forKey: key)
    }
    
    func removeObject(forKey key: String, completion: (() -> Void)?) {
        self.memoryCache.removeObject(forKey: key)
        self.diskCache.removeObject(forKey: key, completion: completion)
    }
}

class MemoryCache {
    
    var costLimit: UInt = 0
    var countLimit: UInt = 0
    
    var autoRemoveAllObjectWhenMemoryWarning = true
    var autoRemoveAllObjectWhenEnterBackground = true
    
    private let semaphoreSignal = DispatchSemaphore(value: 1)
        
    fileprivate lazy var linkedList = LinkedList()
    
    init() {
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(didReceiveMemoryWarningNotification),
                                               name: UIApplication.didReceiveMemoryWarningNotification,
                                               object: nil)
        
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(didEnterBackgroundNotification),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self,
                                                  name: UIApplication.didReceiveMemoryWarningNotification,
                                                  object: nil)
        NotificationCenter.default.removeObserver(self,
                                                  name: UIApplication.didEnterBackgroundNotification,
                                                  object: nil)
    }
    
}

extension MemoryCache {
    
    fileprivate class LinkedList {
        
        class Node: Equatable {
            static func == (lhs: MemoryCache.LinkedList.Node, rhs: MemoryCache.LinkedList.Node) -> Bool {
                return lhs.key == rhs.key
            }
            
            weak var preNode: Node?
            weak var nextNode: Node?
            
            var key: String
            var cost: UInt
            var object: Codable
            
            init(key: String, object: Codable, cost: UInt) {
                self.key = key
                self.object = object
                self.cost = cost
            }
        }
        
        private var headNode: Node?
        private var tailNode: Node?
        
        private(set) var totalCost: UInt = 0
        private(set) var totalCount: Int = 0
        
        private(set) var nodeDic = [String : Node]()
                
        func inserToHead(_ node: Node) {
            nodeDic[node.key] = node
            self.totalCost += node.cost
            self.totalCount += 1
            if let headNode = headNode {
                node.nextNode = headNode
                headNode.preNode = node
                self.headNode = node
            } else {
                headNode = node
                tailNode = headNode
            }
        }
        
        func removeTail() {
            guard let tail = tailNode else { return }
            let preNode = tail.preNode
            preNode?.nextNode = nil
            self.tailNode = preNode
            
            nodeDic.removeValue(forKey: tail.key)
            self.totalCost -= tail.cost
            self.totalCount -= 1
        }
        
        func moveToHead(_ node: Node) {
            if node == headNode {
                return
            }
            if node == tailNode {
                let preNode = node.preNode
                preNode?.nextNode = nil
                self.tailNode = preNode
                
                node.nextNode = headNode
                self.headNode?.preNode = node
                self.headNode = node
            } else {
                let preNode = node.preNode
                let nextNode = node.nextNode
                preNode?.nextNode = nextNode
                nextNode?.preNode = preNode
                
                node.nextNode = self.headNode
                self.headNode?.preNode = node
                self.headNode = node
            }
        }
        
        func remove(_ node: Node) {
            guard let _ = headNode else { return }
            if node == tailNode {
                removeTail()
            } else if node == headNode {
                let nextNode = node.nextNode;
                node.nextNode = nil
                nextNode?.preNode = nil
                
                self.headNode = nextNode
                
                self.nodeDic.removeValue(forKey: node.key)
                self.totalCost -= node.cost
                self.totalCount -= 1
            } else if let preNode = node.preNode, let nextNode = node.nextNode {
                preNode.nextNode = nextNode
                nextNode.preNode = preNode
                node.preNode = nil
                node.nextNode = nil
                
                self.nodeDic.removeValue(forKey: node.key)
                self.totalCost -= node.cost
                self.totalCount -= 1
            }
        }
        
        func removeAll() {
            totalCost = 0
            totalCount = 0
            self.nodeDic.removeAll()
            self.headNode = nil
            self.tailNode = nil
        }
        
        func contains(_ node: Node) -> Bool {
            return contains(node.key)
        }
        
        func contains(_ key: String) -> Bool {
            return self.nodeDic.contains{$0.key == key}
        }
        
        func object(_ key: String) -> Node? {
            return self.nodeDic[key]
        }
    }
}

extension MemoryCache: CacheLock {
    
    func lock() {
        self.semaphoreSignal.wait()
    }
    
    func unlock() {
        self.semaphoreSignal.signal()
    }
    
    @objc fileprivate func didReceiveMemoryWarningNotification() {
        if self.autoRemoveAllObjectWhenMemoryWarning {
            removeAll()
        }
    }
       
    @objc fileprivate func didEnterBackgroundNotification() {
        if self.autoRemoveAllObjectWhenEnterBackground {
            removeAll()
        }
    }
}

extension MemoryCache: MemoryCachable, Trimable, CacheSize {
    
    func set<T>(object: T, forKey key: String, cost: UInt = 0) where T : Decodable, T : Encodable {
        self.lock()
        if let node = linkedList.object(key) {
            node.object = object
            node.cost = cost
            linkedList.moveToHead(node)
        } else {
            let node = LinkedList.Node.init(key: key, object: object, cost: cost)
            linkedList.inserToHead(node)
        }
        trimCount()
        trimCost()
        self.unlock()
    }
    
    func object<T>(forKey key: String, type: T.Type) -> T? where T : Decodable, T : Encodable {
        self.lock()
        let node = linkedList.object(key)
        self.unlock()
        let object = node?.object as? T
        return object
    }
    
    func containsObject(forKey key: String) -> Bool {
        self.lock()
        let isExist = linkedList.contains(key)
        self.unlock()
        if isExist == false {
            print(key)
        }
        return isExist
    }
    
    func removeAll() {
        self.lock()
        linkedList.removeAll()
        self.unlock()
    }
    
    func removeObject(forKey key: String) {
        self.lock()
        if let node = linkedList.object(key) {
            linkedList.remove(node)
        }
        self.unlock()
    }
    
    func trimCount() {
        if self.countLimit > 0 {
            if self.linkedList.totalCount > self.costLimit {
                linkedList.removeTail()
            }
        }
    }
    
    func trimCost() {
        if self.costLimit > 0 {
            if self.linkedList.totalCost > self.costLimit {
                linkedList.removeTail()
            }
        }
    }
    
    var totalCost: UInt {
        self.lock()
        let totalCost = self.linkedList.totalCost
        self.unlock()
        return totalCost
    }
    
    var totalCount: Int {
        self.lock()
        let totalCount = self.linkedList.totalCount
        self.unlock()
        return totalCount
    }
}

class DiskCache {
    
    var costLimit: UInt = 0
    
    var countLimit: UInt = 0
    
    var maxCachePeriodInSecond: TimeInterval = 7 * 24 * 60 * 60
    
    fileprivate var semaphoreSignal = DispatchSemaphore.init(value: 1)
    
    let inlineThreshold: UInt
    
    var autoInterval: TimeInterval = 120
        
    fileprivate let diskStorage: DiskStorage
    
    fileprivate lazy var queue: DispatchQueue = {
        let label = Bundle.main.bundleIdentifier ?? "com.iOS" + "." + CacheType.disk.rawValue
        let queue = DispatchQueue.init(label: label, attributes: DispatchQueue.Attributes.concurrent)
        return queue
    }()
    
    init?(path filePath: String = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0], inlineThreshold: UInt = 20 * 1024) {
        self.inlineThreshold = inlineThreshold
        guard let diskStorage = DiskStorage.init(filePath: filePath) else { return nil }
        self.diskStorage = diskStorage
        recursively()
    }
}

extension DiskCache {
    
    fileprivate class DiskStorage {
        
        class DiskStorageItem {
            var key: String?
            var data: Data?
            var filename: String?
            var size: Int32 = 0
            var accessTime: Int32 = 0
        }
        
        struct Constant {
            static let uniqueIdentifier = (Bundle.main.bundleIdentifier ?? "com.iOS")
            
            static let databaseFileName = "diskcache.sqlite"
            
            static let databaseWalFileName = "diskcache.sqlite-wal"
            
            static let databaseShmFileName = "diskcache.sqlite-shm"
            
            static let folderName = "diskcache" + "." + uniqueIdentifier
        }
    
        var filePath: String
        
        var folderName: String
        
        var databasePath: String
        
        var database: OpaquePointer?
        
        var databaseStmtCacheDic: Dictionary = [String : OpaquePointer]()
        
        init?(filePath: String) {
            self.folderName = (filePath as NSString).appendingPathComponent(Constant.folderName)
            self.databasePath = (self.folderName as NSString).appendingPathComponent(Constant.databaseFileName)
            self.filePath = (self.folderName as NSString).appendingPathComponent(Constant.folderName)
            
            guard self.createDirectory() == true else {
                return nil
            }
            
            guard self.openDatabase() == true else {
                return nil
            }
            
            guard self.createDatabaseTable() == true else {
                return nil
            }
        }
        
        deinit {
            closeDatabase()
        }
        
        @discardableResult
        func closeDatabase() -> Bool {
            guard let database = self.database else { return true }
            var retry = false
            var stmtFinalized = false
            repeat {
                retry = false
                let result = sqlite3_close(database)
                if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                    if stmtFinalized == false {
                        stmtFinalized = true
                        while let stmt = sqlite3_next_stmt(database, nil) {
                            sqlite3_finalize(stmt)
                            retry = true
                        }
                    }
                } else if result != SQLITE_OK {
                    print("sqlite close failed \(String(describing: String(validatingUTF8: sqlite3_errmsg(database))))")
                }
            } while(retry == true)
            self.database = nil
            return true
        }
        
        @discardableResult
        func createDirectory() -> Bool {
            do {
                try FileManager.default.createDirectory(atPath: self.filePath, withIntermediateDirectories: true)
            } catch {
                print(error)
                return false
            }
            return true
        }
        
        func writeData(_ data: Data, to fileName: String) -> Bool {
            let filePath = (self.filePath as NSString).appendingPathComponent(fileName)
            do {
                try data.write(to: URL.init(fileURLWithPath: filePath))
            } catch {
                print(error)
                return false
            }
            return true
        }
        
        func readData(from fileName: String) -> Data? {
            let filePath = (self.filePath as NSString).appendingPathComponent(fileName)
            let data = FileManager.default.contents(atPath: filePath)
            return data
        }
                
        @discardableResult
        func removeFile(_ fileName: String) -> Bool {
            let filePath = (self.filePath as NSString).appendingPathComponent(fileName)
            do {
                try FileManager.default.removeItem(atPath: filePath)
            } catch {
                print(error)
                return false
            }
            return true
        }
        
        /**
         移除全部文件数据
         */
        func removeAllItem() {
            databaseStmtCacheDic.removeAll(keepingCapacity: true)
            guard closeDatabase() == true else {
                return
            }
            try? FileManager.default.removeItem(atPath: self.databasePath)
            try? FileManager.default.removeItem(atPath: (self.folderName as NSString).appendingPathComponent(Constant.databaseShmFileName))
            try? FileManager.default.removeItem(atPath: (self.folderName as NSString).appendingPathComponent(Constant.databaseWalFileName))

            try? FileManager.default.removeItem(atPath: self.filePath)
            
            guard createDirectory() == true else {
                return
            }
            
            guard openDatabase() == true else {
                return
            }
            
            guard createDatabaseTable() else {
                return
            }
        }
        
        @discardableResult
        func openDatabase() -> Bool {
            let databasePath = self.databasePath
            let result = sqlite3_open(databasePath.cString(using: .utf8), &database)
            guard result == SQLITE_OK else {
                print("sqlite insert error \(String(describing: String(validatingUTF8: sqlite3_errmsg(database))))")
                return false
            }
            return true
        }
        
        @discardableResult
        func createDatabaseTable() -> Bool {
            guard let database = self.database else { return false }
            let sql = "pragma journal_mode = wal; pragma synchronous = normal; create table if not exists detailed (key text primary key,filename text,inline_data blob,size integer,last_access_time integer); create index if not exists last_access_time_idx on detailed(last_access_time);"
            let result = sqlite3_exec(database, sql.cString(using: .utf8), nil, nil, nil)
            guard result == SQLITE_OK else {
                print("sqlite insert error \(String(describing: String(validatingUTF8: sqlite3_errmsg(database))))")
                return false
            }
            return true
        }
        
        @discardableResult
        func writeData(_ data: Data, key: String, fileName: String?) -> Bool {
            if let fileName = fileName {
                guard writeData(data, to: fileName) == true else {
                    return false
                }
                guard writeData(data, key: key, toDatabase: fileName) == true else {
                    removeFile(fileName)
                    return false
                }
                return true
            }
            if let currentFileName = queryFileNameFromDatabase(key: key) {
                removeFile(currentFileName)
            }
            guard writeData(data, key: key, toDatabase: fileName) == true else {
                return false
            }
            return true
        }
        
        func readData(for key: String) -> Data? {
            let storageItem = self.queryStorageItemFromDatabase(for: key)
            updateLastAccessTime(for: key)
            if let fileName = storageItem?.filename {
                storageItem?.data = readData(from: fileName)
            }
            return storageItem?.data
        }
        
        func writeData(_ data: Data, key: String, toDatabase filename: String?) -> Bool {
            let sqlitTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let sql = "insert or replace into detailed" + "(key,filename,inline_data,size,last_access_time)" + "values(?1,?2,?3,?4,?5);"
            guard let stmt = prepareDatabaseStmt(sql) else { return false }
            sqlite3_bind_text(stmt, 1, key.cString(using: .utf8), -1, sqlitTransient)
            if let filename = filename {
                sqlite3_bind_text(stmt, 2, filename, -1, sqlitTransient)
                sqlite3_bind_blob(stmt, 3, nil, 0, sqlitTransient)
            } else {
                sqlite3_bind_text(stmt, 2, nil, -1, sqlitTransient)
                sqlite3_bind_blob(stmt, 3, [UInt8](data), Int32(data.count), sqlitTransient)
            }
            sqlite3_bind_int(stmt, 4, Int32(data.count))
            sqlite3_bind_int(stmt, 5, Int32(Date().timeIntervalSince1970))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                print("sqlite insert error \(String(describing: String(validatingUTF8: sqlite3_errmsg(database))))")
                return false
            }
            return true
        }
        
        func prepareDatabaseStmt(_ sql: String) -> OpaquePointer? {
            guard let database = self.database else { return nil }
            guard sql.isEmpty == false || self.databaseStmtCacheDic.isEmpty == false else {
                return nil
            }
            var stmt: OpaquePointer? = self.databaseStmtCacheDic[sql]
            guard let stmt = stmt else {
                let result = sqlite3_prepare_v2(database, sql.cString(using: .utf8), -1, &stmt, nil)
                guard result == SQLITE_OK else {
                    print("sqlite stmt prepare error \(String(describing: String(validatingUTF8: sqlite3_errmsg(database))))")
                    return nil
                }
                self.databaseStmtCacheDic[sql] = stmt
                return stmt
            }
            sqlite3_reset(stmt)
            return stmt
        }
                
        func queryStorageItemFromDatabase(for key: String) -> DiskStorageItem? {
            guard let database = self.database else { return nil }
            let sql = "select key,filename,inline_data,size,last_access_time from detailed where key=?1;"
            guard let stmt = prepareDatabaseStmt(sql) else { return nil }
            let sqlitTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, key.cString(using: .utf8), -1, sqlitTransient)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                print("sqlite stmt prepare error \(String(describing: String(validatingUTF8: sqlite3_errmsg(database))))")
                return nil
            }
            let diskStorageItem = diskStorageItem(from: stmt)
            return diskStorageItem
        }
        
        func queryAllKeysFromDatabase() -> [String]? {
            let sql = "select key from detailed;"
            guard let stmt = prepareDatabaseStmt(sql) else { return nil }
            var keys = [String]()
            repeat{
                let result = sqlite3_step(stmt)
                if result == SQLITE_ROW {
                    let key = String(cString: sqlite3_column_text(stmt, 0))
                    keys.append(key)
                } else if result == SQLITE_DONE {
                    break
                } else {
                    print("sqlite query keys error \(String(describing: String(validatingUTF8: sqlite3_errmsg(database))))")
                    break
                }
            } while(true)
            return keys
        }
        
        func queryFileNameFromDatabase(key: String) -> String? {
            let sql = "select filename from detailed where key = ?1;"
            guard let stmt = prepareDatabaseStmt(sql) else { return nil }
            sqlite3_bind_text(stmt, 1, key.cString(using: .utf8), -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return nil
            }
            guard let filename = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: filename)
        }
        
        func diskStorageItem(from stmt: OpaquePointer) -> DiskStorageItem {
            let diskStorageItem = DiskStorageItem()
            let currentKey = String(cString: sqlite3_column_text(stmt, 0))
            if let name = sqlite3_column_text(stmt, 1) {
                let filename = String(cString: name)
                diskStorageItem.filename = filename
            }
            let size = sqlite3_column_int(stmt, 3)
            if let blob = sqlite3_column_blob(stmt, 2) {
                diskStorageItem.data = Data(bytes: blob, count: Int(size))
            }
            let last_access_time = sqlite3_column_int(stmt, 4)
            diskStorageItem.key = currentKey
            diskStorageItem.size = size
            diskStorageItem.accessTime = last_access_time
            return diskStorageItem
        }
        
        /**
         移除所有过期数据
         @return 移除成功返回true,否则返回false
         */
        func removeAllExpiredData(_ time: TimeInterval) -> Bool{
            let filenames = expiredFilesOfDatabase(time)
            guard let filenames = filenames else {
                return false
            }
            for filename in filenames {
                removeFile(filename)
            }
            if removeExpiredDataFromDatabase(time) == true {
                databaseCheckpoint()
                return true
            }
            return false
        }
        
        /**
         直接把日志数据同步到数据库中
         */
        func databaseCheckpoint(){
            guard let database = self.database else { return }
            sqlite3_wal_checkpoint(database, nil);
        }
        
        /**
         获取过期文件名
         @return 如果没有获取到不为nil的文件名，则返回一个空的数组
         */
        func expiredFilesOfDatabase(_ time:TimeInterval) -> [String]? {
            let sql = "select filename from detailed where last_access_time < ?1 and filename is not null;"
            guard let stmt = prepareDatabaseStmt(sql) else { return nil }
            
            var filenames = [String]()
            sqlite3_bind_int(stmt,1,Int32(time))
            repeat {
                let result = sqlite3_step(stmt)
                if result == SQLITE_ROW {
                    let filename = String(cString: sqlite3_column_text(stmt, 0))
                    filenames.append(filename)
                } else if result == SQLITE_DONE {
                    break
                } else {
                    print("sqlite query expired file error \(String(describing: String(validatingUTF8: sqlite3_errmsg(self.database))))")
                    break
                }
            } while(true)
            return filenames
        }
        
        /**
         移除数据库中过期的数据
         @return 移除成功返回true,否则返回false
         */
        func removeExpiredDataFromDatabase(_ time: TimeInterval) -> Bool {
            let sql = "delete from detailed where last_access_time < ?1;"
            guard let stmt = prepareDatabaseStmt(sql) else { return false }
            sqlite3_bind_int(stmt, 1, Int32(time))
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                print("sqlite remove expired data error \(String(describing: String(validatingUTF8: sqlite3_errmsg(database))))")
                return false
            }
            return true
        }

        
        func sizeExceededValueFromDatabaseStmt(_ stmt: OpaquePointer?) -> DiskStorageItem {
            let diskStorageItem = DiskStorageItem()
            let currentKey = String(cString: sqlite3_column_text(stmt, 0))
            if let name = sqlite3_column_text(stmt, 1) {
                let filename = String(cString: name)
                diskStorageItem.filename = filename
            }
            let size = sqlite3_column_int(stmt, 2)
            diskStorageItem.key = currentKey
            diskStorageItem.size = size
            return diskStorageItem
        }
        
        /**
         删除超过指定大小的值
         */
        func sizeExceededValuesFromDatabase() -> [DiskStorageItem] {
            let sql = "select key,filename,size from detailed order by last_access_time asc limit ?1;"
            let stmt = prepareDatabaseStmt(sql)
            let count = 16
            var items = [DiskStorageItem]()
            sqlite3_bind_int(stmt, 1, Int32(count))
            repeat{
                let result = sqlite3_step(stmt)
                if result == SQLITE_ROW {
                    let item = sizeExceededValueFromDatabaseStmt(stmt)
                    items.append(item)
                } else if result == SQLITE_OK {
                    break
                } else {
                    break
                }
            } while true
            return items
        }
        
        /**
        根据key查询是否存在对应的值
        @param key: value关联的键
        @return 查询成功返回true,否则返回false
         */
        func isExistFromDatabase(forKey key:String) -> Bool {
            let sql = "select count(key) from detailed where key = ?1"
            guard let stmt = prepareDatabaseStmt(sql) else { return false }
            sqlite3_bind_text(stmt, 1, key.cString(using: .utf8), -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return false
            }
            return Int(sqlite3_column_int(stmt, 0)) > 0
        }
        
        /**
         @return 获取数据总大小
         */
        func totalItemSizeFromDatabase() -> Int32 {
            let sql = "select sum(size) from detailed;"
            guard let stmt = prepareDatabaseStmt(sql) else { return -1 }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                return -1
            }
            return sqlite3_column_int(stmt, 0)
        }
        
        /**
         @return 获取数据总个数
         */
        func totalItemCountFromDatabase() -> Int {
            let sql = "select count(*) from detailed;"
            guard let stmt = prepareDatabaseStmt(sql) else { return -1 }
            guard sqlite3_step(stmt) == SQLITE_ROW else{
                return -1
            }
            return Int(sqlite3_column_int(stmt, 0))
        }
        
        /**
         根据key更新最后访问时间
         */
        func updateLastAccessTime(for key: String) {
            let sql = "update detailed set last_access_time=?1 where key=?2;"
            guard let stmt = prepareDatabaseStmt(sql) else { return }
            sqlite3_bind_int(stmt, 1, Int32(Date().timeIntervalSince1970))
            sqlite3_bind_text(stmt, 2, key.cString(using: .utf8), -1, nil)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                print("sqlite update accessTime error \(String(describing: String(validatingUTF8: sqlite3_errmsg(self.database))))")
                return
            }
        }
        
        /**
         移除key指定数据
         @return 成功返回true，否则返回false
         */
        @discardableResult
        func removeStorageItemFromDatabase(for key: String) -> Bool {
            //删除sql语句
            let sql = "delete from detailed where key = ?1";
            guard let stmt = prepareDatabaseStmt(sql) else { return false }
            sqlite3_bind_text(stmt, 1, key.cString(using: .utf8), -1, nil)
            //step执行
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                print("sqlite remove data error \(String(describing: String(validatingUTF8: sqlite3_errmsg(self.database))))")
                return false
            }
            return true
        }
        
        func removeAllStorageItem() -> Bool {
            //删除sql语句
            let sql = "delete from detailed";
            guard let stmt = prepareDatabaseStmt(sql) else { return false }
            //step执行
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                print("sqlite remove data error \(String(describing: String(validatingUTF8: sqlite3_errmsg(self.database))))")
                return false
            }
            return true
        }
    }
}

extension DiskCache {
    
    private func recursively() {
        DispatchQueue.global().asyncAfter(deadline: .now() + autoInterval) { [weak self] in
            guard let self = self else { return }
            self.trimData()
            self.recursively()
        }
    }
    
    private func trimData() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.lock()
            self.trimCost()
            self.trimCount()
            self.removeExpired()
            self.unlock()
        }
    }
    
    /**
     移除过期数据
     @return 移除成功,返回true,否则返回false
     */
    @discardableResult
    private func removeExpired() -> Bool {
        var currentTime = Date().timeIntervalSince1970
        currentTime -= maxCachePeriodInSecond
        let result = diskStorage.removeAllExpiredData(currentTime)
        return result
    }
}

extension DiskCache: CacheLock {
    
    func lock() {
        self.semaphoreSignal.wait()
    }
    
    func unlock() {
        self.semaphoreSignal.signal()
    }
}

extension DiskCache: Cachable, Trimable, CacheSize {
    
    func set<T>(object: T, forKey key: String, cost: UInt = 0) where T : Decodable, T : Encodable {
        var data: Data?
        if object is Data {
            data = object as? Data
        } else {
            data = try? JSONEncoder().encode(object)
            if data == nil {
                data = try? JSONSerialization.data(withJSONObject: object, options: .fragmentsAllowed)
            }
        }
        guard let data = data else {
            assertionFailure("json encode fail \(key)")
            return
        }
        var fileName: String?
        if cost > inlineThreshold {
            fileName = key.sha256
        }
        self.lock()
        diskStorage.writeData(data, key: key, fileName: fileName)
        self.unlock()
    }
    
    func set<T>(object: T, forKey key: String, cost: UInt = 0, completion: ((String) -> Void)?) where T : Decodable, T : Encodable {
        self.queue.async { [weak self] in
            guard let self = self else { completion?(key); return }
            self.set(object: object, forKey: key, cost: cost)
            completion?(key)
        }
    }
        
    func object<T>(forKey key: String, type: T.Type) -> T? where T : Decodable, T : Encodable {
        var object: T?
        
        self.lock()
        let data = diskStorage.readData(for: key)
        self.unlock()
        if let data = data {
            do {
                if type is Data.Type {
                    object = data as? T
                } else {
                    object = try? JSONDecoder().decode(T.self, from: data)
                    if object == nil {
                        object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? T
                    }
                }
                guard let _ = object else {
                    assertionFailure("json decode fail \(key)")
                    return nil
                }
            }
        }
        return object
    }
    
    func object<T>(forKey key: String, type: T.Type, completion: ((String, T?) -> Void)?) where T : Decodable, T : Encodable {
        self.queue.async { [weak self] in
            guard let self = self else { completion?(key, nil); return }
            let object = self.object(forKey: key, type: type)
            completion?(key, object)
        }
    }
    
    func containsObject(forKey key: String) -> Bool {
        self.lock()
        let isExist = diskStorage.isExistFromDatabase(forKey: key)
        self.unlock()
        return isExist
    }
    
    func containsObject(forKey key: String, completion: ((String, Bool) -> Void)?) {
        self.queue.async { [weak self] in
            guard let self = self else { completion?(key, false); return }
            let isExist = self.containsObject(forKey: key)
            completion?(key, isExist)
        }
    }
    
    func removeAll() {
        self.lock()
        diskStorage.removeAllItem()
        self.unlock()
    }
    
    func removeAll(completion: (() -> Void)?) {
        self.queue.async { [weak self] in
            guard let self = self else { completion?(); return }
            self.removeAll()
            completion?()
        }
    }
    
    func removeObject(forKey key: String) {
        self.lock()
        if let fileName = diskStorage.queryFileNameFromDatabase(key: key) {
            diskStorage.removeFile(fileName)
        }
        diskStorage.removeStorageItemFromDatabase(for: key)
        self.unlock()
    }
    
    func removeObject(forKey key: String, completion: (() -> Void)?) {
        self.queue.async { [weak self] in
            guard let self = self else { completion?(); return }
            self.removeObject(forKey: key)
            completion?()
        }
    }
    
    /**
     超过限定张数，需要丢弃一部分内容
     */
    func trimCount(){
        guard self.countLimit > 0 else { return }
        var totalCount = diskStorage.totalItemCountFromDatabase()
        if totalCount <= self.countLimit {
            return
        }
        var finish = false
        repeat {
            let items = diskStorage.sizeExceededValuesFromDatabase()
            for item in items {
                if totalCount > self.countLimit {
                    if let fileName = item.filename, diskStorage.removeFile(fileName) {
                        if let key = item.key {
                            finish = diskStorage.removeStorageItemFromDatabase(for: key)
                        }
                    } else if let key = item.key {
                        finish = diskStorage.removeStorageItemFromDatabase(for: key)
                    }
                    if finish {
                        totalCount -= 1
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
        } while(totalCount > self.countLimit)
        
        if finish {
            diskStorage.databaseCheckpoint()
        }
    }
    
    /**
     超过限定容量,需要丢弃一部分内容
     */
    func trimCost() {
        guard self.costLimit > 0 else { return }
        var totalSize = diskStorage.totalItemSizeFromDatabase()
        if totalSize < self.costLimit {
            return
        }
        var finish = false
        repeat{
            let items = diskStorage.sizeExceededValuesFromDatabase()
            for item in items{
                if totalSize > self.costLimit {
                    if let filename = item.filename{
                        if diskStorage.removeFile(filename) {
                            if let key = item.key {
                                finish = diskStorage.removeStorageItemFromDatabase(for: key)
                            }
                        }
                    } else if let key = item.key {
                        finish = diskStorage.removeStorageItemFromDatabase(for: key)
                    }
                    if finish {
                        totalSize -= item.size
                    } else {
                        break
                    }
                } else {
                    break
                }
            }
        } while (totalSize > self.costLimit)
        
        if finish {
            diskStorage.databaseCheckpoint()
        }
    }
    
    var totalCost: UInt {
        self.lock()
        let totalCost = self.diskStorage.totalItemSizeFromDatabase()
        self.unlock()
        return UInt(totalCost)
    }
    
    var totalCount: Int {
        self.lock()
        let totalCount = self.diskStorage.totalItemCountFromDatabase()
        self.unlock()
        return totalCount
    }
    
}
extension String {
    var sha256: String {
        let utf8 = cString(using: .utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        CC_SHA256(utf8, CC_LONG(utf8!.count - 1), &digest)
        return digest.reduce("") { $0 + String(format:"%02x", $1) }
    }
}

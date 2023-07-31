# CacheKit
CacheKit是一个适用于iOS、令人愉快的缓存框架，一行代码实现缓存。支持存储泛型对象，并且，它是线程安全的！

## Example

/// 写入缓存
/// - Parameters:
///   - object: 对象（支持泛型）
///   - key: 缓存的key
CacheManager.shared.set(object: <#T##Decodable & Encodable#>, forKey: <#T##String#>)

/// 获取缓存内容
/// - Parameters:
///   - key: key
///   - type: 类型
/// - Returns: 返回缓存的实例
CacheManager.shared.object(forKey: <#T##String#>, type: <#T##(Decodable & Encodable).Protocol#>)

/// 删除缓存
/// - Parameter key: key
CacheManager.shared.removeObject(forKey: <#T##String#>)

/// 判断是否有缓存
/// - Parameter key: key
/// - Returns: 结果
CacheManager.shared.containsObject(forKey: <#T##String#>)

## Requirements

## Installation

CacheKit is available through [CocoaPods](https://cocoapods.org). To install
it, simply add the following line to your Podfile:

```ruby
pod 'CacheKit'
```

## Author

洪陪, 1220144667@qq.com, 麻烦给个star、谢谢啦

## License

CacheKit is available under the MIT license. See the LICENSE file for more info.
# Hadoop

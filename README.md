# CacheKit
CacheKit是一个适用于iOS、令人愉快的缓存框架，一行代码实现缓存。支持存储泛型对象，并且，它是线程安全的！

## Example
写入缓存：传入需要缓存的对象（支持泛型），缓存的key\n
CacheManager.shared.set(object: <#T##Decodable & Encodable#>, forKey: <#T##String#>)

获取缓存内容：传入对象、对应类型、返回缓存的实例\n
CacheManager.shared.object(forKey: <#T##String#>, type: <#T##(Decodable & Encodable).Protocol#>)

删除缓存：\n
CacheManager.shared.removeObject(forKey: <#T##String#>)

判断是否已缓存:\n
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

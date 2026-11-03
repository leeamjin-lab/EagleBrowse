# EagleBrowse

EagleBrowse 是一个 iOS 17+ SwiftUI 工程骨架，使用 XcodeGen 生成 Xcode 工程。第一版只读，连接页、网格和大图界面等 UI 留给 Design 阶段，不包含上传、编辑或删除。

## 目录结构

- `Sources/EagleBrowseApp`：SwiftUI App 入口和占位 RootView。
- `Sources/EagleBrowseCore/Connection`：SMB/WebDAV 连接模型、密码 Keychain 封装和远程文件协议。
- `Sources/EagleBrowseCore/Parsing`：Eagle `.library` 根 metadata、素材 metadata 和本地索引模型。
- `Sources/EagleBrowseCore/Cache`：JSON 文件本地索引缓存。
- `Tests/EagleBrowseTests`：解析层单元测试及假 metadata fixture。
- `project.yml`：XcodeGen 工程定义。

## 生成和打开工程

在项目根目录执行：

```sh
~/Projects/.tools/xcodegen/bin/xcodegen generate
open EagleBrowse.xcodeproj
```

如果本机的 XcodeGen 位于其他路径，请替换上面的命令。生成的工程文件 `EagleBrowse.xcodeproj` 不需要手工编辑；修改源码或 `project.yml` 后重新生成即可。

## 验证

```sh
xcodebuild -scheme EagleBrowse \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build
```

SMB 当前只有可编译的接口占位实现，代码中标记了后续接入真实 SMB 客户端的位置；WebDAV 使用 `URLSession`，请求层提供超时、重试次数和重试回调钩子。密码通过 Keychain 读写，不写入连接模型或 JSON 缓存。

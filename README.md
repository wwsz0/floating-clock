# 悬浮时钟 · Floating Clock

一个使用 Swift / AppKit 编写的 macOS 原生悬浮时钟，可拖动到屏幕任意位置，并展示局域网服务提供的账号额度。

## 功能

- 悬浮置顶、多桌面显示，自动记住位置。
- 锁定位置与鼠标穿透，可从菜单栏解锁。
- 24 小时制，显示系统本地时间加 16 小时，日期与星期同步顺延。
- 显示或隐藏秒、日期，支持三种字号。
- 本机与远端账号额度按账户分卡片显示，包含剩余比例、进度条及重置时间。
- 整体展开或收起额度，底部按钮手动查询，每 60 秒自动刷新。
- 网络失败时保留并标记上次数据。
- 底部齿轮可调整背景颜色与 0%–100% 透明度，即时生效并自动保存；默认透明度为 85%。

## 编译与运行

需要 macOS、Apple Command Line Tools 中的 `swiftc`，无需第三方依赖。

```sh
xcode-select --install  # 未安装 Command Line Tools 时运行
./build.command
open '悬浮时钟.app'
```

编译脚本包含本机 Command Line Tools 的重复 SwiftBridging 模块映射兼容配置；使用不同工具链时，可调整 `build.command` 中对应的路径与编译参数。

```sh
# 运行内置自检，不启动界面或查询网络
'悬浮时钟.app/Contents/MacOS/FloatingClock' --self-test

# 启动时直接打开外观设置
open '悬浮时钟.app' --args --show-settings
```

更多操作见 [使用说明](使用说明.txt)。锁定鼠标穿透后，窗口按钮不会响应点击；可通过菜单栏进入设置或解锁。

## 额度服务

`Quota.swift` 中的 `QuotaLoader.baseURL` 配置额度服务地址，默认使用本机回环地址 `http://127.0.0.1:8318`，只读访问：

- `GET /local/quota.json`
- `GET /remote/quota.json`

其他电脑需根据实际环境修改地址，并自行提供兼容服务。额度后端与网络转发服务不包含在本仓库中；服务不可达时，时钟仍可使用。重置时间与更新时间和时钟一样，按系统本地时间加 16 小时显示。

## 文件

- `main.swift`：时钟、悬浮窗口、菜单和应用入口。
- `Quota.swift`：额度查询、数据解析、账号卡片和进度条。
- `Appearance.swift`：透明度与颜色设置、偏好保存。
- `Info.plist`：应用元数据。
- `build.command`、`empty.modulemap`：本地构建与工具链兼容配置。

## 隐私

应用只向配置的额度服务发起查询，不读取 API 密钥，不操作 VPN，不需要辅助功能或屏幕录制权限。颜色、透明度、位置等偏好保存在本机。仓库不包含账号凭据、真实额度响应或编译生成的应用包。

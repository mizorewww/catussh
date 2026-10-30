# 远程接入：UU 远程、VNC / macOS 屏幕共享、文件夹

状态：实现中，按下面的验收目标逐项验证（2026-10-30）

## 1. 调查结论

### 1.1 ⌘Q 无法退出

- Debug 构建复现：开着菜单栏猫和弹出框，用 Apple Event 退出 → 正常退出；再开一个终端，
  退出 → 出现「Quit catussh?」确认框（sheet），终止路径本身工作。
- 正在运行的正式版：主窗口不在屏幕上（onscreen=0），另有一个 500×500 的隐藏窗口。
  `windowStatusWatcher` 每秒执行一次：没有 `isVisible` 的普通窗口、又有菜单栏猫时，
  把 App 切成 accessory（无 Dock 图标、无菜单栏）。**最小化的窗口 `isVisible == false`**，
  所以最小化主窗口就会让 App 变成 accessory；这时 ⌘Q 没有菜单可走，Dock 里也找不回窗口。
  这和「与托盘相关」的观察一致。
- 快捷键拦截里，只要任意普通窗口挂着 sheet，⌘Q 就被**静默丢弃**；`quitAsked` 只有在
  确认框回调后才清零，确认框没出现或丢失时，后面的每一次退出都被吞掉。

处理：
1. accessory 只在「没有任何主窗口（含最小化）」时切换。
2. ⌘Q 不再因为 sheet 丢弃；`quitAsked` 为真但确认框已不在屏幕上时，重新询问。
3. 退出路径打 `os_log`（subsystem `me.mizorewww.rayon`, category `quit`），之后可以用
   `log show` 定位。

### 1.2 UU 远程「完全没法用」

- 实测接口（`UU_LIVE=1 swift test --filter UURemoteLiveTests`）：
  - `/api/v1/qrcode/gen/login` 不带设备身份 → HTTP 422，缺 `X-Param-client-id`、
    `X-Param-device-id`。我们的客户端把 422 一律当成 `tokenExpired`，界面上只显示
    「token 过期」，看不出原因。
  - 先 `/api/v1/device/windows/init` 注册设备拿到 `device_id`，再请求二维码 → 200，
    能拿到 `qrcode_jump_url`。
  - `ensureLocalDeviceIdentity` 只在已有 token 时注册设备，所以**首次登录永远失败**。
- 签名：内置密钥属于 PC 客户端（`X-Param-PLAT=1`），平台 4 的签名会被拒。
- 不从本机 UURemote.app 导入登录：按之前的决定（不解密、不反汇编官方 App 的数据），
  只做我们自己的二维码 / 短信 / token 登录。
- 归类不对：UU 设备现在挂在「Remote Desktop」页的一张卡片里，像一个附属功能。但 UU 远程
  本身就能提供桌面、观看模式、终端、文件传输、端口映射，应该和 SSH 服务器平级。

官方 App 截图（设备页）：在线状态胶囊 + 设备名 + 菜单；大幅壁纸卡片，中间是「进入桌面 →」；
底部一排：文件传输 · 观看模式 · 终端 · 端口映射 · 更多。

### 1.3 macOS 屏幕共享

- 局域网用 Bonjour 能扫到 `Macbook_Pro_M2._rfb._tcp` → `MacbookProM2.local:5900`。
- 握手实测：服务器版本 `RFB 003.889`，安全类型 `30, 33, 36, 2, 35`。我们支持 2（VNC 密码）
  和 30（Apple 账户 DH），协议上能接。
- `Info.plist` 里没有 `NSLocalNetworkUsageDescription` 和 `NSBonjourServices`。macOS 15 起，
  沙盒 App 访问局域网要走本地网络权限，Bonjour 浏览必须声明服务类型，否则直接失败。
- 界面上没有「附近的 Mac」，用户只能手填地址。

## 2. 方案

### 2.1 文件夹（先做）

现在的分组只是 `RDMachine.group` 字符串，没有空文件夹、不能改名、不能有来源。

- 新增 `RDFolder`：`id`、`name`、`source`（`.local` / `.uuRemote`）、`sortIndex`。
  存在 `CatusshStore.folderGroup`，跟服务器一起同步。
- 服务器仍然用 `group` 指向文件夹名（保持旧数据和同步格式不变）；文件夹改名时一起改。
  旧数据里出现过的组名在加载时自动补成本地文件夹。
- 服务器页按文件夹分节：新建 / 改名 / 删除文件夹，服务器右键「移到文件夹」。
- 来源为 UU 远程的文件夹：表头显示账号和刷新按钮；内容由同步得到，
  不能手动往里加服务器。

### 2.2 UU 远程 = 绑定账号 + 同步文件夹

- 登录前先注册本机设备；422 给出真正的错误信息。
- 设置里加「账户」：绑定 UU 远程账号（二维码 / 短信 / token）。
- 绑定后自动创建「UU 远程」文件夹，拉取设备列表 upsert 成服务器（以 `uuDeviceID` 为键），
  设备改名会同步，下线的设备标灰，账号里删掉的设备从文件夹移除（用户手动改过的不删）。
- 打开一台 UU 服务器：设备页，仿官方布局——状态胶囊、壁纸卡片「进入桌面」，
  底下是 观看模式 / 终端 / 文件传输 / 端口映射。没接通的能力显示为禁用并说明原因，
  不假装可用。

### 2.3 VNC / 屏幕共享

- `Info.plist` 加本地网络说明和 `_rfb._tcp`、`_ssh._tcp`。
- 远程桌面页加「附近」区：Bonjour 浏览 `_rfb._tcp`，一键保存为 VNC 服务器（macOS 默认
  用 Apple 账户认证）。
- 实机连接 `MacbookProM2.local`（需要用户提供账号密码时由用户在 App 里输入）。

## 3. 阶段与提交

| # | 内容 | 验证 |
|---|------|------|
| 1 | ⌘Q / accessory 修复 + 退出日志 | Debug 构建，Apple Event 退出 |
| 2 | UU 登录：先注册设备、422 报错 | live test：二维码生成 + 状态轮询 |
| 3 | 本地网络权限 + Bonjour 发现 + 附近区 | 单元测试 + 扫描本机网络 |
| 4 | `RDFolder` 模型、迁移、同步 | 单元测试 |
| 5 | 服务器页文件夹 UI | 截图 |
| 6 | UU 账号绑定 → 同步文件夹 | 单元测试（假设备列表） |
| 7 | UU 设备页 | 截图 |
| 8 | UU 终端接入终端页 | 需要真实登录，由用户扫码验证 |

每个阶段单独提交，提交前由 subagent 审查。

## 4. 不做

- 从官方 UURemote.app 导入登录 / 解密其数据。
- 用合成键鼠操作用户桌面做 UI 验证（只截图，交互由用户确认）。

## 5. 验收目标（Goals）

每一项都在装到 /Applications 的 Release 版里、用已登录的 UU 账号实测；不能自动测的写明由谁、怎么测。

| # | 目标 | 通过标准 |
|---|------|----------|
| G1 | ⌘Q / 退出 | 无会话时菜单「Quit catussh」直接退出；开着 UU 桌面时也能退出（不再卡住）；有终端时先弹确认框 |
| G2 | ⌘W | 在终端页关闭当前终端标签；最后一个标签关闭后换成同一服务器的新终端；不关窗口 |
| G3 | UU 登录 | 「Link UU Remote Account…」打开登录页，二维码自动生成；登录状态重启后仍在 |
| G4 | UU 文件夹 | 服务器页有「UU Remote」文件夹，列出账号的桌面设备（不含 catussh 自己），显示在线/离线 |
| G5 | UU 桌面 | 对在线设备点 Desktop：连上，画面铺满页面，显示 fps；工具栏只有 Terminal / Desktop |
| G6 | UU 终端 | 对在线设备点 Terminal：出现设备自己的 shell 提示符，输入命令有输出 |
| G7 | 文件夹 | 新建 / 改名 / 删除文件夹，服务器「Move to Folder」 |
| G8 | 附近的 Mac | 远程桌面页「附近」列出 MacbookProM2.local:5900，「Add…」打开预填好的新服务器（不先保存） |
| G9 | 不回退 | 普通 SSH 服务器仍有 Files / Monitor / Terminal，双击开终端 |

不在本轮自动验收：远程桌面的键鼠控制（会操作另一台 Mac，由用户确认）、VNC 用账号密码的完整连接（需要那台 Mac 的密码）。


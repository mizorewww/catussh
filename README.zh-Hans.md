# catussh

[English](./README.md) · **简体中文** · [繁體中文](./README.zh-Hant.md)

为管理 Linux 和 macOS 服务器而生的原生 macOS 应用：基于 [Ghostty](https://ghostty.org)
的 SSH 终端、SFTP 文件传输、实时资源监控，每台服务器三者并排可用。

[![License](https://img.shields.io/badge/license-MIT-blue)](./LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6.2-orange)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./Resources/Screenshots/home-dark.jpg">
  <img alt="catussh 主页：顶部是快速连接，下方是已保存服务器的卡片，每张卡片都有连接、文件和监控按钮。" src="./Resources/Screenshots/home-light.jpg">
</picture>

## 安装

```sh
brew install --cask mizorewww/tap/catussh
```

需要 macOS 13 或更高版本。应用是通用二进制，已签名并经过公证。也可以在
[Releases](https://github.com/mizorewww/catussh/releases) 下载磁盘映像。

## 功能

- **每台服务器都有终端、文件和监控**，各一键打开，工具栏里可以来回切换。
- **原生 Ghostty 终端**：GPU 渲染，600 多套主题，半透明背景。
- **可视化终端设置**：直接挑选已安装的字体和真实字重，按键录制快捷键，配色实时预览。
- **快速连接**：输入 `user@host:port` 后回车。
- **Cloudflare Access**：连接 Cloudflare Tunnel 后面的服务器，效果等同于
  `ssh -o ProxyCommand='cloudflared access ssh --hostname %h'`，无需安装 cloudflared，支持服务令牌。
- **Linux 和 macOS 服务器监控**：CPU、内存、磁盘、网络和 NVIDIA GPU，使用系统自带工具，无需安装任何 agent。
- **身份**（密码或密钥）多台服务器共用，**代码片段**可在多台服务器上同时执行，
  还有**端口转发**和**菜单栏**监控。
- 另有 iPhone 和 iPad 版，终端和设置与 Mac 相同，需从源码构建。

## 截图

### 服务器列表

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./Resources/Screenshots/servers-dark.jpg">
  <img alt="服务器列表按生产、CI 和家庭实验室分组，每一行都有文件、监控和连接按钮。" src="./Resources/Screenshots/servers-light.jpg">
</picture>

### 终端文字设置

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./Resources/Screenshots/text-dark.jpg">
  <img alt="设置中的文字页：字体选择器、样式菜单、带数值输入框的字号滑块，以及笔画加粗。" src="./Resources/Screenshots/text-light.jpg">
</picture>

### 配色与实时预览

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./Resources/Screenshots/colors-dark.jpg">
  <img alt="设置中的配色页：上方是实时终端预览，下方是主题库。" src="./Resources/Screenshots/colors-light.jpg">
</picture>

### 键盘快捷键

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./Resources/Screenshots/keyboard-dark.jpg">
  <img alt="设置中的键盘页：快捷键以键帽显示，配有直白的动作说明，按用途分组。" src="./Resources/Screenshots/keyboard-light.jpg">
</picture>

## 使用 catussh

1. **添加服务器**：在主页点 **New Server**（⇧⌘N）。
2. **连接**：点服务器卡片。**Files** 打开 SFTP，**Monitor** 打开实时用量；工具栏切换器可在三者间切换。
3. **快速连接**：在主页输入 `user@host`、`user@host:2222` 或完整的 `ssh` 命令。
4. **设置**（⌘,）包含应用和终端的全部选项。Ghostty 配置项的覆盖情况见
   [CONFIGURATION.md](Foundation/CatusshTerminal/CONFIGURATION.md)。

## 从源码构建

需要 Xcode 26 或更高版本（Swift 6.2）。

```sh
git clone https://github.com/mizorewww/catussh.git
cd catussh
bash Workflow/Scripts/install-macos.sh   # Release 构建，并安装到 /Applications
```

也可以打开 `App.xcworkspace`，运行 **catussh** scheme（macOS）或 **mCatussh**（iOS 16+）。

## 参与贡献

Bug 和建议请提到 [issues](https://github.com/mizorewww/catussh/issues)。欢迎 Pull
Request，提交前请先跑终端测试：

```sh
swift test --package-path Foundation/CatusshTerminal
```

## 许可证

[MIT](./LICENSE)。第三方许可证见 [Resources/LICENSE](./Resources/LICENSE)。

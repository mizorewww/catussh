# catussh

[English](./README.md) · [简体中文](./README.zh-Hans.md) · **繁體中文**

專為管理 Linux 和 macOS 伺服器打造的原生 macOS App：以 [Ghostty](https://ghostty.org)
為基礎的 SSH 終端機、SFTP 檔案傳輸、即時資源監控，每台伺服器三者並排可用。

[![License](https://img.shields.io/badge/license-MIT-blue)](./LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6.2-orange)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./Resources/Screenshots/home-dark.jpg">
  <img alt="catussh 首頁：上方是快速連線，下方是已儲存伺服器的卡片，每張卡片都有連線、檔案和監控按鈕。" src="./Resources/Screenshots/home-light.jpg">
</picture>

## 安裝

```sh
brew install --cask mizorewww/tap/catussh
```

需要 macOS 13 或以上版本。App 為通用二進位檔，已簽署並通過公證。也可以到
[Releases](https://github.com/mizorewww/catussh/releases) 下載磁碟映像檔。

## 功能

- **每台伺服器都有終端機、檔案和監控**，各一鍵開啟，工具列上可以來回切換。
- **原生 Ghostty 終端機**：GPU 繪製，600 多套主題，半透明背景。
- **視覺化終端機設定**：直接挑選已安裝的字型與真實字重，以按鍵錄製快速鍵，配色即時預覽。
- **快速連線**：輸入 `user@host:port` 後按 Return。
- **Cloudflare Access**：連線 Cloudflare Tunnel 後面的伺服器，效果等同於
  `ssh -o ProxyCommand='cloudflared access ssh --hostname %h'`，不需安裝 cloudflared，支援服務權杖。
- **Linux 和 macOS 伺服器監控**：CPU、記憶體、磁碟、網路和 NVIDIA GPU，使用系統內建工具，不必安裝任何 agent。
- **身分**（密碼或金鑰）多台伺服器共用，**程式碼片段**可在多台伺服器上同時執行，
  還有**連接埠轉送**和**選單列**監控。
- 另有 iPhone 與 iPad 版，終端機和設定與 Mac 相同，需從原始碼建置。

## 螢幕截圖

### 伺服器列表

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./Resources/Screenshots/servers-dark.jpg">
  <img alt="伺服器列表依正式環境、CI 和家用實驗室分組，每一列都有檔案、監控和連線按鈕。" src="./Resources/Screenshots/servers-light.jpg">
</picture>

### 終端機文字設定

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./Resources/Screenshots/text-dark.jpg">
  <img alt="設定中的文字頁：字型選擇器、樣式選單、附數值輸入框的字級滑桿，以及筆畫加粗。" src="./Resources/Screenshots/text-light.jpg">
</picture>

### 配色與即時預覽

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./Resources/Screenshots/colors-dark.jpg">
  <img alt="設定中的配色頁：上方是即時終端機預覽，下方是主題庫。" src="./Resources/Screenshots/colors-light.jpg">
</picture>

### 鍵盤快速鍵

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="./Resources/Screenshots/keyboard-dark.jpg">
  <img alt="設定中的鍵盤頁：快速鍵以鍵帽顯示，搭配淺白的動作說明，依用途分組。" src="./Resources/Screenshots/keyboard-light.jpg">
</picture>

## 使用 catussh

1. **新增伺服器**：在首頁按 **New Server**（⇧⌘N）。
2. **連線**：按伺服器卡片。**Files** 開啟 SFTP，**Monitor** 開啟即時用量；工具列切換器可在三者間切換。
3. **快速連線**：在首頁輸入 `user@host`、`user@host:2222` 或完整的 `ssh` 指令。
4. **設定**（⌘,）涵蓋 App 與終端機的所有選項。Ghostty 設定項目的支援範圍請見
   [CONFIGURATION.md](Foundation/CatusshTerminal/CONFIGURATION.md)。

## 從原始碼建置

需要 Xcode 26 或以上版本（Swift 6.2）。

```sh
git clone https://github.com/mizorewww/catussh.git
cd catussh
bash Workflow/Scripts/install-macos.sh   # Release 建置，並安裝到 /Applications
```

也可以開啟 `App.xcworkspace`，執行 **catussh** scheme（macOS）或 **mCatussh**（iOS 16+）。

## 參與貢獻

Bug 與建議請提到 [issues](https://github.com/mizorewww/catussh/issues)。歡迎 Pull
Request，送出前請先執行終端機測試：

```sh
swift test --package-path Foundation/CatusshTerminal
```

## 授權

[MIT](./LICENSE)。第三方授權請見 [Resources/LICENSE](./Resources/LICENSE)。

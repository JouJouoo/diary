# 留白日记

一个 SwiftUI iPhone 日记应用首版：使用 Apple 系统语音识别转写口述内容，调用 DeepSeek 整理成日记，并将每篇日记保存为 Markdown。

## 使用

1. 使用 Xcode 打开 `DiaryApp.xcodeproj` 并运行到 iPhone 或模拟器。
2. 在应用设置中填写 DeepSeek API Key。
3. 如需同步，在坚果云第三方应用管理中创建应用密码，再填写坚果云邮箱和 WebDAV 信息。默认地址为 `https://dav.jianguoyun.com/dav/`。
4. 口述后可编辑原文，整理成日记，再保存。日记会保存在设备本地；配置坚果云后，新保存的日记也会自动上传为 `.md` 文件。

每篇 Markdown 文件包含日期、日记正文和可折叠的口述原文。

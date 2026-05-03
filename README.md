# QwenPaw-Guide-Mode-
类似于codex的引导模式

# QwenPaw 引导模式可复用补丁包

这个补丁包用于在重装或更新 QwenPaw 后，快速恢复当前已经验证可用的“引导模式”改造。

## 一键安装

1. 重装或更新 QwenPaw。
2. 关闭正在运行的 QwenPaw Desktop。
3. 双击 `Install-QwenPawGuideMode.cmd`。
4. 脚本会自动备份原文件、安装补丁、校验补丁，并启动 QwenPaw Desktop。

默认安装路径是自动识别，优先识别 `D:\QwenPaw`。如果你的安装路径变了，用 PowerShell 手动指定：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-QwenPawGuideMode.ps1 -QwenPawRoot "D:\QwenPaw" -StartAfterInstall
```

只安装不启动：

```powershell
.\Install-QwenPawGuideMode-NoStart.cmd
```

## 这个补丁包含什么

- `/guide on`、`/guide off`
- `/g` 快捷引导
- `/引导 on`、`/引导 off`
- Desktop 前端运行中输入时走 `/api/console/guide` 侧通道，不再触发 stop
- 后端把中途输入注入到正在运行的 agent
- 如果模型收到引导后想只输出文字，后端会强制再走一次工具调用，避免“说了但不执行”
- 日志中会出现这些关键记录：
  - `Console guide queued`
  - `Injected ... guidance item(s)`
  - `Guidance action guard`

## 安装时会备份什么

每次安装前都会把被覆盖的原文件备份到桌面：

```text
%USERPROFILE%\Desktop\QwenPaw-guide-mode-patch-backups\backup-时间戳
```

备份目录里有：

- `original/`：重装后原始文件
- `backup-manifest.json`：恢复用清单

## 恢复到安装补丁前

双击：

```text
Restore-LastBackup.cmd
```

它会自动找桌面上最新的 `backup-*`，把原文件恢复回 QwenPaw，然后启动 QwenPaw Desktop。

手动指定某个备份：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Restore-QwenPawGuideModeBackup.ps1 -BackupDir "C:\Users\yang\Desktop\QwenPaw-guide-mode-patch-backups\backup-20260503-xxxxxx"
```

## 手动校验

安装后可以运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Verify-QwenPawGuideMode.ps1 -QwenPawRoot "D:\QwenPaw"
```

通过后会显示：

```text
Guide mode verification passed.
```

## 运行时验证

1. 打开 QwenPaw Desktop。
2. 输入 `/引导 on`。
3. 发一个耗时任务，例如“在桌面创建 B.txt，放进今天科技新闻 3 条”。
4. 执行中继续输入“再复制一份命名为 C”。
5. 看桌面是否同时出现 `B.txt` 和 `C.txt`。
6. 看日志 `C:\Users\yang\.qwenpaw\qwenpaw.log` 是否有：

```text
Console guide queued
Injected 1 guidance item(s)
Guidance action guard
```

如果同一轮任务里出现这些记录，就说明它是“引导插入”，不是顺序排队执行。

## 兼容性说明

这个包是从当前已验证可用的 QwenPaw 安装目录提取出来的覆盖式补丁。优点是重装后恢复非常快；缺点是如果未来 QwenPaw 官方大幅改了内部文件结构，补丁可能需要重新生成。

如果安装脚本校验失败，先运行 `Restore-LastBackup.cmd` 恢复，再基于新版本重新做一次补丁包。

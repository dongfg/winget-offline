# WinGet 离线安装包

在 GitHub Actions 上下载软件，生成 ZIP；在目标 Windows 上解压、双击 `install.cmd`，由 WinGet 通过本地 Manifest 安装。安装器来自压缩包中的本机 HTTP 服务，服务只监听 `127.0.0.1`，不需要注册软件源。

## 配置和构建

编辑仓库根目录的 `packages.json`，例如：

```json
{
  "architecture": "x64",
  "packages": [
    { "id": "Git.Git", "version": "2.52.0" },
    { "id": "Microsoft.VisualStudioCode", "scope": "user" },
    { "id": "7zip.7zip", "installerType": "msi" }
  ]
}
```

- `architecture`：`x64`、`x86` 或 `arm64`，目标 Windows 系统架构必须一致。
- `id`：官方 `winget` 源中的精确包 ID。
- `version`：可选，省略则下载构建时最新版本；指定的版本必须仍在源中。
- `scope`：可选，`user` 或 `machine`，由包自身支持情况决定。
- `installerType`、`locale`：可选，传给 `winget download` 的安装器类型和语言筛选。

推送仓库后，在 **Actions → Build offline bundle → Run workflow** 手动运行，完成后下载页面底部的 artifact。Action **只有 `workflow_dispatch`**，push、PR 和定时任务均不会触发；不会创建 Release。

GitHub artifact 外层 ZIP 中包含 `winget-offline-x64.zip`（或相应架构）。解压内层 ZIP 后安装。任意下载、哈希校验或清单转换失败，整个构建失败，不发布不完整包。Artifact 保留 14 天，可在 workflow 中修改。

## 在目标机器安装

需要 Windows 10/11、Windows PowerShell 5.1，以及支持 `download`、`settings export` 和本地 Manifest 的当前稳定版 WinGet。上游生成的 Manifest 可能使用新字段，旧版 WinGet 不保证兼容；建议构建机与目标机都更新到当前稳定版。WinGet 自身不包含在 ZIP 中。

`winget.exe` 是独立程序，在 PowerShell 5.1 和 PowerShell 7 中调用同一版本时能力相同。目标机器不需要安装 PowerShell 7；只有构建脚本使用 PowerShell 7 的语法和 YAML 模块。

1. 将 ZIP 完整解压到可写目录，避免直接在压缩包预览中运行。
2. 双击 `install.cmd`，接受 UAC 管理员授权。请以当前用户提升权限；`scope: user` 的软件安装到提升后的用户账户。
3. 脚本校验全部安装器和 Manifest，启动动态端口 HTTP 服务，然后依次静默安装。
4. 查看 `logs/<时间与随机标识>/install.log` 和 `results.json`。任意软件失败，最终退出码为 1；其他软件仍继续尝试。

可重复运行；WinGet 返回“已安装且无适用升级”时记为 `skipped`。已装旧版时由 WinGet 执行升级；已装新版不会强制降级。具体识别能力取决于软件的注册信息。

安装结束后停止 HTTP 服务，清理临时 Manifest，并恢复脚本临时启用的 `LocalManifestFiles`。原本已经启用的设置会保留。强制结束进程、断电等情况下 `finally` 无法保证执行，如有需要以管理员运行 `winget settings --disable LocalManifestFiles`。组策略禁止本地 Manifest 时会失败并报告。

只验证解压包和 HTTP 传输、不安装软件、不修改 WinGet 设置：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -VerifyOnly
```

## 支持范围

第一版支持官方 `winget` 源中能下载的单个 EXE（含 Inno、Nullsoft、Burn）、MSI/WiX、无额外依赖的 MSIX 安装器。构建以 WinGet 实际下载的文件哈希选择唯一安装器，保留上游的静默参数、ProductCode 和 AppsAndFeaturesEntries 等识别信息；生成的 `packages.json` 记录实际版本、来源 URL、哈希和类型。安装时不会改用其他版本或在线安装器 URL。

以下情况构建直接失败：Microsoft Store 包、portable、ZIP/nested 安装器、清单含额外依赖、多个安装器或无法与下载文件匹配的 Manifest。当前不自动构建依赖图；需要这些包时应扩展构建器后再添加。不要通过忽略哈希或删除依赖声明绕过错误。

B 机器可以联网。这是“预下载主要安装器以加速安装”，不承诺任意软件完全断网安装：厂商的 bootstrapper 可能在执行过程中下载组件，WinGet 也可能读取源元数据。请选完整安装器，并在目标环境确认。脚本不回退到上游安装包 URL，也不自动安装 WinGet 或运行时。

安装后，只要软件能被官方源正确匹配，仍可用 `winget list`、`winget upgrade`、`winget uninstall` 管理；后续普通升级会从官方源下载新安装器。离线构建不会注册长期存在的 WinGet 软件源。

## 本地开发

构建需要 PowerShell 7 和 `powershell-yaml`（仅构建机需要该模块）：

```powershell
Install-Module powershell-yaml -RequiredVersion 0.4.12 -Scope CurrentUser
./tests/test.ps1
./scripts/build.ps1
```

测试使用合成安装器验证清单转换、哈希筛选、元数据保留、依赖拒绝，以及真实本机 HTTP 服务的 GET/HEAD/路径限制。不会运行任何软件安装器。目标机首次使用时仍需验证 UAC、企业策略和具体软件的安装行为。

参考：[WinGet download](https://learn.microsoft.com/windows/package-manager/winget/download)、[本地 Manifest 安装](https://learn.microsoft.com/windows/package-manager/winget/install#local-install)。

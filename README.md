# WinGet 离线安装包

在 GitHub Actions 的 Windows 节点或 CNB 的 Linux 节点下载软件，生成 ZIP；在目标 Windows 上解压、双击 `install.cmd`，由 WinGet 通过本地 Manifest 安装。安装器来自压缩包中的本机 HTTP 服务，服务只监听 `127.0.0.1`，不需要注册软件源。

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
- `version`：可选；GitHub Actions 省略时由 WinGet 选最新版本，CNB Linux 的版本规则见下文。指定的版本必须仍在源中。
- `scope`：可选，`user` 或 `machine`，由包自身支持情况决定。
- `installerType`、`locale`：可选，安装器类型和语言筛选；GitHub Actions 传给 `winget download`，CNB Linux 直接筛选 Manifest。

推送仓库后，在 **Actions → Build offline bundle → Run workflow** 手动运行。构建、测试和 ZIP 验证全部成功后，自动发布 GitHub Release，名称和标签使用北京时间的 `yyyyMMddHHmmss`（年月日时分秒），例如 `20261113153045`。从仓库 **Releases** 页面直接下载 ZIP，解压后安装。发布先创建草稿并上传附件，附件上传成功后才公开并标记为 Latest。

构建流程仍只有 `workflow_dispatch`，push、PR 和定时任务均不会触发构建。独立的 **Clean old releases** 流程每天北京时间 **04:17** 执行（GitHub 可能延迟调度），按发布时间仅保留最新一个已发布 Release，删除其余 Release 及附件；草稿和 Git 标签会保留。也可在 Actions 页面手动触发清理。发布和清理共享并发锁，避免清理与发布同时执行。

Action 仍额外保留 artifact 作为构建记录，外层 ZIP 中包含 `winget-offline-x64.zip`（或相应架构）。从 artifact 下载时需要再解压内层 ZIP。任意下载、哈希校验或清单转换失败，整个构建失败，不发布不完整包。Artifact 保留 14 天，可在 workflow 中修改；每日 Release 清理不会删除 artifact。

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

第一版支持官方 `winget` 源中能下载的单个 EXE（含 Inno、Nullsoft、Burn）、MSI/WiX、无额外依赖的 MSIX 安装器。GitHub Actions 以 WinGet 实际下载的文件哈希选择唯一安装器，CNB Linux 直接读取官方仓库清单并选择安装器；两者均保留上游的静默参数、ProductCode 和 AppsAndFeaturesEntries 等识别信息。生成的 `packages.json` 记录实际版本、来源 URL、哈希和类型。安装时不会改用其他版本或在线安装器 URL。

以下情况构建直接失败：Microsoft Store 包、portable、ZIP/nested 安装器、清单含额外依赖、多个安装器或无法与下载文件匹配的 Manifest。当前不自动构建依赖图；需要这些包时应扩展构建器后再添加。不要通过忽略哈希或删除依赖声明绕过错误。

B 机器可以联网。这是“预下载主要安装器以加速安装”，不承诺任意软件完全断网安装：厂商的 bootstrapper 可能在执行过程中下载组件，WinGet 也可能读取源元数据。请选完整安装器，并在目标环境确认。脚本不回退到上游安装包 URL，也不自动安装 WinGet 或运行时。

安装后，只要软件能被官方源正确匹配，仍可用 `winget list`、`winget upgrade`、`winget uninstall` 管理；后续普通升级会从官方源下载新安装器。离线构建不会注册长期存在的 WinGet 软件源。

## 本地开发

### CNB 流水线

根目录 `.cnb.yml` 在 CNB **官方 Linux 节点**运行，不需要 Windows Runner，也不运行 WinGet：`master` 分支手动构建、下载打包、上传保留 14 天的 Commit 附件，再发布到 CNB **当前仓库**，Release 使用北京时间 `yyyyMMddHHmmss` 命名。Release 先创建为草稿，附件上传并确认后才公开和标记 Latest。

Linux 镜像提供跨平台 PowerShell 7，用于发布和清理；准备阶段安装 Python 3、创建虚拟环境并安装锁定版本的 PyYAML。`scripts/build-linux.py` 从微软 `winget-pkgs` 官方仓库读取多文件 Manifest，合并为单文件清单、下载安装器并校验上游 SHA256，最后打包现有 Windows 安装脚本。一次构建固定同一个上游提交，其 SHA 记录在生成的 `packages.json` 的 `manifestRepositoryCommit` 中。

Linux 下载器采用明确的有限规则，不完全复刻 WinGet 的运行环境判断：

- `version` 未指定时，只在数字版本（例如 `26.06`、`2.56.0.4`，允许 `v` 前缀）中按数字段选择最大值。预发布或特殊版本号需要显式指定 `version`；建议固定版本以便复现。
- 架构优先精确匹配，其次 `neutral`；指定 `scope` 时必须精确匹配，不指定则优先 `machine`，其次 `user`，最后未声明 scope 的条目。
- `locale` 默认取包的默认语言，优先该语言，其次未声明安装器语言的条目；其他安装器语言不自动回退。
- `installerType` 按 Manifest 的原始类型精确筛选（WiX 要写 `wix`）；未指定时，同等架构、scope 和语言下依次优先 `wix`、`msi`、`inno`、`nullsoft`、`burn`、`exe`、`msix`。
- 排除有额外依赖、禁止下载、要求认证或不支持类型的安装器；仍有多个同等候选则构建失败，要求补充筛选条件。没有符合条件的安装器时不会改装旧版或回退在线下载。

Linux 阶段进行下载哈希校验，不运行 Windows PowerShell 5.1、WinGet 或 Windows 安装测试。解压后的 ZIP 仍在 Windows 上运行 `install.cmd`。目标机的 WinGet 会继续检查实际系统是否满足清单要求；Linux 构建成功不代表已经验证安装兼容性。

将代码同步到 CNB 的 `master` 分支，在分支详情页点击「构建离线安装包」。页面按钮定义在 `.cnb/web_trigger.yml`，没有 push/PR 自动构建。发布和清理使用构建期间注入的 `CNB_TOKEN`、`CNB_API_ENDPOINT`、`CNB_REPO_SLUG`；触发者需有当前 CNB 仓库的 Release 和 Commit 附件写权限。读取公开 Manifest 默认无需 GitHub Token；若遇到 GitHub API 限流，可通过 CNB 密钥仓库的 `imports` 注入可读取公开仓库的 `WINGET_GITHUB_TOKEN`，它仅用于 GitHub 清单 API，不会转发给软件厂商下载地址。

每日北京时间 **04:17** 在 CNB 官方 Linux 节点清理旧 Release，只保留最新一个已发布 Release，草稿、Git 标签及 Commit 附件保留；也可点击「清理旧 Release」手动执行。清理与构建共享仓库锁。CNB cron 直接使用北京时间，表达式是 `17 4 * * *`。推送包含 `.cnb.yml` 的变更后会自动同步定时任务；迁移后若未出现任务，可在「云原生构建 → 定时任务」选择 `master` 手动同步，并确认仓库和组织允许定时触发。

CNB 的 Release、附件和定时任务 API 对照[官方 OpenAPI](https://api.cnb.cool/)及[流水线语法](https://docs.cnb.cool/zh/build/grammar)编写。

### 本机构建

Windows 构建需要 WinGet、PowerShell 7 和 `powershell-yaml`（仅构建机需要该模块）：

```powershell
Install-Module powershell-yaml -RequiredVersion 0.4.12 -Scope CurrentUser
./tests/test.ps1
./scripts/build.ps1
```

测试使用合成安装器验证清单转换、哈希筛选、元数据保留、依赖拒绝，以及真实本机 HTTP 服务的 GET/HEAD/路径限制。不会运行任何软件安装器。目标机首次使用时仍需验证 UAC、企业策略和具体软件的安装行为。

Linux 本机构建只需要 Python 3.9+ 和 PyYAML：

```sh
python3 -m venv .work/cnb-python
.work/cnb-python/bin/pip install -r scripts/requirements-linux.txt
.work/cnb-python/bin/python scripts/build-linux.py
```

参考：[WinGet download](https://learn.microsoft.com/windows/package-manager/winget/download)、[本地 Manifest 安装](https://learn.microsoft.com/windows/package-manager/winget/install#local-install)。

# WinGet 离线安装包

在 CNB 或 GitHub Actions 上预先下载 Windows 软件并打包，在目标机器解压后双击安装，减少从软件官网下载的等待时间。

## 1. 配置软件

在源码仓库中编辑 `packages.json`，提交到 `master` 分支。下载后的 ZIP 无需修改配置。

```json
{
  "architecture": "x64",
  "packages": [
    { "id": "Git.Git", "installMode": "interactive" },
    { "id": "Microsoft.VisualStudioCode", "scope": "user" },
    { "id": "7zip.7zip" }
  ]
}
```

默认下载 x64 安装器。`architecture` 也支持 `x86`、`arm64`，需要与目标 Windows 系统架构一致。

| 软件配置项 | 说明 |
| --- | --- |
| `id` | 必填，WinGet 官方源中的精确软件 ID，可用 `winget search 软件名` 查询 |
| `version` | 可选，字符串，指定要下载的版本；CNB 省略时选择最新数字版本，特殊版本号需明确指定 |
| `scope` | 可选，`user` 或 `machine`，分别表示当前用户安装和所有用户安装 |
| `installMode` | 可选，`silent`（默认）或 `interactive`；后者显示安装向导，供你手动选择组件 |
| `installerType` | 可选，筛选安装器类型，例如 `inno`、`exe`、`msi`、`wix`；CNB 必须与清单类型完全一致 |
| `locale` | 可选，筛选安装器语言，例如 `zh-CN`、`en-US` |

可选字段需要软件本身支持。优先选择完整安装器；当前不支持 Microsoft Store、portable、ZIP 安装器及声明了额外依赖的安装器。无法确定安装器或校验失败时，构建会报错。

例如上面的 Git 配置会显示安装向导，可取消右键菜单集成等选项；其他软件未设置 `installMode`，仍为静默安装。仓库默认配置保持全部静默，需要时将对应软件的 `installMode` 改为 `interactive`，再重新构建下载。

使用自己的 CNB 仓库时，将 `.cnb.yml` 下载步骤中的 `imports` 改为自己的密钥文件地址，文件内容为：

```yaml
WINGET_GITHUB_TOKEN: "你的 GitHub Token"
```

Token 只需公开仓库只读访问。也可以删除该 `imports`，不带 Token 读取公开清单，但更容易遇到 GitHub API 限流。

## 2. 触发构建

两种平台任选其一，均为手动构建，推送代码不会自动打包。

| 平台 | 操作 |
| --- | --- |
| CNB | 打开仓库 `master` 分支详情页，点击「构建离线安装包」 |
| GitHub | 打开 **Actions → Build offline bundle → Run workflow**，选择 `master` 并运行 |

等待流水线成功，安装包会自动发布到对应平台的 Release，名称为北京时间的年月日时分秒，例如 `20261113153045`。

## 3. 下载安装包

打开 [CNB Releases](https://cnb.cool/dongfg/winget-offline/-/releases) 或 [GitHub 最新 Release](https://github.com/dongfg/winget-offline/releases/latest)，下载附件 **`winget-offline-x64.zip`**（其他架构使用相应文件名）。使用自己的仓库时，在该仓库的 Releases 页面下载。

请选择安装包附件，GitHub 的 `Source code` 是项目源码。两个平台每天北京时间 **04:17** 清理旧 Release，仅保留最新一个已发布版本，建议及时下载保存。

## 4. 安装软件

目标机器需要 Windows 10/11、系统自带的 Windows PowerShell 5.1，以及当前稳定版 WinGet。可以先运行 `winget --version` 确认可用，无需安装 Python 或 PowerShell 7。

1. 将 ZIP **完整解压到可写目录**。
2. 双击 **`install.cmd`**，接受管理员权限提示。
3. 软件会按配置依次安装：静默模式自动执行；交互模式需手动完成安装向导，关闭安装器后继续下一个软件。完成后查看窗口中的成功、跳过或失败结果。

安装日志保存在解压目录的 `logs/` 中，包括 `install.log` 和 `results.json`。失败后可以再次运行；WinGet 识别为已安装且没有适用升级的软件会跳过。

脚本会从 ZIP 中的本机 HTTP 服务读取安装器，安装结束后关闭服务。目标机器可以联网；部分厂商安装器仍可能下载额外组件，因此不保证完全断网安装。软件被官方源正确识别后，可继续使用 `winget list`、`winget upgrade`、`winget uninstall` 管理。

项目代码使用 [MIT License](LICENSE)。下载的软件安装器仍遵循各自的许可证。

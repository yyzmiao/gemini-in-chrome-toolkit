# Gemini in Chrome Toolkit

面向 Windows 的 Gemini in Chrome 配置、诊断与恢复工具。仓库提供功能等价的 Python 脚本和 PowerShell 脚本，用于备份 Chrome 配置、写入地区与语言设置、使用诊断参数启动 Chrome，并从备份恢复原始配置。

## 功能范围

- 自动检测 Chrome 安装目录和用户数据目录。
- 强制关闭 Chrome 后再处理配置，避免运行时写入冲突。
- 修改前备份 `Local State` 和全部常规 Profile 的 `Preferences`。
- 写入 Variations 国家、长期一致性国家和界面语言设置。
- 更新配置中已经存在的 `is_glic_eligible` 字段。
- 使用国家覆盖和国家过滤诊断参数启动 Chrome。
- 支持恢复最新备份或指定备份。
- 支持只读状态检查。
- 不删除注册表策略，不修改 Chrome 企业管理策略。

## 适用边界

工具仅用于 Windows 上的本地配置诊断。以下条件仍由 Google、Chrome 或组织管理员控制：

- Google 账号是否具备 Gemini in Chrome 资格；
- 服务是否已向账号完成分批开放；
- 当前国家或地区是否位于官方支持范围；
- 工作或学校账号是否获得管理员授权；
- Chrome 版本、设备语言和操作系统是否满足要求；
- 服务器端状态是否允许使用该功能。

本地配置和启动参数不能授予服务器端资格。Chrome 更新后可能重新计算或覆盖相关字段，内部参数也可能发生变化。

## 系统要求

- Windows 10 或 Windows 11
- Google Chrome 正式版
- PowerShell 7.4 或更高版本，仅 PowerShell 脚本需要
- Python 3.10 或更高版本，仅 Python 脚本需要
- 对当前 Windows 用户的 Chrome 配置目录具有读写权限

管理员权限通常不是必需条件。组织管理设备上的策略应由系统管理员处理。

## 安全机制

启用和恢复操作会强制结束全部 `chrome.exe` 进程。执行前保存网页表单、在线文档、下载任务和其他未提交内容。普通标签页通常可由 Chrome 恢复，隐身窗口和未提交数据无法保证恢复。

每次启用操作都会创建独立备份，默认位置为：

```text
%USERPROFILE%\Documents\GeminiInChromeToolkit\backups\时间戳
```

备份目录包含：

```text
manifest.json
Local State
Default\Preferences
Profile 1\Preferences
Profile 2\Preferences
```

实际 Profile 文件取决于本机 Chrome 配置。

## 快速使用

### PowerShell

打开 PowerShell，进入仓库目录后执行：

```powershell
pwsh -NoProfile -File .\scripts\gemini_chrome.ps1
```

脚本显示交互式菜单：

```text
1. 启用并启动 Chrome
2. 恢复最新备份
3. 查看状态
0. 退出
```

直接执行指定操作：

```powershell
# 启用、备份并启动 Chrome
pwsh -NoProfile -File .\scripts\gemini_chrome.ps1 -Action Enable

# 恢复最新备份
pwsh -NoProfile -File .\scripts\gemini_chrome.ps1 -Action Restore

# 恢复指定备份
pwsh -NoProfile -File .\scripts\gemini_chrome.ps1 -Action Restore -Backup "C:\path\to\backup"

# 查看状态
pwsh -NoProfile -File .\scripts\gemini_chrome.ps1 -Action Status
```

自动化环境可使用 `-Yes` 跳过关闭 Chrome 前的确认。使用 `-NoLaunch` 可在写入配置后不启动 Chrome。

### Python

打开命令提示符或 PowerShell，进入仓库目录后执行：

```powershell
python .\scripts\gemini_chrome.py
```

直接执行指定操作：

```powershell
# 启用、备份并启动 Chrome
python .\scripts\gemini_chrome.py enable

# 恢复最新备份
python .\scripts\gemini_chrome.py restore

# 恢复指定备份
python .\scripts\gemini_chrome.py restore --backup "C:\path\to\backup"

# 查看状态
python .\scripts\gemini_chrome.py status
```

自动化环境可使用 `--yes` 跳过关闭 Chrome 前的确认。使用 `--no-launch` 可在写入配置后不启动 Chrome。

## 启用操作

启用流程按以下顺序执行：

1. 检测 Chrome 安装路径和用户数据目录。
2. 请求确认并结束全部 Chrome 进程。
3. 备份 `Local State` 和常规 Profile 配置。
4. 将 `variations_country` 设置为 `us`。
5. 将长期一致性国家设置为当前 Chrome 版本和 `us`。
6. 将 Chrome 界面区域设置为 `en-US`。
7. 将 Profile 接受语言设置为 `en-US,en`。
8. 将配置中已经存在的 `is_glic_eligible` 字段设置为 `true`。
9. 使用以下诊断参数启动 Chrome：

```text
--variations-override-country=us
--disable-features=GlicCountryFiltering
```

`--variations-override-country` 是 Chromium 提供的测试参数，不会跨会话永久保存。`GlicCountryFiltering` 属于 Chrome 内部功能标识，未来版本可能改名、删除或改变行为。

## 恢复操作

未指定备份时，脚本选择时间戳最新且包含有效 `manifest.json` 的备份。恢复流程会先关闭 Chrome，再按照清单把备份文件复制回原始位置。

恢复操作只处理清单中记录的文件，不删除备份后新建的 Profile，也不更改注册表、扩展、浏览记录、书签或 Google 账号。

## 验证方法

### 检查启动参数

打开以下页面：

```text
chrome://version
```

检查“命令行”字段是否包含：

```text
--variations-override-country=us
--disable-features=GlicCountryFiltering
```

### 检查 Gemini 启用状态

打开以下页面：

```text
chrome://glic/internals
```

重点检查：

- `Enabled by Chrome Flags`
- `Regular profile`
- `Pref or flag based rollout applies`
- `Account exists and has the Gemini in Chrome capability`
- `Account exists and is fully signed-in`
- `Server side allows this feature`
- `Passed locale filter`
- `Passed country filter`
- `Permanent Country Code`
- `Session Country Code`

账号、服务器、语言和地区检查均通过后，Gemini 面板仍无法加载时，继续检查扩展冲突、Chrome 版本和组织策略。

## 故障排查

### 启动参数未显示

已有 Chrome 主进程会接管新窗口，导致新快捷方式中的参数不生效。保存未提交内容，完全退出 Chrome 后重新运行启用操作。

### 国家代码仍未变化

Chrome 可能保留服务器下发的会话国家或长期国家。确认当前网络位于官方支持地区，关闭 VPN 后复测，并在下一个 Chrome 版本发布后再次检查。

### 按钮出现但面板无法打开

检查 `chrome://glic/internals` 中的账号能力、完整登录、服务器许可、语言和地区条件。入口可见不代表全部启用条件均已满足。

### 配置被 Chrome 覆盖

Chrome 会根据账号和服务器状态重新计算部分资格字段。本地 `is_glic_eligible` 不能代替服务器授权。重复写入该字段无法解决账号资格或 rollout 问题。

### 企业设备无法使用

工具不会删除或绕过企业策略。工作或学校账号需要管理员开放 Gemini in Chrome，受管理设备应由组织管理员核查对应策略。

## 仓库结构

```text
.
├── .github
│   └── workflows
│       └── validate.yml
├── scripts
│   ├── __init__.py
│   ├── gemini_chrome.py
│   └── gemini_chrome.ps1
├── tests
│   └── test_gemini_chrome.py
├── .gitignore
├── LICENSE
└── README.md
```

## 隐私与数据处理

脚本只访问当前 Windows 用户的本地 Chrome 配置文件。脚本不上传配置、账号、浏览记录或备份。备份保存在本机文档目录，删除备份前应确认不再需要恢复。

公开问题报告不得包含完整 `Local State`、`Preferences`、Cookie、账号标识、访问令牌或其他个人数据。

## 参考资料

- [Google Chrome 帮助：使用 Chrome 中的 Gemini](https://support.google.com/chrome/answer/16283624?hl=zh-Hans)
- [Google Chrome 帮助：Chrome 中的 Gemini 支持范围](https://support.google.com/chrome/answer/17140089?hl=zh-Hans)
- [Chromium：Variations 启动参数](https://chromium.googlesource.com/chromium/src/+/main/components/variations/variations_switches.cc)
- [Chromium：Gemini in Chrome 启用条件](https://chromium.googlesource.com/chromium/src/+/main/chrome/browser/glic/public/glic_enabling.cc)

## 许可证

项目采用 MIT License。

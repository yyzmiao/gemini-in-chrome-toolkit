#Requires -Version 7.4

[CmdletBinding()]
param(
    [ValidateSet("Menu", "Enable", "Restore", "Status", "Shortcut", "RemoveShortcut", "Exit")]
    [string]$Action = "Menu",
    [string]$Backup,
    [switch]$Yes,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
$Country = "us"
$Languages = "en-US,en"
$ChromeFlags = @(
    "--variations-override-country=us",
    "--disable-features=GlicCountryFiltering"
)
$ShortcutName = "Chrome - Gemini US.lnk"
$LauncherName = "launch_gemini_chrome.cmd"

function Assert-Windows {
    if ($env:OS -ne "Windows_NT") {
        throw "该工具仅支持 Windows。"
    }
}

function Get-ChromeUserData {
    if (-not $env:LOCALAPPDATA) {
        throw "未找到 LOCALAPPDATA 环境变量。"
    }
    $Path = Join-Path $env:LOCALAPPDATA "Google\Chrome\User Data"
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        throw "未找到 Chrome 用户数据目录：$Path"
    }
    return [IO.Path]::GetFullPath($Path)
}

function Get-ChromeExecutable {
    $Candidates = @(
        $env:ProgramFiles
        ${env:ProgramFiles(x86)}
        $env:LOCALAPPDATA
    ) | Where-Object { $_ } | ForEach-Object {
        Join-Path $_ "Google\Chrome\Application\chrome.exe"
    }
    foreach ($Candidate in $Candidates) {
        if ($Candidate -and (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
            return [IO.Path]::GetFullPath($Candidate)
        }
    }
    throw "未找到 Chrome 可执行文件。"
}

function Get-BackupRoot {
    $Documents = [Environment]::GetFolderPath("MyDocuments")
    if (-not $Documents) {
        $Documents = $HOME
    }
    return Join-Path $Documents "GeminiInChromeToolkit\backups"
}

function Get-ToolkitDataDirectory {
    if (-not $env:LOCALAPPDATA) {
        throw "未找到 LOCALAPPDATA 环境变量。"
    }
    return Join-Path $env:LOCALAPPDATA "GeminiInChromeToolkit"
}

function New-DesktopShortcut([string]$ChromePath) {
    $DataDirectory = Get-ToolkitDataDirectory
    New-Item -ItemType Directory -Path $DataDirectory -Force | Out-Null
    $LauncherPath = Join-Path $DataDirectory $LauncherName
    $LauncherLines = @(
        "@echo off"
        "taskkill /IM chrome.exe /F >nul 2>&1"
        "for /L %%G in (1,1,20) do ("
        '  tasklist /FI "IMAGENAME eq chrome.exe" /NH | find /I "chrome.exe" >nul'
        "  if errorlevel 1 goto launch"
        "  >nul 2>&1 ping 127.0.0.1 -n 2"
        ")"
        ":launch"
        ('start "" "{0}" {1}' -f $ChromePath, ($ChromeFlags -join " "))
        ""
    )
    [IO.File]::WriteAllText(
        $LauncherPath,
        ($LauncherLines -join "`r`n"),
        [Text.UTF8Encoding]::new($false)
    )

    $Shell = New-Object -ComObject WScript.Shell
    $Desktop = $Shell.SpecialFolders.Item("Desktop")
    $ShortcutPath = Join-Path $Desktop $ShortcutName
    $Shortcut = $Shell.CreateShortcut($ShortcutPath)
    $Shortcut.TargetPath = $LauncherPath
    $Shortcut.WorkingDirectory = Split-Path $ChromePath
    $Shortcut.IconLocation = "$ChromePath,0"
    $Shortcut.Description = "Start Chrome with Gemini diagnostic settings"
    $Shortcut.Save()
    return $LauncherPath
}

function Remove-DesktopShortcut {
    $Shell = New-Object -ComObject WScript.Shell
    $Desktop = $Shell.SpecialFolders.Item("Desktop")
    $ShortcutPath = Join-Path $Desktop $ShortcutName
    $LauncherPath = Join-Path (Get-ToolkitDataDirectory) $LauncherName
    if (Test-Path -LiteralPath $ShortcutPath) {
        Remove-Item -LiteralPath $ShortcutPath -Force
    }
    if (Test-Path -LiteralPath $LauncherPath) {
        Remove-Item -LiteralPath $LauncherPath -Force
    }
    Write-Host "桌面快捷方式和启动器已删除：$ShortcutName"
}

function Get-PreferenceFiles([string]$UserData) {
    $Directories = Get-ChildItem -LiteralPath $UserData -Directory | Where-Object {
        $_.Name -eq "Default" -or $_.Name -like "Profile *"
    }
    return @($Directories | ForEach-Object {
        $Preferences = Join-Path $_.FullName "Preferences"
        if (Test-Path -LiteralPath $Preferences -PathType Leaf) {
            Get-Item -LiteralPath $Preferences
        }
    } | Sort-Object FullName)
}

function Stop-Chrome {
    Get-Process chrome -ErrorAction SilentlyContinue | Stop-Process -Force
    for ($Index = 0; $Index -lt 20; $Index++) {
        if (-not (Get-Process chrome -ErrorAction SilentlyContinue)) {
            return
        }
        Start-Sleep -Milliseconds 250
    }
    throw "Chrome 进程未能在规定时间内退出。"
}

function Read-JsonObject([string]$Path) {
    $Object = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $Object) {
        throw "JSON 文件为空：$Path"
    }
    return $Object
}

function Write-JsonAtomic([string]$Path, $Object) {
    $Temporary = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $Json = $Object | ConvertTo-Json -Depth 100 -Compress
        $Utf8 = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($Temporary, $Json, $Utf8)
        Move-Item -LiteralPath $Temporary -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $Temporary) {
            Remove-Item -LiteralPath $Temporary -Force
        }
    }
}

function Set-Property($Object, [string]$Name, $Value) {
    $Property = $Object.PSObject.Properties[$Name]
    if ($null -eq $Property) {
        $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value
    }
    else {
        $Object.$Name = $Value
    }
}

function Set-ExistingEligibility($Node) {
    $Changed = 0
    if ($null -eq $Node -or $Node -is [string] -or $Node.GetType().IsPrimitive) {
        return $Changed
    }
    if ($Node -is [Collections.IEnumerable] -and $Node -isnot [Management.Automation.PSCustomObject]) {
        foreach ($Item in $Node) {
            $Changed += Set-ExistingEligibility $Item
        }
        return $Changed
    }
    foreach ($Property in @($Node.PSObject.Properties)) {
        if ($Property.Name -eq "is_glic_eligible") {
            if ($Property.Value -ne $true) {
                $Property.Value = $true
                $Changed++
            }
        }
        else {
            $Changed += Set-ExistingEligibility $Property.Value
        }
    }
    return $Changed
}

function New-ConfigurationBackup([string]$UserData) {
    $Destination = Join-Path (Get-BackupRoot) (Get-Date -Format "yyyyMMdd-HHmmss-fff")
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $Targets = @((Join-Path $UserData "Local State")) + @((Get-PreferenceFiles $UserData).FullName)
    $Entries = @()
    foreach ($Source in $Targets) {
        if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
            continue
        }
        $Relative = $Source.Substring($UserData.TrimEnd("\").Length).TrimStart("\")
        $BackupFile = Join-Path $Destination $Relative
        New-Item -ItemType Directory -Path (Split-Path $BackupFile) -Force | Out-Null
        Copy-Item -LiteralPath $Source -Destination $BackupFile -Force
        $Entries += [PSCustomObject]@{ source = $Source; backup = $Relative }
    }
    $Manifest = [PSCustomObject]@{
        format = 1
        created_at = [DateTimeOffset]::UtcNow.ToString("o")
        user_data_dir = $UserData
        files = $Entries
    }
    $ManifestPath = Join-Path $Destination "manifest.json"
    $Utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($ManifestPath, ($Manifest | ConvertTo-Json -Depth 10), $Utf8)
    return $Destination
}

function Get-LatestBackup {
    $Root = Get-BackupRoot
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "未找到可用备份：$Root"
    }
    $Latest = Get-ChildItem -LiteralPath $Root -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName "manifest.json") } |
        Sort-Object Name -Descending |
        Select-Object -First 1
    if ($null -eq $Latest) {
        throw "未找到可用备份：$Root"
    }
    return $Latest.FullName
}

function Set-LocalState([string]$Path, [string]$ChromePath) {
    $Data = Read-JsonObject $Path
    $Version = (Get-Item -LiteralPath $ChromePath).VersionInfo.ProductVersion
    Set-Property $Data "variations_country" $Country
    Set-Property $Data "variations_permanent_consistency_country" @($Version, $Country)
    if ($null -eq $Data.PSObject.Properties["intl"] -or $null -eq $Data.intl) {
        Set-Property $Data "intl" ([PSCustomObject]@{})
    }
    Set-Property $Data.intl "app_locale" "en-US"
    $Changed = Set-ExistingEligibility $Data
    Write-JsonAtomic $Path $Data
    return $Changed
}

function Set-Preferences([string]$Path) {
    $Data = Read-JsonObject $Path
    if ($null -eq $Data.PSObject.Properties["intl"] -or $null -eq $Data.intl) {
        Set-Property $Data "intl" ([PSCustomObject]@{})
    }
    Set-Property $Data.intl "selected_languages" $Languages
    Set-Property $Data.intl "accept_languages" $Languages
    $Changed = Set-ExistingEligibility $Data
    Write-JsonAtomic $Path $Data
    return $Changed
}

function Confirm-ChromeClose {
    if ($Yes) {
        return
    }
    Write-Host "操作将强制关闭全部 Chrome 窗口。请先保存网页表单、下载和在线编辑内容。"
    $Answer = Read-Host "输入 YES 继续"
    if ($Answer -cne "YES") {
        throw "操作已取消。"
    }
}

function Invoke-Enable {
    $UserData = Get-ChromeUserData
    $ChromePath = Get-ChromeExecutable
    Confirm-ChromeClose
    Stop-Chrome
    $BackupPath = New-ConfigurationBackup $UserData
    $LocalState = Join-Path $UserData "Local State"
    if (-not (Test-Path -LiteralPath $LocalState -PathType Leaf)) {
        throw "未找到 Local State：$LocalState"
    }
    $Changed = Set-LocalState $LocalState $ChromePath
    $Profiles = Get-PreferenceFiles $UserData
    foreach ($Preferences in $Profiles) {
        $Changed += Set-Preferences $Preferences.FullName
    }
    $LauncherPath = New-DesktopShortcut $ChromePath
    Write-Host "配置已写入，备份目录：$BackupPath"
    Write-Host "已处理配置文件：$($Profiles.Count + 1)"
    Write-Host "已更新现有 is_glic_eligible 字段：$Changed"
    Write-Host "桌面快捷方式已创建：$ShortcutName"
    Write-Host "快捷方式启动器：$LauncherPath"
    if (-not $NoLaunch) {
        Start-Process -FilePath $ChromePath -ArgumentList $ChromeFlags
        Write-Host "Chrome 已使用诊断参数启动。"
    }
}

function Invoke-Restore {
    $Selected = if ($Backup) { [IO.Path]::GetFullPath($Backup) } else { Get-LatestBackup }
    $ManifestPath = Join-Path $Selected "manifest.json"
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "备份清单不存在：$ManifestPath"
    }
    $Manifest = Read-JsonObject $ManifestPath
    if ($null -eq $Manifest.files -or @($Manifest.files).Count -eq 0) {
        throw "备份清单不包含可恢复文件。"
    }
    Confirm-ChromeClose
    Stop-Chrome
    $Restored = 0
    foreach ($Entry in @($Manifest.files)) {
        $BackupFile = Join-Path $Selected $Entry.backup
        if (-not (Test-Path -LiteralPath $BackupFile -PathType Leaf)) {
            throw "备份文件不存在：$BackupFile"
        }
        New-Item -ItemType Directory -Path (Split-Path $Entry.source) -Force | Out-Null
        Copy-Item -LiteralPath $BackupFile -Destination $Entry.source -Force
        $Restored++
    }
    Write-Host "恢复完成，来源备份：$Selected"
    Write-Host "已恢复配置文件：$Restored"
}

function Show-Status {
    $UserData = Get-ChromeUserData
    $Data = Read-JsonObject (Join-Path $UserData "Local State")
    $Locale = if ($Data.intl) { $Data.intl.app_locale } else { "<未设置>" }
    Write-Host "Chrome 用户数据：$UserData"
    Write-Host "Variations 国家：$($Data.variations_country)"
    Write-Host "长期国家配置：$($Data.variations_permanent_consistency_country -join ', ')"
    Write-Host "界面语言：$Locale"
    Write-Host "Profile 数量：$(@(Get-PreferenceFiles $UserData).Count)"
    Write-Host "备份目录：$(Get-BackupRoot)"
    try { Write-Host "最新备份：$(Get-LatestBackup)" } catch { Write-Host "最新备份：无" }
}

function Show-Menu {
    Write-Host "Gemini in Chrome 配置工具"
    Write-Host "1. 启用并启动 Chrome"
    Write-Host "2. 恢复最新备份"
    Write-Host "3. 查看状态"
    Write-Host "4. 创建或刷新桌面快捷方式"
    Write-Host "5. 删除桌面快捷方式"
    Write-Host "0. 退出"
    switch ((Read-Host "请选择操作").Trim()) {
        "1" { return "Enable" }
        "2" { return "Restore" }
        "3" { return "Status" }
        "4" { return "Shortcut" }
        "5" { return "RemoveShortcut" }
        "0" { return "Exit" }
        default { throw "无效选项。" }
    }
}

try {
    Assert-Windows
    if ($Action -eq "Menu") {
        $Action = Show-Menu
    }
    switch ($Action) {
        "Enable" { Invoke-Enable }
        "Restore" { Invoke-Restore }
        "Status" { Show-Status }
        "Shortcut" {
            $LauncherPath = New-DesktopShortcut (Get-ChromeExecutable)
            Write-Host "桌面快捷方式已创建：$ShortcutName"
            Write-Host "快捷方式启动器：$LauncherPath"
        }
        "RemoveShortcut" { Remove-DesktopShortcut }
        "Exit" { exit 0 }
    }
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}

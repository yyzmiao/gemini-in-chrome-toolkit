#!/usr/bin/env python3
"""Configure, diagnose, and restore Gemini in Chrome settings on Windows."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

COUNTRY = "us"
LANGUAGES = "en-US,en"
CHROME_FLAGS = (
    "--variations-override-country=us",
    "--disable-features=GlicCountryFiltering",
)


def require_windows() -> None:
    if os.name != "nt":
        raise RuntimeError("该工具仅支持 Windows。")


def user_data_dir() -> Path:
    local_app_data = os.environ.get("LOCALAPPDATA")
    if not local_app_data:
        raise RuntimeError("未找到 LOCALAPPDATA 环境变量。")
    path = Path(local_app_data) / "Google" / "Chrome" / "User Data"
    if not path.exists():
        raise FileNotFoundError(f"未找到 Chrome 用户数据目录：{path}")
    return path


def chrome_executable() -> Path:
    roots = [
        os.environ.get("PROGRAMFILES"),
        os.environ.get("PROGRAMFILES(X86)"),
        os.environ.get("LOCALAPPDATA"),
    ]
    candidates = [
        Path(root) / "Google/Chrome/Application/chrome.exe"
        for root in roots
        if root
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise FileNotFoundError("未找到 Chrome 可执行文件。")


def backup_root() -> Path:
    home = Path.home()
    documents = home / "Documents"
    base = documents if documents.exists() else home
    return base / "GeminiInChromeToolkit" / "backups"


def preference_files(data_dir: Path) -> list[Path]:
    files: list[Path] = []
    for directory in data_dir.iterdir():
        if not directory.is_dir():
            continue
        if directory.name == "Default" or directory.name.startswith("Profile "):
            preferences = directory / "Preferences"
            if preferences.is_file():
                files.append(preferences)
    return sorted(files)


def stop_chrome() -> None:
    subprocess.run(
        ["taskkill", "/IM", "chrome.exe", "/F"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    for _ in range(20):
        result = subprocess.run(
            ["tasklist", "/FI", "IMAGENAME eq chrome.exe", "/NH"],
            capture_output=True,
            text=True,
            check=False,
        )
        if "chrome.exe" not in result.stdout.lower():
            return
        time.sleep(0.25)
    raise RuntimeError("Chrome 进程未能在规定时间内退出。")


def load_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)
    if not isinstance(data, dict):
        raise ValueError(f"JSON 根节点不是对象：{path}")
    return data


def write_json_atomic(path: Path, data: dict[str, Any]) -> None:
    descriptor, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temp_path = Path(temp_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(data, handle, ensure_ascii=False, separators=(",", ":"))
        os.replace(temp_path, path)
    except Exception:
        temp_path.unlink(missing_ok=True)
        raise


def update_existing_eligibility(node: Any) -> int:
    changed = 0
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "is_glic_eligible":
                if value is not True:
                    node[key] = True
                    changed += 1
            else:
                changed += update_existing_eligibility(value)
    elif isinstance(node, list):
        for value in node:
            changed += update_existing_eligibility(value)
    return changed


def create_backup(data_dir: Path) -> Path:
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")[:-3]
    destination = backup_root() / timestamp
    destination.mkdir(parents=True, exist_ok=False)

    targets = [data_dir / "Local State", *preference_files(data_dir)]
    entries: list[dict[str, str]] = []
    for source in targets:
        if not source.is_file():
            continue
        relative = source.relative_to(data_dir)
        backup_file = destination / relative
        backup_file.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, backup_file)
        entries.append({"source": str(source), "backup": str(relative)})

    manifest = {
        "format": 1,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "user_data_dir": str(data_dir),
        "files": entries,
    }
    (destination / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return destination


def latest_backup() -> Path:
    root = backup_root()
    candidates = sorted(
        (path for path in root.glob("*") if (path / "manifest.json").is_file()),
        reverse=True,
    ) if root.exists() else []
    if not candidates:
        raise FileNotFoundError(f"未找到可用备份：{root}")
    return candidates[0]


def chrome_version(executable: Path, local_state: dict[str, Any]) -> str:
    existing = local_state.get("variations_permanent_consistency_country")
    if isinstance(existing, list) and existing and isinstance(existing[0], str):
        return existing[0]
    try:
        escaped_path = str(executable).replace("'", "''")
        command = [
            "powershell.exe",
            "-NoProfile",
            "-Command",
            f"(Get-Item -LiteralPath '{escaped_path}').VersionInfo.ProductVersion",
        ]
        result = subprocess.run(command, capture_output=True, text=True, check=True)
        version = result.stdout.strip()
        if version:
            return version
    except (OSError, subprocess.SubprocessError):
        pass
    return "0.0.0.0"


def configure_local_state(path: Path, executable: Path) -> int:
    data = load_json(path)
    data["variations_country"] = COUNTRY
    data["variations_permanent_consistency_country"] = [
        chrome_version(executable, data),
        COUNTRY,
    ]
    intl = data.setdefault("intl", {})
    if not isinstance(intl, dict):
        intl = {}
        data["intl"] = intl
    intl["app_locale"] = "en-US"
    eligibility_changes = update_existing_eligibility(data)
    write_json_atomic(path, data)
    return eligibility_changes


def configure_preferences(path: Path) -> int:
    data = load_json(path)
    intl = data.setdefault("intl", {})
    if not isinstance(intl, dict):
        intl = {}
        data["intl"] = intl
    intl["selected_languages"] = LANGUAGES
    intl["accept_languages"] = LANGUAGES
    eligibility_changes = update_existing_eligibility(data)
    write_json_atomic(path, data)
    return eligibility_changes


def confirm_close(assume_yes: bool) -> None:
    if assume_yes:
        return
    print("操作将强制关闭全部 Chrome 窗口。请先保存网页表单、下载和在线编辑内容。")
    answer = input("输入 YES 继续：").strip()
    if answer != "YES":
        raise RuntimeError("操作已取消。")


def enable(assume_yes: bool, no_launch: bool) -> None:
    data_dir = user_data_dir()
    executable = chrome_executable()
    confirm_close(assume_yes)
    stop_chrome()
    backup = create_backup(data_dir)

    local_state = data_dir / "Local State"
    if not local_state.is_file():
        raise FileNotFoundError(f"未找到 Local State：{local_state}")

    eligibility_changes = configure_local_state(local_state, executable)
    profiles = preference_files(data_dir)
    for preferences in profiles:
        eligibility_changes += configure_preferences(preferences)

    print(f"配置已写入，备份目录：{backup}")
    print(f"已处理配置文件：{len(profiles) + 1}")
    print(f"已更新现有 is_glic_eligible 字段：{eligibility_changes}")
    if not no_launch:
        subprocess.Popen([str(executable), *CHROME_FLAGS], close_fds=True)
        print("Chrome 已使用诊断参数启动。")


def restore(backup: Path | None, assume_yes: bool) -> None:
    selected = backup.resolve() if backup else latest_backup()
    manifest_path = selected / "manifest.json"
    if not manifest_path.is_file():
        raise FileNotFoundError(f"备份清单不存在：{manifest_path}")
    manifest = load_json(manifest_path)
    files = manifest.get("files")
    if not isinstance(files, list) or not files:
        raise ValueError("备份清单不包含可恢复文件。")

    confirm_close(assume_yes)
    stop_chrome()
    restored = 0
    for entry in files:
        if not isinstance(entry, dict):
            continue
        source = entry.get("source")
        backup_name = entry.get("backup")
        if not isinstance(source, str) or not isinstance(backup_name, str):
            continue
        backup_file = selected / backup_name
        destination = Path(source)
        if not backup_file.is_file():
            raise FileNotFoundError(f"备份文件不存在：{backup_file}")
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(backup_file, destination)
        restored += 1
    print(f"恢复完成，来源备份：{selected}")
    print(f"已恢复配置文件：{restored}")


def status() -> None:
    data_dir = user_data_dir()
    local_state_path = data_dir / "Local State"
    data = load_json(local_state_path)
    intl = data.get("intl") if isinstance(data.get("intl"), dict) else {}
    print(f"Chrome 用户数据：{data_dir}")
    print(f"Variations 国家：{data.get('variations_country', '<未设置>')}")
    print(f"长期国家配置：{data.get('variations_permanent_consistency_country', '<未设置>')}")
    print(f"界面语言：{intl.get('app_locale', '<未设置>')}")
    print(f"Profile 数量：{len(preference_files(data_dir))}")
    root = backup_root()
    print(f"备份目录：{root}")
    try:
        print(f"最新备份：{latest_backup()}")
    except FileNotFoundError:
        print("最新备份：无")


def menu() -> str:
    print("Gemini in Chrome 配置工具")
    print("1. 启用并启动 Chrome")
    print("2. 恢复最新备份")
    print("3. 查看状态")
    print("0. 退出")
    choice = input("请选择操作：").strip()
    return {"1": "enable", "2": "restore", "3": "status", "0": "exit"}.get(choice, "")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Gemini in Chrome 配置、诊断与恢复工具")
    subparsers = parser.add_subparsers(dest="action")

    enable_parser = subparsers.add_parser("enable", help="备份配置、写入设置并启动 Chrome")
    enable_parser.add_argument("--yes", action="store_true", help="跳过关闭 Chrome 的确认")
    enable_parser.add_argument("--no-launch", action="store_true", help="写入配置后不启动 Chrome")

    restore_parser = subparsers.add_parser("restore", help="恢复指定或最新备份")
    restore_parser.add_argument("--backup", type=Path, help="指定备份目录")
    restore_parser.add_argument("--yes", action="store_true", help="跳过关闭 Chrome 的确认")

    subparsers.add_parser("status", help="显示当前配置和备份状态")
    return parser


def main() -> int:
    try:
        require_windows()
        parser = build_parser()
        args = parser.parse_args()
        action = args.action or menu()
        if action == "exit":
            return 0
        if action == "enable":
            enable(getattr(args, "yes", False), getattr(args, "no_launch", False))
        elif action == "restore":
            restore(getattr(args, "backup", None), getattr(args, "yes", False))
        elif action == "status":
            status()
        else:
            parser.print_help()
            return 2
        return 0
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as error:
        print(f"错误：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())

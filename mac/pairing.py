#!/usr/bin/env python3
"""車上K歌・配對碼

同一個 Wi-Fi 裡的裝置，要先輸入這台 Mac 的 6 位數配對碼，才能使用 Mac 上的伺服器。
配對成功後，手機會拿到一把很長的隨機金鑰（存在 iPhone 的鑰匙圈），之後每次連線都帶著它。
Mac 只存金鑰的 SHA-256 雜湊值，不存金鑰本身。配對碼連續輸錯 10 次，會暫停配對 15 分鐘。

設定檔在 ~/Library/Application Support/CarKaraoke/pairing.json（只有自己的帳號能讀），
不在 CarKaraoke 資料夾裡，所以把程式分享給朋友時，不會連配對碼一起分享出去。

  python pairing.py           顯示配對碼和已經配對的手機
  python pairing.py --code    只顯示配對碼
  python pairing.py --reset   換一組新的配對碼，所有手機都要重新配對

只用 Python 標準函式庫。
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import secrets
import sys
import threading
import time
from pathlib import Path

CONFIG_DIR = Path(os.environ.get("CARKARAOKE_CONFIG") or Path.home() / "Library" / "Application Support" / "CarKaraoke")
MAX_DEVICES = 20
MAX_FAILS = 10
LOCK_SECONDS = 15 * 60


def _digest(key: str) -> str:
    return hashlib.sha256(key.encode("utf-8", "replace")).hexdigest()


class Pairing:
    def __init__(self, folder: Path = CONFIG_DIR) -> None:
        self.path = folder / "pairing.json"
        self.lock = threading.Lock()
        self.mtime: float | None = None
        self.data: dict = {}
        self.fails: list[float] = []
        with self.lock:
            self._load()

    # ------------------------------------------------------------ 檔案

    def _load(self) -> None:
        """檔案改過（例如用「配對碼.command」重設）就重新讀；不見了或壞掉就產生新的。呼叫時要持有 lock"""
        try:
            mtime = self.path.stat().st_mtime
            if mtime == self.mtime:
                return
            data = json.loads(self.path.read_text(encoding="utf-8"))
            if not (isinstance(data, dict) and isinstance(data.get("id"), str)
                    and re.fullmatch(r"[0-9]{6}", str(data.get("code"))) and isinstance(data.get("devices"), list)):
                raise ValueError
            self.data, self.mtime = data, mtime
        except (OSError, ValueError):
            self._fresh()

    def _fresh(self) -> None:
        self.data = {"id": secrets.token_hex(8), "code": f"{secrets.randbelow(10 ** 6):06d}", "devices": []}
        self._save()

    def _save(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_name(self.path.name + ".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)  # 只有自己的帳號能讀寫
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(self.data, f, ensure_ascii=False, indent=1)
        os.chmod(tmp, 0o600)
        os.replace(tmp, self.path)
        self.mtime = self.path.stat().st_mtime

    # ------------------------------------------------------------ 給伺服器用

    @property
    def server_id(self) -> str:
        """這台 Mac 的配對編號（重設配對時會換）：手機用它記住哪一把金鑰是給哪一台 Mac"""
        with self.lock:
            self._load()
            return self.data["id"]

    def check(self, key: str | None) -> bool:
        """手機帶來的金鑰是不是配對過的"""
        if not key:
            return False
        digest = _digest(key)
        with self.lock:
            self._load()
            return any(hmac.compare_digest(digest, str(d.get("hash", ""))) for d in self.data["devices"])

    def pair(self, code: str, device: str) -> tuple[str | None, str | None]:
        """輸入配對碼 → (金鑰, None)；失敗 → (None, 給使用者看的原因)"""
        code = re.sub(r"[^0-9]", "", code or "")  # 只留半形數字（容許中間有空白）
        now = time.time()
        with self.lock:
            self._load()
            self.fails = [t for t in self.fails if now - t < LOCK_SECONDS]
            if len(self.fails) >= MAX_FAILS:
                wait = int(LOCK_SECONDS - (now - self.fails[0])) // 60 + 1
                return None, f"配對碼輸錯太多次了，請 {wait} 分鐘後再試"
            if not hmac.compare_digest(code.encode(), self.data["code"].encode()):
                self.fails.append(now)
                left = MAX_FAILS - len(self.fails)
                if left == 0:
                    return None, f"配對碼不對。輸錯太多次了，請 {LOCK_SECONDS // 60} 分鐘後再試"
                hint = f"（再錯 {left} 次要等 {LOCK_SECONDS // 60} 分鐘）" if left <= 3 else ""
                return None, "配對碼不對，請再看一次 Mac 上的配對碼" + hint
            key = secrets.token_urlsafe(32)
            name = re.sub(r"[\x00-\x1f]", "", device or "")[:60] or "手機"
            self.data["devices"].append({"name": name, "hash": _digest(key), "added": int(now)})
            del self.data["devices"][:-MAX_DEVICES]
            self.fails.clear()
            self._save()
            return key, None

    # ------------------------------------------------------------ 給「配對碼.command」用

    def reset(self) -> None:
        with self.lock:
            self._fresh()

    def summary(self) -> tuple[str, list[dict]]:
        with self.lock:
            self._load()
            return self.data["code"], list(self.data["devices"])


def pretty(code: str) -> str:
    return f"{code[:3]} {code[3:]}"


def main() -> int:
    p = Pairing()
    if "--reset" in sys.argv[1:]:
        p.reset()
        print("已經換了一組新的配對碼。之前配對過的手機都要重新輸入。")
    code, devices = p.summary()
    if "--code" in sys.argv[1:]:
        print(pretty(code))
        return 0
    print(f"這台 Mac 的配對碼：{pretty(code)}")
    print("手機第一次連到這台 Mac 時，在車上K歌輸入這 6 位數字（每支手機只要輸入一次）。")
    if devices:
        print(f"\n已經配對的手機（{len(devices)} 支）：")
        for d in devices:
            print(f"  - {d.get('name') or '手機'}（{time.strftime('%Y-%m-%d %H:%M', time.localtime(d.get('added', 0)))} 配對）")
    else:
        print("\n還沒有配對任何手機。")
    return 0


if __name__ == "__main__":
    sys.exit(main())

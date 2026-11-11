#!/usr/bin/env python3
"""車上K歌・伴唱伺服器（在家裡的 Mac 上自動執行）

iPhone 貼上 YouTube 連結 → 這台 Mac 下載＋去人聲（karaoke.py，Demucs 離線）→ 手機自動下載回去開始唱。
貼 Spotify 歌曲連結也可以：Mac 讀出歌名、歌手、長度，在 YouTube 找同一首（spotify.py）。
貼 Spotify 播放清單／專輯：每一首各排一個工作，手機照清單的順序建立播放清單。
Mac 不留歌：手機收好一首歌就通知 Mac，Mac 把那首的檔案刪掉，只留一筆紀錄（.delivered.json）。
之後再點同一首，手機上還有就不用重做；手機上也刪了，手機會要 Mac 重做（redo）。

只用 Python 標準函式庫，不連任何 AI 服務、不花任何 token。
只接受同一個 Wi-Fi（或 Tailscale）裡的裝置連線，而且要先配對（pairing.py）：
手機輸入 Mac 的 6 位數配對碼 → 拿到金鑰 → 之後每個要求都在 X-CarKaraoke-Key 標頭帶著金鑰。

  GET  /ping                 伺服器資訊（不用金鑰；"paired"＝帶來的金鑰是不是配對過的）
  POST /pair   {"code": "123456", "device": "手機名稱"}  配對 → {"key": 金鑰}（不用金鑰）
  以下都要帶金鑰，沒帶或不對 → 401
  POST /jobs   {"url": ...}  新增一首（YouTube／Spotify 連結，或含連結的分享文字）
                             Spotify 播放清單／專輯 → 回傳 {"type": "list", ...}（每首歌的進度）
                             "redo": true（播放清單：要重做的 Spotify 歌曲 ID 陣列）＝已經傳過、手機上又刪掉的歌重做
  GET  /lists/<id>           一個播放清單的進度
  POST /lists/<id>/cancel    停止匯入（還在排隊的歌不做了）
  GET  /jobs                 最近的工作
  GET  /jobs/<id>            一個工作的進度
  GET  /songs                Mac 上做好、還沒傳到手機的歌
  GET  /files/<檔名>          下載伴唱／人聲檔／歌詞（.lrc）
  POST /received {"songs": [伴唱檔名, ...]}  手機收好了 → Mac 刪掉這些歌的檔案
工作的 "delivered": true ＝這首已經傳到手機、Mac 上的檔案刪掉了（手機上沒有的話用 redo 重做）
"""
from __future__ import annotations

import ipaddress
import json
import os
import queue
import re
import shutil
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))  # 同資料夾的 spotify.py（用 python -I 執行時預設不會找）
import spotify  # noqa: E402
import pairing  # noqa: E402
SONGS = Path(os.environ.get("CARKARAOKE_SONGS") or HERE.parent / "songs").resolve()
PORT = int(os.environ.get("CARKARAOKE_PORT") or 8765)
PYTHON = HERE / ".venv" / "bin" / "python"
CONVERTER = HERE / "karaoke.py"
SERVICE_TYPE = "_carkaraoke._tcp"
API_VERSION = 2  # 2：要配對
KEY_HEADER = "X-CarKaraoke-Key"
INST, VOCAL, LRC = ".伴唱.m4a", ".人聲.m4a", ".lrc"
DELIVERED = ".delivered.json"  # 已經傳到手機、Mac 上刪掉的歌（每首約 300 bytes）
YT_HOSTS = {"youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com", "youtu.be", "www.youtu.be"}
TAILSCALE = ipaddress.ip_network("100.64.0.0/10")
JOB_TIMEOUT = 30 * 60
MAX_ACTIVE = 300  # 排隊＋處理中的歌最多幾首（避免同一個網路裡有人一直丟工作把 Mac 塞爆）
MIN_FREE = 2 * 1024 ** 3  # Mac 硬碟至少要剩這麼多才開始做下一首
KEEP_JOBS = 300  # 播放清單一次最多 100 首
ACTIVE = ("queued", "searching", "downloading", "separating")
SPOTIFY_TAG = re.compile(r"spotify:track:([A-Za-z0-9]{22})")
PROGRESS_RE = re.compile(r"^\s*(\d{1,3})%\|")  # Demucs 的進度條
YTDLP_ERRORS = [  # yt-dlp 的英文錯誤 → 看得懂的說明
    ("not a bot", "YouTube 暫時擋下載，請過幾分鐘再試；一直不行就在 Mac 執行 brew upgrade yt-dlp"),
    ("confirm your age", "有年齡限制的影片無法下載"),
    ("Private video", "這是私人影片，無法下載"),
    ("members-only", "頻道會員限定影片，無法下載"),
    ("Join this channel", "頻道會員限定影片，無法下載"),
    ("live event will begin", "直播還沒開始"),
    ("not available in your country", "這支影片在台灣看不到"),
    ("unavailable", "影片無法播放（可能已刪除或設為私人）"),
]


def log(msg: str) -> None:
    print(time.strftime("%m-%d %H:%M:%S"), msg, flush=True)


def _id_prefix(s: str | None) -> str | None:
    m = re.match(r"([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])", s or "")
    return m.group(1) if m else None


def youtube_id(text: str) -> str | None:
    """從連結（或 YouTube「分享」複製出來、夾雜文字的內容）取出影片 ID；不是 YouTube 影片就回傳 None。"""
    m = re.search(r"https?://[^\s<>\"'）」】]+", text or "")
    if not m:
        return None
    u = urllib.parse.urlsplit(m.group(0))
    host = (u.hostname or "").lower()
    if host not in YT_HOSTS:
        return None
    parts = [p for p in u.path.split("/") if p]
    if host.endswith("youtu.be"):
        return _id_prefix(parts[0] if parts else None)
    if parts and parts[0] in ("shorts", "live", "embed", "v") and len(parts) > 1:
        return _id_prefix(parts[1])
    if parts == ["watch"]:
        return _id_prefix(urllib.parse.parse_qs(u.query).get("v", [None])[0])
    return None


def _name(sp: dict | None) -> tuple[str, str] | None:
    """Spotify 歌曲的（歌名, 歌手）：檔名就是用這兩個取的。同一首歌在專輯、播放清單裡的 Spotify ID 不一樣、
    在 YouTube 找到的影片也可能不同，用歌名＋歌手才認得出來"""
    if not sp or not sp.get("title") or not sp.get("artist"):
        return None
    return spotify.display_title(sp["title"]).casefold(), sp["artist"].casefold()


def _same(rec: dict, video_id: str | None, spotify_id: str | None, name: tuple[str, str] | None) -> bool:
    if (video_id and rec.get("videoId") == video_id) or (spotify_id and rec.get("spotifyId") == spotify_id):
        return True
    return bool(name and rec.get("title") and rec.get("artist")
                and (rec["title"].casefold(), rec["artist"].casefold()) == name)


# ---------------------------------------------------------------- Mac 上已經做好的歌

class SongIndex:
    """掃 songs 資料夾；從伴唱檔的 comment 標籤（原始 YouTube 網址）認出是哪支影片，避免重複處理。"""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.cache: dict[str, tuple[float, dict]] = {}

    def _probe(self, path: Path) -> dict:
        tags = {}
        try:
            out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format_tags=title,artist,comment",
                                  "-of", "json", str(path)], capture_output=True, text=True, timeout=20).stdout
            tags = {k.lower(): v for k, v in json.loads(out).get("format", {}).get("tags", {}).items()}
        except Exception:
            pass
        base = path.name[: -len(INST)]
        title, artist = tags.get("title"), tags.get("artist")
        if not title:
            title, _, artist = base.partition(" - ")
        sp = SPOTIFY_TAG.search(tags.get("comment", ""))
        return {"base": base, "title": title, "artist": artist or None,
                "videoId": youtube_id(tags.get("comment", "")), "spotifyId": sp.group(1) if sp else None}

    def songs(self) -> list[dict]:
        with self.lock:
            out, alive = [], set()
            for p in SONGS.glob("*" + INST):
                try:
                    st = p.stat()
                except OSError:
                    continue
                alive.add(p.name)
                cached = self.cache.get(p.name)
                if not cached or cached[0] != st.st_mtime:
                    cached = (st.st_mtime, self._probe(p))
                    self.cache[p.name] = cached
                vocal = SONGS / (p.name[: -len(INST)] + VOCAL)
                lrc = SONGS / (p.name[: -len(INST)] + LRC)
                try:
                    lrc_size = lrc.stat().st_size
                except OSError:
                    lrc_size = None
                out.append({**cached[1], "inst": p.name, "vocals": vocal.name if vocal.exists() else None,
                            "lyrics": lrc.name if lrc_size is not None else None,
                            "lyricsSize": lrc_size,  # 歌詞更新（例如補上逐字時間）時手機重新下載
                            "size": st.st_size + (vocal.stat().st_size if vocal.exists() else 0),
                            "modified": st.st_mtime})
            for gone in set(self.cache) - alive:
                del self.cache[gone]
        return sorted(out, key=lambda s: s["modified"], reverse=True)

    def find(self, video_id: str | None = None, spotify_id: str | None = None,
             name: tuple[str, str] | None = None) -> dict | None:
        return next((s for s in self.songs() if _same(s, video_id, spotify_id, name)), None)

    def release(self, names: list[str], sent: "Delivered") -> tuple[int, int]:
        """手機收好了：記下這幾首、刪掉 Mac 上的檔案。回傳（刪了幾首，省下幾 bytes）"""
        wanted = set(names)
        songs = [s for s in self.songs() if s["inst"] in wanted]
        if not songs:
            return 0, 0
        sent.add(songs)  # 先記下來再刪：之後再點同一首才知道手機上有
        freed = 0
        for s in songs:
            for name in (s["inst"], s["vocals"], s["lyrics"]):
                if not name:
                    continue
                try:
                    p = SONGS / name
                    size = p.stat().st_size
                    p.unlink()
                    freed += size
                except OSError:
                    pass
        return len(songs), freed


class Delivered:
    """已經傳到手機的歌：Mac 上的檔案刪掉了，只留歌名、YouTube／Spotify ID 和檔名。"""
    MAX = 5000

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.path = SONGS / DELIVERED
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = []
        self.items: list[dict] = [d for d in data if isinstance(d, dict)] if isinstance(data, list) else []

    def find(self, video_id: str | None = None, spotify_id: str | None = None,
             name: tuple[str, str] | None = None) -> dict | None:
        with self.lock:
            return next((d for d in reversed(self.items) if _same(d, video_id, spotify_id, name)), None)

    def add(self, songs: list[dict]) -> None:
        keys = ("base", "title", "artist", "videoId", "spotifyId", "inst", "vocals", "lyrics")
        recs = [{**{k: s.get(k) for k in keys}, "delivered": int(time.time())} for s in songs]
        bases = {r["base"] for r in recs}
        with self.lock:
            self.items = [d for d in self.items if d.get("base") not in bases] + recs
            del self.items[:-self.MAX]
            tmp = self.path.with_name(DELIVERED + ".tmp")
            tmp.write_text(json.dumps(self.items, ensure_ascii=False), encoding="utf-8")
            tmp.replace(self.path)


def _gone(job: dict) -> bool:
    """做好了，但檔案已經不在 Mac 上（傳到手機後刪掉了）"""
    return job.get("status") == "done" and bool(job.get("inst")) and not (SONGS / job["inst"]).exists()


# ---------------------------------------------------------------- 排隊處理

class Jobs:
    def __init__(self, index: SongIndex, sent: Delivered) -> None:
        self.index = index
        self.sent = sent
        self.lock = threading.Lock()
        self.jobs: dict[str, dict] = {}
        self.order: list[str] = []
        self.lists: dict[str, dict] = {}  # 匯入的 Spotify 播放清單／專輯
        self.pending: queue.Queue[str] = queue.Queue()
        self.proc: subprocess.Popen | None = None
        threading.Thread(target=self._worker, name="converter", daemon=True).start()

    def _active(self, key: str, value: str) -> dict | None:
        with self.lock:
            for jid in reversed(self.order):
                j = self.jobs[jid]
                if j[key] == value and j["status"] in ACTIVE:
                    return self._view(j)
        return None

    def submit_list(self, info: dict, redo: set[str] = frozenset()) -> dict:
        """Spotify 播放清單／專輯：每一首各排一個工作（已經有的、正在做的不重複）。
        redo：已經傳過、手機上又沒有的歌（Spotify 歌曲 ID）"""
        tracks = []
        for t in info["tracks"]:
            view = self._active("spotifyId", t["id"]) or self.submit(sp={**t, "fromList": True},
                                                                     redo=t["id"] in redo)
            tracks.append({"spotifyId": t["id"], "title": t["title"], "artist": t.get("artist"), "job": view["id"]})
        rec = {"id": uuid.uuid4().hex[:12], "kind": info["kind"], "listId": info["id"], "name": info["name"],
               "owner": info.get("owner"), "total": info.get("total", len(tracks)), "tracks": tracks,
               "created": time.time()}
        with self.lock:
            self.lists[rec["id"]] = rec
            while len(self.lists) > 20:
                self.lists.pop(next(iter(self.lists)))
        log(f"匯入{spotify.KIND_NAMES[info['kind']]}「{info['name']}」：{len(tracks)} 首")
        return self.list_view(rec["id"])

    def list_view(self, lid: str) -> dict | None:
        with self.lock:
            rec = self.lists.get(lid)
            if not rec:
                return None
            jobs = {t["job"]: self._view(self.jobs[t["job"]]) for t in rec["tracks"] if t["job"] in self.jobs}
        made = None
        tracks = []
        for t in rec["tracks"]:
            j = jobs.get(t["job"])
            if j is None:  # 很久以前的工作紀錄已經清掉：看 Mac 上有沒有這首、是不是已經傳到手機
                if made is None:
                    made = {s["spotifyId"]: s for s in self.index.songs() if s["spotifyId"]}
                song = made.get(t["spotifyId"]) or self.sent.find(spotify_id=t["spotifyId"])
                j = {"status": "done", "inst": song["inst"], "vocals": song["vocals"], "lyrics": song["lyrics"]} if song \
                    else {"status": "failed", "error": "請重新匯入"}
            tracks.append({"spotifyId": t["spotifyId"], "title": j.get("title") or t["title"],
                           "artist": j.get("artist") or t["artist"], "status": j["status"],
                           "progress": j.get("progress"), "ahead": j.get("ahead"), "inst": j.get("inst"),
                           "vocals": j.get("vocals"), "lyrics": j.get("lyrics"), "error": j.get("error"),
                           "delivered": _gone(j)})
        return {"type": "list", "id": rec["id"], "kind": rec["kind"], "listId": rec["listId"], "name": rec["name"],
                "owner": rec["owner"], "total": rec["total"], "tracks": tracks}

    def cancel_list(self, lid: str) -> dict | None:
        with self.lock:
            rec = self.lists.get(lid)
            if not rec:
                return None
            n = 0
            for t in rec["tracks"]:
                j = self.jobs.get(t["job"])
                if j and j["status"] == "queued":
                    j.update(status="canceled", updated=time.time())
                    n += 1
        log(f"停止匯入「{rec['name']}」：{n} 首不做了")
        return self.list_view(lid)

    def submit_spotify(self, sid: str, redo: bool = False) -> dict:
        """Spotify 歌曲：已經在做／做好了就不用再查 Spotify；否則讀歌名（查不到會丟 SpotifyError）"""
        view = self._active("spotifyId", sid)
        if view:
            return view
        found = self.index.find(spotify_id=sid) or self.sent.find(spotify_id=sid)
        if found and redo and not found.get("videoId"):
            found = None  # 不知道上次用哪支 YouTube 影片：重新找
        info = {"id": sid, "title": found["title"], "artist": found["artist"]} if found else spotify.track_info(sid)
        return self.submit(sp=info, redo=redo)

    def submit(self, video_id: str | None = None, sp: dict | None = None, redo: bool = False) -> dict:
        """redo：這首已經傳到手機、Mac 上刪掉了，但手機上又沒有了 → 重做"""
        view = self._active("videoId", video_id) if video_id else None
        if view:
            return view
        sid, name = (sp["id"] if sp else None), _name(sp)
        found = self.index.find(video_id, sid, name)
        sent = None if found else self.sent.find(video_id, sid, name)
        redone = bool(sent and redo)
        if redone:  # 上次找到的 YouTube 影片、歌名直接用，檔名才會一樣
            video_id = video_id or sent.get("videoId")
            if sp:
                sp = {**sp, "title": sent.get("title") or sp["title"], "artist": sent.get("artist") or sp.get("artist")}
            sent = None
            if video_id and (view := self._active("videoId", video_id)):
                return view
        done = found or sent
        now = time.time()
        job = {"id": uuid.uuid4().hex[:12], "videoId": video_id, "spotifyId": sp["id"] if sp else None, "spotify": sp,
               "url": f"https://www.youtube.com/watch?v={video_id}" if video_id
               else f"https://open.spotify.com/track/{sp['id']}",
               "status": "queued", "title": sp["title"] if sp else None, "artist": sp.get("artist") if sp else None,
               "inst": None, "vocals": None, "lyrics": None,
               "error": None, "existing": False, "progress": None, "created": now, "updated": now, "redo": redo}
        if done:
            job.update(status="done", existing=True, title=done["title"], artist=done["artist"],
                       inst=done["inst"], vocals=done["vocals"], lyrics=done["lyrics"])
        with self.lock:
            self.jobs[job["id"]] = job
            self.order.append(job["id"])
            while len(self.order) > KEEP_JOBS:
                old = self.order[0]
                if self.jobs[old]["status"] in ACTIVE:
                    break
                self.order.pop(0)
                del self.jobs[old]
            view = self._view(job)
        if not done:
            self.pending.put(job["id"])
            log(f"＋ 排入：{job['url']}" + ("（已經傳過，手機上沒有了：重做）" if redone else ""))
        else:
            log(f"＝ 已經有了：{done['inst']}" + ("（已經傳到手機）" if sent else ""))
        return view

    def get(self, jid: str) -> dict | None:
        with self.lock:
            j = self.jobs.get(jid)
            return self._view(j) if j else None

    def all(self) -> list[dict]:
        with self.lock:
            return [self._view(self.jobs[j]) for j in reversed(self.order)]

    def busy(self) -> bool:
        with self.lock:
            return any(j["status"] in ACTIVE for j in self.jobs.values())

    def full(self) -> bool:
        with self.lock:
            return sum(j["status"] in ACTIVE for j in self.jobs.values()) >= MAX_ACTIVE

    def _view(self, j: dict) -> dict:  # 呼叫時要持有 lock
        v = dict(j)
        v.pop("spotify", None)
        v["delivered"] = _gone(j)
        if j["status"] == "queued":
            v["ahead"] = sum(1 for o in self.order if self.jobs[o]["status"] in ACTIVE
                             and self.jobs[o]["created"] < j["created"])
        return v

    def _set(self, jid: str, **kw) -> None:
        with self.lock:
            self.jobs[jid].update(kw, updated=time.time())

    def _worker(self) -> None:
        while True:
            jid = self.pending.get()
            try:
                self._run(jid)
            except Exception as e:  # 不讓單一工作把整個伺服器弄掛
                self._set(jid, status="failed", error=f"內部錯誤：{e}")
                log(f"內部錯誤：{e!r}")

    def _run(self, jid: str) -> None:
        with self.lock:
            if self.jobs[jid]["status"] != "queued":
                return  # 停止匯入時取消了
            job = dict(self.jobs[jid])
        if job["spotify"] and not job["videoId"] and not self._find_youtube(jid, job):
            return
        with self.lock:
            job = dict(self.jobs[jid])
        name = _name(job["spotify"])
        found = self.index.find(job["videoId"], job["spotifyId"], name)  # 排隊期間可能已被別的工作做好
        if not found and not job["redo"]:  # 同一支 YouTube 影片（或同歌名＋歌手）以前傳到手機過
            found = self.sent.find(job["videoId"], None, name)
        if found:
            self._set(jid, status="done", existing=True, title=found["title"], artist=found["artist"],
                      inst=found["inst"], vocals=found["vocals"], lyrics=found["lyrics"])
            log(f"＝ 已經有了：{found['inst']}" + ("" if (SONGS / found["inst"]).exists() else "（已經傳到手機）"))
            return
        if shutil.disk_usage(SONGS).free < MIN_FREE:
            err = f"Mac 的硬碟空間不夠（剩不到 {MIN_FREE // 1024 ** 3} GB），請先清出一些空間"
            self._set(jid, status="failed", error=err)
            log(f"失敗：{err}")
            return
        self._set(jid, status="downloading", progress=None)
        t0 = time.time()
        log(f"開始：{job['url']}")
        # caffeinate -i：處理中不讓 Mac 進入閒置睡眠
        cmd = ["/usr/bin/caffeinate", "-i", str(PYTHON), "-I", str(CONVERTER), "--events", "-o", str(SONGS)]
        if job["spotify"]:  # 歌名、歌手用 Spotify 的
            sp = job["spotify"]
            cmd += [f"--spotify-id={sp['id']}", f"--title={spotify.display_title(sp['title'])}"]
            cmd += [f"--artist={sp['artist']}"] if sp.get("artist") else []
        cmd.append(job["url"])
        proc = subprocess.Popen(cmd, cwd=HERE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, encoding="utf-8", errors="replace", bufsize=1)
        self.proc = proc
        watchdog = threading.Timer(JOB_TIMEOUT, proc.kill)
        watchdog.start()
        tail: list[str] = []
        ytdlp_error = None
        result: dict = {}
        last_pct = -1
        try:
            for line in proc.stdout:
                line = line.rstrip("\n")
                if line.startswith("@@"):
                    try:
                        ev = json.loads(line[2:])
                    except ValueError:
                        continue
                    kind = ev.get("event")
                    if kind == "separating":
                        self._set(jid, status="separating", title=ev.get("title"), artist=ev.get("artist"))
                    elif kind == "done":
                        result = ev
                    elif kind == "failed":
                        result = {"error": ev.get("error")}
                elif m := PROGRESS_RE.match(line):
                    pct = min(int(m.group(1)), 100)
                    if pct != last_pct:
                        last_pct = pct
                        self._set(jid, progress=pct / 100)
                elif line.strip():
                    log("   " + line)
                    tail = (tail + [line.strip()])[-20:]
                    if line.startswith("ERROR:"):
                        ytdlp_error = next((msg for key, msg in YTDLP_ERRORS if key.lower() in line.lower()),
                                           None) or ytdlp_error
            code = proc.wait()
        finally:
            watchdog.cancel()
            self.proc = None
        if result.get("inst") and (SONGS / result["inst"]).exists():
            self._set(jid, status="done", title=result.get("title"), artist=result.get("artist"),
                      inst=result["inst"], vocals=result.get("vocals"), lyrics=result.get("lyrics"),
                      existing=bool(result.get("skipped")))
            log(f"完成（{time.time() - t0:.0f} 秒）：{result['inst']}")
        else:
            err = ytdlp_error or result.get("error") or next((t for t in reversed(tail) if t.startswith("錯誤：")), None) \
                or (tail[-1] if tail else f"轉檔程式結束代碼 {code}")
            if time.time() - t0 >= JOB_TIMEOUT:
                err = "處理太久（超過 30 分鐘）已停止"
            err = err.removeprefix("錯誤：").strip()[:300]
            self._set(jid, status="failed", error=err)
            log(f"失敗：{err}")

    def _find_youtube(self, jid: str, job: dict) -> bool:
        """Spotify 歌曲：在 YouTube 找同一首。找不到 → 工作失敗，回傳 False"""
        self._set(jid, status="searching")
        sp = job["spotify"]
        log(f"Spotify：{spotify.describe(sp)}，在 YouTube 找同一首")
        try:
            if sp.get("fromList"):  # 清單裡的歌手欄位是一串文字：重新讀這首歌的完整資料
                try:
                    sp = spotify.track_info(sp["id"], alt_names=True)
                except spotify.SpotifyError:
                    sp = spotify.add_alt_names(sp)
            else:
                sp = spotify.add_alt_names(sp)
            video, score, why = spotify.find_youtube(sp)
        except spotify.SpotifyError as e:
            self._set(jid, status="failed", error=str(e))
            log(f"失敗：{e}")
            return False
        vid = video["id"]
        log(f"   → YouTube：{video.get('title')}（{video.get('channel')}，{video.get('duration')} 秒，"
            f"{score:.1f} 分：{'、'.join(why)}）")
        self._set(jid, videoId=vid, url=f"https://www.youtube.com/watch?v={vid}", spotify=sp)
        return True

    def stop(self) -> None:
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()


# ---------------------------------------------------------------- HTTP

def allowed(host: str) -> bool:
    try:
        ip = ipaddress.ip_address(host.split("%")[0])
    except ValueError:
        return False
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip.is_private or ip.is_loopback or ip.is_link_local or (ip.version == 4 and ip in TAILSCALE)


class Handler(BaseHTTPRequestHandler):
    server_version = "CarKaraoke/1"
    protocol_version = "HTTP/1.1"
    timeout = 60  # 連線閒置太久就關掉（不讓佔著不放的連線把伺服器拖垮）
    jobs: Jobs
    index: SongIndex
    sent: Delivered
    pairing: pairing.Pairing

    def log_message(self, fmt, *args) -> None:  # 安靜一點，只記錄重要事件
        pass

    def _json(self, code: int, obj) -> None:
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _guard(self) -> bool:
        if allowed(self.client_address[0]):
            return True
        log(f"拒絕外部連線：{self.client_address[0]}")
        self._json(403, {"error": "只接受同一個網路裡的裝置"})
        return False

    def _paired(self) -> bool:
        """帶來的金鑰是配對過的；不是的話回 401（並關掉這條連線，沒讀的內容不會被當成下一個要求）"""
        if self.pairing.check(self.headers.get(KEY_HEADER)):
            return True
        self.close_connection = True
        self._json(401, {"error": "要先配對：在 App 輸入這台 Mac 的配對碼"
                                  "（在 Mac 上雙擊 CarKaraoke 資料夾裡的「配對碼.command」就會看到）"})
        return False

    def _body(self) -> dict | None:
        """讀 JSON 內容；格式不對就回 400，傳回 None"""
        try:
            n = int(self.headers.get("Content-Length") or 0)
            if not 0 < n <= 256 * 1024:
                raise ValueError
            body = json.loads(self.rfile.read(n).decode("utf-8"))
            if not isinstance(body, dict):
                raise ValueError
            return body
        except (ValueError, UnicodeDecodeError):
            self.close_connection = True
            self._json(400, {"error": "格式不對"})
            return None

    def do_GET(self) -> None:
        if not self._guard():
            return
        path = urllib.parse.urlsplit(self.path).path
        if path == "/ping":
            paired = self.pairing.check(self.headers.get(KEY_HEADER))
            info = {"app": "carkaraoke", "version": API_VERSION, "name": computer_name(),
                    "id": self.pairing.server_id, "pairing": True, "paired": paired}
            if paired:
                info.update(busy=self.jobs.busy(), songs=len(list(SONGS.glob("*" + INST))))
            return self._json(200, info)
        if not self._paired():
            return
        if path == "/jobs":
            self._json(200, self.jobs.all())
        elif path.startswith("/lists/"):
            view = self.jobs.list_view(path[len("/lists/"):])
            self._json(200, view) if view else self._json(404, {"error": "找不到這個播放清單（Mac 的伺服器可能重新啟動過）"})
        elif path.startswith("/jobs/"):
            job = self.jobs.get(path[len("/jobs/"):])
            self._json(200, job) if job else self._json(404, {"error": "找不到這個工作"})
        elif path == "/songs":
            self._json(200, self.index.songs())
        elif path.startswith("/files/"):
            self._file(urllib.parse.unquote(path[len("/files/"):]))
        else:
            self._json(404, {"error": "沒有這個功能"})

    def do_POST(self) -> None:
        if not self._guard():
            return
        path = urllib.parse.urlsplit(self.path).path
        if path == "/pair":
            return self._pair()
        if not self._paired():
            return
        if path.startswith("/lists/") and path.endswith("/cancel"):
            view = self.jobs.cancel_list(path[len("/lists/"):-len("/cancel")])
            return self._json(200, view) if view else self._json(404, {"error": "找不到這個播放清單"})
        if path not in ("/jobs", "/received"):
            return self._json(404, {"error": "沒有這個功能"})
        body = self._body()
        if body is None:
            return
        if path == "/received":
            names = [x for x in body.get("songs") or [] if isinstance(x, str) and _song_file(x) and x.endswith(INST)]
            count, freed = self.index.release(names, self.sent)
            if count:
                log(f"{count} 首已經傳到手機，Mac 上的檔案刪掉了（省下 {freed / 1e6:.0f} MB）")
            return self._json(200, {"removed": count, "freed": freed})
        if self.jobs.full():
            return self._json(503, {"error": f"Mac 上排隊的歌太多了（{MAX_ACTIVE} 首），請等前面的做完再加"})
        text = body.get("url")
        text = text if isinstance(text, str) else ""
        redo = body.get("redo")
        vid = youtube_id(text)
        if vid:
            return self._json(202, self.jobs.submit(vid, redo=redo is True))
        if spotify.find_link(text):
            try:
                kind, sid = spotify.ref(text)
                if kind == "track":
                    return self._json(202, self.jobs.submit_spotify(sid, redo=redo is True))
                ids = {x for x in redo if isinstance(x, str)} if isinstance(redo, list) else set()
                return self._json(202, self.jobs.submit_list(spotify.list_info(kind, sid), ids))
            except spotify.SpotifyError as e:
                return self._json(400, {"error": str(e)})
        self._json(400, {"error": "這不是 YouTube 或 Spotify 的歌曲連結"})

    def _pair(self) -> None:
        body = self._body()
        if body is None:
            return
        device = str(body.get("device") or "")
        key, err = self.pairing.pair(str(body.get("code") or ""), device)
        ip = self.client_address[0]
        if key:
            log(f"配對成功：{device[:60] or '手機'}（{ip}）")
            return self._json(200, {"key": key, "id": self.pairing.server_id, "name": computer_name()})
        locked = err.startswith("配對碼輸錯太多次")
        if not locked:
            log(f"配對碼輸入錯誤（{ip}）")
        self._json(429 if locked else 403, {"error": err})

    def _file(self, name: str) -> None:
        if not _song_file(name):
            return self._json(404, {"error": "沒有這個檔案"})
        p = SONGS / name
        if p.resolve().parent != SONGS or not p.is_file():
            return self._json(404, {"error": "沒有這個檔案"})
        size = p.stat().st_size
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8" if name.endswith(LRC) else "audio/mp4")
        self.send_header("Content-Length", str(size))
        self.end_headers()
        with p.open("rb") as f:
            while chunk := f.read(256 * 1024):
                self.wfile.write(chunk)


def _song_file(name: str) -> bool:
    """歌曲資料夾裡的伴唱／人聲／歌詞檔名（不能是別的資料夾、隱藏檔）"""
    return (0 < len(name) <= 255 and "/" not in name and "\\" not in name and "\x00" not in name
            and not name.startswith(".") and name.endswith((INST, VOCAL, LRC)))


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request, client_address) -> None:
        if isinstance(sys.exc_info()[1], (ConnectionError, TimeoutError)):
            return  # 手機中途斷線（例如離開 Wi-Fi），不用記錄
        super().handle_error(request, client_address)

    def server_bind(self) -> None:  # 不做反查 DNS（可能很慢）
        if self.address_family == socket.AF_INET6:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)  # 同時收 IPv4、IPv6
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = "carkaraoke", self.server_address[1]


def make_server() -> Server:
    try:
        Server.address_family = socket.AF_INET6
        return Server(("::", PORT), Handler)
    except OSError as e:
        if e.errno == 48:  # 連接埠被占用（多半是伺服器已經在跑了）
            raise
        Server.address_family = socket.AF_INET
        return Server(("0.0.0.0", PORT), Handler)


# ---------------------------------------------------------------- Bonjour（讓 iPhone 自動找到這台 Mac）

def _scutil(key: str) -> str:
    try:
        return subprocess.run(["/usr/sbin/scutil", "--get", key], capture_output=True, text=True,
                              timeout=5).stdout.strip()
    except Exception:
        return ""


_name_cache: tuple[float, str] = (0.0, "")


def computer_name() -> str:
    """Mac 的名稱（快取 5 分鐘：/ping 要回得快，Mac 很忙時 scutil 可能要好幾秒）"""
    global _name_cache
    if time.time() - _name_cache[0] > 300 or not _name_cache[1]:
        _name_cache = (time.time(), _scutil("ComputerName") or socket.gethostname())
    return _name_cache[1]


def advertise(stop: threading.Event) -> None:
    name = f"車上K歌 @ {computer_name()}"
    while len(name.encode("utf-8")) > 63:
        name = name[:-1]
    host = (_scutil("LocalHostName") or socket.gethostname().split(".")[0]) + ".local"
    cmd = ["/usr/bin/dns-sd", "-R", name, SERVICE_TYPE, "local", str(PORT),
           f"host={host}", f"port={PORT}", f"v={API_VERSION}"]
    while not stop.is_set():
        p = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log(f"Bonjour 廣播：{name}（{host}:{PORT}）")
        while not stop.wait(5):
            if p.poll() is not None:
                break
        if p.poll() is None:
            p.terminate()
        stop.wait(5)


# ---------------------------------------------------------------- main

def backfill_lyrics(stop: threading.Event) -> None:
    """伺服器啟動後，幫還沒有歌詞的歌補上歌詞（之後每天再試一次找不到的）"""
    while not stop.wait(5):
        try:
            r = subprocess.run([str(PYTHON), "-I", str(CONVERTER), "--lyrics-only", "-o", str(SONGS)],
                               cwd=HERE, capture_output=True, text=True, encoding="utf-8", errors="replace",
                               timeout=30 * 60)
            for line in r.stdout.splitlines():
                if line.strip() and "每首歌都已經有歌詞" not in line:
                    log("   " + line.strip())
        except Exception as e:
            log(f"補歌詞失敗：{e!r}")
        if stop.wait(24 * 3600):
            return


def clean_temp() -> None:
    """轉檔做到一半被停掉（例如伺服器重新啟動）留下的暫存資料夾"""
    for d in Path(tempfile.gettempdir()).glob("carkaraoke-*"):
        try:
            if d.is_dir() and time.time() - d.stat().st_mtime > 2 * JOB_TIMEOUT:
                shutil.rmtree(d, ignore_errors=True)
        except OSError:
            pass


def main() -> int:
    if not PYTHON.exists() or not CONVERTER.exists():
        log(f"找不到轉檔程式（{PYTHON}）。請先執行 mac/setup.sh")
        return 1
    SONGS.mkdir(parents=True, exist_ok=True)
    clean_temp()
    index = SongIndex()
    Handler.index = index
    Handler.sent = sent = Delivered()
    Handler.pairing = pairing.Pairing()
    Handler.jobs = jobs = Jobs(index, sent)
    try:
        server = make_server()
    except OSError as e:
        log(f"無法使用連接埠 {PORT}：{e}")
        return 1
    stop = threading.Event()
    bonjour = threading.Thread(target=advertise, args=(stop,), name="bonjour", daemon=True)
    bonjour.start()
    threading.Thread(target=backfill_lyrics, args=(stop,), name="lyrics", daemon=True).start()

    def on_term(*_):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, on_term)
    computer_name()  # 先查好，第一次 /ping 就能馬上回應
    log(f"車上K歌伺服器啟動：port {PORT}，歌曲資料夾 {SONGS}（Mac 上有 {len(index.songs())} 首還沒傳到手機，"
        f"已經傳過 {len(sent.items)} 首）")
    try:
        server.serve_forever(poll_interval=1)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        jobs.stop()
        server.server_close()
        bonjour.join(timeout=7)
        log("伺服器已停止")
    return 0


if __name__ == "__main__":
    sys.exit(main())

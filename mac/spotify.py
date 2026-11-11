"""車上K歌 — Spotify 點歌

在 Spotify 按「分享 → 複製連結」，貼到 App：
  1. 讀出歌名、歌手、長度（Spotify 公開的嵌入頁，不用登入、不用 API 金鑰）
     播放清單／專輯：讀出曲目（Spotify 的嵌入頁最多給前 100 首），每一首照下面的步驟各做一次
  2. 在 YouTube 找同一首歌：長度、歌名、歌手都要對得上，避開翻唱／現場／伴奏／串燒版本
  3. 交給原本的流程（下載 → Demucs 去人聲 → 歌詞）；歌名、歌手用 Spotify 的（比 YouTube 標題乾淨，找歌詞也比較準）

Spotify 本身不提供音樂檔（有 DRM 保護），所以聲音一樣是從 YouTube 來。
只用 Python 標準函式庫和 yt-dlp；不是 AI、不花 token。
"""
from __future__ import annotations

import html
import json
import math
import os
import re
import shutil
import ssl
import subprocess
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

BROWSER_UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
              "(KHTML, like Gecko) Version/17.0 Safari/605.1.15")
EMBED = "https://open.spotify.com/embed/"
MAX_LIST = 100  # 嵌入頁最多列出 100 首
SHORT_HOSTS = {"spotify.link", "spotify.app.link"}
KIND_NAMES = {"album": "專輯", "playlist": "播放清單", "artist": "歌手頁面", "episode": "Podcast", "show": "Podcast"}
TIMEOUT = 4  # 秒；手機等 Mac 回應最多 10 秒（短網址要查兩次）

_ID = r"[A-Za-z0-9]{22}"
_URL = re.compile(r"https?://[^\s<>\"'）」】]+")
_OPEN_PATH = re.compile(rf"^/(?:intl-[A-Za-z-]+/)?(?:embed/)?(track|album|playlist|artist|episode|show)/({_ID})(?![A-Za-z0-9])")
_URI = re.compile(rf"spotify:(track|album|playlist|artist|episode|show):({_ID})(?![A-Za-z0-9])")
_NEXT_DATA = re.compile(r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>', re.S)


class SpotifyError(Exception):
    """給使用者看的錯誤訊息"""


# ---------------------------------------------------------------- 連結

def find_link(text: str) -> str | None:
    """文字裡的 Spotify 連結（或 spotify:track:… URI）；沒有就回傳 None。不連網。"""
    m = _URI.search(text or "")
    if m:
        return m.group(0)
    for m in _URL.finditer(text or ""):
        host = (urllib.parse.urlsplit(m.group(0)).hostname or "").lower()
        if host == "open.spotify.com" or host in SHORT_HOSTS:
            return m.group(0)
    return None


def _kind_id(link: str) -> tuple[str, str] | None:
    m = _URI.search(link)
    if m:
        return m.group(1).lower(), m.group(2)
    u = urllib.parse.urlsplit(link)
    if (u.hostname or "").lower() != "open.spotify.com":
        return None
    m = _OPEN_PATH.match(u.path)
    return (m.group(1).lower(), m.group(2)) if m else None


def ref(text: str) -> tuple[str, str]:
    """分享文字 → (種類, ID)；種類是 track／playlist／album（其他的直接報錯）。短網址（spotify.link）會連網查一次。"""
    link = find_link(text)
    if not link:
        raise SpotifyError("這不是 Spotify 連結")
    found = _kind_id(link)
    if found is None and (urllib.parse.urlsplit(link).hostname or "").lower() in SHORT_HOSTS:
        found = _expand_short(link)
    if found is None:
        raise SpotifyError("看不懂這個 Spotify 連結。請在 Spotify 的歌曲或播放清單上按「分享 → 複製連結」")
    if found[0] not in ("track", "playlist", "album"):
        raise SpotifyError(f"這是 Spotify 的{KIND_NAMES.get(found[0], found[0])}連結。"
                           "請貼一首歌、一個播放清單或一張專輯的連結（按「分享 → 複製連結」）")
    return found


def track_id(text: str) -> str:
    """分享文字 → Spotify 歌曲 ID（不是歌曲連結就報錯）"""
    kind, sid = ref(text)
    if kind != "track":
        raise SpotifyError(f"這是 Spotify 的{KIND_NAMES[kind]}連結。請打開其中一首歌，按「分享 → 複製連結」")
    return sid


def _expand_short(link: str) -> tuple[str, str] | None:
    link = "https://" + link.split("://", 1)[-1]  # 一律用 https
    try:
        with _open(link) as r:
            final = r.geturl()
            body = r.read(400_000).decode("utf-8", "replace")
    except (urllib.error.URLError, OSError) as e:
        raise SpotifyError(f"連不到 Spotify（{_reason(e)}）") from None
    ref = _kind_id(final)
    if ref:
        return ref
    for m in re.finditer(r"https://open\.spotify\.com/[^\s\"'<>\\]+", body):  # 轉址頁裡的連結
        ref = _kind_id(html.unescape(m.group(0)))
        if ref:
            return ref
    return None


# ---------------------------------------------------------------- 歌曲資料

def _ssl_context() -> ssl.SSLContext:
    for cafile in ("/etc/ssl/cert.pem", "/private/etc/ssl/cert.pem"):  # python.org 版的 Python 沒有內建根憑證
        if os.path.exists(cafile):
            return ssl.create_default_context(cafile=cafile)
    return ssl.create_default_context()


def _trusted(url: str) -> bool:
    """只連 Spotify 自己的網站（https）"""
    u = urllib.parse.urlsplit(url)
    host = (u.hostname or "").lower()
    return u.scheme == "https" and (host == "spotify.com" or host.endswith(".spotify.com") or host in SHORT_HOSTS
                                    or host == "spotify-alternate.app.link")


class _SpotifyOnly(urllib.request.HTTPRedirectHandler):
    """短網址只能轉到 Spotify 自己的網站：不讓一個做壞的連結把 Mac 帶去連家裡網路的其他裝置（路由器等）"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not _trusted(newurl):
            raise urllib.error.URLError("連結轉到 Spotify 以外的網站")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _open(url: str):
    if not _trusted(url):
        raise urllib.error.URLError("不是 Spotify 的網址")
    req = urllib.request.Request(url, headers={"User-Agent": BROWSER_UA, "Accept-Language": "zh-TW,zh;q=0.9,en;q=0.5"})
    opener = urllib.request.build_opener(urllib.request.HTTPSHandler(context=_ssl_context()), _SpotifyOnly)
    return opener.open(req, timeout=TIMEOUT)


def _reason(e: Exception) -> str:
    r = getattr(e, "reason", None) or e
    return "逾時" if isinstance(r, TimeoutError) or "timed out" in str(r) else str(r)[:80]


_NOT_FOUND = {"track": "Spotify 上找不到這首歌（連結可能不完整）",
              "album": "Spotify 上找不到這張專輯（連結可能不完整）",
              "playlist": "Spotify 上找不到這個播放清單（連結可能不完整；私人播放清單要先在 Spotify 設成公開）"}


def _embed(sid: str, locale: str | None, kind: str = "track") -> dict:
    url = EMBED + f"{kind}/{sid}" + (f"?locale={locale}" if locale else "")
    try:
        with _open(url) as r:
            page = r.read(4_000_000).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        if e.code in (400, 404):
            raise SpotifyError(_NOT_FOUND[kind]) from None
        raise SpotifyError(f"Spotify 回應錯誤（{e.code}）") from None
    except (urllib.error.URLError, OSError) as e:
        raise SpotifyError(f"連不到 Spotify（{_reason(e)}）") from None
    m = _NEXT_DATA.search(page)
    try:
        props = json.loads(m.group(1))["props"]["pageProps"]
    except (AttributeError, KeyError, TypeError, ValueError):
        props = None
    if isinstance(props, dict) and props.get("status") in (400, 403, 404):  # ID 不存在、私人清單
        raise SpotifyError(_NOT_FOUND[kind])
    try:
        return props["state"]["data"]["entity"]
    except (KeyError, TypeError):
        raise SpotifyError("讀不到 Spotify 的資料（Spotify 可能改版了）") from None


def _names(entity: dict) -> list[str]:
    return [a["name"].strip() for a in entity.get("artists") or [] if (a.get("name") or "").strip()]


def track_info(sid: str, alt_names: bool = False) -> dict:
    """{"id", "title", "artist"（第一位歌手）, "artists", "altArtists"（英文名）, "duration"（秒）}

    歌手名用台灣的寫法（例如「孫燕姿」而不是 Stefanie Sun）；alt_names=True 時再查一次英文名。"""
    e = _embed(sid, "zh-TW")
    title = (e.get("name") or e.get("title") or "").strip()
    if not title or e.get("type", "track") != "track":
        raise SpotifyError("讀不到這首歌的歌名")
    artists = _names(e)
    info = {"id": sid, "title": title, "artist": artists[0] if artists else None, "artists": artists,
            "altArtists": [], "duration": (e.get("duration") or 0) / 1000}
    return add_alt_names(info) if alt_names else info


def list_info(kind: str, lid: str) -> dict:
    """播放清單／專輯 → {"kind", "id", "name", "owner", "tracks": [歌曲資料（同 track_info，沒有英文名）]}"""
    e = _embed(lid, "zh-TW", kind)
    tracks, seen = [], set()
    for t in e.get("trackList") or []:
        m = _URI.match(t.get("uri") or "")
        title = (t.get("title") or "").strip()
        if not m or m.group(1) != "track" or not title or m.group(2) in seen:
            continue  # Podcast 單集、本機檔案、重複的歌
        seen.add(m.group(2))
        artists = [a.strip() for a in (t.get("subtitle") or "").replace("\xa0", " ").split(", ") if a.strip()]
        tracks.append({"id": m.group(2), "title": title, "artist": artists[0] if artists else None, "artists": artists,
                       "altArtists": [], "duration": (t.get("duration") or 0) / 1000})
    name = (e.get("name") or e.get("title") or "").strip() or KIND_NAMES[kind]
    if not tracks:
        raise SpotifyError(f"這個{KIND_NAMES[kind]}裡沒有歌")
    return {"kind": kind, "id": lid, "name": name, "owner": (e.get("subtitle") or "").strip() or None,
            "tracks": tracks[:MAX_LIST], "total": len(tracks)}


def add_alt_names(info: dict) -> dict:
    """補上歌手的英文名（YouTube 的「歌手 - Topic」官方音源頻道常用英文名）；查不到就算了"""
    try:
        alt = [n for n in _names(_embed(info["id"], None)) if n not in info.get("artists", [])]
    except SpotifyError:
        alt = []
    return {**info, "altArtists": alt}


_EXTRA = re.compile(r"remaster|from |theme|soundtrack|主題曲|插曲|片頭曲|片尾曲|電影|電視劇|影集|edit|mono|stereo|bonus", re.I)


def display_title(title: str) -> str:
    """App 裡顯示的歌名：「天黑黑 - Remastered」→「天黑黑」；「Song - Live」這種有意義的版本說明保留"""
    parts = re.split(r"\s+[-–—]\s+", title, maxsplit=1)
    return parts[0].strip() if len(parts) == 2 and _EXTRA.search(parts[1]) and parts[0].strip() else title


# ---------------------------------------------------------------- 在 YouTube 找同一首歌

# 標題有這些字、但 Spotify 歌名沒有的：通常不是原曲（英文要整個字對上，避免 alive、olive…）
_BAD_WORDS = [
    "live", "concert", "cover", "covered by", "karaoke", "ktv", "instrumental", "inst", "off vocal", "mmr",
    "remix", "dj", "sped up", "speed up", "slowed", "reverb", "nightcore", "8d", "1 hour", "loop", "reaction",
    "tutorial", "lesson", "piano", "guitar", "acoustic", "demo", "teaser", "preview", "trailer", "shorts",
    "tiktok", "medley", "mashup", "full album", "playlist", "remastered 4k", "behind the scenes",
    "原唱:", "原唱 :", "翻自", "cover by",
    "現場", "演唱會", "巡演", "翻唱", "伴奏", "伴唱", "純音樂", "消音", "去人聲", "加速", "降速", "循環", "一小時",
    "1小時", "教學", "鋼琴", "吉他", "抖音", "串燒", "合輯", "精選", "全專輯", "專輯", "預告", "片段", "花絮",
    "舞蹈", "練習室", "直拍", "樂譜", "完整版歌單", "舞台", "打歌", "表演", "不插電",
    "version", "ver", "practice", "dance", "performance", "stage", "fancam", "music core", "musiccore",
    "inkigayo", "m countdown", "mcountdown", "music bank", "show champion", "合唱",
]
# 「…版」：這些是同一個錄音（完整版、歌詞版…），其他的（粵語版、合唱版、降調版…）是別的版本
_SAME_VERSION = ("完整", "官方", "正式", "原版", "原唱", "高清", "高畫質", "高音質", "超高音質", "字幕", "歌詞", "歌词",
                 "動態歌詞", "动态歌词", "中字", "MV", "mv", "4K", "4k", "HD", "hd", "首播", "修復")
_LATIN = re.compile(r"[a-z0-9]")


def _other_versions(yt_title: str, sp_title: str) -> list[str]:
    out = []
    for m in re.finditer(r"版", yt_title):
        before = yt_title[max(0, m.start() - 5):m.start()]
        if before.endswith(_SAME_VERSION):
            continue
        word = (re.findall(r"[㐀-鿿]{1,3}$", before) or [""])[0] + "版"
        if word != "版" and word not in sp_title:
            out.append(word)
    return out


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKC", s or "").lower()
    return re.sub(r"[\W_]+", "", s)


def _bare_title(title: str) -> str:
    t = re.sub(r"\s*[(\[（【「《][^)\]）】」》]*[)\]）】」》]", " ", title)  # 括號：feat.、版本說明
    t = re.split(r"\s+[-–—]\s+", t)[0]                               # 「歌名 - Remastered 2011」
    return t.strip() or title


def _has_word(text: str, word: str) -> bool:
    if _LATIN.match(word):
        return re.search(rf"(?<![a-z0-9]){re.escape(word)}(?![a-z0-9])", text) is not None
    return word in text


def _artist_keys(names: list[str]) -> list[str]:
    keys: list[str] = []
    for name in names:
        primary = re.split(r"\s*(?:,|&|/|、|＆|\sx\s|×|feat\.?\s|ft\.?\s)\s*", name, flags=re.I)[0]
        cjk = "".join(re.findall(r"[぀-ヿ㐀-鿿가-힯]+", primary))
        latin = re.sub(r"[぀-ヿ㐀-鿿가-힯]+", " ", primary)
        for k in (_norm(name), _norm(primary), _norm(cjk), _norm(latin)):
            if len(k) >= 2 and k not in keys:
                keys.append(k)
    return keys


def score(info: dict, entry: dict, rank: int = 0) -> tuple[float, list[str]]:
    """一支 YouTube 影片像不像 Spotify 上的這首歌。回傳 (分數, 理由)"""
    why: list[str] = []
    yt_title = unicodedata.normalize("NFKC", entry.get("title") or "").lower()
    yt, channel = _norm(yt_title), _norm(entry.get("channel") or entry.get("uploader") or "")
    sp_title = unicodedata.normalize("NFKC", info["title"]).lower()
    full, bare = _norm(sp_title), _norm(_bare_title(info["title"]))
    s = 0.0
    # 歌名
    title_ok = False
    if full and full in yt:
        s += 4; title_ok = True; why.append("歌名完全對上")
    elif bare and bare in yt:
        s += 3.5; title_ok = True; why.append("歌名對上")
    elif bare:
        overlap = sum(1 for ch in set(bare) if ch in yt) / len(set(bare))
        if overlap >= 0.75 and len(bare) >= 3:
            s += 1.5; title_ok = True; why.append(f"歌名大致對上 {overlap:.0%}")
        else:
            s -= 4; why.append("歌名不對")
    # 歌手
    keys = _artist_keys(info.get("artists") or [])
    alt_keys = _artist_keys(info.get("altArtists") or [])
    all_keys = keys + [k for k in alt_keys if k not in keys]
    artist_ok = any(k in yt or k in channel for k in all_keys) or not all_keys
    if artist_ok:
        s += 2; why.append("歌手對上")
    else:
        s -= 1; why.append("歌手不對")
    raw_channel = (entry.get("channel") or entry.get("uploader") or "")
    if raw_channel.endswith(" - Topic") and _norm(raw_channel[:-8]) in all_keys:
        s += 3; why.append("官方音源（Topic）")
    # 長度
    dur, want = entry.get("duration"), info.get("duration") or 0
    if dur and want:
        diff = float(dur) - want
        d = diff if diff >= 0 else -2 * diff  # 比原曲短（少了一段）比多一段前奏更糟
        s += 3 if d <= 2 else 2 if d <= 5 else 1 if d <= 15 else 0 if d <= 45 else -2 if d <= 90 else -6
        why.append(f"長度差 {diff:+.0f} 秒")
    else:
        s -= 1
    if dur and (dur < 60 or dur > 12 * 60):
        s -= 6; why.append("長度不像一首歌")
    # 不是原曲的版本
    bad = [w for w in _BAD_WORDS if _has_word(yt_title, w) and not _has_word(sp_title, w)]
    bad += _other_versions(yt_title, sp_title)
    if bad:
        s -= min(4 * len(bad), 8); why.append("可能不是原曲：" + "、".join(bad[:3]))
    if entry.get("live_status") in ("is_live", "is_upcoming", "post_live"):
        s -= 6; why.append("直播")
    # 人氣、搜尋排名（同分時才有影響）
    views = entry.get("view_count") or 0
    s += min(math.log10(views + 1), 8) * 0.25
    s += 0.6 if rank == 0 else 0.3 if rank <= 2 else 0
    if not title_ok or not artist_ok:
        s = min(s, 2.0)  # 歌名或歌手對不上的，再像也不選（同名的別首歌、翻唱）
    return s, why


ACCEPT = 4.0  # 低於這個分數就當作找不到


def pick(info: dict, entries: list[dict]) -> tuple[dict, float, list[str]] | None:
    best = None
    seen: set[str] = set()
    for rank, e in enumerate(entries):
        if not e.get("id") or e["id"] in seen:
            continue
        seen.add(e["id"])
        sc, why = score(info, e, rank)
        if best is None or sc > best[1]:
            best = (e, sc, why)
    return best if best and best[1] >= ACCEPT else None


def search_youtube(query: str, n: int = 10) -> list[dict]:
    ytdlp = shutil.which("yt-dlp")
    if not ytdlp:
        raise SpotifyError("Mac 上找不到 yt-dlp，請執行：brew install yt-dlp")
    try:
        r = subprocess.run([ytdlp, "--flat-playlist", "-J", "--no-warnings", f"ytsearch{n}:{query}"],
                           capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)
        data = json.loads(r.stdout or "{}")
    except (subprocess.TimeoutExpired, ValueError):
        raise SpotifyError("YouTube 搜尋失敗，請稍後再試") from None
    entries = [e for e in data.get("entries") or [] if isinstance(e, dict)]
    if not entries and r.returncode:
        raise SpotifyError("YouTube 搜尋失敗（如果一直這樣，請在 Mac 執行 brew upgrade yt-dlp）")
    return entries


def queries(info: dict) -> list[str]:
    """依序試的搜尋字串（YouTube 偶爾對完整歌名搜不到東西，所以有後備的寫法）"""
    bare = _bare_title(info["title"])
    artist = info.get("artist") or ""
    out = [f"{artist} {bare}", f"{bare} {artist}"]
    out += [f"{a} {bare}" for a in (info.get("altArtists") or [])[:1]]
    if len(re.findall(r"[㐀-鿿]", bare)) >= 4:
        out.append(f"{artist} {bare[: (len(bare) + 1) // 2]}")  # 歌名前半段
    if artist:
        out.append(artist)  # 歌手的熱門影片
    seen: set[str] = set()
    return [q.strip() for q in out if q.strip() and not (q.strip() in seen or seen.add(q.strip()))]


def find_youtube(info: dict) -> tuple[dict, float, list[str]]:
    """回傳 (YouTube 影片, 分數, 理由)；找不到對得上的版本就丟 SpotifyError。"""
    tried: list[dict] = []
    for query in queries(info):
        tried += search_youtube(query)
        found = pick(info, tried)
        if found:
            return found
    raise SpotifyError(f"YouTube 上找不到對得上的「{info['title']}」（長度、歌名、歌手都對得上的版本）。"
                       "可以在 YouTube 自己找，然後貼 YouTube 連結")


def describe(info: dict) -> str:
    return info["title"] + (f" - {info['artist']}" if info.get("artist") else "")

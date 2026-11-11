"""車上K歌 — 時間同步歌詞（LRC）

從 LRCLIB（https://lrclib.net，免費、開放的社群歌詞資料庫；不用帳號、不是 AI、不花 token）
找有時間軸的歌詞，再用去人聲得到的「人聲軌」自動對齊時間：
YouTube 上的 MV 常比專輯版多一段前奏，直接用資料庫的時間會整首錯開。

對齊方法（傳統訊號處理）：歌詞每一行開始的時間，應該對到人聲軌「開始唱」的地方；
試各種位移，找命中最多行的那一個。整首歌只算一次，在 Mac 上約 0.1 秒。
"""
from __future__ import annotations

import json
import os
import re
import ssl
import urllib.parse
import urllib.request

API = "https://lrclib.net/api/search"
USER_AGENT = "CarKaraoke/1.0 (personal karaoke app)"
LRC_SUFFIX = ".lrc"
FPS = 20                 # 人聲活動每秒 20 格（和評分用的音高資料一樣）
MAX_SHIFT = 60.0         # 最多容許前後錯開 60 秒

_TS = re.compile(r"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]")
_WORD_TS = re.compile(r"<\d{1,3}:\d{1,2}(?:[.:]\d{1,3})?>")
_OFFSET = re.compile(r"^\[offset:\s*([+-]?\d+)\s*\]$", re.I)
_BRACKETS = re.compile(r"\s*[(\[（【「《][^)\]）】」》]*[)\]）】」》]\s*")
_CJK = re.compile(r"[㐀-鿿豈-﫿]+")
# 常見的簡體／繁體字（只用來判斷歌詞是哪一種字體）
_SIMP = set("爱这说们会时为来过还没对开关门问间听见气电话东车长发乐书声让应该经现实认识梦变边远运进伤忆泪恋怀亲给无")
_TRAD = set("愛這說們會時為來過還沒對開關門問間聽見氣電話東車長發樂書聲讓應該經現實認識夢變邊遠運進傷憶淚戀懷親給無")


# ---------------------------------------------------------------- LRC 格式

def parse_lrc(text: str) -> list[tuple[float, str]]:
    """LRC 文字 → [(秒, 這一行歌詞)]，依時間排序。空字串代表間奏（清掉上一行）。"""
    lines: list[tuple[float, str]] = []
    offset = 0.0
    for raw in (text or "").splitlines():
        raw = raw.strip()
        m = _OFFSET.match(raw)
        if m:
            offset = int(m.group(1)) / 1000  # LRC 規格：正數 = 歌詞提早出現
            continue
        stamps, pos = [], 0
        while (m := _TS.match(raw, pos)):
            stamps.append(int(m.group(1)) * 60 + float(m.group(2).replace(":", ".")))
            pos = m.end()
        if not stamps:
            continue
        body = _WORD_TS.sub("", raw[pos:]).strip()
        lines.extend((t, body) for t in stamps)
    lines = [(max(0.0, t - offset), s) for t, s in lines]
    lines.sort(key=lambda x: x[0])
    return lines


def _stamp(t: float) -> str:
    cs = int(round(max(t, 0) * 100))
    return f"{cs // 6000:02d}:{cs // 100 % 60:02d}.{cs % 100:02d}"


def to_lrc(lines: list[tuple], title: str, artist: str | None, note: str) -> str:
    """lines：(秒, 歌詞)，或 (秒, 歌詞, [(秒, 這段文字)], 唱完的秒) — 後者寫成逐字格式（Enhanced LRC）：
    [00:12.30]<00:12.30>我<00:12.80>愛<00:13.40>你<00:14.90>"""
    out = [f"[ti:{title}]"] + ([f"[ar:{artist}]"] if artist else []) + [f"[re:車上K歌 {note}]"]
    for item in lines:
        t, s = item[0], item[1]
        if len(item) == 4 and item[2]:
            body = "".join(f"<{_stamp(wt)}>{chunk}" for wt, chunk in item[2]) + f"<{_stamp(item[3])}>"
            out.append(f"[{_stamp(t)}]{body}")
        else:
            out.append(f"[{_stamp(t)}]{s}")
    return "\n".join(out) + "\n"


def has_word_times(text: str) -> bool:
    return bool(_WORD_TS.search(text or ""))


def tag(text: str, name: str) -> str | None:
    """LRC 標頭標籤，例如 tag(text, "ar") → 歌手"""
    m = re.search(rf"^\[{name}:(.*)\]\s*$", text or "", re.M | re.I)
    return m.group(1).strip() if m else None


# ---------------------------------------------------------------- LRCLIB

def _ssl_context() -> ssl.SSLContext:
    # python.org 版的 Python 沒有內建根憑證；改用 macOS 系統內建的憑證檔
    for cafile in ("/etc/ssl/cert.pem", "/private/etc/ssl/cert.pem"):
        if os.path.exists(cafile):
            return ssl.create_default_context(cafile=cafile)
    return ssl.create_default_context()


def _get(params: dict) -> list[dict]:
    req = urllib.request.Request(API + "?" + urllib.parse.urlencode(params), headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=12, context=_ssl_context()) as r:
            data = json.load(r)
        return data if isinstance(data, list) else []
    except Exception:
        return []


def _variants(title: str, artist: str | None) -> tuple[list[str], list[str]]:
    titles = [title]
    bare = _BRACKETS.sub(" ", title).strip()
    if bare and bare != title:
        titles.append(bare)  # "Superhero (feat. Chris Linton)" → "Superhero"
    dash = re.split(r"\s+[-–—]\s+", bare or title)[0].strip()
    if dash and dash not in titles:
        titles.append(dash)  # "天黑黑 - Remastered" → "天黑黑"
    artists: list[str] = []
    if artist:
        artists.append(artist)
        primary = re.split(r"\s*(?:,|&|/|、|＆|\sx\s|×|feat\.?\s|ft\.?\s)\s*", artist, flags=re.I)[0].strip()
        cjk = "".join(_CJK.findall(primary))       # "王傑 Dave Wong" → "王傑"
        latin = _CJK.sub(" ", primary).strip()     # → "Dave Wong"
        for a in (primary, cjk, latin):
            if a and a not in artists:
                artists.append(a)
    return titles, artists


def search(title: str, artist: str | None) -> list[dict]:
    """找有時間軸的歌詞候選（內容相同的只留一份）。"""
    titles, artists = _variants(title, artist)
    queries = [{"track_name": t, "artist_name": a} for t in titles for a in artists]
    queries.append({"q": f"{titles[-1]} {artists[-1] if artists else ''}".strip()})
    seen: set[str] = set()
    found: list[dict] = []
    for params in queries[:7]:
        for item in _get(params):
            synced = (item.get("syncedLyrics") or "").strip()
            if not synced or item.get("instrumental") or synced in seen:
                continue
            seen.add(synced)
            found.append(item)
        if found:
            break
    return found


# ---------------------------------------------------------------- 對齊
# 做法：歌詞每一行開始的時間，應該剛好是人聲「開始唱」的時間。
# 試每一種位移（前後 60 秒、每 0.05 秒），算有幾成歌詞行落在真正的人聲開始點 ±0.4 秒內。

def voiced_from_pitch(pitch: bytes):
    """評分用的旋律音高（每 50ms 1 byte，0 = 沒唱）→ 有沒有在唱"""
    import numpy as np
    return np.frombuffer(pitch, dtype=np.uint8) > 0


def voiced_from_audio(mono16k):
    """沒有音高資料時，用人聲軌的音量判斷"""
    import numpy as np
    hop = 16000 // FPS
    n = len(mono16k) // hop
    if n == 0:
        return np.zeros(0, dtype=bool)
    frames = np.asarray(mono16k[: n * hop], dtype=np.float64).reshape(n, hop)
    db = 10 * np.log10(np.mean(frames ** 2, axis=1) + 1e-12)
    return db > max(float(np.percentile(db, 95)) - 15.0, -55.0)


def _onsets(voiced, gap: float = 0.3):
    """人聲「開始唱」的位置：前面至少 gap 秒沒聲音"""
    import numpy as np
    v = np.asarray(voiced, dtype=bool)
    g = int(gap * FPS)
    before = np.convolve(v.astype(float), np.ones(g), mode="full")[: len(v)] - v  # 前 g 格有幾格在唱
    return v & (np.concatenate([[0], before[:-1]]) <= 0) if len(v) else v


def hit_curve(lines: list[tuple[float, str]], voiced, tolerance: float = 0.4):
    """回傳 (位移陣列, 命中率陣列)"""
    import numpy as np
    starts = np.array([t for t, s in lines if s])
    on = _onsets(voiced).astype(float)
    near = np.convolve(on, np.ones(int(2 * tolerance * FPS) + 1), mode="same") > 0
    shifts = np.arange(-int(MAX_SHIFT * FPS), int(MAX_SHIFT * FPS) + 1)
    idx = np.round(starts * FPS).astype(int)
    pos = idx[None, :] + shifts[:, None]
    ok = (pos >= 0) & (pos < len(near))
    hits = np.where(ok, near[np.clip(pos, 0, max(len(near) - 1, 0))], False).sum(axis=1)
    return shifts / FPS, hits / max(len(starts), 1)


def choose_shift(lines, voiced, length_diff: float) -> tuple[float, float]:
    """回傳 (位移秒數, 命中率)。長度相同的版本只做 ±3 秒微調；版本不同時才允許大幅位移。"""
    import numpy as np
    if voiced is None or len(voiced) == 0 or sum(1 for _, s in lines if s) < 6:
        return 0.0, 0.0  # 歌詞太少，判斷不準
    sh, rate = hit_curve(lines, voiced)
    zero = rate[np.argmin(np.abs(sh))]
    local = np.abs(sh) <= 3
    li = int(np.argmax(np.where(local, rate, -1)))
    shift, hit = (float(sh[li]), float(rate[li])) if rate[li] >= zero + 0.05 else (0.0, float(zero))
    if length_diff > 3:
        b = int(np.argmax(rate))
        runner_up = rate[np.abs(sh - sh[b]) > 2].max()
        # 歌曲段落會重複，錯開一個樂句也可能命中不少行，所以只要求明顯勝過「不位移」、而且不是平手
        if abs(sh[b]) > 3 and rate[b] >= 0.6 and rate[b] - zero >= 0.25 and rate[b] - runner_up >= 0.03:
            shift, hit = float(sh[b]), float(rate[b])
    return shift, hit


def _script(text: str) -> tuple[int, int]:
    return sum(ch in _TRAD for ch in text), sum(ch in _SIMP for ch in text)


def _to_traditional(text: str) -> str | None:
    try:
        import opencc  # 選用：pip install opencc，可把簡體歌詞轉成台灣繁體
    except ImportError:
        return None
    return opencc.OpenCC("s2tw").convert(text)


def find(title: str, artist: str | None, duration: float, voiced=None) -> tuple[list[tuple[float, str]], str] | None:
    """找歌詞並對齊。回傳 (歌詞行, 說明) 或 None（找不到可信的歌詞）。

    voiced：每 50ms 有沒有在唱（voiced_from_pitch／voiced_from_audio）；沒有時只接受長度幾乎一樣的版本。
    """
    candidates = search(title, artist)
    if not candidates:
        return None
    trad_name, simp_name = _script(title + (artist or ""))
    want_trad = trad_name >= simp_name
    best = None
    for item in candidates[:8]:
        lines = parse_lrc(item["syncedLyrics"])
        sung = [t for t, s in lines if s]
        if len(sung) < 4:
            continue
        length_diff = abs(float(item.get("duration") or duration) - duration)
        shift, hit = choose_shift(lines, voiced, length_diff)
        coverage = min(1.0, (sung[-1] - sung[0]) / max(duration * 0.6, 1.0))  # 只有半首的不要
        trad, simp = _script(item["syncedLyrics"])
        script_ok = (trad >= simp) == want_trad or trad == simp
        score = 2 * hit + 2 * coverage - min(length_diff, 60) / 30 + (0.5 if script_ok else 0)
        if not best or score > best[0]:
            best = (score, item, lines, shift, hit, length_diff)
    if not best:
        return None
    _, item, lines, shift, hit, length_diff = best
    if length_diff > 3 and hit < 0.5:
        return None  # 版本長度不同、又對不準：寧可不顯示，也不要顯示錯的
    note = f"lrclib#{item.get('id')} 位移 {shift:+.2f}s 命中 {hit:.0%}"
    lines = [(round(t + shift, 2), s) for t, s in lines if 0 <= t + shift <= duration + 1]
    trad, simp = _script("".join(s for _, s in lines))
    if want_trad and simp > trad:
        converted = _to_traditional("\n".join(s for _, s in lines))
        if converted is not None:
            lines = list(zip([t for t, _ in lines], converted.split("\n")))
            note += " 簡轉繁"
    return lines, note

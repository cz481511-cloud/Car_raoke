#!/usr/bin/env python3
"""車上K歌 — Mac 端轉換工具

把 YouTube 網址、Spotify 歌曲連結（在 YouTube 找同一首）、歌名（自動搜尋 YouTube）或本機音檔，用 Demucs（在 Mac 本機離線執行的開源去人聲程式，
不連網、不需要帳號、不花任何 token）拆成：
  「歌名 - 歌手.伴唱.m4a」  去掉人聲的伴奏
  「歌名 - 歌手.人聲.m4a」  單獨人聲（App 用它切換 原唱 / 導唱 / 伴唱）

用法：
  karaoke.py "https://www.youtube.com/watch?v=..."
  karaoke.py "https://open.spotify.com/track/..."
  karaoke.py "https://open.spotify.com/playlist/..."   （播放清單／專輯：每一首都做）
  karaoke.py "周杰倫 晴天"
  karaoke.py ~/Music/song.mp3
  karaoke.py --playlist "https://www.youtube.com/playlist?list=..."

只供個人使用：從 YouTube 下載可能違反 YouTube 服務條款，請勿散布轉出的檔案。
"""
from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")
sys.path.insert(0, str(Path(__file__).resolve().parent))  # 同資料夾的 lyrics.py（用 python -I 執行時預設不會找）
import lyrics  # noqa: E402
import spotify  # noqa: E402
import wordtiming  # noqa: E402

SAMPLE_RATE = 44100
CHANNELS = 2
AUDIO_EXTS = {".mp3", ".m4a", ".aac", ".wav", ".flac", ".ogg", ".opus", ".webm", ".mp4", ".mkv", ".mov", ".aiff", ".aif"}
INST_SUFFIX = ".伴唱.m4a"
VOCAL_SUFFIX = ".人聲.m4a"
LRC_SUFFIX = lyrics.LRC_SUFFIX
DEFAULT_OUT = Path(__file__).resolve().parent.parent / "songs"

# YouTube 標題裡常見、但歌名不需要的括號內容
_NOISE = re.compile(
    r"[\(\[【〔《「『]\s*[^\)\]】〕》」』]*?"
    r"(official|music\s*video|mv|m/v|lyric|lyrics|audio|visualizer|hd|4k|1080p|官方|完整版|高清|歌詞|動態歌詞|中字|字幕|首播|premiere)"
    r"[^\)\]】〕》」』]*[\)\]】〕》」』]",
    re.IGNORECASE,
)
_TRAILING_NOISE = re.compile(
    r"\s*[-–|｜]?\s*(official\s*(live\s*)?(music\s*)?video|official\s*mv|music\s*video|官方\s*mv|官方完整版\s*mv|lyric\s*video)\s*$",
    re.IGNORECASE,
)


def log(msg: str) -> None:
    print(msg, flush=True)


EVENTS = False  # --events：給伴唱伺服器讀的進度（每行 "@@{json}"）


def event(kind: str, **data) -> None:
    if EVENTS:
        print("@@" + json.dumps({"event": kind, **data}, ensure_ascii=False), flush=True)


def need(tool: str) -> str:
    path = shutil.which(tool)
    if not path:
        sys.exit(f"找不到 {tool}，請先執行：brew install {tool}")
    return path


def clean_title(title: str) -> str:
    t = re.split(r"\s[|｜]\s|[|｜]", title)[0]          # 「歌名 | 曲風 | 頻道」只留第一段
    t = _NOISE.sub("", t)
    t = _TRAILING_NOISE.sub("", t)
    t = re.sub(r"\s{2,}", " ", t).strip(" -–|｜")
    return t or title.strip()


def split_artist_title(title: str) -> tuple[str | None, str]:
    """從 YouTube 標題猜歌手：「歌手 - 歌名」或「歌手【歌名】／《歌名》／[歌名]」。"""
    m = re.match(r"^(.+?)\s*[【《「\[]\s*(.+?)\s*[】》」\]]\s*(.*)$", title)
    if m and m.group(1).strip():
        return m.group(1).strip(), m.group(2).strip()
    if " - " in title:
        artist, song = title.split(" - ", 1)
        return artist.strip(), song.strip()
    return None, title


def clean_artist(artist: str | None) -> str | None:
    if not artist:
        return None
    a = re.sub(r"\s*-\s*Topic$", "", artist).strip()
    a = re.sub(r"\s*(official|官方頻道|官方)\s*$", "", a, flags=re.IGNORECASE).strip()
    return a or None


def safe_name(text: str, limit: int = 90) -> str:
    t = re.sub(r'[\\/:*?"<>|\x00-\x1f]', " ", text)
    t = t.replace(".伴唱", "").replace(".人聲", "")
    t = re.sub(r"\s{2,}", " ", t).strip(" .")
    return (t[:limit].rstrip(" .")) or "未命名"


# ---------------------------------------------------------------- 取得音源

class Track:
    def __init__(self, audio: Path, title: str, artist: str | None, cover: Path | None, source: str):
        self.audio, self.title, self.artist, self.cover, self.source = audio, title, artist, cover, source

    @property
    def base_name(self) -> str:
        name = self.title
        if self.artist and self.artist.lower() not in self.title.lower():
            name = f"{self.title} - {self.artist}"
        return safe_name(name)


def fetch_youtube(query: str, workdir: Path, playlist: bool) -> list[Track]:
    ytdlp = need("yt-dlp")
    target = query if re.match(r"https?://", query) else f"ytsearch1:{query}"
    cmd = [
        ytdlp, "--quiet", "--no-warnings", "--no-progress",
        "--yes-playlist" if playlist else "--no-playlist",
        "-f", "bestaudio/best",
        "--write-info-json", "--write-thumbnail", "--convert-thumbnails", "jpg",
        "-o", str(workdir / "%(id)s.%(ext)s"),
        target,
    ]
    log(f"下載中：{query}")
    r = subprocess.run(cmd)
    tracks: list[Track] = []
    for info_path in sorted(workdir.glob("*.info.json")):
        info = json.loads(info_path.read_text(encoding="utf-8"))
        vid = info.get("id") or info_path.name.split(".")[0]
        audio = next((p for p in workdir.glob(f"{glob_escape(vid)}.*")
                      if p.suffix.lower() not in {".json", ".jpg", ".webp", ".png", ".part"}), None)
        if not audio:
            continue
        if info.get("track"):  # YouTube Music 有正式的歌名、歌手資料
            title, artist = info["track"], clean_artist(info.get("artist") or info.get("creator"))
            if artist and "," in artist:
                artist = artist.split(",")[0].strip()
        else:
            guessed_artist, title = split_artist_title(clean_title(info.get("title") or vid))
            artist = guessed_artist or clean_artist(info.get("uploader") or info.get("channel"))
        cover = workdir / f"{vid}.jpg"
        tracks.append(Track(audio, title, artist, cover if cover.exists() else None,
                            info.get("webpage_url") or query))
    if not tracks:
        hint = "（如果之前可以、現在突然不行，通常是 YouTube 改版，請執行：brew upgrade yt-dlp）"
        raise RuntimeError(f"下載失敗：{query} {hint}" if r.returncode else f"找不到：{query}")
    return tracks


def use_spotify_names(tracks: list[Track], sid: str, title: str, artist: str | None) -> None:
    """歌名、歌手改用 Spotify 的（比 YouTube 標題乾淨）；comment 標籤記下 Spotify 歌曲 ID，伺服器靠它認出重複點的歌"""
    for t in tracks:
        t.title, t.artist = title, artist or t.artist
        t.source = f"{t.source} spotify:track:{sid}"


def fetch_spotify(link: str, workdir: Path) -> list[Track]:
    info = spotify.track_info(spotify.track_id(link), alt_names=True)
    log(f"Spotify：{spotify.describe(info)}（{info['duration']:.0f} 秒），在 YouTube 找同一首…")
    video, score, why = spotify.find_youtube(info)
    log(f"   → YouTube：{video.get('title')}（{video.get('channel')}，{video.get('duration')} 秒；{'、'.join(why)}）")
    tracks = fetch_youtube(f"https://www.youtube.com/watch?v={video['id']}", workdir, False)
    use_spotify_names(tracks, info["id"], spotify.display_title(info["title"]), info.get("artist"))
    return tracks


def expand_spotify_lists(items: list[str]) -> list[str]:
    """Spotify 播放清單／專輯連結 → 裡面每一首歌的連結"""
    out: list[str] = []
    for item in items:
        if spotify.find_link(item) and not re.match(r"https?://(www\.|m\.|music\.)?youtu", item):
            try:
                kind, sid = spotify.ref(item)
                if kind != "track":
                    info = spotify.list_info(kind, sid)
                    log(f"Spotify {spotify.KIND_NAMES[kind]}「{info['name']}」：{len(info['tracks'])} 首")
                    out += [f"https://open.spotify.com/track/{t['id']}" for t in info["tracks"]]
                    continue
            except spotify.SpotifyError:
                pass  # 錯誤訊息在處理這一項時再顯示
        out.append(item)
    return out


def glob_escape(s: str) -> str:
    return re.sub(r"([\[\]*?])", r"[\1]", s)


def local_track(path: Path, workdir: Path) -> Track:
    ffprobe = need("ffprobe")
    tags = {}
    try:
        out = subprocess.run([ffprobe, "-v", "error", "-show_entries", "format_tags=title,artist",
                              "-of", "json", str(path)], capture_output=True, text=True, check=True).stdout
        tags = {k.lower(): v for k, v in json.loads(out).get("format", {}).get("tags", {}).items()}
    except Exception:
        pass
    stem = path.stem.replace(".伴唱", "").replace(".人聲", "")
    title, artist = tags.get("title"), tags.get("artist")
    if not title:
        if " - " in stem:
            title, artist = [s.strip() for s in stem.split(" - ", 1)]
        else:
            title = stem
    cover = workdir / f"{path.stem}.cover.jpg"
    subprocess.run([need("ffmpeg"), "-v", "error", "-y", "-i", str(path), "-an", "-frames:v", "1", str(cover)],
                   capture_output=True)
    return Track(path, title, artist, cover if cover.exists() and cover.stat().st_size > 0 else None, str(path))


# ---------------------------------------------------------------- 去人聲

_model = None
_device = None


def load_model(name: str):
    global _model, _device
    if _model is None:
        import torch
        import huggingface_hub.constants as hf
        from demucs.pretrained import get_model
        hf.HF_HUB_OFFLINE = True  # 模型下載過就完全離線
        try:
            _model = get_model(name)
        except Exception:
            hf.HF_HUB_OFFLINE = False
            log(f"   第一次使用，下載去人聲模型 {name}（約 80 MB，只需要一次）…")
            _model = get_model(name)
        _model.eval()
        _device = "mps" if torch.backends.mps.is_available() else "cpu"
    return _model


# ---------------------------------------------------------------- 原唱音高（評分用）
# 用 YIN 演算法（傳統訊號處理）從人聲軌抓出旋律音高，每秒 20 點，存進伴唱檔的 description 標籤。
# iPhone App 唱歌評分時拿它和麥克風音高比對；參數要和 App 的 PitchDetector.swift 一致。
PITCH_SR, PITCH_HOP, PITCH_W, TAU_MIN, TAU_MAX = 16000, 800, 512, 16, 229  # 70–1000 Hz


def to_mono16k(stereo):
    import numpy as np
    raw = subprocess.run([need("ffmpeg"), "-v", "error", "-f", "f32le", "-ar", str(SAMPLE_RATE), "-ac", str(CHANNELS),
                          "-i", "-", "-ac", "1", "-ar", str(PITCH_SR), "-f", "f32le", "-"],
                         input=stereo.T.tobytes(), capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).astype(np.float64)


def melody_pitch(vocals, mono16k=None) -> bytes:
    """人聲 → 每 50ms 一個音高（1 byte：(MIDI-24)*4，0 = 沒有唱）"""
    import numpy as np
    x = to_mono16k(vocals) if mono16k is None else mono16k
    span = PITCH_W + TAU_MAX
    count = 1 + (len(x) - span) // PITCH_HOP
    if count <= 0:
        return b""
    frames = x[np.arange(span)[None, :] + PITCH_HOP * np.arange(count)[:, None]]
    base = frames[:, :PITCH_W]
    d = np.zeros((count, TAU_MAX + 1))
    for tau in range(1, TAU_MAX + 1):
        diff = base - frames[:, tau:tau + PITCH_W]
        d[:, tau] = np.einsum("ij,ij->i", diff, diff)
    cmnd = np.ones_like(d)
    cmnd[:, 1:] = d[:, 1:] * np.arange(1, TAU_MAX + 1) / np.maximum(np.cumsum(d[:, 1:], axis=1), 1e-12)
    rms_db = 10 * np.log10(np.mean(base ** 2, axis=1) + 1e-12)
    gate = max(-50.0, float(np.percentile(rms_db, 95)) - 30.0)

    midi = np.zeros(count)
    for i in range(count):
        if rms_db[i] < gate:
            continue
        dp = cmnd[i]
        below = np.nonzero(dp[TAU_MIN:TAU_MAX] < 0.15)[0]
        if len(below):
            t = int(below[0]) + TAU_MIN
            while t + 1 < TAU_MAX and dp[t + 1] < dp[t]:
                t += 1
        else:
            t = int(np.argmin(dp[TAU_MIN:TAU_MAX])) + TAU_MIN
            if dp[t] > 0.25:
                continue
        a, b, c = dp[t - 1], dp[t], dp[t + 1]
        den = a - 2 * b + c
        shift = 0.5 * (a - c) / den if abs(den) > 1e-12 else 0.0
        f0 = PITCH_SR / (t + max(-1.0, min(1.0, shift)))
        midi[i] = 69 + 12 * np.log2(f0 / 440)

    # 去雜訊：中位數平滑、刪掉短於 150ms 的片段
    out = midi.copy()
    for i in range(count):
        if midi[i] > 0:
            win = midi[max(0, i - 2):i + 3]
            out[i] = np.median(win[win > 0])
    voiced = out > 0
    i = 0
    while i < count:
        if voiced[i]:
            j = i
            while j < count and voiced[j]:
                j += 1
            if j - i < 3:
                out[i:j] = 0
            i = j
        else:
            i += 1
    q = np.where(out > 0, np.clip(np.round((out - 24) * 4), 1, 255), 0).astype(np.uint8)
    return q.tobytes()


def decode(path: Path):
    import numpy as np
    raw = subprocess.run([need("ffmpeg"), "-v", "error", "-i", str(path), "-vn", "-f", "f32le",
                          "-ac", str(CHANNELS), "-ar", str(SAMPLE_RATE), "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, CHANNELS).T.copy()


def separate(audio, model_name: str):
    """回傳 (伴奏, 人聲)，都是 shape=(2, samples) 的 numpy float32。"""
    global _device
    import torch
    from demucs.apply import apply_model
    model = load_model(model_name)
    wav = torch.from_numpy(audio)
    ref = wav.mean(0)
    mean, std = ref.mean(), ref.std() + 1e-8
    mix = ((wav - mean) / std)[None]
    with torch.no_grad():
        try:
            out = apply_model(model, mix, device=_device, shifts=1, split=True, overlap=0.25, progress=True)
        except Exception as e:  # MPS 偶爾不支援某些運算，改用 CPU
            if _device == "cpu":
                raise
            log(f"   （GPU 失敗，改用 CPU：{type(e).__name__}）")
            _device = "cpu"
            out = apply_model(model, mix, device="cpu", shifts=1, split=True, overlap=0.25, progress=True)
    sources = (out[0] * std + mean).cpu()
    vi = model.sources.index("vocals")
    vocals = sources[vi]
    inst = sources.sum(0) - vocals
    return inst.numpy().astype("float32"), vocals.numpy().astype("float32")


def encode(samples, dest: Path, track: Track, kind: str, bitrate: str, pitch: bytes | None = None) -> None:
    ffmpeg = need("ffmpeg")
    tmp = dest.with_name(dest.name + ".tmp.m4a")
    cmd = [ffmpeg, "-v", "error", "-y", "-f", "f32le", "-ar", str(SAMPLE_RATE), "-ac", str(CHANNELS), "-i", "-"]
    if track.cover:
        cmd += ["-i", str(track.cover), "-map", "0:a", "-map", "1:v",
                "-filter:v", "crop='min(iw,ih)':'min(iw,ih)',scale=600:600",
                "-c:v", "mjpeg", "-disposition:v:0", "attached_pic"]
    cmd += ["-c:a", "aac", "-b:a", bitrate,
            "-metadata", f"title={track.title}",
            "-metadata", f"album=車上K歌 {kind}",
            "-metadata", f"comment={track.source}"]
    if track.artist:
        cmd += ["-metadata", f"artist={track.artist}"]
    if pitch:
        cmd += ["-metadata", f"description=CKP1:{PITCH_SR // PITCH_HOP}:{base64.b64encode(pitch).decode()}"]
    cmd += ["-f", "mp4", str(tmp)]
    subprocess.run(cmd, input=samples.T.tobytes(), check=True)
    tmp.replace(dest)


# ---------------------------------------------------------------- 主流程

# ---------------------------------------------------------------- 歌詞

def add_word_times(lines, vocals16k, pitch: bytes | None) -> tuple[list, str]:
    """每一行再對到每一個字（KTV 逐字跑色）。失敗就維持整行時間，不影響歌詞。"""
    if vocals16k is None:
        return lines, ""
    try:
        out, timed, sung = wordtiming.add_word_times(lines, vocals16k, pitch)
    except Exception as e:
        log(f"   逐字時間：失敗（{type(e).__name__}），維持整行")
        return lines, ""
    return out, f" 逐字 {timed}/{sung}"


def write_lrc(dest: Path, lines, title: str, artist: str | None, note: str) -> None:
    tmp = dest.with_name(dest.name + ".tmp")
    tmp.write_text(lyrics.to_lrc(lines, title, artist, note), encoding="utf-8")
    tmp.replace(dest)


def save_lyrics(title: str, artist: str | None, duration: float, voiced, dest: Path,
                vocals16k=None, pitch: bytes | None = None) -> str | None:
    """找時間同步歌詞、對齊後存成「歌名 - 歌手.lrc」。找不到或沒網路都不影響伴唱檔。
    有人聲軌（vocals16k：16kHz 單聲道）時，再算出每個字開始唱的時間。"""
    try:
        found = lyrics.find(title, artist, duration, voiced)
    except Exception as e:
        log(f"   歌詞：查詢失敗（{type(e).__name__}），之後會再試")
        return None
    if not found:
        log("   歌詞：找不到對得上的時間同步歌詞")
        return None
    lines, note = found
    lines, extra = add_word_times(lines, vocals16k, pitch)
    write_lrc(dest, lines, title, artist, note + extra)
    log(f"   歌詞：{sum(1 for item in lines if item[1])} 行（{note + extra}）")
    return dest.name


def _ckp1(tags: dict) -> bytes | None:
    desc = tags.get("description", "")
    return base64.b64decode(desc.split(":", 2)[2]) if desc.startswith("CKP1:") else None


def upgrade_word_times(out_dir: Path) -> int:
    """以前做好的歌詞（只有整行時間）補上逐字時間。只動車上K歌自己產生的 .lrc；算過的不再算。"""
    done = 0
    for lrc in sorted(out_dir.glob("*" + LRC_SUFFIX)):
        base = lrc.name[: -len(LRC_SUFFIX)]
        vocal, inst = out_dir / (base + VOCAL_SUFFIX), out_dir / (base + INST_SUFFIX)
        try:
            text = lrc.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        note = lyrics.tag(text, "re") or ""
        if not note.startswith("車上K歌") or "逐字" in note or lyrics.has_word_times(text) or not vocal.exists():
            continue
        log(f"逐字時間：{base}")
        try:
            tags, _ = _probe(inst) if inst.exists() else ({}, 0)
            lines = lyrics.parse_lrc(text)
            words, extra = add_word_times(lines, to_mono16k(decode(vocal)), _ckp1(tags))
        except Exception as e:
            log(f"   失敗（{type(e).__name__}）")
            continue
        if not extra:
            continue
        # 先確認檔案沒有在這段時間被改過（例如手動修歌詞）
        if lrc.read_text(encoding="utf-8") != text:
            continue
        write_lrc(lrc, words, lyrics.tag(text, "ti") or base, lyrics.tag(text, "ar"),
                  note[len("車上K歌"):].strip() + extra)
        log(f"   {extra.strip()} 行")
        done += 1
    return done


def _probe(path: Path) -> tuple[dict, float]:
    out = subprocess.run([need("ffprobe"), "-v", "error", "-show_entries",
                          "format_tags=title,artist,description:format=duration", "-of", "json", str(path)],
                         capture_output=True, text=True, check=True).stdout
    fmt = json.loads(out).get("format", {})
    return {k.lower(): v for k, v in fmt.get("tags", {}).items()}, float(fmt.get("duration") or 0)


def backfill_lyrics(out_dir: Path, force: bool) -> int:
    """幫已經做好、還沒有歌詞的歌補上歌詞。找不到的 7 天內不重查。"""
    miss_path = out_dir / ".lyrics-miss.json"
    try:
        miss = json.loads(miss_path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        miss = {}
    now, added, todo = time.time(), 0, []
    for inst in sorted(out_dir.glob("*" + INST_SUFFIX)):
        base = inst.name[: -len(INST_SUFFIX)]
        if (out_dir / (base + LRC_SUFFIX)).exists() and not force:
            continue
        if not force and now - float(miss.get(base, 0)) < 7 * 86400:
            continue
        todo.append((inst, base))
    upgraded = upgrade_word_times(out_dir)
    if upgraded:
        log(f"{upgraded} 首歌詞補上逐字時間")
    if not todo:
        log("每首歌都已經有歌詞了（或最近查過找不到）")
        return 0
    for inst, base in todo:
        log(f"補歌詞：{base}")
        try:
            tags, duration = _probe(inst)
        except Exception:
            continue
        pitch = _ckp1(tags)
        mono = None
        if (out_dir / (base + VOCAL_SUFFIX)).exists():
            try:
                mono = to_mono16k(decode(out_dir / (base + VOCAL_SUFFIX)))
            except Exception:
                mono = None
        voiced = lyrics.voiced_from_pitch(pitch) if pitch else (lyrics.voiced_from_audio(mono) if mono is not None else None)
        title, artist = tags.get("title") or base, tags.get("artist")
        if save_lyrics(title, artist, duration, voiced, out_dir / (base + LRC_SUFFIX), mono, pitch):
            added += 1
            miss.pop(base, None)
        else:
            miss[base] = now
    try:
        miss_path.write_text(json.dumps(miss, ensure_ascii=False, indent=1), encoding="utf-8")
    except OSError:
        pass
    log(f"補好 {added} 首歌詞" + (f"，{len(todo) - added} 首找不到" if len(todo) > added else ""))
    return added


def process(track: Track, out_dir: Path, args) -> bool:
    base = track.base_name
    inst_path, vocal_path = out_dir / (base + INST_SUFFIX), out_dir / (base + VOCAL_SUFFIX)
    if inst_path.exists() and not args.force:
        log(f"已經有了，略過：{base}（要重做請加 --force）")
        lrc_path = out_dir / (base + LRC_SUFFIX)
        event("done", base=base, title=track.title, artist=track.artist, inst=inst_path.name,
              vocals=vocal_path.name if vocal_path.exists() else None,
              lyrics=lrc_path.name if lrc_path.exists() else None, skipped=True)
        return True
    log(f"去人聲：{base}")
    event("separating", base=base, title=track.title, artist=track.artist)
    t0 = time.time()
    audio = decode(track.audio)
    if audio.shape[1] < SAMPLE_RATE:
        raise RuntimeError("音檔太短或無法讀取")
    inst, vocals = separate(audio, args.model)
    peak = max(float(abs(inst).max()), float(abs(vocals).max()), float(abs(inst + vocals).max()))
    if peak > 0.98:  # 兩軌一起縮放，避免爆音，也保持 伴奏+人聲 = 原曲
        inst, vocals = inst * (0.98 / peak), vocals * (0.98 / peak)
    mono = to_mono16k(vocals)
    pitch = melody_pitch(vocals, mono)
    voiced = sum(1 for b in pitch if b) / max(len(pitch), 1)
    log(f"   原唱音高：{len(pitch)} 點，有唱的部分佔 {voiced:.0%}（評分用）")
    encode(inst, inst_path, track, "伴唱", args.bitrate, pitch)
    if not args.no_vocals:
        encode(vocals, vocal_path, track, "人聲", args.bitrate)
    lrc_name = None
    if not args.no_lyrics:
        lrc_name = save_lyrics(track.title, track.artist, audio.shape[1] / SAMPLE_RATE,
                               lyrics.voiced_from_pitch(pitch), out_dir / (base + LRC_SUFFIX), mono, pitch)
    log(f"完成（{time.time() - t0:.0f} 秒）：{inst_path.name}")
    event("done", base=base, title=track.title, artist=track.artist, inst=inst_path.name,
          vocals=None if args.no_vocals else vocal_path.name, lyrics=lrc_name)
    return True


def main() -> int:
    p = argparse.ArgumentParser(description="車上K歌：YouTube／Spotify／歌名／音檔 → 去人聲伴唱檔")
    p.add_argument("inputs", nargs="*", help="YouTube 網址、Spotify 歌曲連結、歌名（自動搜尋 YouTube）或本機音檔")
    p.add_argument("-o", "--out", type=Path, default=DEFAULT_OUT, help=f"輸出資料夾（預設 {DEFAULT_OUT}）")
    p.add_argument("--playlist", action="store_true", help="網址是播放清單時，下載整個清單")
    p.add_argument("--no-vocals", action="store_true", help="不輸出人聲檔（App 就只能播伴唱）")
    p.add_argument("--model", default="htdemucs", help="Demucs 模型（htdemucs 快；htdemucs_ft 較準但慢 4 倍）")
    p.add_argument("--bitrate", default="192k", help="AAC 位元率（預設 192k）")
    p.add_argument("--force", action="store_true", help="已經轉過的歌也重做")
    p.add_argument("--no-lyrics", action="store_true", help="不要找歌詞")
    p.add_argument("--lyrics-only", action="store_true", help="不轉檔，只幫輸出資料夾裡的歌補上歌詞（和逐字時間）")
    p.add_argument("--events", action="store_true", help=argparse.SUPPRESS)
    # 伺服器用：已經在 YouTube 找好的 Spotify 歌曲（輸入是 YouTube 網址，歌名、歌手用 Spotify 的）
    p.add_argument("--spotify-id", help=argparse.SUPPRESS)
    p.add_argument("--title", help=argparse.SUPPRESS)
    p.add_argument("--artist", help=argparse.SUPPRESS)
    args = p.parse_args()
    if args.lyrics_only:
        args.out.mkdir(parents=True, exist_ok=True)
        backfill_lyrics(args.out, args.force)
        return 0
    if not args.inputs:
        p.error("請給 YouTube 網址、Spotify 歌曲連結、歌名或音檔")
    global EVENTS
    EVENTS = args.events

    args.out.mkdir(parents=True, exist_ok=True)
    items = expand_spotify_lists([i.strip() for i in args.inputs if i.strip()])
    ok = fail = 0
    started = time.time()

    def resolve(item: str, work: Path) -> list[Track]:
        path = Path(item).expanduser()
        if path.is_file():
            return [local_track(path, work)]
        if path.is_dir():
            return [local_track(f, work) for f in sorted(path.iterdir())
                    if f.suffix.lower() in AUDIO_EXTS and ".伴唱" not in f.name and ".人聲" not in f.name]
        event("downloading", item=item)
        if spotify.find_link(item) and not re.match(r"https?://(www\.|m\.|music\.)?youtu", item):
            tracks = fetch_spotify(item, work)
        else:
            tracks = fetch_youtube(item, work, args.playlist)
            if args.spotify_id and args.title:
                use_spotify_names(tracks, args.spotify_id, args.title, args.artist)
        log(f"   下載好了：{', '.join(t.base_name for t in tracks)}")
        return tracks

    # 邊下載邊去人聲：處理第 1 首時，後面的歌已經在背景下載
    with tempfile.TemporaryDirectory(prefix="carkaraoke-") as tmp, ThreadPoolExecutor(max_workers=2) as pool:
        jobs = []
        for n, item in enumerate(items):
            work = Path(tmp) / str(n)
            work.mkdir()
            jobs.append((item, pool.submit(resolve, item, work)))
        for n, (item, job) in enumerate(jobs, 1):
            try:
                tracks = job.result()
            except Exception as e:
                fail += 1
                log(f"錯誤：{e}")
                event("failed", item=item, error=str(e))
                continue
            for t in tracks:
                try:
                    log(f"\n[{n}/{len(jobs)}]")
                    process(t, args.out, args)
                    ok += 1
                except Exception as e:
                    fail += 1
                    log(f"錯誤：{t.title}：{e}")
                    event("failed", item=item, title=t.title, error=str(e))
    log(f"\n完成 {ok} 首" + (f"，失敗 {fail} 首" if fail else "")
        + f"，共 {time.time() - started:.0f} 秒。檔案在：{args.out}")
    return 1 if fail and not ok else 0


if __name__ == "__main__":
    sys.exit(main())

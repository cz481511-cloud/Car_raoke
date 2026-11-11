"""車上K歌 — 逐字歌詞時間（KTV 跑字對上每一個字）

LRCLIB 的歌詞只有「每一行」的時間；這裡用去人聲時得到的人聲軌，找出每個字開始唱的時間。

做法（傳統訊號處理，不是 AI、不花 token）：
唱到新的字時，聲音通常會有「起音」：子音的噪音、音量突然變大、或音高換到下一個音。
先算出人聲軌每 10ms 的起音強度，再在每一行的時間範圍內用動態規劃挑出 N 個位置
（N = 這一行的字數；英文是單字數），讓「挑到的位置都是明顯的起音」而且「每個字的長度不要差太多」。
整首歌在 Mac 上約 1～3 秒；結果寫進 .lrc 的逐字標記 <mm:ss.xx>，手機只要讀，不用運算。
"""
from __future__ import annotations

import re

SR = 16000              # 輸入：16kHz 單聲道人聲
FPS = 100               # 每 10ms 一格
HOP = SR // FPS
NFFT = 512
PITCH_FPS = 20          # 評分用的音高資料（CKP1）每秒 20 點

_CJK = re.compile(r"[぀-ヿ㐀-䶿一-鿿豈-﫿가-힯]")
_WORD = re.compile(r"[0-9A-Za-zÀ-ɏ]+(?:['’][A-Za-z]+)*")

# 調整參數（用合成歌聲和實際歌曲測過）
DMIN = 0.07             # 一個字最短 70ms
DMAX = 3.0              # 句子中間的字最長 3 秒（句尾拉長音不限）
LAMBDA = 0.35           # 字長偏離平均的懲罰
MU = 0.6                # 第一個字偏離 LRC 行首時間的懲罰（每 0.25 秒）
SILENT_PENALTY = 1.2    # 在沒聲音的地方「開始唱一個字」的懲罰


# ---------------------------------------------------------------- 切字

def _syllables(word: str) -> int:
    if word.isdigit():
        return max(1, len(word))
    w = word.lower()
    n = len(re.findall(r"[aeiouyàâäéèêëîïôöùûü]+", w))
    if n > 1 and w.endswith("e") and not w.endswith(("le", "ee", "ye")):
        n -= 1
    return max(1, n)


def units(text: str) -> list[tuple[int, int, float, bool]]:
    """一行歌詞 → [(開始, 結束, 權重, 句尾?)]。開始／結束是 text 的字元位置。

    中日韓每個字一個單位；英文每個單字一個單位（權重 = 音節數）。
    標點和空白併進前一個單位一起變色；後面接著標點／空白的單位視為「句尾」，可以拉長音。
    """
    spans: list[list] = []
    i, n = 0, len(text)
    while i < n:
        if _CJK.match(text[i]):
            spans.append([i, i + 1, 1.0])
            i += 1
            continue
        m = _WORD.match(text, i)
        if m:
            spans.append([i, m.end(), float(_syllables(m.group()))])
            i = m.end()
            continue
        i += 1
    if not spans:
        return []
    out = []
    for k, (a, b, w) in enumerate(spans):
        start = 0 if k == 0 else a
        end = spans[k + 1][0] if k + 1 < len(spans) else n
        phrase_end = k + 1 == len(spans) or text[b:end].strip() != "" or " " in text[b:end] or "　" in text[b:end]
        out.append((start, end, w, phrase_end))
    return out


# ---------------------------------------------------------------- 起音特徵

class Features:
    """人聲軌每 10ms 的：起音強度（頻譜變化）、音量（dB）、有沒有聲音、音高跳動"""

    def __init__(self, mono16k, pitch: bytes | None = None):
        import numpy as np
        x = np.asarray(mono16k, dtype=np.float64)
        x = np.concatenate([np.zeros(NFFT // 2), x, np.zeros(NFFT)])
        n = max(0, (len(x) - NFFT) // HOP)
        self.n = n
        win = np.hanning(NFFT)
        lo, hi = 3, 193  # 約 94 Hz～6 kHz
        logmag = np.zeros((n, hi - lo), dtype=np.float32)
        db = np.zeros(n)
        step = 4096
        for s in range(0, n, step):
            idx = np.arange(s, min(n, s + step))
            frames = x[idx[:, None] * HOP + np.arange(NFFT)[None, :]]
            db[idx] = 10 * np.log10(np.mean(frames ** 2, axis=1) + 1e-10)
            spec = np.abs(np.fft.rfft(frames * win, axis=1))[:, lo:hi]
            logmag[idx] = np.log1p(200 * spec)
        diff = np.zeros_like(logmag)
        diff[2:] = logmag[2:] - logmag[:-2]
        flux = np.maximum(diff, 0).sum(axis=1)
        flux[2:] = flux[2:] - 0.5 * np.minimum(flux[2:], np.maximum(-diff[2:], 0).sum(axis=1))  # 整體變小聲不算起音
        self.flux = np.maximum(flux, 0)
        # 「有在唱」的門檻：比最大聲小 30dB 以內，而且明顯高過安靜時的雜訊（去人聲殘留）
        self.gate = max(float(np.percentile(db, 95)) - 30.0, float(np.percentile(db, 10)) + 10.0, -62.0) if n else -60.0
        self.db = db
        self.voiced = db > self.gate
        smooth = np.convolve(np.maximum(db, self.gate), np.ones(5) / 5, mode="same")
        rise = np.zeros(n)
        rise[4:-4] = smooth[8:] - smooth[:-8]
        self.rise = np.maximum(rise, 0)
        self.pjump = np.zeros(n)
        if pitch:
            p = np.frombuffer(pitch, dtype=np.uint8).astype(np.float64)
            midi = np.where(p > 0, p / 4 + 24, np.nan)
            up = np.repeat(midi, FPS // PITCH_FPS)[:n]
            up = np.concatenate([up, np.full(n - len(up), np.nan)])
            jump = np.zeros(n)
            a, b = up[:-8], up[8:]
            ok = ~np.isnan(a) & ~np.isnan(b)
            jump[4:-4][ok] = np.abs(b[ok] - a[ok])
            self.pjump = np.clip((jump - 0.7) / 1.5, 0, 1)  # 換了大約一個半音以上

    def score(self, a: int, b: int):
        """a～b 這段每一格「像是一個字開始」的分數"""
        import numpy as np
        flux, rise = self.flux[a:b], self.rise[a:b]
        voiced = self.voiced[a:b + 10].astype(float)
        fn = flux / max(float(np.percentile(flux, 97)), 1e-6) if len(flux) else flux
        rn = rise / max(float(np.percentile(rise, 97)), 3.0) if len(rise) else rise
        s = np.minimum(fn, 1.5) + 0.8 * np.minimum(rn, 1.5) + 0.7 * self.pjump[a:b]
        # 一個字開始後應該有聲音：看後面 80ms 有幾成在唱
        ahead = np.convolve(voiced, np.ones(8) / 8, mode="full")[7:7 + (b - a)]
        ahead = np.concatenate([ahead, np.zeros(max(0, (b - a) - len(ahead)))])
        return s - SILENT_PENALTY * (1 - ahead)


# ---------------------------------------------------------------- 對齊一行

def _align(score, weights, finals, t0: int, end: int):
    """動態規劃：在 score（每格分數）上挑 len(weights) 個開始位置，最後一個字唱到 end 為止。"""
    import numpy as np
    F, N = len(score), len(weights)
    dmin, dmax = int(DMIN * FPS), int(DMAX * FPS)
    if N == 0 or end - N * dmin < 0:
        return None
    u = max((end - max(t0, 0)) / sum(weights), dmin)  # 平均每個權重單位多長
    NEG = -1e18
    f = np.arange(F)
    dp = np.where(f <= end - N * dmin, score - MU * ((f - t0) / 25.0) ** 2, NEG)
    backs = []
    for i in range(1, N):
        exp_d = weights[i - 1] * u
        best = np.full(F, NEG)
        arg = np.zeros(F, dtype=np.int32)
        top = (F - 1) if finals[i - 1] else min(dmax, F - 1)
        for d in range(dmin, top + 1):
            r = np.log(d / exp_d)
            pen = LAMBDA * r * r if (r < 0 or not finals[i - 1]) else LAMBDA * 0.15 * r * r
            cand = dp[: F - d] - pen
            seg = best[d:]
            better = cand > seg
            if better.any():
                seg[better] = cand[better]
                arg[d:][better] = f[: F - d][better]
        dp = np.where(f <= end - (N - i) * dmin, best + score, NEG)
        backs.append(arg)
    # 最後一個字：唱到 end
    exp_d = weights[-1] * u
    last_d = np.maximum(end - f, 1)
    r = np.log(last_d / exp_d)
    total = dp - np.where(r < 0, LAMBDA * r * r, LAMBDA * 0.15 * r * r)
    total = np.where(end - f >= dmin, total, NEG)
    s = int(np.argmax(total))
    if total[s] <= NEG / 2:
        return None
    starts = [s]
    for arg in reversed(backs):
        s = int(arg[s])
        starts.append(s)
    return starts[::-1]


def _line_end(voiced, next_start: int) -> int:
    """這一行唱完的位置。LRC 下一行的時間可能晚一點，所以視窗尾巴可能已經是下一行的第一個字：
    停頓之後、在下一行時間前後 0.5 秒內才開始的那段聲音，算下一行的。"""
    import numpy as np
    v = np.concatenate([[False], np.asarray(voiced, dtype=bool), [False]])
    edges = np.flatnonzero(v[1:] != v[:-1])
    runs = list(zip(edges[::2], edges[1::2]))  # (開始, 結束)
    while len(runs) > 1 and runs[-1][0] >= next_start - 50 and runs[-1][0] - runs[-2][1] >= 12:
        runs.pop()
    return int(runs[-1][1])


def add_word_times(lines: list[tuple[float, str]], mono16k, pitch: bytes | None = None):
    """[(秒, 歌詞)] → [(秒, 歌詞, [(秒, 這段文字)], 唱完的秒)]；對不出來的行維持 (秒, 歌詞)。"""
    import numpy as np
    feat = Features(mono16k, pitch)
    out: list[tuple] = []
    bound = 0        # 下一行的第一個字不能早於這裡（上一行最後一個字開始後 0.15 秒）
    timed = 0
    sung = sum(1 for _, s in lines if s)
    for k, (t, text) in enumerate(lines):
        us = units(text) if text else []
        if not us:
            out.append((t, text))
            continue
        nxt = lines[k + 1][0] if k + 1 < len(lines) else t + 12.0
        floor = int(out[-1][0] * FPS) + 1 if out else 0  # 行的順序不能亂
        a = max(int((t - 0.6) * FPS), bound, floor, 0)
        b = min(int((nxt + 0.1) * FPS), feat.n)
        if b - a < len(us) * int(DMIN * FPS) + 5:
            out.append((t, text))
            continue
        v = feat.voiced[a:b]
        on = np.nonzero(v)[0]
        t0 = int(round(t * FPS)) - a
        if len(on) == 0:
            out.append((t, text))
            continue
        end = _line_end(v, int(round(nxt * FPS)) - a)
        if (v[max(t0, 0):end].mean() if end > max(t0, 0) else 0) < 0.3:
            out.append((t, text))  # 這一行幾乎沒有人聲（和聲、口白…）：不做逐字
            continue
        score = feat.score(a, b)[:end]
        starts = _align(score, [w for _, _, w, _ in us], [fin for _, _, _, fin in us], t0, end)
        if not starts:
            out.append((t, text))
            continue
        words = [(round((a + s) / FPS, 2), text[us[i][0]:us[i][1]]) for i, s in enumerate(starts)]
        out.append((round(min(t, words[0][0]), 2), text, words, round((a + end) / FPS, 2)))
        bound = a + starts[-1] + int(0.15 * FPS)
        timed += 1
    # 連著唱的兩行：上一行唱完的時間 = 下一行第一個字開始
    for k in range(len(out) - 1):
        if len(out[k]) == 4:
            nxt = next((o for o in out[k + 1:] if o[1]), None)
            if nxt and len(nxt) == 4 and nxt[2][0][0] < out[k][3]:
                t, text, words, _ = out[k]
                out[k] = (t, text, words, max(nxt[2][0][0], round(words[-1][0] + DMIN, 2)))
    return out, timed, sung

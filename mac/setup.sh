#!/bin/bash
# 車上K歌：安裝 Mac 端轉換工具（只需要做一次）
set -e
cd "$(dirname "$0")"
command -v brew >/dev/null || { echo "請先安裝 Homebrew：https://brew.sh"; exit 1; }
brew install ffmpeg yt-dlp xcodegen uv
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python demucs numpy
chmod +x ../做伴唱.command ../配對碼.command
echo "安裝完成。之後雙擊「做伴唱.command」就能使用。"

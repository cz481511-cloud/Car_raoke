#!/bin/bash
# 車上K歌：雙擊這個檔案，貼上 YouTube 網址、Spotify 歌曲／播放清單連結或輸入歌名，就會做出去人聲的伴唱檔。
cd "$(dirname "$0")" || exit 1
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
PY="mac/.venv/bin/python"

if [ ! -x "$PY" ]; then
  echo "還沒安裝轉換工具，請先在終端機執行：bash mac/setup.sh"
  read -r -p "按 Enter 關閉…" _
  exit 1
fi

echo "車上K歌：做伴唱"
echo "一行一首：可以貼 YouTube 網址、Spotify 歌曲／播放清單連結、輸入歌名（例如：周杰倫 晴天），或把音檔拖進來。"
echo "全部輸入完，直接按 Enter（空白行）開始。"
echo
items=()
while true; do
  read -r -p "> " line
  line="${line%"${line##*[![:space:]]}"}"   # 去掉結尾空白（拖曳檔案時會多一個空白）
  [ -z "$line" ] && break
  line="${line//\\ / }"                      # 拖曳進來的路徑會把空白跳脫成 "\ "
  items+=("$line")
done

if [ ${#items[@]} -eq 0 ]; then
  echo "沒有輸入任何歌曲。"
  exit 0
fi

"$PY" -I mac/karaoke.py "${items[@]}"
open songs
echo
read -r -p "完成！把 songs 資料夾裡的檔案傳到 iPhone 的「車上K歌」。按 Enter 關閉…" _

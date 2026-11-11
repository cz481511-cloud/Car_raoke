#!/bin/bash
# 車上K歌：顯示這台 Mac 的配對碼（手機第一次連到這台 Mac 時要輸入）
cd "$(dirname "$0")" || exit 1
PY="mac/.venv/bin/python"
[ -x "$PY" ] || PY="/usr/bin/python3"   # pairing.py 只用 Python 標準函式庫

"$PY" -I mac/pairing.py
echo
echo "如果手機遺失、或不想讓之前配對過的手機再連進來，可以換一組新的配對碼。"
read -r -p "要換新的配對碼嗎？輸入 y 再按 Enter；直接按 Enter 關閉：" ans
if [ "$ans" = "y" ] || [ "$ans" = "Y" ]; then
  echo
  "$PY" -I mac/pairing.py --reset
  echo
  read -r -p "按 Enter 關閉…" _
fi

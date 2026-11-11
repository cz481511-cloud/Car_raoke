#!/bin/bash
# 讓「車上K歌伺服器」在這台 Mac 登入後自動在背景執行（關掉視窗、重開機都會自己啟動）
# 再執行一次＝重新啟動伺服器。要移除請執行 uninstall-server.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL=com.example.carkaraoke.server
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/Library/Logs/CarKaraoke"
PY="$HERE/.venv/bin/python"
DOMAIN="gui/$(id -u)"

[ -x "$PY" ] || { echo "錯誤：找不到 $PY，請先執行 setup.sh"; exit 1; }
case "$HERE" in
  "$HOME/Desktop"*|"$HOME/Documents"*|"$HOME/Downloads"*)
    echo "錯誤：背景程式無法讀取「桌面／文件／下載項目」資料夾，請把整個 CarKaraoke 資料夾移到家目錄（例如 ~/CarKaraoke）再執行"; exit 1;;
esac
mkdir -p "$HOME/Library/LaunchAgents" "$LOGDIR"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string>
    <string>-I</string>
    <string>$HERE/server.py</string>
  </array>
  <key>WorkingDirectory</key><string>$HERE</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>LANG</key><string>zh_TW.UTF-8</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOGDIR/server.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/server.log</string>
</dict>
</plist>
PLIST
plutil -lint "$PLIST" >/dev/null

# 先停掉舊的（停止是非同步的，要等它真的結束才能重新登記）
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
for _ in $(seq 1 30); do
  launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
  sleep 0.5
done
for attempt in 1 2 3; do
  launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null && break
  [ $attempt = 3 ] && { echo "錯誤：無法啟動伺服器（launchctl bootstrap 失敗）"; exit 1; }
  sleep 2
done

for _ in $(seq 1 20); do
  if curl -sf --max-time 1 http://127.0.0.1:8765/ping >/dev/null; then
    IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
    echo "車上K歌伺服器已在背景執行，之後開機會自動啟動"
    echo "   iPhone 連同一個 Wi-Fi 就會自動找到這台 Mac${IP:+（手動輸入位址：$IP:8765）}"
    echo "   手機第一次連線時要輸入配對碼：$("$PY" -I "$HERE/pairing.py" --code)（之後也可以雙擊「配對碼.command」查看）"
    echo "   紀錄檔：$LOGDIR/server.log"
    echo "   如果 Mac 跳出「是否允許 python3 接受連入的網路連線」，請按「允許」"
    exit 0
  fi
  sleep 0.5
done
echo "錯誤：伺服器沒有啟動，最後幾行紀錄："; tail -20 "$LOGDIR/server.log"; exit 1

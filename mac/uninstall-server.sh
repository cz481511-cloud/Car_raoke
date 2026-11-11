#!/bin/bash
# 停止並移除「車上K歌伺服器」的自動啟動（已經做好的歌不會被刪除）
LABEL=com.example.carkaraoke.server
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "已停止並移除自動啟動。要再開啟請執行 install-server.sh"

#!/bin/bash

# エラー時に停止
set -e

if [ "$EUID" -ne 0 ]; then 
    echo "このスクリプトはroot権限で実行する必要があります"
    exit 1
fi

# インストール先にコピー
cp minecraft-server-control.sh /usr/local/bin/
chmod +x /usr/local/bin/minecraft-server-control.sh

echo "インストールが完了しました"
echo "minecraft-server-control.sh --config <config file> で設定ファイルを指定して起動してください"


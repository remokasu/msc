# Minecraft Server Control

自動でMinecraftサーバーの起動/停止、バックアップを行うためのスケジューラ


## 機能

- 時間帯を指定したサーバーの自動起動/停止
- 自動バックアップ（世界データ、設定ファイルなど）


## 依存パッケージのインストール
```bash
sudo apt-get install screen jq curl
```

## 使い方

### 1. インストール

付属の`install.sh`を使用してインストールします：

```bash
sudo ./install.sh
```

インストールスクリプトは以下の処理を行います：
- 管理スクリプトを `/usr/local/bin/` にコピー
- 実行権限の付与


### 2. 設定ファイルの作成

`config.json`：

```json
{
    "server": {
        "dir": "/opt/minecraft",          // Minecraftサーバーのディレクトリ
        "jar": "minecraft_server.jar",    // サーバーJARファイル名
        "java_path": "/usr/bin/java",     // Javaの実行ファイルパス
        "max_memory": "4G",               // 最大メモリ使用量
        "screen_name": "minecraft"        // screenセッション名
    },
    "backup": {
        "dest": "/opt/backup/minecraft",  // バックアップ先ディレクトリ
        "items": [                        // バックアップ対象
            "/opt/minecraft/world",
            "/opt/minecraft/server.properties",
            "/opt/minecraft/whitelist.json",
            "/opt/minecraft/ops.json"
        ]
    },
    "schedule": {
        "repeat": true,                   // スケジュールの繰り返し
        "intervals": [                    // 運用時間帯
            {
                "start": "10:00",         // 開始時刻
                "stop": "11:59",          // 終了時刻
                "backup": false           // バックアップの有無
            },
            {
                "start": "22:00",
                "stop": "23:59",
                "backup": true
            }
        ]
    }
}
```

### 2. スクリプトの実行

#### バックグラウンドでの実行（推奨）
``` bash
nohup minecraft-server-control.sh --config config.json > minecraft.log 2>&1 &
```

#### バックグラウンドでの実行時のログ確認
``` bash
tail -f minecraft.log
```

#### コンソールの表示
``` bash
screen -r minecraft
```

#### 通常の実行
``` bash
minecraft-server-control.sh --config config.json
```

### 3. その他の操作

#### ステータス確認
``` bash
minecraft-server-control.sh --config config.json --status
```

#### 即時バックアップ実行
``` bash
minecraft-server-control.sh --config config.json --backup-now
```

#### 古いバックアップの削除（30日以上前）
``` bash
minecraft-server-control.sh --config config.json --clean
```

#### ロックファイルのクリーンアップ
``` bash
minecraft-server-control.sh --config config.json --clean-lock
```

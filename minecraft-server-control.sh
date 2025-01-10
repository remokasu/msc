#!/bin/bash

export CONFIG_FILE=""


# ログレベル
declare -r LOG_LEVEL_ERROR="ERROR"
declare -r LOG_LEVEL_WARN="WARN"
declare -r LOG_LEVEL_INFO="INFO"
declare -r LOG_LEVEL_DEBUG="DEBUG"

# シグナルハンドリングの設定
trap 'cleanup; exit 0' SIGTERM SIGINT SIGHUP SIGQUIT

# ログ関数
log() {
    local level="$1"
    shift
    case "$level" in
        "$LOG_LEVEL_ERROR"|"$LOG_LEVEL_WARN"|"$LOG_LEVEL_INFO")
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" ;;
        *)
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] 不正なログレベル: $level" ;;
    esac
}

# ステータス表示用の関数
log_status() {
    echo "$@"
}

# ヘルプメッセージ表示関数
show_help() {
    cat << EOF
使用方法: $0 --config <設定ファイル> [オプション]

実行方法:
  バックグラウンド実行: nohup $0 --config <設定ファイル> [オプション] > minecraft.log 2>&1 &
  例) nohup $0 --config server.json > minecraft.log 2>&1 &
    ※ ログファイルは minecraft.log に出力されます
    ログの監視: tail -f minecraft.log

オプション:
  --config <file> : 設定ファイルを指定（必須）
  --backup-now    : バックアップを即座に実行
  --clean         : 30日以上前の古いバックアップを削除
  --clean-lock    : ロックファイルを削除
  --status        : サーバーの状態を表示
  --help, -h      : このヘルプメッセージを表示

モード説明:
  スケジュールモード : 設定ファイルで指定された時間帯でサーバーを起動・停止
      - 各時間帯でバックアップの有無を設定可能
      - repeat設定で繰り返し実行の有無を制御

設定ファイル:
  JSON形式で以下の設定が必要:
  - サーバー設定（ディレクトリ、JAR、Javaパス、メモリ）
  - バックアップ設定（保存先、対象項目）
  - 実行スケジュール（時間帯、バックアップ指定）

注意:
  - SSHセッションが切断されても継続動作させるためにnohupを使用
  - ステータス確認: $0 --config <file> --status
  - プロセス停止: killall $(basename $0)
EOF
}


# コマンドライン引数の処理
process_command() {
    local command="$1"
    case "$command" in
        backup)
            backup_world || exit 1
            ;;
        clean)
            log "$LOG_LEVEL_INFO" "古いバックアップを削除します..."
            find "$BACKUP_DIR" -name "world_backup_*.tar.gz" -mtime +30 -delete
            log "$LOG_LEVEL_INFO" "クリーンアップが完了しました"
            ;;
        clean-lock)
            log "$LOG_LEVEL_INFO" "ロックファイルを削除します..."
            rm -f "$LOCK_FILE"
            log "$LOG_LEVEL_INFO" "ロックファイルを削除しました"
            ;;
        status)
            show_status
            ;;
    esac
}

# コマンドライン引数の解析
COMMAND=""


# 設定を読み込む関数
load_config() {
    export SERVER_DIR=$(jq -r .server.dir "$CONFIG_FILE")
    export SERVER_JAR=$(jq -r .server.jar "$CONFIG_FILE")
    export JAVA_PATH=$(jq -r .server.java_path "$CONFIG_FILE")
    export MAX_MEMORY=$(jq -r .server.max_memory "$CONFIG_FILE")
    export SCREEN_NAME=$(jq -r .server.screen_name "$CONFIG_FILE")
    export BACKUP_DIR=$(jq -r .backup.dest "$CONFIG_FILE")
    export LOCK_FILE=$(jq -r .lock.file "$CONFIG_FILE")
    # バックアップ対象の読み込み
    readarray -t BACKUP_ITEMS < <(jq -r .backup.items[] "$CONFIG_FILE")
}


# プレイヤーリスト取得関数
get_player_list() {
    if ! screen -list | grep -q "$SCREEN_NAME"; then
        return 1
    fi
    # listコマンドを送信
    screen -S "$SCREEN_NAME" -p 0 -X stuff "list\n"
    sleep 2  # 結果を待つ
    # ログから最新のプレイヤーリストを取得
    local player_info=$(tail -n 20 "$SERVER_DIR/logs/latest.log" | grep "There are .* players online" | tail -n 1)
    if [ -n "$player_info" ]; then
        echo "$player_info"
        return 0
    fi
    return 1
}


# 現在時刻取得関数
get_current_time() {
    date +%H:%M
}


# ステータス表示関数
show_status() {
    log_status "===== Minecraft サーバー状態 ====="

    # サーバー稼働状態確認
    if screen -list | grep -q "$SCREEN_NAME"; then
        log_status "サーバー状態: 稼働中"
    else
        log_status "サーバー状態: 停止中"
    fi

    # 次のインターバル情報を表示
    local current_time=$(get_current_time)
    local current_interval=$(jq -r --arg time "$current_time" '.schedule.intervals[] | select(.start <= $time and .stop > $time)' "$CONFIG_FILE")
    if [ -n "$current_interval" ]; then
        local stop_time=$(echo "$current_interval" | jq -r .stop)
        log_status "次のアクション: $stop_time に停止予定"
    else
        local next_interval=$(jq -r --arg time "$current_time" '.schedule.intervals[] | select(.start > $time)' "$CONFIG_FILE" | head -n 1)
        if [ -n "$next_interval" ]; then
            local start_time=$(echo "$next_interval" | jq -r .start)
            log_status "次のアクション: $start_time に起動予定"
        else
            # repeatがtrueの場合は最初のインターバルを表示
            if [ "$(jq -r .schedule.repeat "$CONFIG_FILE")" = "true" ]; then
                local first_interval=$(jq -r '.schedule.intervals[0]' "$CONFIG_FILE")
                local start_time=$(echo "$first_interval" | jq -r .start)
                log_status "次のアクション: $start_time に起動予定（次回スケジュール）"
            else
                log_status "次のアクション: 予定なし"
            fi
        fi
    fi

    # バックアップ容量確認
    if [ -d "$BACKUP_DIR" ]; then
        local backup_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1)
        local backup_count=$(find "$BACKUP_DIR" -name "world_backup_*.tar.gz" | wc -l)
        log_status "バックアップ情報:"
        log_status "  - 合計容量: ${backup_size:-不明}"
        log_status "  - バックアップ数: ${backup_count:-0}個"
    else
        log_status "バックアップ情報: バックアップディレクトリが存在しません"
    fi

    # 現在のプレイヤー数確認
    if screen -list | grep -q "$SCREEN_NAME"; then
        log_status "プレイヤー情報:"
        local player_info=$(get_player_list)
        if [ -n "$player_info" ]; then
            log_status "  $player_info"
        else
            log_status "  プレイヤー情報を取得できません"
        fi
    fi
    log_status "================================"
}

# 時刻フォーマットの検証
validate_time_format() {
    local time="$1"
    if [[ "$time" = "24:00" ]] || [[ "$time" =~ ^([0-9]|0[0-9]|1[0-9]|2[0-3]):[0-5][0-9]$ ]]; then
        return 0
    fi
    return 1
}


# 時刻を分単位の数値に変換する関数
time_to_minutes() {
    local time="$1"
    local hour min
    IFS=: read hour min <<< "$time"
    echo $((10#$hour * 60 + 10#$min))
}


# 設定ファイルの検証
validate_config() {
   # 必須フィールドの確認
   local required_fields=(
       ".server.dir" ".server.java_path" ".server.jar"
       ".server.max_memory" ".server.screen_name"
       ".backup.dest" ".backup.items"
       ".schedule.intervals"
       ".schedule.repeat"
       ".lock.file"
   )

   for field in "${required_fields[@]}"; do
       if [ "$(jq "$field" "$CONFIG_FILE" 2>/dev/null)" = "null" ]; then
           log "$LOG_LEVEL_ERROR" "設定エラー: $field が未定義です"
           return 1
       fi
   done

   # インターバルの存在確認
   local intervals_count=$(jq '.schedule.intervals | length' "$CONFIG_FILE")
   if [ "$intervals_count" -eq 0 ]; then
       log "$LOG_LEVEL_ERROR" "設定エラー: スケジュールが定義されていません"
       return 1
   fi

   # 時刻フォーマットとインターバルの妥当性をチェック
   local prev_stop=""
   while read -r interval; do
       local start_time=$(echo "$interval" | jq -r .start)
       local stop_time=$(echo "$interval" | jq -r .stop)
       local backup=$(echo "$interval" | jq -r .backup)

       # 時刻フォーマットの検証
       if ! validate_time_format "$start_time"; then
           log "$LOG_LEVEL_ERROR" "設定エラー: 不正な開始時刻フォーマット: $start_time"
           return 1
       fi
       if ! validate_time_format "$stop_time"; then
           log "$LOG_LEVEL_ERROR" "設定エラー: 不正な終了時刻フォーマット: $stop_time"
           return 1
       fi

       # backupフラグの検証
       if [[ "$backup" != "true" && "$backup" != "false" ]]; then
           log "$LOG_LEVEL_ERROR" "設定エラー: バックアップフラグは true または false である必要があります"
           return 1
       fi

       # 開始時刻が終了時刻より前であることを確認
       local start_min=$(time_to_minutes "$start_time")
       local stop_min=$(time_to_minutes "$stop_time")
       if [ $start_min -ge $stop_min ] && [ "$stop_time" != "24:00" ]; then
           log "$LOG_LEVEL_ERROR" "設定エラー: 開始時刻($start_time)が終了時刻($stop_time)より後になっています"
           return 1
       fi

       # インターバルの重複チェック
       if [ -n "$prev_stop" ]; then
           local prev_stop_min=$(time_to_minutes "$prev_stop")
           if [ $start_min -lt $prev_stop_min ]; then
               log "$LOG_LEVEL_ERROR" "設定エラー: インターバルが重複しています（$start_time < $prev_stop）"
               return 1
           fi
       fi
       prev_stop=$stop_time

   done < <(jq -c '.schedule.intervals[]' "$CONFIG_FILE")

   # パスの存在確認
   local server_dir=$(jq -r .server.dir "$CONFIG_FILE")
   if [ ! -d "$server_dir" ]; then
       log "$LOG_LEVEL_ERROR" "設定エラー: サーバーディレクトリが存在しません: $server_dir"
       return 1
   fi

   local backup_dir=$(jq -r .backup.dest "$CONFIG_FILE")
   if [ ! -d "$backup_dir" ]; then
       log "$LOG_LEVEL_ERROR" "設定エラー: バックアップディレクトリが存在しません: $backup_dir"
       return 1
   fi

   # Javaパスの確認
   local java_path=$(jq -r .server.java_path "$CONFIG_FILE")
   if [ ! -x "$java_path" ]; then
       log "$LOG_LEVEL_ERROR" "設定エラー: Javaの実行ファイルが存在しないか実行権限がありません: $java_path"
       return 1
   fi

   # メモリ設定の検証
   local max_memory=$(jq -r .server.max_memory "$CONFIG_FILE")
   if ! [[ "$max_memory" =~ ^[1-9][0-9]*[MGmg]$ ]]; then
       log "$LOG_LEVEL_ERROR" "設定エラー: 不正なメモリ設定です: $max_memory"
       return 1
   fi

   # バックアップ項目の存在確認
   while read -r item; do
       local full_path
       if [[ "$item" = /* ]]; then
           full_path="$item"
       else
           full_path="$server_dir/$item"
       fi
       if [ ! -e "$full_path" ]; then
           log "$LOG_LEVEL_WARN" "警告: バックアップ対象が存在しません: $item"
       fi
   done < <(jq -r '.backup.items[]' "$CONFIG_FILE")

   return 0
}


# 時刻処理用の関数
get_seconds_until() {
    local target_time="$1"
    local now=$(date +%s)
    local target
    
    # 現在時刻を基準に目標時刻のUNIX時間を計算
    if [ "$target_time" = "24:00" ]; then
        target=$(date -d "tomorrow 00:00:00" +%s)
    else
        target=$(date -d "today $target_time:00" +%s)
        # 目標時刻が過去の場合は翌日の同時刻に設定
        if [ $target -le $now ]; then
            target=$(date -d "tomorrow $target_time:00" +%s)
        fi
    fi
    
    echo $(( target - now ))
}


# cleanup関数の修正
cleanup() {
    [ -z "$LOCK_FILE" ] && return 0

    log "$LOG_LEVEL_INFO" "クリーンアップを開始します..."
    if screen -list | grep -q "$SCREEN_NAME"; then
        log "$LOG_LEVEL_INFO" "実行中のサーバーを停止します..."
        screen -S "$SCREEN_NAME" -p 0 -X stuff "stop\n" || true
        local wait_count=0
        while screen -list | grep -q "$SCREEN_NAME" && [ $wait_count -lt 30 ]; do
            sleep 1
            wait_count=$((wait_count + 1))
        done
        if screen -list | grep -q "$SCREEN_NAME"; then
            screen -S "$SCREEN_NAME" -X quit || true
        fi
    fi
    [ -f "$LOCK_FILE" ] && rm -f "$LOCK_FILE"
    log "$LOG_LEVEL_INFO" "クリーンアップが完了しました"
}


# ロック処理関数
acquire_lock() {
    local lock_dir=$(dirname "$LOCK_FILE")
    if [ ! -d "$lock_dir" ]; then
        mkdir -p "$lock_dir" || {
            log "$LOG_LEVEL_ERROR" "ロックディレクトリの作成に失敗しました: $lock_dir"
            return 1
        }
    fi

    if [ -f "$LOCK_FILE" ]; then
        local old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
        if [ -n "$old_pid" ] && kill -0 "$old_pid" 2>/dev/null; then
            log "$LOG_LEVEL_INFO" "既存のプロセスを終了します (PID: $old_pid)"
            # プロセスグループ全体を終了
            pkill -P "$old_pid"
            kill "$old_pid"
            sleep 1
            if kill -0 "$old_pid" 2>/dev/null; then
                log "$LOG_LEVEL_WARN" "強制終了します"
                pkill -9 -P "$old_pid"
                kill -9 "$old_pid"
            fi
            rm -f "$LOCK_FILE"
        else
            log "$LOG_LEVEL_INFO" "古いロックファイルを削除します"
            rm -f "$LOCK_FILE"
        fi
    fi

    echo $$ > "$LOCK_FILE" || {
        log "$LOG_LEVEL_ERROR" "ロックファイルの作成に失敗しました"
        return 1
    }
    
    chmod 600 "$LOCK_FILE" || {
        log "$LOG_LEVEL_ERROR" "ロックファイルのパーミッション設定に失敗しました"
        rm -f "$LOCK_FILE"
        return 1
    }
    
    return 0
}


# サーバー起動関数
start_server() {
    if screen -list | grep -q "$SCREEN_NAME"; then
        log "$LOG_LEVEL_INFO" "サーバーは既に起動しています"
        return 0
    fi
    local current_dir=$(pwd)  # 現在のディレクトリを保存
    cd "$SERVER_DIR" || return 1
    screen -dmS "$SCREEN_NAME" "$JAVA_PATH" -Xmx"$MAX_MEMORY" -jar "$SERVER_JAR" nogui || return 1
    cd "$current_dir"  # 元のディレクトリに戻る
    log "$LOG_LEVEL_INFO" "サーバーを起動しました - $(date)"
    return 0
}


# サーバー停止関数
stop_server() {
    if ! screen -list | grep -q "$SCREEN_NAME"; then
        log "$LOG_LEVEL_INFO" "サーバーは既に停止しています"
        return 0
    fi
    # 停止予告
    screen -S "$SCREEN_NAME" -p 0 -X stuff "say Server will stop in 1 minute!\n" || true
    sleep 30
    screen -S "$SCREEN_NAME" -p 0 -X stuff "say Server will stop in 30 seconds!\n" || true
    sleep 25
    screen -S "$SCREEN_NAME" -p 0 -X stuff "say Server stopping in 5 seconds!\n" || true
    sleep 5
    # サーバー停止コマンド送信
    screen -S "$SCREEN_NAME" -p 0 -X stuff "stop\n" || true
    # サーバーの停止を待機（最大30秒）
    local wait_count=0
    while screen -list | grep -q "$SCREEN_NAME" && [ $wait_count -lt 30 ]; do
        sleep 1
        wait_count=$((wait_count + 1))
    done
    # 30秒待っても終了しない場合は強制終了
    if screen -list | grep -q "$SCREEN_NAME"; then
        log "$LOG_LEVEL_WARN" "サーバーが応答しないため強制終了します"
        screen -S "$SCREEN_NAME" -X quit || true
    fi
    log "$LOG_LEVEL_INFO" "サーバーを停止しました - $(date)"
    return 0
}


# バックアップ関数
backup_world() {
    local BACKUP_NAME="world_backup_$(date +%Y%m%d_%H%M%S)"
    local TEMP_DIR="$BACKUP_DIR/$BACKUP_NAME"

    # バックアップディレクトリの存在確認と書き込み権限チェック
    if [ ! -d "$BACKUP_DIR" ]; then
        log "$LOG_LEVEL_ERROR" "バックアップディレクトリが存在しません: $BACKUP_DIR"
        return 1
    fi

    if [ ! -w "$BACKUP_DIR" ]; then
        log "$LOG_LEVEL_ERROR" "バックアップディレクトリへの書き込み権限がありません: $BACKUP_DIR"
        return 1
    fi

    # 一時ディレクトリの作成
    mkdir -p "$TEMP_DIR" || {
        log "$LOG_LEVEL_ERROR" "一時ディレクトリの作成に失敗しました: $TEMP_DIR"
        return 1
    }

    # サーバーディレクトリへの移動
    cd "$SERVER_DIR" || {
        log "$LOG_LEVEL_ERROR" "サーバーディレクトリへの移動に失敗しました: $SERVER_DIR"
        rm -rf "$TEMP_DIR"
        return 1
    }

    # バックアップ項目の存在確認とコピー
    local all_items_exist=true
    local missing_items=()

    for item in "${BACKUP_ITEMS[@]}"; do
        local full_path
        if [[ "$item" = /* ]]; then
            full_path="$item"
        else
            full_path="$SERVER_DIR/$item"
        fi

        if [ ! -e "$full_path" ]; then
            all_items_exist=false
            missing_items+=("$item")
        else
            # ディレクトリ構造を維持してコピー
            cp -r "$full_path" "$TEMP_DIR/" || {
                log "$LOG_LEVEL_ERROR" "ファイルのコピーに失敗しました: $item"
                rm -rf "$TEMP_DIR"
                return 1
            }
        fi
    done

    if [ "$all_items_exist" = false ]; then
        log "$LOG_LEVEL_ERROR" "以下のバックアップ項目が見つかりません:"
        for item in "${missing_items[@]}"; do
            log "$LOG_LEVEL_ERROR" "  - $item"
        done
        rm -rf "$TEMP_DIR"
        return 1
    fi

    # バックアップアーカイブの作成
    cd "$BACKUP_DIR" || {
        log "$LOG_LEVEL_ERROR" "バックアップディレクトリへの移動に失敗しました"
        rm -rf "$TEMP_DIR"
        return 1
    }

    tar -czf "${BACKUP_NAME}.tar.gz" "$BACKUP_NAME" 2>/dev/null || {
        log "$LOG_LEVEL_ERROR" "バックアップの作成に失敗しました"
        rm -rf "$TEMP_DIR"
        rm -f "${BACKUP_NAME}.tar.gz"
        return 1
    }

    # 一時ディレクトリの削除
    rm -rf "$TEMP_DIR"

    # バックアップファイルの存在と大きさを確認
    if [ ! -f "${BACKUP_NAME}.tar.gz" ]; then
        log "$LOG_LEVEL_ERROR" "バックアップファイルの作成に失敗しました"
        return 1
    fi

    local backup_size=$(du -h "${BACKUP_NAME}.tar.gz" | cut -f1)
    log "$LOG_LEVEL_INFO" "バックアップを作成しました: $BACKUP_NAME (サイズ: $backup_size)"

    # 古いバックアップの削除
    log "$LOG_LEVEL_INFO" "30日以上前の古いバックアップを削除します"
    local deleted_count=0
    deleted_count=$(find "$BACKUP_DIR" -name "world_backup_*.tar.gz" -mtime +30 -delete -print | wc -l)
    if [ $deleted_count -gt 0 ]; then
        log "$LOG_LEVEL_INFO" "$deleted_count 個の古いバックアップを削除しました"
    fi

    return 0
}


# 時刻を分単位の数値に変換する関数
time_to_minutes() {
    local time="$1"
    local hour min
    if [ "$time" = "24:00" ]; then
        echo $((24 * 60))
        return
    fi
    IFS=: read hour min <<< "$time"
    # 10進数として扱うために10#を付ける
    echo $(( 10#$hour * 60 + 10#$min ))
}


# 現在時刻に合わせて開始インデックスを決定する関数
get_initial_interval_index() {
    local current_time=$(get_current_time)
    local intervals_count=$(jq '.schedule.intervals | length' "$CONFIG_FILE")
    local current_minutes=$(time_to_minutes "$current_time")
    
    # 全インターバルをチェック
    for ((i=0; i<intervals_count; i++)); do
        local interval=$(jq -r --arg idx "$i" '.schedule.intervals[$idx | tonumber]' "$CONFIG_FILE")
        local start_time=$(echo "$interval" | jq -r .start)
        local stop_time=$(echo "$interval" | jq -r .stop)
        
        # 現在時刻がインターバル内か次のインターバルまでの待機中かを判定
        if [ $(time_to_minutes "$current_time") -lt $(time_to_minutes "$stop_time") ]; then
            echo "$i"
            return 0
        fi
    done
    
    # 全インターバルが終了している場合は最初のインターバルに戻る
    echo "0"
    return 0
}

# スケジュールモード
run_schedule() {
    while true; do
        local current_time=$(get_current_time)
        local current_minutes=$(time_to_minutes "$current_time")
        local found_interval=false
        local next_start_time=""
        local min_wait_minutes=1440  # 24時間

        for ((i=0; i<$(jq '.schedule.intervals | length' "$CONFIG_FILE"); i++)); do
            local interval=$(jq -r --arg idx "$i" '.schedule.intervals[$idx | tonumber]' "$CONFIG_FILE")
            local start_time=$(echo "$interval" | jq -r .start)
            local stop_time=$(echo "$interval" | jq -r .stop)
            local start_minutes=$(time_to_minutes "$start_time")
            local stop_minutes=$(time_to_minutes "$stop_time")

            if [ $current_minutes -ge $start_minutes ] && [ $current_minutes -lt $stop_minutes ]; then
                found_interval=true
                start_server
                sleep $((($stop_minutes - $current_minutes) * 60))
                stop_server
                break
            elif [ $current_minutes -lt $start_minutes ]; then
                local wait_minutes=$(($start_minutes - $current_minutes))
                if [ $wait_minutes -lt $min_wait_minutes ]; then
                    min_wait_minutes=$wait_minutes
                    next_start_time=$start_time
                fi
            fi
        done

        if [ "$found_interval" = false ]; then
            log "$LOG_LEVEL_INFO" "次回起動までの待機時間: $min_wait_minutes分"
            sleep $(($min_wait_minutes * 60))
        fi
    done
}


# 前提条件チェック
check_prerequisites() {
    [ -d "$SERVER_DIR" ] || { log "$LOG_LEVEL_ERROR" "サーバーディレクトリ "$SERVER_DIR"が存在しません"; return 1; }
    [ -d "$BACKUP_DIR" ] || { log "$LOG_LEVEL_ERROR" "バックアップディレクトリ "$BACKUP_DIR" が存在しません"; return 1; }
    [ -f "$SERVER_DIR/$SERVER_JAR" ] || { log "$LOG_LEVEL_ERROR" "サーバーJARファイルが見つかりません"; return 1; }
    command -v screen >/dev/null 2>&1 || { log "$LOG_LEVEL_ERROR" "screenがインストールされていません"; return 1; }
    return 0
}


main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --help|-h)
                show_help
                exit 0
                ;;
            --config)
                if [ -z "$2" ]; then
                    echo "エラー: 設定ファイルが指定されていません"
                    echo "使用方法: $0 --config <file> [その他のオプション]"
                    exit 1
                fi
                CONFIG_FILE="$2"
                shift 2
                ;;
            --backup-now)
                COMMAND="backup"
                shift
                ;;
            --clean)
                COMMAND="clean"
                shift
                ;;
            --clean-lock)
                COMMAND="clean-lock"
                shift
                ;;
            --status)
                COMMAND="status"
                shift
                ;;
            *)
                show_help
                exit 1
                ;;
        esac
    done

    if [ -z "$CONFIG_FILE" ]; then
        echo "エラー: 設定ファイルが指定されていません"
        echo "使用方法: $0 --config <file> [その他のオプション]"
        exit 1
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "設定ファイルが見つかりません: $CONFIG_FILE"
        exit 1
    fi

    if ! command -v jq &> /dev/null; then
        echo "jqコマンドが見つかりません。インストールしてください。"
        echo "sudo apt-get install jq"
        exit 1
    fi

    validate_config || exit 1
    load_config || exit 1
    check_prerequisites || exit 1
    acquire_lock || exit 1

    if [ -n "$COMMAND" ]; then
        process_command "$COMMAND"
        exit 0
    fi

    log_status "===== Minecraft サーバー管理デーモン ====="
    log_status ""
    log_status "【サーバー情報】"
    log_status "IPv4アドレス: $(curl -4s ifconfig.me || echo '取得失敗')"
    log_status "IPv6アドレス: $(curl -6s ifconfig.me || echo 'IPv6は利用できません')"
    log_status ""
    log_status "【基本的な使い方】"
    log_status "サーバーコンソールの表示    : screen -r $SCREEN_NAME"
    log_status "コンソールから抜ける        : Ctrl+A を押した後に D を押す"
    log_status "                            (抜けてもサーバーは動き続けます)"
    log_status ""
    log_status "【バックアップ】"
    log_status "保存先: $BACKUP_DIR"
    log_status "※30日以上経過したバックアップは自動的に削除されます"
    log_status ""
    log "$LOG_LEVEL_INFO" "デーモンを開始します..."
    log_status "===================================="
    log_status ""

    run_schedule || {
        log "$LOG_LEVEL_ERROR" "メインループが異常終了しました"
        cleanup
        exit 1
    }

    cleanup
    exit 0
}

main "$@"

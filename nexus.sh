#!/bin/bash

BASE_DIR="$HOME/.nexus"
NODE_ID_FILE="$BASE_DIR/node_ids.conf"
GLIBC_DIR="/opt/glibc-2.39"
NEXUS_CLI_BIN="$HOME/.nexus/bin/nexus-network"
MONITOR_PID_FILE="$BASE_DIR/monitor.pid"
MONITOR_LOG="$BASE_DIR/monitor.log"

function green() { echo -e "\033[32m$1\033[0m"; }
function red()   { echo -e "\033[31m$1\033[0m"; }

function check_node() {
    source ~/.bashrc
    if [ -x "$NEXUS_CLI_BIN" ]; then
        true
    elif command -v nexus-network >/dev/null 2>&1; then
        NEXUS_CLI_BIN="$(command -v nexus-network)"
    else
        green "[*] 未检测到 nexus-network，正在自动安装..."
        curl https://cli.nexus.xyz/ | sh
        source ~/.bashrc
        if [ -x "$NEXUS_CLI_BIN" ]; then
            true
        elif command -v nexus-network >/dev/null 2>&1; then
            NEXUS_CLI_BIN="$(command -v nexus-network)"
        else
            red "nexus-network 安装失败，请检查网络或权限！"
            exit 1
        fi
    fi
}

function check_install_dependencies() {
    green "[*] 检查和安装依赖..."
    deps=(curl build-essential pkg-config libssl-dev git-all protobuf-compiler nodejs npm jq)
    for dep in "${deps[@]}"; do
        if ! dpkg -s $dep >/dev/null 2>&1; then
            apt-get install -y $dep
        fi
    done
    if ! command -v pm2 >/dev/null 2>&1; then
        green "[*] pm2 未安装，正在通过npm全局安装pm2..."
        npm install -g pm2
        export PATH="$PATH:$(npm root -g)/.bin"
    fi
    check_node
    GLIBC_VERSION=$(ldd --version | head -n1 | awk '{print $NF}')
    if [ "$(echo -e "$GLIBC_VERSION\n2.39" | sort -V | head -n1)" != "2.39" ]; then
        green "[*] 检测到GLIBC版本低于2.39，正在安装2.39..."
        install_glibc_239
    else
        green "[*] GLIBC版本符合要求。"
    fi
}

function install_glibc_239() {
    cd /tmp
    apt-get install -y gcc make bison gawk python3
    wget https://ftp.gnu.org/gnu/glibc/glibc-2.39.tar.gz
    tar zxvf glibc-2.39.tar.gz
    cd glibc-2.39
    mkdir build && cd build
    ../configure --prefix=$GLIBC_DIR
    make -j$(nproc)
    make install
    green "[*] GLIBC 2.39 安装完成。"
}

function list_nodes() {
    pm2 jlist | jq -r '.[] | select(.name|startswith("nexus_")) | .name' | sed 's/^nexus_//' | nl
    if [ $? -ne 0 ]; then
        red "当前没有用pm2管理的nexus节点。"
        return 1
    fi
    return 0
}

function id_from_num() {
    ids=($(pm2 jlist | jq -r '.[] | select(.name|startswith("nexus_")) | .name' | sed 's/^nexus_//'))
    idx=$1
    if [ "$idx" -ge 1 ] && [ "$idx" -le "${#ids[@]}" ]; then
        echo "${ids[$((idx-1))]}"
    else
        echo ""
    fi
}

function pm2_start_node() {
    local id="$1"
    local threads="$2"
    check_node
    if [ -z "$id" ]; then
        red "[!] 节点ID为空，已跳过。"
        return
    fi
    GLIBC_VERSION=$(ldd --version | head -n1 | awk '{print $NF}')
    LIBPATH="/opt/glibc-2.39/lib:/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
    pm2 delete "nexus_$id" >/dev/null 2>&1

    if [ "$(echo -e "$GLIBC_VERSION\n2.39" | sort -V | head -n1)" != "2.39" ]; then
        local fullcmd="$GLIBC_DIR/lib/ld-linux-x86-64.so.2 --library-path $LIBPATH $NEXUS_CLI_BIN start --node-id $id --headless --max-threads $threads"
        echo -e "\033[33m[DEBUG] pm2 start bash --name nexus_$id -- -c \"$fullcmd\"\033[0m"
        pm2 start bash --name "nexus_$id" -- -c "$fullcmd"
    else
        local fullcmd="$NEXUS_CLI_BIN start --node-id $id --headless --max-threads $threads"
        echo -e "\033[33m[DEBUG] pm2 start bash --name nexus_$id -- -c \"$fullcmd\"\033[0m"
        pm2 start bash --name "nexus_$id" -- -c "$fullcmd"
    fi
    green "[*] 节点 $id 已用pm2启动！（pm2 logs nexus_$id 可实时查看日志）"
}

function pm2_restart_node() {
    local id="$1"
    if pm2 describe "nexus_$id" >/dev/null 2>&1; then
        pm2 restart "nexus_$id"
        green "[*] 已重启节点 $id"
    else
        red "[!] 节点 $id 未运行，无法重启。"
    fi
}

function pm2_stop_node() {
    local id="$1"
    pm2 delete "nexus_$id"
    green "[*] 已停止并移除节点 $id"
}

function start_nodes_menu() {
    local node_ids=()
    local threads

    if [ -f "$NODE_ID_FILE" ]; then
        last_ids=$(cat "$NODE_ID_FILE")
        green "[*] 检测到上次保存的节点ID: $last_ids"
        read -p "是否继续用这些ID启动节点? (y/n): " use_last
        if [[ "$use_last" == "y" ]]; then
            IFS=',' read -ra node_ids <<< "$last_ids"
        fi
    fi
    if [ "${#node_ids[@]}" -eq 0 ]; then
        read -p "请输入节点ID（多个以英文逗号分隔）: " ids
        IFS=',' read -ra node_ids <<< "$ids"
        echo "$ids" > "$NODE_ID_FILE"
    fi
    read -p "请输入线程数: " threads
    for id in "${node_ids[@]}"; do
        id=$(echo $id | xargs)
        pm2_start_node "$id" "$threads"
    done
}

function restart_menu() {
    list_nodes || return
    read -p "请输入要重启的节点编号（支持1,3,5或1-3）: " sel
    IFS=',' read -ra parts <<< "$sel"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ '-' ]]; then
            IFS='-' read s e <<< "$part"
            for ((i=s;i<=e;i++)); do
                id=$(id_from_num "$i")
                [ -n "$id" ] && pm2_restart_node "$id"
            done
        else
            id=$(id_from_num "$part")
            [ -n "$id" ] && pm2_restart_node "$id"
        fi
    done
}

function delete_menu() {
    list_nodes || return
    read -p "请输入要删除的节点编号（支持1,3,5或1-3）: " sel
    IFS=',' read -ra parts <<< "$sel"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ '-' ]]; then
            IFS='-' read s e <<< "$part"
            for ((i=s;i<=e;i++)); do
                id=$(id_from_num "$i")
                [ -n "$id" ] && pm2_stop_node "$id"
            done
        else
            id=$(id_from_num "$part")
            [ -n "$id" ] && pm2_stop_node "$id"
        fi
    done
}

function view_logs() {
    list_nodes || return
    read -p "请输入要查看日志的节点编号: " n
    nid=$(id_from_num "$n")
    if [ -z "$nid" ]; then red "输入有误。"; return; fi

    PM2_OUT="$HOME/.pm2/logs/nexus-$nid-out.log"
    PM2_ERR="$HOME/.pm2/logs/nexus-$nid-error.log"

    echo "请选择日志类型："
    echo "1. 实时pm2日志 (推荐)"
    echo "2. 查看pm2 out.log (最新50行)"
    echo "3. 查看pm2 error.log (最新50行)"
    read -p "请输入选项(默认1): " typ

    case "$typ" in
        2)
            if [ -f "$PM2_OUT" ]; then
                tail -n 50 "$PM2_OUT" | less
            else
                red "$PM2_OUT 文件不存在"
            fi
            ;;
        3)
            if [ -f "$PM2_ERR" ]; then
                tail -n 50 "$PM2_ERR" | less
            else
                red "$PM2_ERR 文件不存在"
            fi
            ;;
        *)
            pm2 logs "nexus_$nid"
            ;;
    esac
}

function monitor_log_screen() {
    green "实时显示所有节点pm2日志，按 Ctrl+C 返回主菜单。"
    pm2 logs
}

function start_log_monitor() {
    if [ -f "$MONITOR_PID_FILE" ]; then
        kill $(cat "$MONITOR_PID_FILE") 2>/dev/null
        rm -f "$MONITOR_PID_FILE"
    fi
    nohup bash -c '
        while true; do
            ids=($(pm2 jlist | jq -r ".[] | select(.name|startswith(\"nexus_\")) | .name" | sed "s/^nexus_//"))
            for id in "${ids[@]}"; do
                log_file="$HOME/.pm2/logs/nexus-$id-out.log"
                [ ! -f "$log_file" ] && continue
                last_line=$(grep "Proof completed successfully" "$log_file" | tail -1)
                last_time=$(echo "$last_line" | grep -oE "\[([0-9 :-]+)\]" | tr -d "[]")
                if [ -n "$last_time" ]; then
                    now=$(date +%s)
                    last_ts=$(date -d "$last_time" +%s 2>/dev/null)
                    delta=$((now - last_ts))
                    if [ $delta -ge 300 ]; then
                        pm2 restart "nexus_$id"
                        echo "$(date "+%F %T") [节点 $id] [异常重启] Proof超时$delta秒, 已重启" >> "'"$MONITOR_LOG"'"
                    else
                        echo "$(date "+%F %T") [节点 $id] [正常] Proof正常, 距今$delta秒" >> "'"$MONITOR_LOG"'"
                    fi
                else
                    echo "$(date "+%F %T") [节点 $id] [无Proof] 还没有找到成功Proof日志" >> "'"$MONITOR_LOG"'"
                fi
            done
            sleep 60
        done
    ' >/dev/null 2>&1 &
    echo $! > "$MONITOR_PID_FILE"
    green "[*] 智能日志监控后台已启动！日志见 $MONITOR_LOG"
}

function stop_log_monitor() {
    if [ -f "$MONITOR_PID_FILE" ]; then
        kill $(cat "$MONITOR_PID_FILE") 2>/dev/null
        rm -f "$MONITOR_PID_FILE"
        green "[*] 已停止智能日志监控。"
    fi
}

while true; do
    green "========= Nexus CLI 节点管理器 ========="
    echo "1. 一键安装依赖和NEXUS"
    echo "2. 启动节点（pm2守护）"
    echo "3. 一键重启节点"
    echo "4. 一键删除节点"
    echo "5. 查看节点日志"
    echo "6. 实时监控所有节点状态"
    echo "7. 启动智能日志监控"
    echo "8. 停止日志监控"
    echo "0. 退出"
    read -p "请输入选项: " choice
    case "$choice" in
        1) check_install_dependencies ;;
        2) start_nodes_menu ;;
        3) restart_menu ;;
        4) delete_menu ;;
        5) view_logs ;;
        6) monitor_log_screen ;;
        7) start_log_monitor ;;
        8) stop_log_monitor ;;
        0) exit 0 ;;
        *) red "无效输入，请重试。" ;;
    esac
done

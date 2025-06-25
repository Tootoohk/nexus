#!/bin/bash

BASE_DIR="$HOME/.nexus"
LOG_DIR="$BASE_DIR/logs"
PID_DIR="$BASE_DIR/monitor_pids"
NODE_ID_FILE="$BASE_DIR/node_ids.conf"
GLIBC_DIR="/opt/glibc-2.39"
NEXUS_CLI_BIN="$HOME/.nexus/bin/nexus-network"

mkdir -p "$LOG_DIR" "$PID_DIR"

function green() { echo -e "\033[32m$1\033[0m"; }
function red()   { echo -e "\033[31m$1\033[0m"; }

function check_nexus_cli() {
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
    deps=(screen curl build-essential pkg-config libssl-dev git-all protobuf-compiler)
    for dep in "${deps[@]}"; do
        if ! dpkg -s $dep >/dev/null 2>&1; then
            apt-get install -y $dep
        fi
    done
    if ! command -v cargo >/dev/null 2>&1; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source $HOME/.cargo/env
    fi
    rustup target add riscv32i-unknown-none-elf 2>/dev/null
    GLIBC_VERSION=$(ldd --version | head -n1 | awk '{print $NF}')
    if [ "$(echo -e "$GLIBC_VERSION\n2.39" | sort -V | head -n1)" != "2.39" ]; then
        green "[*] 检测到GLIBC版本低于2.39，正在安装2.39..."
        install_glibc_239
    else
        green "[*] GLIBC版本符合要求。"
    fi
    check_nexus_cli
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

function start_node_and_monitor() {
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
    check_nexus_cli

    GLIBC_VERSION=$(ldd --version | head -n1 | awk '{print $NF}')
    for id in "${node_ids[@]}"; do
        id=$(echo $id | xargs)
        screen_name="nexus_$id"
        log_file="$LOG_DIR/$id.log"
        green "[*] 启动节点 $id..."
        stop_node "$id"
        if [ "$(echo -e "$GLIBC_VERSION\n2.39" | sort -V | head -n1)" != "2.39" ]; then
            LIBC_PATH=$(ldd $(which bash) | grep libc.so | awk '{print $3}')
            START_CMD="/opt/glibc-2.39/lib/ld-linux-x86-64.so.2 --library-path /opt/glibc-2.39/lib:$LIBC_PATH ~/.nexus/bin/nexus-network start --node-id $id --headless --max-threads $threads 2>&1 | tee -a $log_file"
        else
            START_CMD="~/.nexus/bin/nexus-network start --node-id $id --headless --max-threads $threads 2>&1 | tee -a $log_file"
        fi
        screen -dmS "$screen_name" bash -c "$START_CMD"
        sleep 1
        start_monitor "$id" "$threads" &
    done
}

function start_monitor() {
    local id="$1"
    local threads="$2"
    local log_file="$LOG_DIR/$id.log"
    local screen_name="nexus_$id"
    local pid_file="$PID_DIR/$id.pid"
    (
    while true; do
        last_time=$(grep 'Proof completed successfully' "$log_file" | tail -1 | awk -F'[][]' '{print $2}')
        now=$(date +%s)
        if [ -n "$last_time" ]; then
            last_ts=$(date -d "$last_time" +%s 2>/dev/null)
            if [ $((now - last_ts)) -ge 120 ]; then
                red "[!] [$id] 2分钟未见Proof completed successfully，重启中..."
                restart_node "$id" "$threads"
            fi
        else
            red "[!] [$id] 暂无成功证明日志，尝试重启..."
            restart_node "$id" "$threads"
        fi
        sleep 60
    done
    ) &
    echo $! > "$pid_file"
}

function stop_node() {
    local id="$1"
    local screen_name="nexus_$id"
    local pid_file="$PID_DIR/$id.pid"
    screen -S "$screen_name" -X quit 2>/dev/null
    if [ -f "$pid_file" ]; then
        kill $(cat "$pid_file") 2>/dev/null
        rm -f "$pid_file"
    fi
}

function restart_node() {
    local id="$1"
    local threads="$2"
    local screen_name="nexus_$id"
    local log_file="$LOG_DIR/$id.log"
    stop_node "$id"
    sleep 2
    check_nexus_cli
    GLIBC_VERSION=$(ldd --version | head -n1 | awk '{print $NF}')
    if [ "$(echo -e "$GLIBC_VERSION\n2.39" | sort -V | head -n1)" != "2.39" ]; then
        START_CMD="/opt/glibc-2.39/lib/ld-linux-x86-64.so.2 --library-path /opt/glibc-2.39/lib:$(dirname $(ldd $(which bash) | grep libc.so | awk '{print \$3}')) ~/.nexus/bin/nexus-network start --node-id $id --headless --max-threads $threads 2>&1 | tee -a $log_file"
    else
        START_CMD="~/.nexus/bin/nexus-network start --node-id $id --headless --max-threads $threads 2>&1 | tee -a $log_file"
    fi
    green "[*] 正在重启节点 $id ..."
    screen -dmS "$screen_name" bash -c "$START_CMD"
    sleep 1
    start_monitor "$id" "$threads" &
}

function restart_menu() {
    ids=$(ls $LOG_DIR | sed 's/.log$//')
    green "当前运行节点: $ids"
    read -p "请输入需要重启的节点ID（全部输入all，多ID逗号分隔）: " rid
    read -p "请输入线程数(默认4): " threads
    [ -z "$threads" ] && threads=4
    if [ "$rid" == "all" ]; then
        for id in $ids; do restart_node "$id" "$threads"; done
    else
        IFS=',' read -ra arr <<< "$rid"
        for id in "${arr[@]}"; do restart_node "$(echo $id | xargs)" "$threads"; done
    fi
}

function delete_menu() {
    ids=$(ls $LOG_DIR | sed 's/.log$//')
    green "当前运行节点: $ids"
    read -p "请输入需要删除的节点ID（全部输入all，多ID逗号分隔）: " did
    if [ "$did" == "all" ]; then
        for id in $ids; do stop_node "$id"; rm -f "$LOG_DIR/$id.log"; done
    else
        IFS=',' read -ra arr <<< "$did"
        for id in "${arr[@]}"; do stop_node "$(echo $id | xargs)"; rm -f "$LOG_DIR/$(echo $id | xargs).log"; done
    fi
}

function view_logs() {
    ids=$(ls $LOG_DIR | sed 's/.log$//')
    green "当前运行节点: $ids"
    read -p "请输入要查看日志的节点ID: " lid
    tail -f "$LOG_DIR/$lid.log"
}

while true; do
    green "========= Nexus CLI 节点管理器 ========="
    echo "1. 一键安装依赖和NEXUS"
    echo "2. 启动节点（含自动监控）"
    echo "3. 一键重启节点"
    echo "4. 一键删除节点"
    echo "5. 查看节点日志"
    echo "0. 退出"
    read -p "请输入选项: " choice
    case "$choice" in
        1) check_install_dependencies ;;
        2) start_node_and_monitor ;;
        3) restart_menu ;;
        4) delete_menu ;;
        5) view_logs ;;
        0) exit 0 ;;
        *) red "无效输入，请重试。" ;;
    esac
done

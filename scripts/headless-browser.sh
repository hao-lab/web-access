#!/bin/bash
#
# headless-browser.sh — 统一 wrapper：管理 headless_shell + cdp-proxy 生命周期
#
# 使用：
#   ./scripts/headless-browser.sh start    # 启动
#   ./scripts/headless-browser.sh stop     # 停止
#   ./scripts/headless-browser.sh status   # 查看状态
#   ./scripts/headless-browser.sh restart  # 重启
#   ./scripts/headless-browser.sh logs     # 查看日志
#

set -euo pipefail

# —— —— 配置 —— ——
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# 浏览器配置
: "${HEADLESS_BROWSER:=/root/.cache/ms-playwright/chromium_headless_shell-1217/chrome-headless-shell-linux64/chrome-headless-shell}"
: "${CDP_PORT:=9222}"
: "${PROXY_PORT:=3456}"
: "${USER_DATA_DIR:=/tmp/headless-browser-profile}"

# PID 文件
PID_DIR="${PID_DIR:-/tmp}"
CHROME_PIDFILE="${PID_DIR}/headless-browser.pid"
PROXY_PIDFILE="${PID_DIR}/cdp-proxy.pid"
OWNER_PIDFILE="${PID_DIR}/headless-browser.owner_pid"

# 日志
LOG_DIR="${LOG_DIR:-/tmp}"
CHROME_LOG="${LOG_DIR}/headless-browser.log"
PROXY_LOG="${LOG_DIR}/cdp-proxy.log"

# —— —— 工具函数 —— ——

__is_port_in_use() {
    local port=$1
    python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    s.bind(('127.0.0.1', $port))
    s.close()
    print('free')
except OSError:
    print('in_use')
"
}

__is_pid_alive() {
    local pid=$1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

__get_chrome_pid() {
    local pid=""
    if [ -f "$CHROME_PIDFILE" ]; then
        pid=$(cat "$CHROME_PIDFILE" 2>/dev/null | tr -d '[:space:]')
    fi
    echo "$pid"
}

__get_proxy_pid() {
    local pid=""
    if [ -f "$PROXY_PIDFILE" ]; then
        pid=$(cat "$PROXY_PIDFILE" 2>/dev/null | tr -d '[:space:]')
    fi
    echo "$pid"
}

__count_chrome_children() {
    local main_pid=$1
    if [ -z "$main_pid" ]; then
        echo "0"
        return
    fi
    ps -o pid= --ppid "$main_pid" 2>/dev/null | wc -l | tr -d ' '
}

__get_total_rss() {
    local main_pid=$1
    if [ -z "$main_pid" ] || ! __is_pid_alive "$main_pid"; then
        echo "0"
        return
    fi
    # 统计主进程+所有子进程的 RSS（KB）
    # 使用 /proc 文件系统，不依赖 psutil
    local total=0
    # 获取所有相关进程的 RSS
    for pid in $(ps -o pid= --ppid "$main_pid" 2>/dev/null); do
        local rss=$(awk '/VmRSS/ {print $2}' /proc/$pid/status 2>/dev/null || echo "0")
        total=$((total + rss))
    done
    # 加上主进程
    local main_rss=$(awk '/VmRSS/ {print $2}' /proc/$main_pid/status 2>/dev/null || echo "0")
    total=$((total + main_rss))
    printf "%.1f" $(echo "$total / 1024" | bc -l 2>/dev/null || echo "$total / 1024" | python3 -c "print(eval(input()))")
}

# —— —— 子命令 —— ——

cmd_start() {
    local force_restart=false
    if [ "${1:-}" = "--force" ] || [ "${1:-}" = "-f" ]; then
        force_restart=true
    fi

    echo "[→] 检查环境..."

    # 检查浏览器二进制
    if [ ! -x "$HEADLESS_BROWSER" ]; then
        echo "[❌] 错误: 浏览器不存在或不可执行: $HEADLESS_BROWSER"
        echo "     安装: npx playwright install chromium"
        exit 1
    fi

    # 检查 Node.js（用于 proxy）
    if ! command -v node &>/dev/null; then
        echo "[❌] 错误: Node.js 未安装"
        exit 1
    fi

    # 检查是否已在运行
    local chrome_pid=$(__get_chrome_pid)
    local proxy_pid=$(__get_proxy_pid)

    if [ -n "$chrome_pid" ] && __is_pid_alive "$chrome_pid"; then
        if [ "$force_restart" = true ]; then
            echo "[⚠] 强制模式: 先停止已有进程..."
            cmd_stop
        else
            echo "[⚠] headless_shell 已在运行 (PID=$chrome_pid)，用 --force 强制重启"
            return 0
        fi
    fi

    # 清理旧日志
    > "$CHROME_LOG"
    > "$PROXY_LOG"

    # 创建 profile 目录
    mkdir -p "$USER_DATA_DIR"

    echo "[→] 启动 headless_shell (port $CDP_PORT)..."
    nohup "$HEADLESS_BROWSER" \
        --remote-debugging-port="$CDP_PORT" \
        --no-sandbox \
        --disable-gpu \
        --disable-dev-shm-usage \
        --user-data-dir="$USER_DATA_DIR" \
        about:blank \
        >> "$CHROME_LOG" 2>&1 &
    local chrome_pgid=$!
    echo "$chrome_pgid" > "$CHROME_PIDFILE"
    echo "$$" > "$OWNER_PIDFILE"

    # 等待 Chrome 就绪
    local waited=0
    while [ "$(__is_port_in_use "$CDP_PORT")" = "free" ]; do
        sleep 0.5
        waited=$((waited + 1))
        if [ $waited -gt 20 ]; then
            echo "[❌] 错误: Chrome 启动超时"
            cmd_stop
            exit 1
        fi
    done
    echo "[✓] headless_shell 启动成功 (PID=$chrome_pgid)"

    echo "[→] 启动 CDP Proxy (port $PROXY_PORT)..."
    nohup node "$PROJECT_DIR/scripts/cdp-proxy.mjs" \
        >> "$PROXY_LOG" 2>&1 &
    local proxy_pid=$!
    echo "$proxy_pid" > "$PROXY_PIDFILE"

    # 等待 Proxy 就绪
    waited=0
    while [ "$(__is_port_in_use "$PROXY_PORT")" = "free" ]; do
        sleep 0.5
        waited=$((waited + 1))
        if [ $waited -gt 20 ]; then
            echo "[❌] 错误: Proxy 启动超时"
            cmd_stop
            exit 1
        fi
    done
    echo "[✓] CDP Proxy 启动成功 (PID=$proxy_pid)"

    echo ""
    echo "=== 所有服务已启动 ==="
    echo "  Chrome:  http://127.0.0.1:$CDP_PORT/json/version"
    echo "  Proxy:   http://127.0.0.1:$PROXY_PORT/health"
    echo "  Chrome PID:  $chrome_pgid"
    echo "  Proxy PID:   $proxy_pid"
    echo "  日志:     $CHROME_LOG, $PROXY_LOG"
}

cmd_stop() {
    echo "[→] 停止服务..."

    local proxy_pid=$(__get_proxy_pid)
    local chrome_pid=$(__get_chrome_pid)
    local stopped=0

    # 1. 先停 proxy（让它有机会清理 managed tabs）
    if [ -n "$proxy_pid" ] && __is_pid_alive "$proxy_pid"; then
        echo "  停止 Proxy (PID=$proxy_pid)..."
        kill "$proxy_pid" 2>/dev/null || true
        sleep 1
        if __is_pid_alive "$proxy_pid"; then
            kill -9 "$proxy_pid" 2>/dev/null || true
        fi
        stopped=$((stopped + 1))
    fi
    rm -f "$PROXY_PIDFILE"

    # 2. 再停 Chrome（整个进程组）
    if [ -n "$chrome_pid" ] && __is_pid_alive "$chrome_pid"; then
        echo "  停止 Chrome (PID=$chrome_pid)..."
        # 尝试 SIGTERM 整个进程组
        kill -- -"$chrome_pid" 2>/dev/null || true
        sleep 1

        # 如果还有活进程，强制 SIGKILL
        if __is_pid_alive "$chrome_pid"; then
            echo "  强制终止 Chrome..."
            kill -9 -- -"$chrome_pid" 2>/dev/null || true
            # 单独捕杀每个 chrome-headless 进程（万一死组机制不用效）
            pkill -9 -f "chrome-headless-shell.*remote-debugging-port=$CDP_PORT" 2>/dev/null || true
        fi
        stopped=$((stopped + 1))
    fi
    rm -f "$CHROME_PIDFILE"
    rm -f "$OWNER_PIDFILE"

    # 3. 清理占用的端口（防止复用）
    sleep 0.5
    local port_cleaned=0
    if [ "$(__is_port_in_use "$CDP_PORT")" = "in_use" ]; then
        pkill -9 -f "chrome-headless-shell.*remote-debugging-port=$CDP_PORT" 2>/dev/null || true
        port_cleaned=$((port_cleaned + 1))
    fi

    if [ $stopped -gt 0 ]; then
        echo "[✓] 已停止 $stopped 个服务"
    else
        echo "[−] 没有运行中的服务"
    fi
}

cmd_status() {
    local chrome_pid=$(__get_chrome_pid)
    local proxy_pid=$(__get_proxy_pid)
    local owner_pid=""
    [ -f "$OWNER_PIDFILE" ] && owner_pid=$(cat "$OWNER_PIDFILE" 2>/dev/null)

    echo "=== headless-browser 状态 ==="
    echo ""

    # Chrome
    if [ -n "$chrome_pid" ] && __is_pid_alive "$chrome_pid"; then
        local children=$(__count_chrome_children "$chrome_pid")
        local rss=$(__get_total_rss "$chrome_pid")
        echo "  Chrome:    [运行中] PID=$chrome_pid, 子进程=$children, 总 RSS=${rss}MB"
        echo "             CDP http://127.0.0.1:$CDP_PORT/json/version"
    else
        echo "  Chrome:    [已停止]"
    fi

    # Proxy
    if [ -n "$proxy_pid" ] && __is_pid_alive "$proxy_pid"; then
        echo "  Proxy:     [运行中] PID=$proxy_pid"
        echo "             API http://127.0.0.1:$PROXY_PORT/health"
    else
        echo "  Proxy:     [已停止]"
    fi

    # Owner
    if [ -n "$owner_pid" ]; then
        if __is_pid_alive "$owner_pid"; then
            echo "  Owner:     [活跃] PID=$owner_pid (启动者)"
        else
            echo "  Owner:     [已退出] PID=$owner_pid"
        fi
    fi

    echo ""
    echo "  日志: $LOG_DIR/headless-browser.log, $LOG_DIR/cdp-proxy.log"
}

cmd_restart() {
    echo "[→] 重启..."
    cmd_stop
    sleep 1
    cmd_start
}

cmd_logs() {
    local target="${1:-all}"
    case "$target" in
        chrome|browser)
            echo "=== Chrome 日志 ($CHROME_LOG) ==="
            tail -n 20 "$CHROME_LOG" 2>/dev/null || echo "(空)"
            ;;
        proxy)
            echo "=== Proxy 日志 ($PROXY_LOG) ==="
            tail -n 20 "$PROXY_LOG" 2>/dev/null || echo "(空)"
            ;;
        all|*)
            echo "=== Chrome 日志 ($CHROME_LOG) ==="
            tail -n 10 "$CHROME_LOG" 2>/dev/null || echo "(空)"
            echo ""
            echo "=== Proxy 日志 ($PROXY_LOG) ==="
            tail -n 10 "$PROXY_LOG" 2>/dev/null || echo "(空)"
            ;;
    esac
}

# —— —— 主入口 —— ——

case "${1:-}" in
    start)
        shift
        cmd_start "$@"
        ;;
    stop)
        cmd_stop
        ;;
    status)
        cmd_status
        ;;
    restart)
        cmd_restart
        ;;
    logs)
        shift
        cmd_logs "$@"
        ;;
    *)
        echo "用法: $0 {start [--force] | stop | status | restart | logs [chrome|proxy|all]}"
        echo ""
        echo "  start [--force]  — 启动 Chrome + Proxy（--force 强制重启）"
        echo "  stop             — 停止所有服务"
        echo "  status           — 查看运行状态"
        echo "  restart          — 重启"
        echo "  logs [target]    — 查看日志（chrome|proxy|all）"
        echo ""
        echo "环境变量:"
        echo "  HEADLESS_BROWSER   — 浏览器二进制路径"
        echo "  CDP_PORT           — Chrome 调试端口 (默认 9222)"
        echo "  PROXY_PORT         — Proxy HTTP 端口 (默认 3456)"
        echo "  USER_DATA_DIR      — Chrome profile 目录"
        echo "  LOG_DIR            — 日志目录 (默认 /tmp)"
        exit 1
        ;;
esac

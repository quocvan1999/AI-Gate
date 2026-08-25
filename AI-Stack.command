#!/bin/zsh
# ============================================================
# AI STACK v2.3 - ONE CLICK START + TERMINAL MANAGER
# Node 20.20.2 | 9Router 0.5.55 | AgentRouter Proxy :8318
#
# IMPORTANT:
# - This is a SINGLE file. No start-ai.sh is required.
# - Existing ~/.9router is preserved.
# - Existing services are NOT overwritten.
# - The terminal stays OPEN after startup.
# ============================================================

set -u
set -o pipefail

export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:$HOME/.nvm/versions/node/v20.20.2/bin:$HOME/go/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export NVM_DIR="$HOME/.nvm"
[[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh" 2>/dev/null || true

VERSION="AI-STACK v2.5"
APP_DIR="$HOME/ai-stack"
PROXY_DIR="$APP_DIR/agentrouter-spoof-proxy"
PROXY_BIN="$PROXY_DIR/agentrouter-proxy"
LOG_DIR="$APP_DIR/logs"

PROXY_PORT=8318
ROUTER_PORT=20128
NODE_REQUIRED="20.20.2"
NINE_REQUIRED="0.5.55"

PROXY_LOG="$LOG_DIR/agentrouter-proxy.log"
ROUTER_LOG="$LOG_DIR/9router.log"

mkdir -p "$LOG_DIR"

# ---------- terminal UI ----------
R=$'\e[0m'; B=$'\e[1m'; DIM=$'\e[2m'
C=$'\e[36m'; G=$'\e[32m'; Y=$'\e[33m'; E=$'\e[31m'
M=$'\e[35m'; W=$'\e[37m'; BG=$'\e[48;5;236m'
GRAY=$'\e[90m'

say()  { print "$1"; }
info() { print "${C}  ›${R} $1"; }
ok()   { print "${G}  ●${R} $1"; }
warn() { print "${Y}  ●${R} $1"; }
fail() { print "${E}  ●${R} $1"; }

term_title() {
    print -n "\e]0;AI Stack Manager\e\\"
}

clear_screen() {
    print -n "\e[2J\e[H"
}

hr() {
    print "${GRAY}────────────────────────────────────────────────────────────────────${R}"
}

logo() {
    print "${C}${B}"
    print "      █████╗ ██╗    ███████╗████████╗ █████╗  ██████╗██╗  ██╗"
    print "     ██╔══██╗██║    ██╔════╝╚══██╔══╝██╔══██╗██╔════╝██║ ██╔╝"
    print "     ███████║██║    ███████╗   ██║   ███████║██║     ███████╔╝ "
    print "     ██╔══██║██║    ╚════██║   ██║   ██╔══██║██║     ██╔═██╗  "
    print "     ██║  ██║██║    ███████║   ██║   ██║  ██║╚██████╗██║  ██╗ "
    print "     ╚═╝  ╚═╝╚═╝    ╚══════╝   ╚═╝   ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝ "
    print "${R}${DIM}                         ONE-CLICK AI ENVIRONMENT${R}"
}

banner() {
    clear_screen
    term_title
    logo
    print ""
    hr
    print "  ${B}${W}AI STACK${R} ${DIM}v2.3  •  macOS  •  9Router + AgentRouter Proxy${R}"
    hr
    print ""
}

section() {
    print ""
    print "${C}${B}  $1${R}"
    hr
}

cmd() { command -v "$1" >/dev/null 2>&1; }

pause() {
    print ""
    read -r "?${DIM}  Press Enter to continue...${R}"
}

listening() {
    lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

pid_on_port() {
    lsof -tiTCP:"$1" -sTCP:LISTEN 2>/dev/null | head -n 1
}

http_code() {
    curl -sS -L --max-time 3 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || print "000"
}

http_ok() {
    local code
    code="$(http_code "$1")"
    [[ "$code" == <-> ]] && (( code >= 200 && code < 400 ))
}

wait_http() {
    local url="$1"
    local max="$2"
    local i=0
    while (( i < max )); do
        http_ok "$url" && return 0
        sleep 1
        (( i++ ))
    done
    return 1
}

show_tail() {
    local file="$1"
    local n="${2:-80}"
    print ""
    if [[ -f "$file" ]]; then
        tail -n "$n" "$file"
    else
        warn "Không tìm thấy log: $file"
    fi
    print ""
}

# ============================================================
# CHECK / INSTALL
# ============================================================

step() {
    local label="$1"
    print -n "  ${DIM}•${R} ${label}"
}

step_done() {
    local label="$1"
    print "\r  ${G}●${R} ${label}"
}


bootstrap() {
    banner
    section "BOOTSTRAP"

    # macOS
    if [[ "$(uname -s)" != "Darwin" ]]; then
        fail "Chỉ hỗ trợ macOS."
        return 1
    fi
    ok "macOS"

    # Homebrew
    if cmd brew; then
        ok "Homebrew"
    else
        info "Đang cài Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || {
            fail "Cài Homebrew thất bại."
            return 1
        }
        [[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
        [[ -x /usr/local/bin/brew ]] && eval "$(/usr/local/bin/brew shellenv)"
    fi

    # NVM
    export NVM_DIR="$HOME/.nvm"
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
        source "$NVM_DIR/nvm.sh"
    else
        info "Đang cài NVM..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash || {
            fail "Cài NVM thất bại."
            return 1
        }
        [[ -s "$NVM_DIR/nvm.sh" ]] || {
            fail "Không tìm thấy nvm.sh."
            return 1
        }
        source "$NVM_DIR/nvm.sh"
    fi

    # Node exact version
    local node_ver=""
    cmd node && node_ver="$(node -v 2>/dev/null || true)"

    if [[ "$node_ver" != "v$NODE_REQUIRED" ]]; then
        info "Đang chuyển sang Node.js $NODE_REQUIRED..."
        nvm install "$NODE_REQUIRED" || return 1
        nvm use "$NODE_REQUIRED" || return 1
        nvm alias default "$NODE_REQUIRED" >/dev/null 2>&1 || true
    fi

    if [[ "$(node -v 2>/dev/null)" == "v$NODE_REQUIRED" ]]; then
        ok "Node.js $(node -v)"
    else
        fail "Node.js không đúng phiên bản $NODE_REQUIRED."
        return 1
    fi

    # Go
    if cmd go; then
        ok "Go $(go version | awk '{print $3}')"
    else
        info "Đang cài Go..."
        brew install go || {
            fail "Cài Go thất bại."
            return 1
        }
    fi

    # 9Router exact version
    local nr_version=""
    if cmd 9router; then
        nr_version="$(9router --version 2>/dev/null | head -n 1 || true)"
        ok "9Router command found${nr_version:+ ($nr_version)}"
    else
        info "Đang cài 9Router $NINE_REQUIRED..."
        npm install -g "9router@$NINE_REQUIRED" || {
            fail "Cài 9Router thất bại."
            return 1
        }
        ok "9Router $NINE_REQUIRED installed"
    fi

    if [[ -d "$HOME/.9router" ]]; then
        ok "Giữ nguyên cấu hình: $HOME/.9router"
    else
        warn "Chưa có ~/.9router. 9Router sẽ tạo mới."
    fi

    # Proxy source
    if [[ -d "$PROXY_DIR/.git" ]]; then
        ok "AgentRouter Proxy source found"
    else
        info "Đang tải AgentRouter Proxy..."
        mkdir -p "$APP_DIR"
        git clone "https://github.com/trefeon/agentrouter-spoof-proxy.git" "$PROXY_DIR" || {
            fail "Clone AgentRouter Proxy thất bại."
            return 1
        }
    fi

    if [[ -x "$PROXY_BIN" ]]; then
        ok "AgentRouter Proxy binary found"
    else
        info "Đang build AgentRouter Proxy..."
        (
            cd "$PROXY_DIR" || exit 1
            go build -o "$PROXY_BIN" ./cmd/proxy
        ) || {
            fail "Build AgentRouter Proxy thất bại."
            return 1
        }
        chmod +x "$PROXY_BIN"
        ok "AgentRouter Proxy built"
    fi

    return 0
}

# ============================================================
# START PROXY
# ============================================================

start_proxy() {
    section "AGENTROUTER PROXY :$PROXY_PORT"

    if listening "$PROXY_PORT"; then
        if http_ok "http://127.0.0.1:$PROXY_PORT/health"; then
            ok "Proxy đang chạy và health = OK"
            return 0
        fi
        warn "Port :$PROXY_PORT đang được process khác sử dụng."
        warn "Không tự kill process để tránh ghi đè cấu hình."
        return 1
    fi

    info "Starting AgentRouter Proxy..."
    nohup "$PROXY_BIN" >>"$PROXY_LOG" 2>&1 </dev/null &
    local pid=$!

    if wait_http "http://127.0.0.1:$PROXY_PORT/health" 20; then
        ok "Proxy READY (PID $pid)"
        return 0
    fi

    fail "Proxy không READY."
    show_tail "$PROXY_LOG" 50
    return 1
}

# ============================================================
# START 9ROUTER
# ============================================================

start_router() {
    section "9ROUTER :$ROUTER_PORT"

    # Already running?
    if listening "$ROUTER_PORT"; then
        if http_ok "http://127.0.0.1:$ROUTER_PORT/dashboard"; then
            ok "9Router đã chạy và dashboard READY"
            return 0
        fi

        warn "Port :$ROUTER_PORT đang có process nhưng HTTP chưa READY."
        warn "PID: $(pid_on_port "$ROUTER_PORT")"
        warn "Không tự kill process này."
        return 1
    fi

    # Clear stale log so the next failure is easy to read.
    : > "$ROUTER_LOG"

    info "Starting 9Router..."
    info "Command: 9router --port $ROUTER_PORT --no-browser --skip-update"

    nohup 9router \
        --port "$ROUTER_PORT" \
        --no-browser \
        --skip-update \
        >>"$ROUTER_LOG" 2>&1 </dev/null &

    local pid=$!
    info "9Router process started (PID $pid)"
    info "Waiting for HTTP server tối đa 60 giây..."

    local i=0
    while (( i < 60 )); do
        if http_ok "http://127.0.0.1:$ROUTER_PORT/dashboard"; then
            ok "9Router READY"
            ok "Dashboard: http://127.0.0.1:$ROUTER_PORT/dashboard"
            return 0
        fi

        # If the port appears, give it a little more time.
        if listening "$ROUTER_PORT" && (( i % 5 == 0 )); then
            info "Port :$ROUTER_PORT đã mở, đang chờ dashboard..."
        fi

        # Process may spawn child and exit, so do not treat parent PID
        # as the final health signal. The HTTP endpoint is authoritative.
        sleep 1
        (( i++ ))
    done

    fail "9Router KHÔNG READY sau 60 giây."
    print ""
    print "${E}${B}========== 9ROUTER LOG ==========${R}"
    show_tail "$ROUTER_LOG" 120
    print "${E}${B}===================================${R}"
    print ""
    warn "Không mở dashboard vì 9Router chưa READY."
    return 1
}

# ============================================================
# STATUS
# ============================================================

service_state() {
    local port="$1"
    local url="$2"
    if listening "$port" && http_ok "$url"; then
        print "${G}${B}● READY${R}"
        return 0
    fi
    print "${E}${B}● DOWN${R}"
    return 1
}

status_compact() {
    local proxy_state router_state
    if listening "$PROXY_PORT" && http_ok "http://127.0.0.1:$PROXY_PORT/health"; then
        proxy_state="${G}${B}● READY${R}"
    else
        proxy_state="${E}${B}● DOWN${R}"
    fi

    if listening "$ROUTER_PORT" && http_ok "http://127.0.0.1:$ROUTER_PORT/dashboard"; then
        router_state="${G}${B}● READY${R}"
    else
        router_state="${E}${B}● DOWN${R}"
    fi

    print "  ${B}SERVICES${R}"
    print ""
    print "  ${C}AgentRouter Proxy${R}"
    print "    http://127.0.0.1:$PROXY_PORT/health    ${proxy_state}"
    print ""
    print "  ${C}9Router Dashboard${R}"
    print "    http://127.0.0.1:$ROUTER_PORT/dashboard    ${router_state}"
}

status() {
    banner
    print "  ${B}SYSTEM STATUS${R}"
    hr
    print ""
    status_compact
    print ""
    hr
    print "  ${DIM}Proxy log  ${R}$PROXY_LOG"
    print "  ${DIM}9Router log${R} $ROUTER_LOG"
    print ""

    if http_ok "http://127.0.0.1:$PROXY_PORT/v1/models"; then
        local models
        models="$(curl -fsS --max-time 5 "http://127.0.0.1:$PROXY_PORT/v1/models" 2>/dev/null || true)"
        if [[ "$models" == *"gpt-5.6-sol"* ]]; then
            print "  ${G}●${R} Model ${B}gpt-5.6-sol${R} available"
        else
            print "  ${Y}●${R} Model list reachable; gpt-5.6-sol not detected"
        fi
    fi
    print ""
}

# ============================================================
# DIAGNOSTICS
# ============================================================

check_proxy_health() {
    local code
    code="$(http_code "http://127.0.0.1:$PROXY_PORT/health")"
    if [[ "$code" == "200" ]]; then
        ok "AgentRouter Proxy /health → HTTP $code"
        return 0
    fi
    fail "AgentRouter Proxy /health → HTTP $code"
    return 1
}

check_router_health() {
    local code
    code="$(http_code "http://127.0.0.1:$ROUTER_PORT/dashboard")"
    if [[ "$code" == <-> ]] && (( code >= 200 && code < 400 )); then
        ok "9Router Dashboard → HTTP $code"
        return 0
    fi
    fail "9Router Dashboard → HTTP $code"
    return 1
}

check_models() {
    local payload
    payload="$(curl -fsS --max-time 5 "http://127.0.0.1:$PROXY_PORT/v1/models" 2>/dev/null || true)"

    if [[ -z "$payload" ]]; then
        fail "Proxy /v1/models → không phản hồi"
        return 1
    fi

    if [[ "$payload" == *"gpt-5.6-sol"* ]]; then
        ok "Model discovery → gpt-5.6-sol AVAILABLE"
        return 0
    fi

    warn "Model discovery → Proxy phản hồi nhưng không thấy gpt-5.6-sol"
    return 1
}

diagnostics() {
    local interactive=1
    [[ "${1:-}" == "--noninteractive" ]] && interactive=0
    banner
    section "DIAGNOSTICS"
    print "  ${DIM}Kiểm tra: localhost → Proxy → 9Router → Model${R}"
    print ""

    local proxy_ok=0 router_ok=0 model_ok=0

    if listening "$PROXY_PORT"; then
        ok "Port :$PROXY_PORT đang LISTEN"
        check_proxy_health && proxy_ok=1
    else
        fail "Port :$PROXY_PORT không LISTEN"
    fi

    print ""

    if listening "$ROUTER_PORT"; then
        ok "Port :$ROUTER_PORT đang LISTEN"
        check_router_health && router_ok=1
    else
        fail "Port :$ROUTER_PORT không LISTEN"
    fi

    print ""

    if (( proxy_ok )); then
        check_models && model_ok=1
    else
        warn "Bỏ qua model discovery vì Proxy chưa HEALTHY"
    fi

    print ""
    hr

    if (( proxy_ok && router_ok && model_ok )); then
        print "  ${G}${B}✓ DIAGNOSTICS: HEALTHY${R}"
        print "  ${DIM}Các thành phần local đang phản hồi bình thường.${R}"
    elif (( proxy_ok && router_ok )); then
        print "  ${Y}${B}⚠ DIAGNOSTICS: PARTIAL${R}"
        print "  ${DIM}Proxy và 9Router hoạt động; nếu request lỗi hãy kiểm tra upstream/API key.${R}"
    else
        print "  ${E}${B}✗ DIAGNOSTICS: UNHEALTHY${R}"
        print "  ${DIM}Chạy [1] Start / Repair để tự khôi phục service đang DOWN.${R}"
    fi

    print ""
    print "  ${DIM}Logs:${R}"
    print "    Proxy   $PROXY_LOG"
    print "    9Router $ROUTER_LOG"
    if (( interactive )); then pause; fi
}

# ============================================================
# AUTO-HEALING
# ============================================================

AUTOHEAL_PID=""
AUTOHEAL_INTERVAL=15

proxy_healthy_quiet() {
    listening "$PROXY_PORT" && http_ok "http://127.0.0.1:$PROXY_PORT/health"
}

router_healthy_quiet() {
    listening "$ROUTER_PORT" && http_ok "http://127.0.0.1:$ROUTER_PORT/dashboard"
}

start_proxy_quiet() {
    if proxy_healthy_quiet; then return 0; fi
    # Never kill a process that happens to own our port.
    if listening "$PROXY_PORT"; then return 1; fi
    [[ -x "$PROXY_BIN" ]] || return 1

    nohup "$PROXY_BIN" >>"$PROXY_LOG" 2>&1 </dev/null &
    wait_http "http://127.0.0.1:$PROXY_PORT/health" 10
}

start_router_quiet() {
    if router_healthy_quiet; then return 0; fi
    # Never kill a process that happens to own our port.
    if listening "$ROUTER_PORT"; then return 1; fi
    cmd 9router || return 1

    nohup 9router \
        --port "$ROUTER_PORT" \
        --no-browser \
        --skip-update \
        >>"$ROUTER_LOG" 2>&1 </dev/null &

    wait_http "http://127.0.0.1:$ROUTER_PORT/dashboard" 20
}

autoheal_loop() {
    # Auto-healing only restarts a service when its own health endpoint
    # is down AND its expected port is free. It never kills foreign apps.
    while true; do
        if ! proxy_healthy_quiet; then
            start_proxy_quiet >/dev/null 2>&1 || true
        fi

        if ! router_healthy_quiet; then
            start_router_quiet >/dev/null 2>&1 || true
        fi

        sleep "$AUTOHEAL_INTERVAL"
    done
}

start_autoheal() {
    if [[ -n "$AUTOHEAL_PID" ]] && kill -0 "$AUTOHEAL_PID" 2>/dev/null; then
        return 0
    fi

    pkill -9 -f "autoheal_loop" 2>/dev/null || true
    autoheal_loop >/dev/null 2>&1 &
    AUTOHEAL_PID=$!
    ok "Auto-healing enabled • check every ${AUTOHEAL_INTERVAL}s"
}

stop_autoheal() {
    if [[ -n "$AUTOHEAL_PID" ]]; then
        kill -9 "$AUTOHEAL_PID" 2>/dev/null || true
        wait "$AUTOHEAL_PID" 2>/dev/null || true
        AUTOHEAL_PID=""
    fi
    pkill -9 -f "autoheal_loop" 2>/dev/null || true
}

# ============================================================
# STOP / RESTART
# ============================================================

kill_process_tree() {
    local pid="$1"
    [[ -z "$pid" ]] && return 0

    # Kill children first, then parent. This matters because 9Router may
    # spawn a Node child that owns the listening port.
    local children
    children="$(pgrep -P "$pid" 2>/dev/null || true)"

    for child in ${(f)children}; do
        kill_process_tree "$child"
    done

    kill -9 "$pid" 2>/dev/null || true
}

stop_port_force() {
    local port="$1"
    local label="$2"
    local pid
    local i

    pid="$(pid_on_port "$port")"
    [[ -z "$pid" ]] && {
        ok "$label :$port đã dừng."
        return 0
    }

    info "Stopping $label :$port (PID $pid)..."
    kill_process_tree "$pid"

    # Give children time to exit, then force-kill whoever still owns the port.
    for i in {1..5}; do
        if ! listening "$port"; then
            ok "$label stopped."
            return 0
        fi
        sleep 0.5
    done

    pid="$(pid_on_port "$port")"
    if [[ -n "$pid" ]]; then
        warn "$label vẫn giữ :$port → force kill PID $pid"
        kill -9 "$pid" 2>/dev/null || true
    fi

    if listening "$port"; then
        fail "$label vẫn đang LISTEN trên :$port"
        return 1
    fi

    ok "$label stopped."
    return 0
}

stop_all() {
    section "STOP ALL"

    stop_autoheal
    pkill -9 -f "agentrouter-proxy" 2>/dev/null || true
    pkill -9 -f "9router" 2>/dev/null || true
    stop_port_force "$PROXY_PORT" "AgentRouter Proxy"
    stop_port_force "$ROUTER_PORT" "9Router"

    print ""
    if ! listening "$PROXY_PORT" && ! listening "$ROUTER_PORT"; then
        ok "AI Stack đã STOP hoàn toàn."
    else
        warn "Vẫn còn process trên một trong hai port."
    fi
}

restart_all() {
    stop_autoheal
    stop_all
    sleep 1
    start_proxy
    start_router
    start_autoheal
}

# ============================================================
# MENU
# ============================================================

menu() {
    while true; do
        banner
        print "  ${B}LIVE SERVICES${R}"
        hr
        print ""
        status_compact
        print ""
        print "  ${G}●${R} Auto-healing ${B}ON${R}  ${DIM}• checks every ${AUTOHEAL_INTERVAL}s${R}"
        print ""
        print "  ${B}ACTIONS${R}"
        hr
        print ""
        print "  ${C}[1]${R}  Start / Repair"
        print "  ${C}[2]${R}  Restart"
        print "  ${M}[3]${R}  Open 9Router Dashboard"
        print ""
        print "  ${E}[0]${R}  Exit & Stop"
        print ""
        hr
        printf "  ${B}Select ${R}${DIM}[0-3]${R}: "
        read -r choice

        case "$choice" in
            1)
                banner
                section "START / REPAIR"
                start_proxy
                start_router
                start_autoheal
                print ""
                diagnostics
                ;;
            2)
                banner
                section "RESTART"
                restart_all
                print ""
                diagnostics
                ;;
            3)
                if http_ok "http://127.0.0.1:$ROUTER_PORT/dashboard"; then
                    open "http://127.0.0.1:$ROUTER_PORT/dashboard"
                else
                    banner
                    fail "9Router chưa READY."
                    pause
                fi
                ;;
            0)
                banner
                section "SHUTDOWN"
                warn "Stopping AI Stack..."
                stop_autoheal
                stop_all
                print ""
                ok "AI Stack stopped."
                print ""
                print "${DIM}Returning to normal Terminal shell...${R}"
                sleep 0.5
                trap - EXIT
                exec zsh -l
                ;;
            *)
                print "  ${Y}●${R} Lựa chọn không hợp lệ."
                sleep 0.8
                ;;
        esac
    done
}

# ============================================================
# START / RESTART MODES (used by the native app)
# ============================================================
if [[ "${1:-}" == "--start" ]]; then
    trap - EXIT
    bootstrap || exit 1
    start_proxy >/dev/null 2>&1 || true
    start_router >/dev/null 2>&1 || true
    start_autoheal >/dev/null 2>&1 || true
    exit 0
fi

if [[ "${1:-}" == "--restart" ]]; then
    trap - EXIT
    stop_autoheal >/dev/null 2>&1 || true
    stop_all >/dev/null 2>&1 || true
    sleep 1
    bootstrap || exit 1
    start_proxy >/dev/null 2>&1 || true
    start_router >/dev/null 2>&1 || true
    start_autoheal >/dev/null 2>&1 || true
    exit 0
fi

# ============================================================
# SHUTDOWN MODE (used by the native app)
# ============================================================
if [[ "${1:-}" == "--shutdown" ]]; then
    stop_autoheal 2>/dev/null || true
    local current_pid=$$
    pgrep -f "AI-Stack.command.*--background" | grep -v "^${current_pid}$" | xargs kill -9 2>/dev/null || true
    pgrep -f "AI-Stack.command.*--restart" | grep -v "^${current_pid}$" | xargs kill -9 2>/dev/null || true
    pkill -9 -f "autoheal_loop" 2>/dev/null || true
    pkill -9 -f "agentrouter-proxy" 2>/dev/null || true
    pkill -9 -f "9router" 2>/dev/null || true
    stop_port_force "$PROXY_PORT" "AgentRouter Proxy" >/dev/null 2>&1 || true
    stop_port_force "$ROUTER_PORT" "9Router" >/dev/null 2>&1 || true
    exit 0
fi

# ============================================================
# DIAGNOSTICS-ONLY MODE (used by the native menu-bar app)
# ============================================================
if [[ "${1:-}" == "--diagnostics-only" ]]; then
    diagnostics --noninteractive
    exit 0
fi

# ============================================================
# BACKGROUND MODE (used by the native menu-bar app)
# ============================================================
if [[ "${1:-}" == "--background" ]]; then
    trap - EXIT
    cleanup_background() {
        trap - EXIT
        stop_autoheal
        stop_port_force "$PROXY_PORT" "AgentRouter Proxy" >/dev/null 2>&1 || true
        stop_port_force "$ROUTER_PORT" "9Router" >/dev/null 2>&1 || true
        exit 0
    }
    trap cleanup_background TERM INT HUP EXIT

    bootstrap || exit 1
    start_proxy >/dev/null 2>&1 || true
    start_router >/dev/null 2>&1 || true
    start_autoheal >/dev/null 2>&1 || true

    while true; do
        sleep 3600
    done
fi

# ============================================================
# MAIN
# ============================================================
# If this .command is terminated unexpectedly, clean up the two AI Stack
# ports as well. This prevents orphaned nohup services after closing the window.
cleanup_on_exit() {
    local code=$?
    trap - EXIT
    stop_autoheal
    stop_port_force "$PROXY_PORT" "AgentRouter Proxy" >/dev/null 2>&1 || true
    stop_port_force "$ROUTER_PORT" "9Router" >/dev/null 2>&1 || true
    exit "$code"
}
trap cleanup_on_exit EXIT


bootstrap || {
    print ""
    fail "BOOTSTRAP FAILED."
    print ""
    print "Đã trở về Terminal shell để bạn có thể tiếp tục thao tác."
    trap - EXIT
    exec zsh -l
}

start_proxy
proxy_result=$?

start_router
router_result=$?

start_autoheal

print ""
if (( proxy_result == 0 && router_result == 0 )); then
    print "${G}${B}╔══════════════════════════════════════════════╗${R}"
    print "${G}${B}║                 AI READY                    ║${R}"
    print "${G}${B}╚══════════════════════════════════════════════╝${R}"
    print ""
else
    print "${Y}${B}╔══════════════════════════════════════════════╗${R}"
    print "${Y}${B}║              AI STACK PARTIAL              ║${R}"
    print "${Y}${B}╚══════════════════════════════════════════════╝${R}"
    print ""
    warn "Có service chưa READY. Menu vẫn được giữ mở để xử lý."
fi

banner
if (( proxy_result == 0 && router_result == 0 )); then
    print "  ${G}${B}● AI STACK READY${R}"
    print ""
    status_compact
    print ""
    print "  ${DIM}Dashboard opened automatically.${R}"
else
    print "  ${Y}${B}● AI STACK PARTIAL${R}"
    print ""
    status_compact
    print ""
    print "  ${DIM}Use [2] Start / repair all from the manager.${R}"
fi

menu

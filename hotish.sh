#!/bin/bash

# ═══════════════════════════════════════════
#   hotish — WiFi Hotspot Manager
#   Pure bash. No Python. No dependencies
#   beyond what we install ourselves.
#
#   bash hotish.sh        → installer
#   hotish                → open TUI in new window
#   hotish --tui          → TUI in current terminal
#   hotish --start        → start hotspot (no UI)
#   hotish --stop         → stop hotspot  (no UI)
#   hotish --status       → one-line status
#   hotish --help         → help
#   hotish --coldish      → uninstall everything
#   hotish --uphotish     → update from local file
# ═══════════════════════════════════════════

INSTALL_PATH="/usr/local/bin/hotish"
VERSION="4.2.0"
GITHUB_REPO=""   # set this when you have a repo, e.g. "graham/hotish"
# Auto-detect first wireless interface via iw (more reliable than ip link)
IFACE=$(iw dev 2>/dev/null | awk '/Interface/{print $2; exit}')
: "${IFACE:=wlan0}"
CONF_DIR="$HOME/.hotish"
CONF_FILE="$CONF_DIR/default.conf"
PROFILES_DIR="$CONF_DIR/profiles"
WHITELIST_FILE="$CONF_DIR/whitelist.txt"
BLACKLIST_FILE="$CONF_DIR/blacklist.txt"
LOG_FILE="$CONF_DIR/hotish.log"
START_TIME_FILE="$CONF_DIR/hotish.starttime"

mkdir -p "$CONF_DIR" "$PROFILES_DIR"
touch "$WHITELIST_FILE" "$BLACKLIST_FILE" 2>/dev/null

# ── Colors ───────────────────────────────
R='\033[0;31m';  BR='\033[1;31m'
G='\033[0;32m';  BG='\033[1;32m'
Y='\033[0;33m';  BY='\033[1;33m'
B='\033[0;34m'
C='\033[0;36m';  BC='\033[1;36m'
M='\033[0;35m'
W='\033[1;37m'
DIM='\033[2m';   BOLD='\033[1m'
REV='\033[7m'
NC='\033[0m'

hide_cursor()  { printf '\033[?25l'; }
show_cursor()  { printf '\033[?25h'; }
move_up()      { printf '\033[%dA' "$1"; }
clear_line()   { printf '\033[2K\r'; }

trap 'show_cursor; tput cnorm 2>/dev/null; printf "\n"; exit' INT TERM

# ═══════════════════════════════════════════
#  SHARED: ASCII BANNER
# ═══════════════════════════════════════════

print_banner() {
    printf "\n"
    printf "${BC}${BOLD}   ██╗  ██╗ ██████╗ ████████╗██╗███████╗██╗  ██╗${NC}\n"
    printf "${BC}${BOLD}   ██║  ██║██╔═══██╗╚══██╔══╝██║██╔════╝██║  ██║${NC}\n"
    printf "${BC}${BOLD}   ███████║██║   ██║   ██║   ██║███████╗███████║${NC}\n"
    printf "${BC}${BOLD}   ██╔══██║██║   ██║   ██║   ██║╚════██║██╔══██║${NC}\n"
    printf "${BC}${BOLD}   ██║  ██║╚██████╔╝   ██║   ██║███████║██║  ██║${NC}\n"
    printf "${BC}${BOLD}   ╚═╝  ╚═╝ ╚═════╝    ╚═╝   ╚═╝╚══════╝╚═╝  ╚═╝${NC}\n"
    printf "${DIM}              WiFi Hotspot Manager  •  by graham / IRIR${NC}\n"
    printf "\n"
}

# ═══════════════════════════════════════════
#  CONFIG
# ═══════════════════════════════════════════

load_config() {
    # S#6: randomised default SSID so installs don't all broadcast "hotish"
    local _rand; _rand=$(tr -dc a-z0-9 </dev/urandom 2>/dev/null | head -c4 || echo "$(date +%s | tail -c4)")
    SSID="hotish-${_rand}"; PASSWORD="changeme1"; CHANNEL="6"; HIDDEN="false"
    [[ -f "$CONF_FILE" ]] && source "$CONF_FILE"
}

save_config() {
    cat > "$CONF_FILE" <<EOF
SSID="$SSID"
PASSWORD="$PASSWORD"
CHANNEL="$CHANNEL"
HIDDEN="$HIDDEN"
EOF
}

# ═══════════════════════════════════════════
#  HELPERS
# ═══════════════════════════════════════════

is_running()  { pgrep -f "lnxrouter" > /dev/null 2>&1; }

get_uptime() {
    if [[ -f "$START_TIME_FILE" ]]; then
        local S NOW D
        S=$(cat "$START_TIME_FILE"); NOW=$(date +%s); D=$((NOW - S))
        printf "%02dh %02dm %02ds" $((D/3600)) $(((D%3600)/60)) $((D%60))
    else
        printf "—"
    fi
}

notify_desktop() {
    command -v notify-send &>/dev/null && \
        notify-send "$1" "$2" --icon=network-wireless 2>/dev/null &
}

msg_ok()   { printf "\n   ${BG}✔${NC}  %s\n" "$1"; }
msg_err()  { printf "\n   ${BR}✘${NC}  %s\n" "$1"; }
msg_warn() { printf "\n   ${BY}!${NC}  %s\n" "$1"; }
msg_info() { printf "\n   ${BC}→${NC}  %s\n" "$1"; }

pause() {
    printf "\n   ${DIM}Press Enter to continue...${NC}  "
    read -r
}


# ═══════════════════════════════════════════
#  PROGRESS — linear animated bar
#  Simple, fast, SSH-safe. No spring/gamma math.
# ═══════════════════════════════════════════

# ── Simple linear progress bar (replaces spring-physics version) ──
# API unchanged: progress_run <pct 0-100> [width] [label]
# Renders from current position to target linearly at ~20fps.
# No CPU-hungry gamma/spring math — safe on weak/SSH terminals.
_PR_CUR=0   # current display position (0-100)

progress_render_simple() {
    local POS=$1 WIDTH=${2:-40} LABEL="${3:-}"
    local FILLED=$(( POS * WIDTH / 100 ))
    local EMPTY=$(( WIDTH - FILLED ))
    printf "\r   [${BC}"
    local i; for (( i=0; i<FILLED; i++ )); do printf "█"; done
    printf "${DIM}"
    for (( i=0; i<EMPTY; i++ )); do printf "░"; done
    printf "${NC}] ${W}%3d%%${NC}" "$POS"
    [[ -n "$LABEL" ]] && printf "  ${DIM}%s${NC}" "$LABEL"
}

progress_run() {
    local TARGET=$1 WIDTH=${2:-40} LABEL="${3:-}"
    hide_cursor
    # Animate from _PR_CUR to TARGET in steps
    local step=$(( TARGET > _PR_CUR ? 2 : -2 ))
    while (( (step > 0 && _PR_CUR < TARGET) || (step < 0 && _PR_CUR > TARGET) )); do
        _PR_CUR=$(( _PR_CUR + step ))
        (( step > 0 && _PR_CUR > TARGET )) && _PR_CUR=$TARGET
        (( step < 0 && _PR_CUR < TARGET )) && _PR_CUR=$TARGET
        progress_render_simple "$_PR_CUR" "$WIDTH" "$LABEL"
        sleep 0.03 2>/dev/null || true
    done
    _PR_CUR=$TARGET
    progress_render_simple "$_PR_CUR" "$WIDTH" "$LABEL"
    show_cursor
}

# ── Spinner for indeterminate waits ─────────
# Usage: spinner_start "label"  → sets SPINNER_PID
# Usage: spinner_stop
_SPINNER_FRAMES=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
SPINNER_PID=""

spinner_start() {
    local LABEL="${1:-Working...}"
    local BC='\033[1;36m' NC='\033[0m' DIM='\033[2m'
    hide_cursor
    (
        local i=0
        while true; do
            printf "\r   ${BC}${_SPINNER_FRAMES[$i]}${NC}  ${DIM}%s${NC}  " "$LABEL"
            i=$(( (i + 1) % ${#_SPINNER_FRAMES[@]} ))
            sleep 0.08
        done
    ) &
    SPINNER_PID=$!
}

spinner_stop() {
    local MSG="${1:-}"
    local OK="${2:-ok}"  # ok | err | warn
    if [[ -n "$SPINNER_PID" ]]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null
        SPINNER_PID=""
    fi
    show_cursor
    if [[ -n "$MSG" ]]; then
        case "$OK" in
            ok)   printf "\r   ${BG}✔${NC}  %-50s\n" "$MSG" ;;
            err)  printf "\r   ${BR}✘${NC}  %-50s\n" "$MSG" ;;
            warn) printf "\r   ${BY}!${NC}  %-50s\n" "$MSG" ;;
        esac
    else
        printf "\r%-60s\r" " "
    fi
}

# ═══════════════════════════════════════════
#  OPEN IN NEW TERMINAL WINDOW
# ═══════════════════════════════════════════

open_new_window() {
    local cmd="$INSTALL_PATH --tui"
    if command -v xterm &>/dev/null; then
        xterm -title "hotish" -fa "Monospace" -fs 11 \
              -bg "#0d1117" -fg "#c9d1d9" -geometry 96x38 \
              -e "$cmd" &
    elif command -v gnome-terminal &>/dev/null; then
        gnome-terminal --title="hotish" --geometry=96x38 \
            -- bash -c "$cmd; exec bash" &
    elif command -v xfce4-terminal &>/dev/null; then
        xfce4-terminal --title="hotish" --geometry=96x38 \
            --command="$cmd" &
    elif command -v konsole &>/dev/null; then
        konsole --title "hotish" -e "$cmd" &
    elif command -v lxterminal &>/dev/null; then
        lxterminal --title="hotish" -e "$cmd" &
    else
        printf "\n   ${BY}!${NC}  No terminal emulator found. Launching here instead.\n"
        printf "   ${DIM}Install xterm with: sudo apt install xterm${NC}\n\n"
        sleep 2
        "$INSTALL_PATH" --tui
        return
    fi
    sleep 1
}

# ═══════════════════════════════════════════
#  HELP
# ═══════════════════════════════════════════

show_help() {
    print_banner
    printf "${BC}   ════════════════════════════════════════════${NC}\n"
    printf "${W}                       HELP${NC}\n"
    printf "${BC}   ════════════════════════════════════════════${NC}\n\n"
    printf "   ${W}Usage:${NC}\n\n"
    printf "   ${BC}bash hotish.sh${NC}       ${DIM}First-time install${NC}\n"
    printf "   ${BC}hotish${NC}               ${DIM}Launch TUI in new window${NC}\n"
    printf "   ${BC}hotish --tui${NC}         ${DIM}Launch TUI here${NC}\n"
    printf "   ${BC}hotish --start${NC}       ${DIM}Start hotspot (no UI)${NC}\n"
    printf "   ${BC}hotish --stop${NC}        ${DIM}Stop hotspot (no UI)${NC}\n"
    printf "   ${BC}hotish --status${NC}      ${DIM}One-line status${NC}\n"
    printf "   ${BC}hotish --coldish${NC}          ${DIM}Uninstall everything${NC}\n"
    printf "   ${BC}hotish --uphotish${NC}          ${DIM}Check GitHub for update (needs GITHUB_REPO set)${NC}\n"
    printf "   ${BC}hotish --uphotish <file>${NC}  ${DIM}Update from a local hotish.sh file${NC}\n"
    printf "   ${BC}hotish --help${NC}             ${DIM}This screen${NC}\n"
    printf "\n"
    printf "   ${W}Files:${NC}\n\n"
    printf "   ${DIM}Config   :${NC} ${W}%s${NC}\n" "$CONF_FILE"
    printf "   ${DIM}Profiles :${NC} ${W}%s${NC}\n" "$PROFILES_DIR"
    printf "   ${DIM}Whitelist:${NC} ${W}%s${NC}\n" "$WHITELIST_FILE"
    printf "   ${DIM}Blacklist:${NC} ${W}%s${NC}\n" "$BLACKLIST_FILE"
    printf "   ${DIM}Log      :${NC} ${W}%s${NC}\n" "$LOG_FILE"
    printf "\n"
}

# ═══════════════════════════════════════════
#  CLI (no UI) COMMANDS
# ═══════════════════════════════════════════

cli_start() {
    load_config
    local CHAN; CHAN=$(iw dev "$IFACE" info 2>/dev/null | grep channel | awk '{print $2}')
    [[ -n "$CHAN" ]] && CHANNEL="$CHAN"
    local HFLAG=""; [[ "$HIDDEN" == "true" ]] && HFLAG="--hidden"
    printf "${BC}hotish${NC}  Starting '%s' on ch %s...
" "$SSID" "$CHANNEL"
    sudo lnxrouter --ap "$IFACE" "$SSID" -p "$PASSWORD" -c "$CHANNEL" $HFLAG \
        > "$LOG_FILE" 2>&1 &
    sleep 4
    if pgrep -f "lnxrouter" > /dev/null 2>&1; then
        date +%s > "$START_TIME_FILE"
        printf "${BG}✔${NC}  Hotspot active.
"
    else
        printf "${BR}✘${NC}  Failed. See: %s
" "$LOG_FILE"
    fi
}

cli_stop() {
    printf "${BC}hotish${NC}  Stopping hotspot...\n"
    sudo pkill -f "lnxrouter" 2>/dev/null
    rm -f "$START_TIME_FILE"
    sleep 1
    pgrep -f "lnxrouter" > /dev/null 2>&1 \
        && printf "${BR}✘${NC}  Could not stop.\n" \
        || printf "${BG}✔${NC}  Stopped.\n"
}

cli_status() {
    load_config
    if pgrep -f "lnxrouter" > /dev/null 2>&1; then
        printf "${BG}●${NC}  ${W}ACTIVE${NC}  SSID:${W}%s${NC}  Ch:%s  Up:%s\n" \
            "$SSID" "$CHANNEL" "$(get_uptime)"
    else
        printf "${BR}○${NC}  ${W}INACTIVE${NC}\n"
    fi
}

# ═══════════════════════════════════════════
#  INSTALLER
# ═══════════════════════════════════════════

run_installer() {
    clear
    print_banner
    printf "${BC}   ════════════════════════════════════════════${NC}\n"
    printf "${W}                    INSTALLER${NC}\n"
    printf "${BC}   ════════════════════════════════════════════${NC}\n\n"

    printf "   ${DIM}This will set up hotish on your system:${NC}\n\n"
    printf "   ${BC}❶${NC}  ${W}Install required packages${NC}\n"
    printf "      ${DIM}hostapd · dnsmasq · iw · xterm · qrencode · vnstat${NC}\n\n"
    printf "   ${BC}❷${NC}  ${W}Install lnxrouter${NC}\n"
    printf "      ${DIM}from github.com/garywill/linux-router${NC}\n\n"
    printf "   ${BC}❸${NC}  ${W}Install hotish system-wide${NC}\n"
    printf "      ${DIM}→ /usr/local/bin/hotish${NC}\n\n"
    printf "   ${BC}❹${NC}  ${W}Open hotish TUI in a new window${NC}\n"
    printf "      ${DIM}After that, just type: hotish${NC}\n\n"
    printf "${BC}   ────────────────────────────────────────────${NC}\n\n"
    printf "   ${BY}?${NC}  ${W}Ready to install?${NC} ${DIM}[y/N]${NC}  "
    CONFIRM=""
    read -r CONFIRM </dev/tty || true
    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && printf "\n   ${Y}Cancelled.${NC}\n\n" && exit 0

    # ── STEP 1 ───────────────────────────────
    printf "\n${BC}   ════════════════════════════════════════════${NC}\n"
    printf "${W}   STEP 1 / 4  —  System packages${NC}\n"
    printf "${BC}   ════════════════════════════════════════════${NC}\n\n"

    spinner_start "Updating package lists..."
    sudo apt-get update -qq 2>/dev/null
    spinner_stop "Package lists updated" ok
    printf "\n"

    local _PKGS=(hostapd dnsmasq iw xterm qrencode libnotify-bin vnstat git)
    local _TOTAL=${#_PKGS[@]} _DONE=0
    local _BAR_W=38
    printf "\n"
    for pkg in "${_PKGS[@]}"; do
        _DONE=$(( _DONE + 1 ))
        local _PCT=$(( _DONE * 100 / _TOTAL ))
        if dpkg -s "$pkg" &>/dev/null; then
            progress_run $_PCT $_BAR_W "$pkg (already installed)"
            printf "\n"
        else
            spinner_start "Installing $pkg..."
            if sudo apt-get install -y -qq "$pkg" 2>>"$LOG_FILE"; then
                spinner_stop "$pkg installed" ok
            else
                spinner_stop "$pkg skipped (optional)" warn
            fi
            progress_run $_PCT $_BAR_W ""
            printf "\n"
        fi
    done

    # ── STEP 2 ───────────────────────────────
    printf "\n${BC}   ════════════════════════════════════════════${NC}\n"
    printf "${W}   STEP 2 / 4  —  lnxrouter${NC}\n"
    printf "${BC}   ════════════════════════════════════════════${NC}\n\n"

    if command -v lnxrouter &>/dev/null; then
        printf "   ${BG}✔${NC}  %-24s ${DIM}already installed${NC}\n" "lnxrouter"
    else
        printf "   ${BC}↓${NC}  %-24s cloning from GitHub...\n" "lnxrouter"
        local TMPD; TMPD=$(mktemp -d)
        printf "   ${DIM}Cloning garywill/linux-router...${NC}\n"
        local _CLONE_OK=false
        git clone -q --depth=1 https://github.com/garywill/linux-router "$TMPD/lr" 2>>"$LOG_FILE" \
            && _CLONE_OK=true
        # S#3: fallback — try again without --depth if shallow clone failed
        if [[ "$_CLONE_OK" == false ]]; then
            printf "   ${BY}!${NC}  Shallow clone failed, retrying full clone...\n"
            git clone -q https://github.com/garywill/linux-router "$TMPD/lr" 2>>"$LOG_FILE" \
                && _CLONE_OK=true
        fi
        if [[ "$_CLONE_OK" == true && -f "$TMPD/lr/lnxrouter" ]]; then
            sudo cp "$TMPD/lr/lnxrouter" /usr/local/bin/lnxrouter
            sudo chmod +x /usr/local/bin/lnxrouter
            # C#5: verify it actually works after install
            if lnxrouter --help >/dev/null 2>&1 || lnxrouter -h >/dev/null 2>&1; then
                printf "   ${BG}✔${NC}  %-24s installed and verified\n" "lnxrouter"
            else
                printf "   ${BY}!${NC}  %-24s installed but --help failed — may still work\n" "lnxrouter"
                printf "       ${DIM}Check: lnxrouter --help${NC}\n"
            fi
        else
            printf "   ${BR}✘${NC}  %-24s FAILED — check internet connection\n" "lnxrouter"
            printf "       ${DIM}Manual install: git clone https://github.com/garywill/linux-router${NC}\n"
            printf "       ${DIM}then: sudo install -m755 linux-router/lnxrouter /usr/local/bin/${NC}\n"
        fi
        rm -rf "$TMPD"
    fi

    # ── STEP 3 ───────────────────────────────
    printf "\n${BC}   ════════════════════════════════════════════${NC}\n"
    printf "${W}   STEP 3 / 4  —  Installing hotish${NC}\n"
    printf "${BC}   ════════════════════════════════════════════${NC}\n\n"

    local SCRIPT_PATH; SCRIPT_PATH="$(realpath "$0")"
    printf "   ${BC}→${NC}  Copying to %s...\n" "$INSTALL_PATH"
    sudo cp "$SCRIPT_PATH" "$INSTALL_PATH"
    sudo chmod +x "$INSTALL_PATH"

    if command -v hotish &>/dev/null; then
        printf "   ${BG}✔${NC}  hotish installed at ${W}%s${NC}\n" "$INSTALL_PATH"
    else
        printf "   ${BR}✘${NC}  Installation failed\n"
        exit 1
    fi

    # ── STEP 4 ───────────────────────────────
    printf "\n${BC}   ════════════════════════════════════════════${NC}\n"
    printf "${W}   STEP 4 / 4  —  Launching hotish${NC}\n"
    printf "${BC}   ════════════════════════════════════════════${NC}\n\n"
    printf "   ${BC}→${NC}  Opening in a new terminal window...\n"
    open_new_window

    # ── Done ─────────────────────────────────
    clear
    print_banner
    printf "${BG}${BOLD}"
    printf "   ╔══════════════════════════════════════════╗\n"
    printf "   ║                                          ║\n"
    printf "   ║   ✔  Installation complete!              ║\n"
    printf "   ║                                          ║\n"
    printf "   ╚══════════════════════════════════════════╝\n"
    printf "${NC}\n"
    printf "   ${W}From any terminal you can now run:${NC}\n\n"
    printf "   ${BC}hotish${NC}             ${DIM}→ launch the TUI${NC}\n"
    printf "   ${BC}hotish --start${NC}     ${DIM}→ start hotspot instantly${NC}\n"
    printf "   ${BC}hotish --stop${NC}      ${DIM}→ stop hotspot instantly${NC}\n"
    printf "   ${BC}hotish --status${NC}    ${DIM}→ check status${NC}\n"
    printf "   ${BC}hotish --help${NC}      ${DIM}→ all commands${NC}\n"
    printf "   ${BC}hotish --coldish${NC}     ${DIM}→ uninstall everything${NC}\n"
    printf "\n   ${DIM}The hotish window should now be open. Enjoy! 🚀${NC}\n\n"
    exit 0
}

# ═══════════════════════════════════════════
#  UNINSTALLER
# ═══════════════════════════════════════════

run_uninstaller() {
    clear
    print_banner
    printf "${BR}   ════════════════════════════════════════════${NC}\n"
    printf "${W}                   UNINSTALLER${NC}\n"
    printf "${BR}   ════════════════════════════════════════════${NC}\n\n"

    printf "   ${W}The following will be permanently removed:${NC}\n\n"
    printf "   ${BR}✖${NC}  ${W}%s${NC}\n      ${DIM}The hotish command${NC}\n\n" "$INSTALL_PATH"
    printf "   ${BR}✖${NC}  ${W}/usr/local/bin/lnxrouter${NC}\n      ${DIM}Hotspot engine installed by hotish${NC}\n\n"
    printf "   ${BR}✖${NC}  ${W}%s/${NC}\n      ${DIM}All config, profiles, whitelist, blacklist${NC}\n\n" "$CONF_DIR"
    printf "   ${BY}  Note:${NC} ${DIM}System packages (hostapd, dnsmasq, iw, etc.)${NC}\n"
    printf "   ${DIM}  are NOT removed — may be used by other tools.${NC}\n\n"
    printf "${BR}   ────────────────────────────────────────────${NC}\n\n"
    printf "   ${BY}${BOLD}  This cannot be undone.${NC}\n\n"

    printf "   ${BR}?${NC}  ${W}Are you sure?${NC} ${DIM}Type yes to continue:${NC}  "
    read -r C1
    if [[ "$C1" != "yes" ]]; then
        printf "\n   ${BG}Cancelled — hotish is still installed.${NC}\n\n"
        exit 0
    fi

    # S#5: back up config before wiping anything
    if [[ -d "$CONF_DIR" ]]; then
        local BACKUP_TAR="/tmp/hotish-config-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
        tar -czf "$BACKUP_TAR" -C "$(dirname "$CONF_DIR")" "$(basename "$CONF_DIR")" 2>/dev/null             && printf "   ${BG}✔${NC}  Config backed up to ${W}%s${NC}\n" "$BACKUP_TAR"             || printf "   ${BY}!${NC}  Could not create config backup\n"
    fi

    printf "\n   ${BR}?${NC}  ${W}Type${NC} ${BY}coldish${NC} ${W}to confirm:${NC}  "
    read -r C2
    if [[ "$C2" != "coldish" ]]; then
        printf "\n   ${BG}Cancelled — hotish is still installed.${NC}\n\n"
        exit 0
    fi

    printf "\n${BR}   ════════════════════════════════════════════${NC}\n"
    printf "${W}   Removing...${NC}\n"
    printf "${BR}   ════════════════════════════════════════════${NC}\n\n"

    # Stop hotspot if running
    if pgrep -f "lnxrouter" > /dev/null 2>&1; then
        printf "   ${BC}→${NC}  Stopping active hotspot..."
        sudo pkill -f "lnxrouter" 2>/dev/null
        local VI; VI=$(cat /tmp/hotish.virt_iface 2>/dev/null)
        [[ -n "$VI" && "$VI" != "$IFACE" ]] && sudo iw dev "$VI" del 2>/dev/null
        sudo rm -f /etc/NetworkManager/conf.d/hotish-unmanaged.conf
        sudo nmcli general reload 2>/dev/null
        rm -f /tmp/hotish.virt_iface "$START_TIME_FILE"
        sleep 1
        printf "\r   ${BG}✔${NC}  Active hotspot stopped             \n"
    fi

    # Remove hotish
    if [[ -f "$INSTALL_PATH" ]]; then
        printf "   ${BC}→${NC}  Removing %s..." "$INSTALL_PATH"
        sudo rm -f "$INSTALL_PATH"
        [[ ! -f "$INSTALL_PATH" ]] \
            && printf "\r   ${BG}✔${NC}  Removed %-36s\n" "$INSTALL_PATH" \
            || printf "\r   ${BR}✘${NC}  Could not remove %-30s\n" "$INSTALL_PATH"
    fi

    # Remove lnxrouter
    if [[ -f "/usr/local/bin/lnxrouter" ]]; then
        printf "   ${BC}→${NC}  Removing lnxrouter..."
        sudo rm -f "/usr/local/bin/lnxrouter"
        [[ ! -f "/usr/local/bin/lnxrouter" ]] \
            && printf "\r   ${BG}✔${NC}  Removed lnxrouter                      \n" \
            || printf "\r   ${BR}✘${NC}  Could not remove lnxrouter             \n"
    fi

    # Remove config dir
    if [[ -d "$CONF_DIR" ]]; then
        printf "   ${BC}→${NC}  Removing config dir..."
        rm -rf "$CONF_DIR"
        [[ ! -d "$CONF_DIR" ]] \
            && printf "\r   ${BG}✔${NC}  Removed %s                \n" "$CONF_DIR" \
            || printf "\r   ${BR}✘${NC}  Could not remove %s       \n" "$CONF_DIR"
    fi

    # ── Deep clean: all system traces ──────────
    printf "   ${BC}→${NC}  Scrubbing system traces..."

    # Remove any leftover tmp files
    rm -f "$LOG_FILE" "$START_TIME_FILE" /tmp/hotish.* 2>/dev/null

    # S#5: shell history scrubbing removed — it's surprising behaviour
    # that can corrupt history files on some shells (zsh with HISTFILE locks).
    # Users who want this can run: history -c or manually edit ~/.bash_history

    # Remove any hostapd/dnsmasq/lnxrouter temp files
    sudo rm -f /tmp/lnxrouter.* /tmp/create_ap.* 2>/dev/null  # create_ap: legacy cleanup for upgrades
    sudo rm -f /tmp/hostapd.* 2>/dev/null

    # Remove NetworkManager unmanaged device entries for our iface
    sudo rm -f /etc/NetworkManager/conf.d/hotish-unmanaged.conf 2>/dev/null

    printf "\r   ${BG}✔${NC}  System traces scrubbed                 \n"

    printf "\n"

    if [[ ! -f "$INSTALL_PATH" ]]; then
        printf "${BG}${BOLD}"
        printf "   ╔══════════════════════════════════════════╗\n"
        printf "   ║                                          ║\n"
        printf "   ║   hotish has been fully removed.         ║\n"
        printf "   ║   All data wiped. Clean slate.           ║\n"
        printf "   ║                                          ║\n"
        printf "   ║   It was fun while it lasted. 👋         ║\n"
        printf "   ║                                          ║\n"
        printf "   ╚══════════════════════════════════════════╝\n"
        printf "${NC}\n"
    else
        msg_err "Some files could not be removed. Try: sudo hotish --coldish"
    fi
    exit 0
}


# ═══════════════════════════════════════════
#  UPDATE CHECK (online)
# ═══════════════════════════════════════════

check_for_updates() {
    [[ -z "$GITHUB_REPO" ]] && return   # no repo set, skip silently
    command -v curl &>/dev/null || return

    local LATEST_VER
    LATEST_VER=$(curl -sf --max-time 3         "https://raw.githubusercontent.com/${GITHUB_REPO}/main/VERSION" 2>/dev/null)

    [[ -z "$LATEST_VER" ]] && return    # offline or fetch failed, skip

    if [[ "$LATEST_VER" != "$VERSION" ]]; then
        printf "\n"
        printf "${BY}   ╔══════════════════════════════════════════════╗${NC}\n"
        printf "${BY}   ║  ↑  Update available!  v%s  →  v%s" "$VERSION" "$LATEST_VER"
        printf "%-$((44 - 28 - ${#VERSION} - ${#LATEST_VER}))s║${NC}\n" ""
        printf "${BY}   ║  Run: sudo hotish --uphotish <new_file>     ║${NC}\n"
        printf "${BY}   ╚══════════════════════════════════════════════╝${NC}\n"
        printf "\n"
        sleep 2
    fi
}

# ═══════════════════════════════════════════
#  MANUAL UPDATE  (--uphotish)
# ═══════════════════════════════════════════

run_update() {
    local NEW_FILE="$1"
    clear
    print_banner
    printf "${BC}   ════════════════════════════════════════════${NC}\n"
    printf "${W}                     UPDATE${NC}\n"
    printf "${BC}   ════════════════════════════════════════════${NC}\n\n"

    # ── No file given — try GitHub ────────────
    if [[ -z "$NEW_FILE" ]]; then
        if [[ -z "$GITHUB_REPO" ]]; then
            printf "   ${BR}✘${NC}  No file specified and no GitHub repo configured.\n"
            printf "\n   ${DIM}To update from a file:${NC}\n"
            printf "   ${W}sudo hotish --uphotish /path/to/hotish.sh${NC}\n\n"
            printf "   ${DIM}To enable auto-update from GitHub, set GITHUB_REPO\n"
            printf "   in the script (e.g. GITHUB_REPO=\"graham/hotish\").${NC}\n\n"
            exit 1
        fi

        if ! command -v curl &>/dev/null; then
            msg_err "curl is required for online updates. Install: sudo apt install curl"
            exit 1
        fi

        printf "   ${DIM}No local file given — checking GitHub...${NC}\n\n"

        # Check latest version number first
        local LATEST_VER
        LATEST_VER=$(curl -sf --max-time 6             "https://raw.githubusercontent.com/${GITHUB_REPO}/main/VERSION" 2>/dev/null)

        if [[ -z "$LATEST_VER" ]]; then
            msg_err "Could not reach GitHub. Check your internet connection."
            exit 1
        fi

        printf "   ${DIM}Installed :${NC} ${W}v%s${NC}\n" "$VERSION"
        printf "   ${DIM}Available :${NC} ${W}v%s${NC}\n\n" "$LATEST_VER"

        if [[ "$LATEST_VER" == "$VERSION" ]]; then
            printf "   ${BG}✔${NC}  Already up to date! ${DIM}(v%s)${NC}\n\n" "$VERSION"
            exit 0
        fi

        printf "   ${BC}↓${NC}  Downloading v%s from GitHub...\n" "$LATEST_VER"
        NEW_FILE=$(mktemp /tmp/hotish.update.XXXXXX.sh)
        if ! curl -sf --max-time 30 --progress-bar             "https://raw.githubusercontent.com/${GITHUB_REPO}/main/hotish.sh"             -o "$NEW_FILE" 2>/dev/null; then
            rm -f "$NEW_FILE"
            msg_err "Download failed. Try again or download manually."
            exit 1
        fi
        printf "   ${BG}✔${NC}  Downloaded to %s\n\n" "$NEW_FILE"
        local DOWNLOADED=true
    fi

    # ── Validate file exists ──────────────────
    if [[ ! -f "$NEW_FILE" ]]; then
        msg_err "File not found: $NEW_FILE"
        exit 1
    fi

    printf "   ${DIM}File   :${NC} ${W}%s${NC}\n" "$NEW_FILE"
    printf "   ${DIM}Size   :${NC} ${W}%s bytes${NC}\n" "$(wc -c < "$NEW_FILE")"

    # ── SHA256 fingerprint ────────────────────
    local SHA; SHA=$(sha256sum "$NEW_FILE" | awk '{print $1}')
    printf "   ${DIM}SHA256 :${NC} ${W}%s${NC}\n\n" "$SHA"

    # ── Safety checks ─────────────────────────
    printf "${BC}   ── Safety Checks ──────────────────────────────${NC}\n\n"
    local SAFE=true

    # Check 1: Is it actually a hotish script?
    if grep -q 'hotish — WiFi Hotspot Manager' "$NEW_FILE" 2>/dev/null; then
        printf "   ${BG}✔${NC}  hotish signature found\n"
    else
        printf "   ${BR}✘${NC}  ${BR}${BOLD}hotish signature NOT found${NC}\n"
        printf "      ${DIM}This file does not appear to be a hotish script.${NC}\n"
        SAFE=false
    fi

    # Check 2: Is it a bash script?
    local SHEBANG; SHEBANG=$(head -1 "$NEW_FILE")
    if [[ "$SHEBANG" == "#!/bin/bash" ]] || [[ "$SHEBANG" == "#!/usr/bin/env bash" ]]; then
        printf "   ${BG}✔${NC}  Valid bash shebang\n"
    else
        printf "   ${BR}✘${NC}  ${BR}${BOLD}Not a bash script${NC}  ${DIM}(first line: %s)${NC}\n" "$SHEBANG"
        SAFE=false
    fi

    # Check 3: Bash syntax check
    if bash -n "$NEW_FILE" 2>/dev/null; then
        printf "   ${BG}✔${NC}  Bash syntax valid\n"
    else
        printf "   ${BR}✘${NC}  ${BR}${BOLD}Bash syntax errors detected${NC}\n"
        SAFE=false
    fi

    # Check 4: Version comparison
    local NEW_VER; NEW_VER=$(grep '^VERSION=' "$NEW_FILE" 2>/dev/null | head -1 | cut -d'"' -f2)
    if [[ -n "$NEW_VER" ]]; then
        if [[ "$NEW_VER" == "$VERSION" ]]; then
            printf "   ${BY}!${NC}  Same version as installed  ${DIM}(v%s)${NC}\n" "$VERSION"
        elif [[ "$NEW_VER" > "$VERSION" ]]; then
            printf "   ${BG}✔${NC}  Newer version  ${DIM}v%s${NC} ${BC}→${NC} ${W}v%s${NC}\n" "$VERSION" "$NEW_VER"
        else
            printf "   ${BY}!${NC}  ${BY}${BOLD}OLDER version${NC}  ${DIM}v%s${NC} ${BR}→${NC} ${BY}v%s${NC}  ${DIM}(downgrade)${NC}\n" "$VERSION" "$NEW_VER"
        fi
    else
        printf "   ${BY}!${NC}  No VERSION field found in file\n"
    fi

    # Check 5: File size sanity (must be > 5KB, < 2MB)
    local FSIZE; FSIZE=$(wc -c < "$NEW_FILE")
    if (( FSIZE > 5000 && FSIZE < 2000000 )); then
        printf "   ${BG}✔${NC}  File size reasonable  ${DIM}(%d bytes)${NC}\n" "$FSIZE"
    else
        printf "   ${BY}!${NC}  Unusual file size: %d bytes\n" "$FSIZE"
    fi

    printf "\n"

    # ── Abort if unsafe ───────────────────────
    if [[ "$SAFE" != true ]]; then
        printf "${BR}   ╔══════════════════════════════════════════╗${NC}\n"
        printf "${BR}   ║                                          ║${NC}\n"
        printf "${BR}   ║   ⚠  Safety checks FAILED.              ║${NC}\n"
        printf "${BR}   ║   Update aborted. No changes made.       ║${NC}\n"
        printf "${BR}   ║                                          ║${NC}\n"
        printf "${BR}   ╚══════════════════════════════════════════╝${NC}\n\n"
        exit 1
    fi

    # ── Warn if suspicious but allow override ─
    printf "${BC}   ────────────────────────────────────────────${NC}\n\n"
    printf "   ${BY}⚠  Only install from sources you trust.${NC}\n"
    printf "   ${DIM}   Verify the SHA256 above matches the author's published hash.${NC}\n\n"

    printf "   ${BY}?${NC}  ${W}Install this update?${NC} ${DIM}[yes/N]${NC}  "
    read -r CONFIRM
    if [[ "$CONFIRM" != "yes" ]]; then
        printf "\n   ${BG}Cancelled. No changes made.${NC}\n\n"
        exit 0
    fi

    # ── Backup current version ────────────────
    local BACKUP="/tmp/hotish.backup.$(date +%s)"
    cp "$INSTALL_PATH" "$BACKUP" 2>/dev/null
    printf "\n   ${DIM}Backed up current version to %s${NC}\n" "$BACKUP"
    # Clean up downloaded tmp file after install
    [[ "${DOWNLOADED:-false}" == true ]] && trap "rm -f '$NEW_FILE'" EXIT

    # ── Install ───────────────────────────────
    printf "   ${BC}→${NC}  Installing update...\n"
    sudo cp "$NEW_FILE" "$INSTALL_PATH"
    sudo chmod +x "$INSTALL_PATH"

    if command -v hotish &>/dev/null; then
        printf "\n"
        printf "${BG}${BOLD}"
        printf "   ╔══════════════════════════════════════════╗\n"
        printf "   ║                                          ║\n"
        printf "   ║   ✔  Update installed!  v%s → v%s" "$VERSION" "${NEW_VER:-?}"
        printf "%-$((42 - 22 - ${#VERSION} - ${#NEW_VER:-1}))s║\n" ""
        printf "   ║                                          ║\n"
        printf "   ║   Run: hotish                            ║\n"
        printf "   ║                                          ║\n"
        printf "   ╚══════════════════════════════════════════╝\n"
        printf "${NC}\n"
    else
        printf "\n   ${BR}✘${NC}  Update failed. Restoring backup...\n"
        sudo cp "$BACKUP" "$INSTALL_PATH" 2>/dev/null
        sudo chmod +x "$INSTALL_PATH"
        printf "   ${BG}✔${NC}  Previous version restored.\n\n"
    fi
    exit 0
}

# ═══════════════════════════════════════════
#  TUI: DRAW HEADER
# ═══════════════════════════════════════════

draw_header() {
    clear
    local status_text status_color status_icon uplink hidden_label=""
    if is_running; then
        status_text="ACTIVE";  status_color="$BG"; status_icon="●"
    else
        status_text="OFFLINE"; status_color="$BR"; status_icon="○"
    fi
    [[ "$HIDDEN" == "true" ]] && hidden_label="${BY}[HIDDEN]${NC}"
    uplink=$(iwgetid -r 2>/dev/null); [[ -z "$uplink" ]] && uplink="none"

    print_banner
    printf "${BC}   ╔════════════════════════════════════════════════╗${NC}\n"
    printf "${BC}   ║${NC}  ${status_color}${BOLD}%s %s${NC}         ${DIM}SSID:${NC} ${W}%-14s${NC}  ${DIM}Ch:${NC} ${W}%s${NC}\n" \
        "$status_icon" "$status_text" "$SSID" "$CHANNEL"
    printf "${BC}   ║${NC}  ${DIM}Uptime:${NC} ${W}%-13s${NC}  ${DIM}Pass:${NC} ${W}%-14s${NC}  %b\n" \
        "$(get_uptime)" "$PASSWORD" "$hidden_label"
    printf "${BC}   ║${NC}  ${DIM}Uplink:${NC} ${W}%s${NC}\n" "$uplink"
    printf "${BC}   ╚════════════════════════════════════════════════╝${NC}\n\n"
}

# ═══════════════════════════════════════════
#  TUI: ARROW-KEY MENU ENGINE
# ═══════════════════════════════════════════

arrow_menu() {
    local title="$1"; shift
    local items=("$@")
    local count=${#items[@]}
    local selected=0
    local key esc

    hide_cursor
    while true; do
        for i in "${!items[@]}"; do
            if [[ $i -eq $selected ]]; then
                printf "   ${BC}${BOLD}${REV} ${items[$i]}  ${NC}\n"
            else
                printf "   ${DIM}  ${items[$i]}${NC}\n"
            fi
        done

        IFS= read -r -s -n1 key
        if [[ "$key" == $'\x1b' ]]; then
            IFS= read -r -s -n1 -t 0.1 esc
            IFS= read -r -s -n1 -t 0.1 key
            case "$key" in
                A) ((selected > 0)) && ((selected--)) ;;
                B) ((selected < count-1)) && ((selected++)) ;;
            esac
        elif [[ "$key" == "" ]]; then
            MENU_RESULT=$selected
            show_cursor
            move_up "$count"
            for i in "${!items[@]}"; do clear_line; printf "\n"; done
            move_up "$count"
            return
        elif [[ "$key" == "q" || "$key" == "Q" ]]; then
            MENU_RESULT=999
            show_cursor
            move_up "$count"
            for i in "${!items[@]}"; do clear_line; printf "\n"; done
            move_up "$count"
            return
        fi
        move_up "$count"
    done
}

# ═══════════════════════════════════════════
#  TUI: INPUT PROMPTS
# ═══════════════════════════════════════════

prompt_input() {
    local label="$1" current="$2"
    printf "\n   ${BC}┌─ ${W}%s${NC}\n" "$label"
    printf "   ${BC}│${NC}  ${DIM}current: ${W}%s${NC}\n" "$current"
    printf "   ${BC}└▶${NC} "
    read -r PROMPT_RESULT
    [[ -z "$PROMPT_RESULT" ]] && PROMPT_RESULT="$current"
}

prompt_password() {
    local label="$1" current="$2"
    local input="" char show=false
    printf "\n   ${BC}┌─ ${W}%s${NC}\n" "$label"
    printf "   ${BC}│${NC}  ${DIM}current: ${W}%s${NC}  ${DIM}(? = toggle visibility)${NC}\n" "$current"
    printf "   ${BC}└▶${NC} "
    while IFS= read -r -s -n1 char; do
        case "$char" in
            $'\x7f')
                if [[ -n "$input" ]]; then
                    input="${input%?}"; printf '\b \b'
                fi ;;
            "?")
                show=$([[ "$show" == true ]] && echo false || echo true)
                local len=${#input}
                printf '\r'; printf "   ${BC}└▶${NC} "
                if [[ "$show" == true ]]; then printf "%s" "$input"
                else printf '%0.s*' $(seq 1 $len); fi ;;
            "")
                printf "\n"; break ;;
            *)
                input+="$char"
                [[ "$show" == true ]] && printf "%s" "$char" || printf "*" ;;
        esac
    done
    PROMPT_RESULT="$input"
    [[ -z "$PROMPT_RESULT" ]] && PROMPT_RESULT="$current"
}

prompt_confirm() {
    printf "\n   ${BY}?${NC}  ${W}%s${NC} ${DIM}[y/N]${NC}  " "$1"
    read -r ans; [[ "$ans" =~ ^[Yy]$ ]]
}

section() {
    printf "${BC}   ┌─ ${W}${BOLD}%s${NC}\n   ${BC}└──────────────────────────────────────────${NC}\n\n" "$1"
}

# ═══════════════════════════════════════════
#  TUI: DEPENDENCY CHECK
# ═══════════════════════════════════════════

check_dependencies() {
    draw_header
    section "SYSTEM CHECK"
    spinner_start "Checking dependencies..."
    sleep 0.5
    spinner_stop

    MISSING_DEPS=()

    for dep in lnxrouter iw ip iwgetid; do
        if command -v "$dep" &>/dev/null; then
            printf "   ${BG}✔${NC}  %-20s\n" "$dep"
        else
            printf "   ${BR}✘${NC}  %-20s ${DIM}required${NC}\n" "$dep"
            MISSING_DEPS+=("$dep")
        fi
    done

    printf "\n"
    for opt in qrencode notify-send vnstat; do
        local hint
        case "$opt" in
            qrencode)    hint="QR codes" ;;
            notify-send) hint="desktop notifications" ;;
            vnstat)      hint="bandwidth history" ;;
        esac
        if command -v "$opt" &>/dev/null; then
            printf "   ${BG}✔${NC}  %-20s ${DIM}%s${NC}\n" "$opt" "$hint"
        else
            printf "   ${BY}!${NC}  %-20s ${DIM}optional — %s${NC}\n" "$opt" "$hint"
        fi
    done

    printf "\n"
    sudo -n true 2>/dev/null \
        && printf "   ${BG}✔${NC}  sudo access\n" \
        || { printf "   ${BR}✘${NC}  sudo access required\n"; MISSING_DEPS+=("sudo"); }

    ip link show "$IFACE" &>/dev/null \
        && printf "   ${BG}✔${NC}  Interface ${W}%s${NC}\n" "$IFACE" \
        || {
            printf "   ${BR}✘${NC}  Interface ${W}%s${NC} not found\n" "$IFACE"
            printf "\n   ${DIM}Available:${NC}\n"
            ip link | grep -E "^[0-9]" | awk -F': ' '{print "     "$2}' | grep -v lo
            MISSING_DEPS+=("interface")
        }

    printf "\n"
    local CUR_SSID; CUR_SSID=$(iwgetid -r 2>/dev/null)
    if [[ -n "$CUR_SSID" ]]; then
        local CUR_CHAN; CUR_CHAN=$(iw dev "$IFACE" info 2>/dev/null | grep channel | awk '{print $2}')
        printf "   ${BG}✔${NC}  Uplink: ${W}%s${NC}  ${DIM}ch %s${NC}\n" "$CUR_SSID" "$CUR_CHAN"
        CHANNEL="${CUR_CHAN:-$CHANNEL}"; save_config
    else
        printf "   ${BY}!${NC}  No upstream WiFi  ${DIM}(hotspot works, no internet sharing)${NC}\n"
    fi

    iw list 2>/dev/null | grep -q "AP" \
        && printf "   ${BG}✔${NC}  AP mode supported\n" \
        || { printf "   ${BR}✘${NC}  AP mode not supported\n"; MISSING_DEPS+=("ap-mode"); }

    printf "\n"

    if [[ ${#MISSING_DEPS[@]} -gt 0 ]]; then
        printf "   ${BR}${BOLD}Missing required components:${NC}\n"
        for d in "${MISSING_DEPS[@]}"; do printf "     ${BR}▸${NC} %s\n" "$d"; done
        printf "\n   ${DIM}Run: bash hotish.sh  to auto-install everything${NC}\n"
        pause; show_cursor; exit 1
    fi

    printf "   ${BG}${BOLD}All checks passed.${NC}\n"
    sleep 1
}

# ═══════════════════════════════════════════
#  TUI: QR CODE
# ═══════════════════════════════════════════

show_qr() {
    draw_header; section "QR CODE — SCAN TO CONNECT"
    if ! command -v qrencode &>/dev/null; then
        msg_warn "qrencode not installed."
        msg_info "Install: sudo apt install qrencode"
        pause; return
    fi
    local H="false"; [[ "$HIDDEN" == "true" ]] && H="true"
    printf "   ${DIM}SSID    :${NC} ${W}%s${NC}\n" "$SSID"
    printf "   ${DIM}Password:${NC} ${W}%s${NC}\n" "$PASSWORD"
    [[ "$HIDDEN" == "true" ]] && printf "   ${BY}(Hidden network)${NC}\n"
    printf "\n"
    qrencode -t ANSIUTF8 "WIFI:T:WPA;S:${SSID};P:${PASSWORD};H:${H};;"
    printf "\n   ${DIM}Point your phone camera at the code above.${NC}\n"
    pause
}

# ═══════════════════════════════════════════
#  TUI: START / STOP / RESTART
# ═══════════════════════════════════════════

start_hotspot() {
    draw_header; section "START HOTSPOT"
    if is_running; then msg_warn "Hotspot is already running."; pause; return; fi

    # ── Detect uplink channel + actual phy (C#7: not hardcoded phy0) ────────
    local UPLINK_CHAN; UPLINK_CHAN=$(iw dev "$IFACE" info 2>/dev/null | awk '/channel/{print $2; exit}')
    local IFACE_PHY;  IFACE_PHY=$(iw dev "$IFACE" info 2>/dev/null | awk '/wiphy/{print "phy" $2; exit}')
    : "${IFACE_PHY:=phy0}"   # fallback only

    # ── Always use 2.4GHz for AP — best phone compatibility ────
    # wlp1s0 supports concurrent AP+managed. Uplink stays on 5GHz
    # (ch161); hotspot runs independently on 2.4GHz ch6. Every phone
    # sees 2.4GHz. Only keep a 2.4GHz channel if user set one manually.
    if (( ${CHANNEL:-6} >= 36 )); then
        CHANNEL="6"
        save_config
    fi
    if [[ -n "$UPLINK_CHAN" ]]; then
        printf "   ${DIM}Uplink ch%s — AP on ch%s (2.4GHz)${NC}\n\n" "$UPLINK_CHAN" "$CHANNEL"
    else
        printf "   ${BY}!${NC}  No uplink detected — AP on ch%s\n\n" "$CHANNEL"
    fi

    local HFLAG=""; [[ "$HIDDEN" == "true" ]] && HFLAG="--hidden"

    # ── MAC filter flags ────────────────────────────────────────
    local MAC_FLAGS=""
    if [[ -s "$WHITELIST_FILE" ]]; then
        local wl_macs; wl_macs=$(grep -v '^[[:space:]]*$' "$WHITELIST_FILE" | tr '\n' ',' | sed 's/,$//')
        [[ -n "$wl_macs" ]] && MAC_FLAGS="--mac-filter allow $wl_macs"
        printf "   ${BC}→${NC}  MAC whitelist active: %s\n" "$wl_macs"
    elif [[ -s "$BLACKLIST_FILE" ]]; then
        local bl_macs; bl_macs=$(grep -v '^[[:space:]]*$' "$BLACKLIST_FILE" | tr '\n' ',' | sed 's/,$//')
        [[ -n "$bl_macs" ]] && MAC_FLAGS="--mac-filter deny $bl_macs"
        printf "   ${BC}→${NC}  MAC blacklist active: %s\n" "$bl_macs"
    fi

    printf "   ${DIM}SSID      :${NC} ${W}%s${NC}\n" "$SSID"
    printf "   ${DIM}Password  :${NC} ${W}%s${NC}\n" "$PASSWORD"
    printf "   ${DIM}Channel   :${NC} ${W}%s${NC}\n" "$CHANNEL"
    printf "   ${DIM}Hidden    :${NC} ${W}%s${NC}\n" "$HIDDEN"
    printf "   ${DIM}Interface :${NC} ${W}%s${NC}\n\n" "$IFACE"

    # ── Detect internet uplink BEFORE stopping NM ──────────────
    local INET_IFACE
    INET_IFACE=$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')
    local INET_FLAG=""
    if [[ -n "$INET_IFACE" ]]; then
        INET_FLAG="-o $INET_IFACE"
        printf "   ${DIM}Internet via:${NC} ${W}%s${NC}\n" "$INET_IFACE"
    else
        printf "   ${BY}!${NC}  No default route detected — hotspot only, no internet sharing\n"
    fi

    # ── Stop NM so it releases the interface, start lnxrouter,
    #    then restart NM so the uplink reconnects with internet.
    #    This is the only sequence that works on MT7921/mt7921e:
    #    NM reload alone is not enough — it races and re-grabs wlp1s0.
    printf "   ${DIM}Stopping NetworkManager temporarily...${NC}\n"
    sudo systemctl stop NetworkManager 2>/dev/null
    sleep 1

    # ── Kill stale dnsmasq ──────────────────────────────────────
    sudo pkill dnsmasq 2>/dev/null
    sudo systemctl stop dnsmasq 2>/dev/null
    sleep 0.3
    printf "\n"

    # ── Write NM unmanaged config so when NM restarts it won't
    #    touch the lnxrouter virtual interface (x0wlp1s0*)
    sudo mkdir -p /etc/NetworkManager/conf.d/
    printf '[keyfile]\nunmanaged-devices=interface-name:x0wlp1s0*;interface-name:ap0*\n' \
        | sudo tee /etc/NetworkManager/conf.d/hotish-ap.conf >/dev/null

    # ── Launch lnxrouter ───────────────────────────────────────
    # shellcheck disable=SC2086
    sudo lnxrouter --ap "$IFACE" "$SSID" -p "$PASSWORD" -c "$CHANNEL" \
        $HFLAG $MAC_FLAGS $INET_FLAG \
        > "$LOG_FILE" 2>&1 &

    # C#6: inner trap so Ctrl+C during startup stops spinner cleanly
    trap 'spinner_stop; show_cursor; printf "\n"; return' INT
    spinner_start "Starting hotspot on ch${CHANNEL}..."
    # Wait for lnxrouter to create the virtual interface (~3s) before
    # restarting NM, so NM reconnects uplink without grabbing the AP iface
    sleep 5
    spinner_stop

    # ── Restart NM now — lnxrouter has the AP iface, NM gets uplink ─
    printf "   ${DIM}Restarting NetworkManager (reconnects uplink)...${NC}\n"
    sudo systemctl start NetworkManager 2>/dev/null
    sleep 3
    printf "   ${BG}✔${NC}  NetworkManager restarted\n\n"
    trap 'show_cursor; tput cnorm 2>/dev/null; printf "\n"; exit' INT TERM

    if is_running; then
        date +%s > "$START_TIME_FILE"
        msg_ok "Hotspot is live!"
        notify_desktop "hotish" "Hotspot '${SSID}' is now active."
        if command -v qrencode &>/dev/null; then
            prompt_confirm "Show QR code to connect?" && show_qr && return
        fi
    else
        msg_err "Failed to start. Last log:"
        printf "
"
        tail -8 "$LOG_FILE" | sed 's/^/      /'
    fi
    pause
}

stop_hotspot() {
    draw_header; section "STOP HOTSPOT"
    if ! is_running; then msg_warn "Hotspot is not running."; pause; return; fi

    spinner_start "Stopping hotspot..."
    sudo pkill -f "lnxrouter" 2>/dev/null
    rm -f "$START_TIME_FILE"
    sleep 2
    spinner_stop

    if ! is_running; then
        msg_ok "Hotspot stopped."
        notify_desktop "hotish" "Hotspot '${SSID}' stopped."
        spinner_start "Restoring network..."
        sudo rm -f /etc/NetworkManager/conf.d/hotish-ap.conf
        sudo systemctl reload NetworkManager 2>/dev/null
        sleep 3
        spinner_stop
        local UPLINK; UPLINK=$(iwgetid -r 2>/dev/null)
        if [[ -n "$UPLINK" ]]; then
            printf "   ${BG}✔${NC}  Reconnected to ${W}%s${NC}\n" "$UPLINK"
        else
            printf "   ${BY}!${NC}  Not reconnected yet — WiFi may take a moment\n"
        fi
    else
        msg_err "Could not stop. Try: sudo pkill -9 -f lnxrouter"
    fi
    pause
}

restart_hotspot() {
    draw_header; section "RESTART HOTSPOT"
    msg_info "Stopping..."
    sudo pkill -f "lnxrouter" 2>/dev/null
    rm -f "$START_TIME_FILE"
    sleep 2
    start_hotspot
}

# ═══════════════════════════════════════════
#  TUI: STATUS
# ═══════════════════════════════════════════

show_status() {
    draw_header; section "STATUS & CONNECTED DEVICES"
    local uplink; uplink=$(iwgetid -r 2>/dev/null)
    printf "   ${DIM}Uplink WiFi :${NC} ${W}%s${NC}\n" "${uplink:-none}"
    printf "   ${DIM}Hotspot SSID:${NC} ${W}%s${NC}\n" "$SSID"
    printf "   ${DIM}Password    :${NC} ${W}%s${NC}\n" "$PASSWORD"
    printf "   ${DIM}Channel     :${NC} ${W}%s${NC}\n" "$CHANNEL"
    printf "   ${DIM}Hidden      :${NC} ${W}%s${NC}\n" "$HIDDEN"
    printf "   ${DIM}Uptime      :${NC} ${W}%s${NC}\n\n" "$(get_uptime)"

    if is_running; then
        printf "${BC}   ── Connected Devices ─────────────────────${NC}\n\n"
        # lnxrouter writes leases to /dev/shm, not /var/lib/misc/
        local LEASES
        LEASES=$(find /dev/shm/lnxrouter_tmp/ -name "*.leases" 2>/dev/null | head -1)
        # fallback to system dnsmasq location
        [[ -z "$LEASES" || ! -s "$LEASES" ]] && LEASES="/var/lib/misc/dnsmasq.leases"

        if [[ -f "$LEASES" && -s "$LEASES" ]]; then
            local COUNT=0
            while IFS= read -r line; do
                local MAC IP NAME
                MAC=$(awk '{print $2}' <<< "$line")
                IP=$(awk '{print $3}'  <<< "$line")
                NAME=$(awk '{print $4}' <<< "$line")
                [[ "$NAME" == "*" ]] && NAME="(unknown)"
                printf "   ${BG}▸${NC}  ${W}%-18s${NC}  ${BC}%-16s${NC}  ${DIM}%s${NC}\n" "$NAME" "$IP" "$MAC"
                ((COUNT++))
            done < "$LEASES"
            printf "\n   ${DIM}%d device(s) connected${NC}\n" "$COUNT"
        else
            printf "   ${DIM}No devices connected yet.${NC}\n"
            printf "   ${DIM}(leases file: %s)${NC}\n" "${LEASES:-not found}"
        fi
    fi
    pause
}

# ═══════════════════════════════════════════
#  TUI: BANDWIDTH
# ═══════════════════════════════════════════

show_bandwidth() {
    trap 'show_cursor; printf "\n"; return' INT
    hide_cursor

    # Read /proc/net/dev for a given interface — returns "rx_bytes tx_bytes"
    _bw_read() { awk -v i="$1:" '$1==i{print $2,$10}' /proc/net/dev 2>/dev/null || echo "0 0"; }

    # Human-readable bytes/s
    _bw_fmt() {
        local b=$1
        if   (( b >= 1048576 )); then awk "BEGIN{printf \"%.1f MB/s\",$b/1048576}"
        elif (( b >= 1024    )); then awk "BEGIN{printf \"%.1f KB/s\",$b/1024}"
        else echo "${b} B/s"; fi
    }

    # Bar graph — width proportional to rate vs peak
    _bw_bar() {
        local val=$1 peak=$2 width=30
        (( peak < 1 )) && peak=1
        local filled=$(( val * width / peak ))
        (( filled > width )) && filled=$width
        local empty=$(( width - filled ))
        local i
        for (( i=0; i<filled; i++ )); do printf "█"; done
        for (( i=0; i<empty;  i++ )); do printf "░"; done
    }

    local prev_rx prev_tx cur_rx cur_tx
    read -r prev_rx prev_tx < <(_bw_read "$IFACE")

    local peak_rx=1 peak_tx=1
    local -a rx_hist=() tx_hist=()

    while true; do
        sleep 1
        read -r cur_rx cur_tx < <(_bw_read "$IFACE")
        local drx=$(( cur_rx - prev_rx )); (( drx < 0 )) && drx=0
        local dtx=$(( cur_tx - prev_tx )); (( dtx < 0 )) && dtx=0
        prev_rx=$cur_rx; prev_tx=$cur_tx

        # Update peaks
        (( drx > peak_rx )) && peak_rx=$drx
        (( dtx > peak_tx )) && peak_tx=$dtx

        # Rolling 30s history
        rx_hist+=("$drx"); tx_hist+=("$dtx")
        (( ${#rx_hist[@]} > 30 )) && rx_hist=("${rx_hist[@]:1}") && tx_hist=("${tx_hist[@]:1}")

        # Get connected clients count
        local LEASES; LEASES=$(find /dev/shm/lnxrouter_tmp/ -name "*.leases" 2>/dev/null | head -1)
        [[ -z "$LEASES" || ! -s "$LEASES" ]] && LEASES="/var/lib/misc/dnsmasq.leases"
        local CLIENT_COUNT=0
        [[ -f "$LEASES" && -s "$LEASES" ]] && CLIENT_COUNT=$(grep -c . "$LEASES" 2>/dev/null || echo 0)

        # Redraw
        clear
        draw_header
        printf "${BC}   ── Live Bandwidth Monitor${NC}  ${DIM}(q to return)${NC}\n\n"
        printf "   ${DIM}Interface: ${W}%s${NC}   ${DIM}Clients: ${W}%s${NC}   ${DIM}Uptime: ${W}%s${NC}\n\n" \
            "$IFACE" "$CLIENT_COUNT" "$(get_uptime)"

        # Download
        printf "   ${BG}↓ RX${NC}  ${W}%-12s${NC}  ${BG}" "$(_bw_fmt "$drx")"
        _bw_bar "$drx" "$peak_rx"
        printf "${NC}  ${DIM}peak: %s${NC}\n\n" "$(_bw_fmt "$peak_rx")"

        # Upload
        printf "   ${BY}↑ TX${NC}  ${W}%-12s${NC}  ${BY}" "$(_bw_fmt "$dtx")"
        _bw_bar "$dtx" "$peak_tx"
        printf "${NC}  ${DIM}peak: %s${NC}\n\n" "$(_bw_fmt "$peak_tx")"

        # vnstat totals
        if command -v vnstat &>/dev/null; then
            printf "${BC}   ── vnstat ──────────────────────────────────${NC}\n"
            vnstat -i "$IFACE" --oneline 2>/dev/null | awk -F';' \
                '{printf "   Today  ↓ %-10s ↑ %s\n   Month  ↓ %-10s ↑ %s\n", $9,$10,$11,$12}'
            printf "\n"
        fi

        # Connected clients table (live)
        printf "${BC}   ── Connected Clients ───────────────────────${NC}\n"
        if [[ -f "$LEASES" && -s "$LEASES" ]]; then
            printf "   ${DIM}%-18s %-16s %s${NC}\n" "NAME" "IP" "MAC"
            while IFS= read -r line; do
                local lmac lip lname
                lmac=$(awk '{print $2}' <<< "$line")
                lip=$(awk '{print $3}'  <<< "$line")
                lname=$(awk '{print $4}' <<< "$line")
                [[ "$lname" == "*" ]] && lname="(unknown)"
                printf "   ${W}%-18s${NC} ${BC}%-16s${NC} ${DIM}%s${NC}\n" "$lname" "$lip" "$lmac"
            done < "$LEASES"
        else
            printf "   ${DIM}No clients yet${NC}\n"
        fi

        printf "\n   ${DIM}Press q to return${NC}\n"

        # Non-blocking key check
        local k=""
        IFS= read -rsn1 -t 1 k 2>/dev/null || true
        [[ "$k" == "q" || "$k" == "Q" ]] && break
    done

    show_cursor
    trap 'show_cursor; tput cnorm 2>/dev/null; printf "\n"; exit' INT TERM
}

# ═══════════════════════════════════════════
#  TUI: SPEED TEST
# ═══════════════════════════════════════════

show_speedtest() {
    trap 'show_cursor; printf "\n"; return' INT
    draw_header; section "INTERNET SPEED TEST"

    # Check for speedtest tools in preference order
    local tool=""
    if command -v speedtest &>/dev/null; then
        tool="speedtest"
    elif command -v speedtest-cli &>/dev/null; then
        tool="speedtest-cli"
    elif command -v fast &>/dev/null; then
        tool="fast"
    elif command -v curl &>/dev/null; then
        tool="curl-fallback"
    fi

    if [[ -z "$tool" ]]; then
        printf "   ${BY}!${NC}  No speed test tool found.\n\n"
        printf "   Install one of:\n"
        printf "   ${BC}sudo apt install speedtest-cli${NC}\n"
        printf "   ${BC}sudo pip3 install speedtest-cli${NC}\n"
        pause; return
    fi

    printf "   ${DIM}Tool: %s${NC}\n" "$tool"
    printf "   ${DIM}Testing via uplink: %s${NC}\n\n" "$(iwgetid -r 2>/dev/null || echo "unknown")"
    printf "${BC}   ────────────────────────────────────────────${NC}\n\n"

    spinner_start "Running speed test (this takes ~15 seconds)..."

    local result=""
    case "$tool" in
        speedtest)
            result=$(speedtest --simple 2>/dev/null)
            spinner_stop
            if [[ -n "$result" ]]; then
                local ping dl ul
                ping=$(echo "$result" | awk '/Ping/{print $2,$3}')
                dl=$(echo "$result"   | awk '/Download/{print $2,$3}')
                ul=$(echo "$result"   | awk '/Upload/{print $2,$3}')
                printf "   ${BG}↓${NC}  Download : ${W}%s${NC}\n" "$dl"
                printf "   ${BY}↑${NC}  Upload   : ${W}%s${NC}\n" "$ul"
                printf "   ${BC}◎${NC}  Ping     : ${W}%s${NC}\n" "$ping"
            else
                printf "   ${BR}✘${NC}  Test failed — check internet connection\n"
            fi ;;
        speedtest-cli)
            result=$(speedtest-cli --simple 2>/dev/null)
            spinner_stop
            if [[ -n "$result" ]]; then
                printf "%s\n" "$result" | while IFS= read -r line; do
                    printf "   ${W}%s${NC}\n" "$line"
                done
            else
                printf "   ${BR}✘${NC}  Test failed\n"
            fi ;;
        fast)
            spinner_stop
            printf "   ${DIM}Running fast-cli...${NC}\n\n"
            fast --upload 2>/dev/null || printf "   ${BR}✘${NC}  fast-cli failed\n" ;;
        curl-fallback)
            # Rough download speed test using curl against a known fast host
            spinner_stop
            printf "   ${DIM}No speedtest-cli found — using curl download sample...${NC}\n\n"
            local tmpf; tmpf=$(mktemp)
            local t1; t1=$(date +%s%N)
            curl -s -o "$tmpf" --max-time 10 \
                "http://speedtest.tele2.net/10MB.zip" 2>/dev/null
            local t2; t2=$(date +%s%N)
            local fsize; fsize=$(wc -c < "$tmpf" 2>/dev/null || echo 0)
            rm -f "$tmpf"
            local elapsed_ms=$(( (t2 - t1) / 1000000 ))
            if (( elapsed_ms > 0 && fsize > 0 )); then
                local kbps=$(( fsize * 8 / elapsed_ms ))
                local mbps_int=$(( kbps / 1000 ))
                local mbps_dec=$(( (kbps % 1000) / 100 ))
                printf "   ${BG}↓${NC}  Download : ${W}%d.%d Mbps${NC}  ${DIM}(10MB sample)${NC}\n" "$mbps_int" "$mbps_dec"
                printf "   ${DIM}For upload speed: sudo apt install speedtest-cli${NC}\n"
            else
                printf "   ${BR}✘${NC}  Could not measure — check internet\n"
                printf "   ${DIM}Try: sudo apt install speedtest-cli${NC}\n"
            fi ;;
    esac

    printf "\n"
    pause
    trap 'show_cursor; tput cnorm 2>/dev/null; printf "\n"; exit' INT TERM
}

# ═══════════════════════════════════════════
#  TUI: DEVICE ACCESS
# ═══════════════════════════════════════════

manage_access() {
    while true; do
        draw_header; section "DEVICE ACCESS CONTROL"

        printf "${BC}   ── Whitelist${NC}  ${DIM}(empty = allow all)${NC}\n"
        if [[ -s "$WHITELIST_FILE" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                printf "     ${BG}▸${NC}  %s\n" "$line"
            done < "$WHITELIST_FILE"
        else
            printf "     ${DIM}(empty — all devices allowed)${NC}\n"
        fi

        printf "\n${BC}   ── Blacklist${NC}  ${DIM}(blocked MACs)${NC}\n"
        if [[ -s "$BLACKLIST_FILE" ]]; then
            while IFS= read -r line; do
                [[ -z "$line" ]] && continue
                printf "     ${BR}▸${NC}  %s\n" "$line"
            done < "$BLACKLIST_FILE"
        else
            printf "     ${DIM}(empty)${NC}\n"
        fi

        printf "\n${BC}   ────────────────────────────────────────────${NC}\n\n"

        local opts=(
            "Add to whitelist"
            "Remove from whitelist"
            "Add to blacklist"
            "Remove from blacklist"
            "View connected devices (get MAC)"
            "← Back"
        )
        arrow_menu "Access" "${opts[@]}"
        case $MENU_RESULT in
            0) prompt_input "MAC to whitelist" ""
               [[ -n "$PROMPT_RESULT" ]] && echo "$PROMPT_RESULT" >> "$WHITELIST_FILE" && msg_ok "Added." && sleep 1 ;;
            1) prompt_input "MAC to remove from whitelist" ""
               sed -i "/^${PROMPT_RESULT}$/d" "$WHITELIST_FILE"; msg_ok "Removed."; sleep 1 ;;
            2) prompt_input "MAC to blacklist" ""
               if [[ -n "$PROMPT_RESULT" ]]; then
                   echo "$PROMPT_RESULT" >> "$BLACKLIST_FILE"
                   sudo arp -d "$PROMPT_RESULT" 2>/dev/null
                   msg_ok "Added."; sleep 1
               fi ;;
            3) prompt_input "MAC to remove from blacklist" ""
               sed -i "/^${PROMPT_RESULT}$/d" "$BLACKLIST_FILE"; msg_ok "Removed."; sleep 1 ;;
            4) printf "\n${BC}   ── Connected Devices ───────────────────────${NC}\n\n"
               local LEASES="/var/lib/misc/dnsmasq.leases"
               if [[ -f "$LEASES" ]] && [[ -s "$LEASES" ]]; then
                   while IFS= read -r line; do
                       local MAC IP NAME
                       MAC=$(awk '{print $2}' <<< "$line")
                       IP=$(awk '{print $3}'  <<< "$line")
                       NAME=$(awk '{print $4}' <<< "$line")
                       printf "   ${BG}▸${NC}  ${W}%-16s${NC}  ${DIM}%-16s${NC}  ${W}%s${NC}\n" "$NAME" "$IP" "$MAC"
                   done < "$LEASES"
               else
                   printf "   ${DIM}No devices connected.${NC}\n"
               fi
               pause ;;
            5|999) return ;;
        esac
    done
}

# ═══════════════════════════════════════════
#  TUI: PROFILES
# ═══════════════════════════════════════════

manage_profiles() {
    while true; do
        draw_header; section "PROFILES"

        local PLIST=("$PROFILES_DIR"/*.conf)
        local COUNT=0
        for pf in "${PLIST[@]}"; do
            [[ -f "$pf" ]] || continue
            local PNAME; PNAME=$(basename "$pf" .conf)
            source "$pf"
            printf "   ${BC}▸${NC}  ${W}%-16s${NC}  ${DIM}SSID:%-14s  Ch:%-5s  Hidden:%s${NC}\n" \
                "$PNAME" "$SSID" "$CHANNEL" "$HIDDEN"
            ((COUNT++))
        done
        load_config
        [[ $COUNT -eq 0 ]] && printf "   ${DIM}No profiles saved yet.${NC}\n"
        printf "\n${BC}   ────────────────────────────────────────────${NC}\n\n"

        local opts=("New profile from current config" "Load a profile" "Delete a profile" "← Back")
        arrow_menu "Profiles" "${opts[@]}"
        case $MENU_RESULT in
            0) prompt_input "Profile name" ""
               if [[ -n "$PROMPT_RESULT" ]]; then
                   cat > "$PROFILES_DIR/${PROMPT_RESULT}.conf" <<EOF
SSID="$SSID"
PASSWORD="$PASSWORD"
CHANNEL="$CHANNEL"
HIDDEN="$HIDDEN"
EOF
                   msg_ok "Profile '${PROMPT_RESULT}' saved."; sleep 1
               fi ;;
            1) prompt_input "Profile name to load" ""
               local PF="$PROFILES_DIR/${PROMPT_RESULT}.conf"
               if [[ -f "$PF" ]]; then
                   cp "$PF" "$CONF_FILE"; load_config
                   msg_ok "Profile '${PROMPT_RESULT}' loaded."; sleep 1
               else
                   msg_err "Profile not found."; sleep 1
               fi ;;
            2) prompt_input "Profile name to delete" ""
               local PF="$PROFILES_DIR/${PROMPT_RESULT}.conf"
               [[ -f "$PF" ]] && rm "$PF" && msg_ok "Deleted." || msg_err "Not found."
               sleep 1 ;;
            3|999) return ;;
        esac
    done
}

# ═══════════════════════════════════════════
#  TUI: CONFIGURE
# ═══════════════════════════════════════════

configure() {
    draw_header; section "CONFIGURE HOTSPOT"

    prompt_input "SSID (network name)" "$SSID"; SSID="$PROMPT_RESULT"
    prompt_password "Password (? toggles visibility)" "$PASSWORD"; PASSWORD="$PROMPT_RESULT"

    printf "\n   ${DIM}2.4GHz: 1 6 11   |   5GHz: 36 40 44 48 149 153 157 161${NC}\n"
    printf "   ${DIM}Tip: use 2.4GHz for hotspot if uplink is 5GHz (and vice versa)${NC}\n"
    prompt_input "Channel" "$CHANNEL"; CHANNEL="$PROMPT_RESULT"

    printf "\n   ${BC}Hide from network scan?${NC}\n\n"
    local hopts=("No  — visible to everyone" "Yes — hidden network")
    [[ "$HIDDEN" == "true" ]] && hopts[1]="${hopts[1]}  ← current" || hopts[0]="${hopts[0]}  ← current"
    arrow_menu "Hidden" "${hopts[@]}"
    [[ $MENU_RESULT -eq 1 ]] && HIDDEN="true" || HIDDEN="false"

    save_config
    msg_ok "Configuration saved."
    pause
}

# ═══════════════════════════════════════════
#  TUI: VIEW LOG
# ═══════════════════════════════════════════

view_log() {
    draw_header; section "LOG"
    printf "   ${DIM}%s${NC}\n\n" "$LOG_FILE"
    if [[ -f "$LOG_FILE" ]]; then
        tail -30 "$LOG_FILE" | sed 's/^/   /'
    else
        printf "   ${DIM}No log file yet.${NC}\n"
    fi
    pause
}

# ═══════════════════════════════════════════
#  TUI: MAIN MENU
# ═══════════════════════════════════════════

main_menu() {
    load_config
    check_for_updates
    check_dependencies

    local MENU_ITEMS=(
        " ▶  Start Hotspot"
        " ■  Stop Hotspot"
        " ↺  Restart Hotspot"
        " ◉  Status & Devices"
        " ✎  Configure          SSID · Password · Channel · Hidden"
        " ⊞  Profiles"
        " ⚿  Device Access      Whitelist · Blacklist"
        " ≋  Bandwidth Monitor  (live)"
        " ⚡  Speed Test"
        " ⊡  Show QR Code"
        " ☰  View Log"
        " ✖  Quit"
    )

    while true; do
        draw_header
        printf "   ${DIM}↑ ↓ navigate    Enter select    q quit${NC}\n\n"
        arrow_menu "Main" "${MENU_ITEMS[@]}"
        case $MENU_RESULT in
            0)  start_hotspot ;;
            1)  stop_hotspot ;;
            2)  restart_hotspot ;;
            3)  show_status ;;
            4)  configure ;;
            5)  manage_profiles ;;
            6)  manage_access ;;
            7)  show_bandwidth ;;
            8)  show_speedtest ;;
            9)  show_qr ;;
            10) view_log ;;
            11|999) clear; show_cursor; exit 0 ;;
        esac
    done
}

# ═══════════════════════════════════════════
#  ENTRY POINT
# ═══════════════════════════════════════════

SCRIPT_NAME=$(basename "$0")

case "${1:-}" in
    --help|-h)   show_help; exit 0 ;;
    --coldish)   run_uninstaller ;;
    --uphotish) run_update "$2" ;;
    --start)     cli_start; exit 0 ;;
    --stop)      cli_stop; exit 0 ;;
    --restart)   load_config; cli_stop 2>/dev/null; sleep 2; cli_start; exit 0 ;;
    --status)    load_config; cli_status; exit 0 ;;
    --tui)       load_config; main_menu ;;
    "")
        if [[ "$SCRIPT_NAME" == "hotish" ]]; then
            open_new_window; exit 0
        else
            run_installer
        fi ;;
    *)
        printf "${BR}Unknown option: %s${NC}\n" "$1"
        printf "${DIM}Run: hotish --help${NC}\n"; exit 1 ;;
esac

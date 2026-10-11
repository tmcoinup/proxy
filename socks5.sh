#!/usr/bin/env bash
#
# =============================================================================
#  socks5.sh —— SOCKS5 代理服务端一键部署脚本 (基于 Dante)
# -----------------------------------------------------------------------------
#  功能
#    * 自动识别发行版 / 版本 / 架构 / init 系统，默认按 Ubuntu 流程部署
#    * 自动识别外部出口网卡 (IPv4 / IPv6)
#    * 用户名 + 密码认证 (RFC 1929)，允许任意来源 IP 连接
#    * 用户名 / 密码默认随机生成，可通过参数或环境变量指定
#    * 默认端口 6666，开机自启，异常自动重启
#    * 多主进程 (-N) 利用多核；内核网络调优 + 游戏优化 (UDP 转发 / 低延迟 / BBR)
#    * 不保留任何服务日志
#
#  支持系统
#    Ubuntu 16.04+ / Debian 9+ (首选)         apt 安装 dante-server
#    CentOS / RHEL / Rocky / Alma / Oracle / Fedora / Amazon /
#    openEuler / Anolis / OpenCloudOS 等       软件包，无则源码编译
#    Alpine (OpenRC) / openSUSE / Arch          软件包，无则源码编译
#
#  用法
#    bash socks5.sh                          安装：随机用户名密码，端口 6666
#    bash socks5.sh -u alice -p 'S3cret_pw'  安装：指定用户名密码
#    bash socks5.sh info | status | restart | uninstall
#    bash socks5.sh -h                       查看全部参数
# =============================================================================

if [ -z "${BASH_VERSION:-}" ]; then
    echo "错误: 请使用 bash 运行本脚本，例如: sudo bash $0" >&2
    exit 1
fi
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "错误: 需要 bash 4.0 及以上版本" >&2
    exit 1
fi

set -Eeuo pipefail
umask 022
export LC_ALL=C
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

# ----------------------------------------------------------------------------
# 常量
# ----------------------------------------------------------------------------
readonly SCRIPT_VERSION="1.0.0"
readonly DEFAULT_PORT=6666
readonly DEFAULT_UDP_RANGE="50000-59999"

readonly DANTE_MIN_MAJOR=1
readonly DANTE_MIN_MINOR=4
readonly DANTE_SRC_VERSION="1.4.4"
readonly DANTE_SRC_SHA256="1973c7732f1f9f0a4c0ccf2c1ce462c7c25060b25643ea90f9b98f53a813faec"
readonly DANTE_SRC_URL_DEFAULT="https://www.inet.no/dante/files/dante-${DANTE_SRC_VERSION}.tar.gz"
readonly DANTE_SRC_BIN="/usr/local/sbin/sockd"

readonly SERVICE_NAME="danted"
readonly CONF_FILE="/etc/danted.conf"
readonly CONF_MARKER="# Managed by socks5.sh"
readonly STATE_DIR="/etc/socks5"
readonly STATE_FILE="${STATE_DIR}/socks5.env"
readonly SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
readonly OPENRC_SCRIPT="/etc/init.d/${SERVICE_NAME}"
readonly SYSCTL_FILE="/etc/sysctl.d/99-socks5-tuning.conf"
readonly MODULES_FILE="/etc/modules-load.d/socks5-bbr.conf"
readonly CTL_PATH="/usr/local/sbin/socks5ctl"
readonly PROXY_GROUP="socks5proxy"
readonly FW_TAG="socks5"
readonly MAX_WORKERS=8

# ----------------------------------------------------------------------------
# 运行期变量
# ----------------------------------------------------------------------------
CMD="install"
OPT_USER="${SOCKS5_USER:-}"
OPT_PASS="${SOCKS5_PASS:-}"
OPT_PORT="${SOCKS5_PORT:-}"
OPT_UDP_RANGE="${SOCKS5_UDP_RANGE:-}"
OPT_IFACE="${SOCKS5_IFACE:-}"
OPT_TUNE=1
OPT_RENEW=0
OPT_FORCE_SOURCE=0
OPT_YES=0

OS_ID=""
OS_VERSION=""
OS_NAME=""
OS_LIKE=""
OS_FAMILY=""
PKG_MGR=""
INIT_SYS=""
ARCH=""

DANTE_BIN=""
DANTE_VERSION=""
DANTE_ORIGIN=""
UNPRIV_USER="nobody"
WORKERS=1

EGRESS_IF4=""
EGRESS_IF6=""
EXTERNAL_IFACES=()
LISTEN_V4=0
LISTEN_V6=0
EGRESS_V6_OK=0

SOCKS_USER=""
SOCKS_PASS=""
SOCKS_PORT=""
UDP_RANGE=""

FIREWALL_KIND="none"
FIREWALL_ZONE=""
TUNED=0

PUBLIC_IP4=""
PUBLIC_IP6=""

PREV_USER=""
PREV_PASS=""
PREV_PORT=""
PREV_UDP_RANGE=""
PREV_ORIGIN=""
PREV_BIN=""
PREV_FIREWALL=""
PREV_FW_ZONE=""

TMP_DIR=""
POLICY_RC_CREATED=0

# ----------------------------------------------------------------------------
# 输出
# ----------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'; C_BOLD=$'\033[1m'; C_RESET=$'\033[0m'
else
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_BOLD=""; C_RESET=""
fi

log_info()  { printf '%s[信息]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()  { printf '%s[警告]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%s[错误]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
log_step()  { printf '\n%s==>%s %s%s%s\n' "$C_BLUE" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
die()       { log_error "$*"; exit 1; }

# ----------------------------------------------------------------------------
# 异常与清理
# ----------------------------------------------------------------------------
on_error() {
    local rc=$1 line=$2 cmd=$3
    log_error "第 ${line} 行执行失败 (退出码 ${rc}): ${cmd}"
    exit "$rc"
}

cleanup() {
    if (( POLICY_RC_CREATED )); then
        rm -f /usr/sbin/policy-rc.d
    fi
    if [[ -n $TMP_DIR && -d $TMP_DIR ]]; then
        rm -rf -- "$TMP_DIR"
    fi
}

trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'log_error "操作已被中断"; exit 130' INT TERM

# ----------------------------------------------------------------------------
# 通用工具
# ----------------------------------------------------------------------------
has_cmd() { command -v "$1" >/dev/null 2>&1; }

retry() {
    local attempts=$1 delay=$2 i
    shift 2
    for (( i = 1; i <= attempts; i++ )); do
        if "$@"; then
            return 0
        fi
        if (( i < attempts )); then
            log_warn "第 ${i} 次尝试失败，${delay} 秒后重试: $*"
            sleep "$delay"
        fi
    done
    return 1
}

cpu_count() {
    local n
    n=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    if ! [[ $n =~ ^[0-9]+$ ]] || (( n < 1 )); then
        n=1
    fi
    printf '%s' "$n"
}

# 生成指定长度、指定字符集的随机串 (读取定长随机字节，避免 SIGPIPE 与 pipefail 冲突)
rand_str() {
    local len=$1 charset=$2 out="" chunk
    while (( ${#out} < len )); do
        chunk=$(head -c 512 /dev/urandom | tr -dc "$charset")
        out+=$chunk
    done
    printf '%s' "${out:0:len}"
}

urlencode() {
    local s=$1 out="" c i
    for (( i = 0; i < ${#s}; i++ )); do
        c=${s:i:1}
        case $c in
            [a-zA-Z0-9.~_-]) out+=$c ;;
            *) printf -v c '%%%02X' "'$c"; out+=$c ;;
        esac
    done
    printf '%s' "$out"
}

# curl 配置文件中双引号字符串的转义
curl_cfg_escape() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    printf '%s' "$s"
}

is_ipv4() {
    local ip=$1 o
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

is_ipv6() {
    [[ $1 == *:* && $1 =~ ^[0-9a-fA-F:.]+$ ]]
}

is_container() {
    if has_cmd systemd-detect-virt && systemd-detect-virt --container --quiet 2>/dev/null; then
        return 0
    fi
    if [[ -f /.dockerenv || -f /run/.containerenv ]]; then
        return 0
    fi
    if [[ -r /proc/1/environ ]] && grep -qa 'container=' /proc/1/environ 2>/dev/null; then
        return 0
    fi
    return 1
}

# 判断 TCP 端口是否处于 LISTEN (直接解析 /proc，不依赖 ss/netstat)
port_listening() {
    local hex files=() f
    printf -v hex ':%04X' "$1"
    for f in /proc/net/tcp /proc/net/tcp6; do
        if [[ -r $f ]]; then
            files+=("$f")
        fi
    done
    (( ${#files[@]} > 0 )) || return 1
    awk -v h="$hex" '$4 == "0A" && toupper(substr($2, length($2) - 4)) == h { found = 1 } END { exit !found }' "${files[@]}"
}

port_owner() {
    local out
    if has_cmd ss; then
        out=$(ss -lntpH "sport = :$1" 2>/dev/null || true)
        if [[ $out =~ \"([^\"]+)\" ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    fi
    printf '%s' "未知进程"
}

# ----------------------------------------------------------------------------
# 帮助与参数
# ----------------------------------------------------------------------------
usage() {
    cat <<EOF
SOCKS5 代理服务一键部署脚本 v${SCRIPT_VERSION} (基于 Dante)

用法: bash $0 [命令] [选项]

命令:
  install              安装 / 重新部署 (默认)
  info                 显示连接信息
  status               查看服务状态并做认证自检
  restart              重启服务
  uninstall            卸载服务、账号、防火墙规则与调优配置

选项:
  -u, --user USER      认证用户名 (默认随机；规则: 小写字母/数字/_/-，字母或_开头，最长 32)
  -p, --pass PASS      认证密码   (默认随机 20 位；可见 ASCII 字符，不含空格，最长 255)
  -P, --port PORT      监听端口   (默认 ${DEFAULT_PORT})
      --udp-range A-B  UDP 转发端口段 (默认 ${DEFAULT_UDP_RANGE}，游戏/语音等 UDP 流量使用)
  -i, --iface IFACE    指定外部出口网卡 (默认自动识别)
      --renew          重新随机生成用户名密码 (默认重装时沿用已有账号)
      --no-tune        跳过内核网络 / 游戏低延迟调优
      --source         强制源码编译 Dante v${DANTE_SRC_VERSION}
  -y, --yes            卸载时不再确认
  -h, --help           显示帮助
  -v, --version        显示版本

环境变量 (优先级低于命令行参数):
  SOCKS5_USER  SOCKS5_PASS  SOCKS5_PORT  SOCKS5_UDP_RANGE  SOCKS5_IFACE
  DANTE_SRC_URL  (源码包下载地址，可指向内网镜像，SHA256 仍强制校验)

示例:
  sudo bash $0
  sudo bash $0 -u alice -p 'S3cret_pw'
  curl -fsSL <脚本地址> | sudo bash -s -- -u alice -p 'S3cret_pw'
EOF
}

need_arg() {
    if (( $2 < 2 )); then
        die "参数 $1 需要一个值 (使用 -h 查看帮助)"
    fi
}

parse_args() {
    while (( $# > 0 )); do
        case $1 in
            install|uninstall|info|status|restart) CMD=$1 ;;
            -u|--user)      need_arg "$1" $#; OPT_USER=$2; shift ;;
            --user=*)       OPT_USER=${1#*=} ;;
            -p|--pass|--password) need_arg "$1" $#; OPT_PASS=$2; shift ;;
            --pass=*|--password=*) OPT_PASS=${1#*=} ;;
            -P|--port)      need_arg "$1" $#; OPT_PORT=$2; shift ;;
            --port=*)       OPT_PORT=${1#*=} ;;
            --udp-range)    need_arg "$1" $#; OPT_UDP_RANGE=$2; shift ;;
            --udp-range=*)  OPT_UDP_RANGE=${1#*=} ;;
            -i|--iface)     need_arg "$1" $#; OPT_IFACE=$2; shift ;;
            --iface=*)      OPT_IFACE=${1#*=} ;;
            --renew)        OPT_RENEW=1 ;;
            --no-tune)      OPT_TUNE=0 ;;
            --source)       OPT_FORCE_SOURCE=1 ;;
            -y|--yes)       OPT_YES=1 ;;
            -h|--help)      usage; exit 0 ;;
            -v|--version)   printf 'socks5.sh v%s\n' "$SCRIPT_VERSION"; exit 0 ;;
            *)              die "未知参数: $1 (使用 -h 查看帮助)" ;;
        esac
        shift
    done
}

# ----------------------------------------------------------------------------
# 前置检查
# ----------------------------------------------------------------------------
require_root() {
    if (( EUID != 0 )); then
        die "请使用 root 权限运行: sudo bash $0 $*"
    fi
}

acquire_lock() {
    local lock="/run/socks5-deploy.lock"
    [[ -d /run ]] || lock="/tmp/socks5-deploy.lock"
    if has_cmd flock; then
        exec 9>"$lock"
        if ! flock -n 9; then
            die "已有另一个部署进程正在运行，请稍后再试"
        fi
    fi
}

detect_os() {
    local key val
    if [[ -r /etc/os-release ]]; then
        while IFS='=' read -r key val; do
            val=${val%\"}; val=${val#\"}
            val=${val%\'}; val=${val#\'}
            case $key in
                ID)          OS_ID=${val,,} ;;
                VERSION_ID)  OS_VERSION=$val ;;
                PRETTY_NAME) OS_NAME=$val ;;
                ID_LIKE)     OS_LIKE=${val,,} ;;
            esac
        done </etc/os-release
    elif [[ -r /etc/redhat-release ]]; then
        OS_ID="centos"
        OS_NAME=$(</etc/redhat-release)
        if [[ $OS_NAME =~ ([0-9]+(\.[0-9]+)?) ]]; then
            OS_VERSION=${BASH_REMATCH[1]}
        fi
    fi

    if [[ -z $OS_ID ]]; then
        OS_ID="ubuntu"
        log_warn "无法识别操作系统，按默认 Ubuntu 流程部署"
    fi
    [[ -n $OS_NAME ]] || OS_NAME="${OS_ID} ${OS_VERSION}"
    ARCH=$(uname -m)

    case $OS_ID in
        ubuntu|debian|linuxmint|pop|kali|deepin|uos|raspbian|devuan|elementary|zorin|neon|armbian|pureos)
            OS_FAMILY="debian" ;;
        centos|rhel|rocky|almalinux|ol|fedora|amzn|anolis|openeuler|opencloudos|tencentos|alinux|euleros|kylin|circle|eurolinux|navylinux|miraclelinux|virtuozzo|cloudlinux|scientific|bclinux|hce)
            OS_FAMILY="rhel" ;;
        alpine)
            OS_FAMILY="alpine" ;;
        opensuse*|sles|sled|sle-micro)
            OS_FAMILY="suse" ;;
        arch|manjaro|endeavouros|artix|garuda)
            OS_FAMILY="arch" ;;
        *)
            case " ${OS_LIKE} " in
                *" debian "*|*" ubuntu "*)            OS_FAMILY="debian" ;;
                *" rhel "*|*" fedora "*|*" centos "*) OS_FAMILY="rhel" ;;
                *" suse "*)                           OS_FAMILY="suse" ;;
                *" arch "*)                           OS_FAMILY="arch" ;;
                *)                                    OS_FAMILY="" ;;
            esac ;;
    esac

    case $OS_FAMILY in
        debian) if has_cmd apt-get; then PKG_MGR="apt"; fi ;;
        rhel)
            if has_cmd dnf; then
                PKG_MGR="dnf"
            elif has_cmd yum; then
                PKG_MGR="yum"
            fi ;;
        alpine) if has_cmd apk; then PKG_MGR="apk"; fi ;;
        suse)   if has_cmd zypper; then PKG_MGR="zypper"; fi ;;
        arch)   if has_cmd pacman; then PKG_MGR="pacman"; fi ;;
    esac

    # 发行版标识与包管理器不一致时 (如部分国产衍生版)，以实际包管理器为准，优先 apt (Ubuntu 流程)
    if [[ -z $PKG_MGR ]]; then
        if has_cmd apt-get; then
            PKG_MGR="apt"; OS_FAMILY="debian"
        elif has_cmd dnf; then
            PKG_MGR="dnf"; OS_FAMILY="rhel"
        elif has_cmd yum; then
            PKG_MGR="yum"; OS_FAMILY="rhel"
        elif has_cmd apk; then
            PKG_MGR="apk"; OS_FAMILY="alpine"
        elif has_cmd zypper; then
            PKG_MGR="zypper"; OS_FAMILY="suse"
        elif has_cmd pacman; then
            PKG_MGR="pacman"; OS_FAMILY="arch"
        else
            die "未找到受支持的包管理器 (apt / dnf / yum / apk / zypper / pacman)"
        fi
    fi
}

detect_init() {
    if [[ -d /run/systemd/system ]] && has_cmd systemctl; then
        INIT_SYS="systemd"
    elif has_cmd openrc-run || [[ -x /sbin/openrc-run ]]; then
        INIT_SYS="openrc"
    else
        die "未检测到 systemd 或 OpenRC，无法配置开机自启 (容器内请改在宿主机部署)"
    fi
}

print_env_summary() {
    log_info "操作系统: ${OS_NAME} (ID=${OS_ID}, 版本=${OS_VERSION:-未知}, 系列=${OS_FAMILY})"
    log_info "系统架构: ${ARCH}，内核 $(uname -r)，CPU ${WORKERS}/$(cpu_count) (Dante 主进程/核心)"
    log_info "包管理器: ${PKG_MGR}，init 系统: ${INIT_SYS}"
}

# ----------------------------------------------------------------------------
# 状态文件 (仅 root 可读；不使用 source 解析，杜绝代码注入)
# ----------------------------------------------------------------------------
load_state() {
    local key val
    [[ -r $STATE_FILE ]] || return 0
    while IFS='=' read -r key val; do
        case $key in
            SOCKS5_USER)      PREV_USER=$val ;;
            SOCKS5_PASS)      PREV_PASS=$val ;;
            SOCKS5_PORT)      PREV_PORT=$val ;;
            SOCKS5_UDP_RANGE) PREV_UDP_RANGE=$val ;;
            DANTE_ORIGIN)     PREV_ORIGIN=$val ;;
            DANTE_BIN)        PREV_BIN=$val ;;
            FIREWALL_KIND)    PREV_FIREWALL=$val ;;
            FIREWALL_ZONE)    PREV_FW_ZONE=$val ;;
        esac
    done <"$STATE_FILE"
}

save_state() {
    local tmp
    install -d -m 700 "$STATE_DIR"
    tmp=$(mktemp "${STATE_DIR}/.socks5.env.XXXXXX")
    {
        printf '# 由 socks5.sh 维护，请勿手动修改\n'
        printf 'SOCKS5_USER=%s\n' "$SOCKS_USER"
        printf 'SOCKS5_PASS=%s\n' "$SOCKS_PASS"
        printf 'SOCKS5_PORT=%s\n' "$SOCKS_PORT"
        printf 'SOCKS5_UDP_RANGE=%s\n' "$UDP_RANGE"
        printf 'DANTE_ORIGIN=%s\n' "$DANTE_ORIGIN"
        printf 'DANTE_BIN=%s\n' "$DANTE_BIN"
        printf 'DANTE_VERSION=%s\n' "$DANTE_VERSION"
        printf 'FIREWALL_KIND=%s\n' "$FIREWALL_KIND"
        printf 'FIREWALL_ZONE=%s\n' "$FIREWALL_ZONE"
        printf 'TUNED=%s\n' "$TUNED"
        printf 'INIT_SYS=%s\n' "$INIT_SYS"
        printf 'UPDATED_AT=%s\n' "$(date '+%F %T %z')"
    } >"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

# ----------------------------------------------------------------------------
# 参数决策与校验
# ----------------------------------------------------------------------------
validate_user() {
    [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] \
        || die "用户名不合法: '$1' (小写字母/数字/_/-，字母或_开头，最长 32 位)"
    case $1 in
        root|nobody|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|sshd|admin|ubuntu|centos|debian|ec2-user|"$PROXY_GROUP")
            die "用户名 '$1' 为系统保留名称，请更换" ;;
    esac
}

validate_pass() {
    local len=${#1}
    (( len >= 1 && len <= 255 )) || die "密码长度必须在 1~255 之间"
    [[ $1 =~ ^[[:graph:]]+$ ]] || die "密码只能包含可见 ASCII 字符 (不含空格、中文)"
    if (( len < 8 )); then
        log_warn "密码长度小于 8 位，公网环境下存在被暴力破解风险"
    fi
}

validate_port() {
    if ! [[ $1 =~ ^[0-9]{1,5}$ ]] || (( 10#$1 < 1 || 10#$1 > 65535 )); then
        die "端口不合法: '$1' (1~65535)"
    fi
}

validate_udp_range() {
    local a b
    [[ $1 =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]] || die "UDP 端口段格式错误: '$1' (示例: 50000-59999)"
    a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]}))
    (( a >= 1024 && b <= 65535 && a <= b )) || die "UDP 端口段必须在 1024~65535 之间且起始不大于结束"
    (( b - a + 1 >= 16 )) || die "UDP 端口段过小 (至少 16 个端口)"
    if (( SOCKS_PORT >= a && SOCKS_PORT <= b )); then
        die "UDP 端口段 $1 不能包含 SOCKS5 监听端口 ${SOCKS_PORT}"
    fi
    UDP_RANGE="${a}-${b}"
}

resolve_settings() {
    log_step "确定部署参数"

    SOCKS_PORT=${OPT_PORT:-${PREV_PORT:-$DEFAULT_PORT}}
    validate_port "$SOCKS_PORT"
    SOCKS_PORT=$((10#$SOCKS_PORT))

    validate_udp_range "${OPT_UDP_RANGE:-${PREV_UDP_RANGE:-$DEFAULT_UDP_RANGE}}"

    if [[ -n $OPT_USER ]]; then
        SOCKS_USER=$OPT_USER
    elif (( ! OPT_RENEW )) && [[ -n $PREV_USER ]]; then
        SOCKS_USER=$PREV_USER
        log_info "沿用已有用户名 (如需重新随机生成请加 --renew)"
    else
        SOCKS_USER="u$(rand_str 7 'a-z0-9')"
    fi
    validate_user "$SOCKS_USER"

    if [[ -n $OPT_PASS ]]; then
        SOCKS_PASS=$OPT_PASS
    elif (( ! OPT_RENEW )) && [[ -n $PREV_PASS && $SOCKS_USER == "$PREV_USER" ]]; then
        SOCKS_PASS=$PREV_PASS
    else
        SOCKS_PASS=$(rand_str 20 'A-Za-z0-9')
    fi
    validate_pass "$SOCKS_PASS"

    log_info "监听端口: ${SOCKS_PORT}/tcp，UDP 转发端口段: ${UDP_RANGE}/udp"
    log_info "认证用户: ${SOCKS_USER}"
}

# ----------------------------------------------------------------------------
# 包管理
# ----------------------------------------------------------------------------
apt_update() {
    DEBIAN_FRONTEND=noninteractive apt-get update -q -o DPkg::Lock::Timeout=300 >/dev/null
}

pkg_install() {
    case $PKG_MGR in
        apt)
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends \
                -o DPkg::Lock::Timeout=300 \
                -o Dpkg::Options::=--force-confdef \
                -o Dpkg::Options::=--force-confold "$@" >/dev/null ;;
        dnf)    dnf install -y -q "$@" >/dev/null ;;
        yum)    yum install -y -q "$@" >/dev/null ;;
        apk)    apk add --no-cache -q "$@" >/dev/null ;;
        zypper) zypper --non-interactive --quiet install --no-recommends "$@" >/dev/null ;;
        pacman) pacman -S --noconfirm --needed --quiet "$@" >/dev/null ;;
    esac
}

pkg_remove() {
    case $PKG_MGR in
        apt)    DEBIAN_FRONTEND=noninteractive apt-get purge -y -q -o DPkg::Lock::Timeout=300 "$@" >/dev/null ;;
        dnf)    dnf remove -y -q "$@" >/dev/null ;;
        yum)    yum remove -y -q "$@" >/dev/null ;;
        apk)    apk del -q "$@" >/dev/null ;;
        zypper) zypper --non-interactive --quiet remove "$@" >/dev/null ;;
        pacman) pacman -Rns --noconfirm "$@" >/dev/null ;;
    esac
}

dante_pkg_name() {
    case $PKG_MGR in
        pacman) printf 'dante' ;;
        *)      printf 'dante-server' ;;
    esac
}

pkg_installed() {
    case $PKG_MGR in
        apt)     [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == *"install ok installed"* ]] ;;
        dnf|yum|zypper) rpm -q "$1" >/dev/null 2>&1 ;;
        apk)     apk info -e "$1" >/dev/null 2>&1 ;;
        pacman)  pacman -Qi "$1" >/dev/null 2>&1 ;;
        *)       return 1 ;;
    esac
}

# Debian 系安装软件包时阻止服务被自动拉起 (默认配置必然启动失败)
block_service_autostart() {
    if [[ ! -e /usr/sbin/policy-rc.d ]]; then
        printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
        chmod 755 /usr/sbin/policy-rc.d
        POLICY_RC_CREATED=1
    fi
}

unblock_service_autostart() {
    if (( POLICY_RC_CREATED )); then
        rm -f /usr/sbin/policy-rc.d
        POLICY_RC_CREATED=0
    fi
}

install_base_deps() {
    log_step "安装基础依赖"
    case $PKG_MGR in
        apt)
            retry 3 10 apt_update || log_warn "apt-get update 失败，尝试使用现有软件源索引继续"
            retry 3 10 pkg_install ca-certificates curl iproute2 procps ;;
        dnf|yum) retry 3 5 pkg_install ca-certificates curl iproute procps-ng ;;
        apk)     retry 3 5 pkg_install ca-certificates curl iproute2 procps coreutils ;;
        zypper)  retry 3 5 pkg_install ca-certificates curl iproute2 procps ;;
        pacman)  retry 3 5 pkg_install ca-certificates curl iproute2 procps-ng ;;
    esac || log_warn "部分基础依赖安装失败，继续执行"

    has_cmd ip || log_warn "未找到 ip 命令，出口网卡识别将使用 /proc 兜底"
    has_cmd curl || log_warn "未找到 curl，公网 IP 检测与源码下载可能失败"
}

# ----------------------------------------------------------------------------
# Dante 安装
# ----------------------------------------------------------------------------
dante_version_of() {
    local out
    out=$("$1" -v 2>&1 || true)
    if [[ $out =~ ([0-9]+)\.([0-9]+)(\.[0-9]+)? ]]; then
        printf '%s' "${BASH_REMATCH[0]}"
    fi
}

dante_version_ok() {
    local ver=$1 major minor
    [[ $ver =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    major=$((10#${BASH_REMATCH[1]})); minor=$((10#${BASH_REMATCH[2]}))
    (( major > DANTE_MIN_MAJOR || (major == DANTE_MIN_MAJOR && minor >= DANTE_MIN_MINOR) ))
}

# 查找可用 Dante：$1=package 时只看系统软件包路径
use_dante_bin() {
    local bin=$1 ver
    [[ -x $bin ]] || return 1
    ver=$(dante_version_of "$bin")
    [[ -n $ver ]] || return 1
    DANTE_BIN=$bin
    DANTE_VERSION=$ver
    return 0
}

find_package_dante() {
    local b
    for b in /usr/sbin/danted /usr/sbin/sockd /usr/bin/danted /usr/bin/sockd /sbin/sockd; do
        if use_dante_bin "$b"; then
            return 0
        fi
    done
    return 1
}

install_dante_package() {
    local pkg
    pkg=$(dante_pkg_name)
    log_info "尝试通过系统软件源安装 ${pkg}"
    if [[ $PKG_MGR == "apt" ]]; then
        block_service_autostart
        if ! retry 3 10 pkg_install "$pkg"; then
            unblock_service_autostart
            return 1
        fi
        unblock_service_autostart
    else
        pkg_install "$pkg" 2>/dev/null || return 1
    fi
    return 0
}

install_build_deps() {
    log_info "安装编译依赖"
    case $PKG_MGR in
        apt)     retry 3 10 pkg_install gcc make libc6-dev tar gzip ca-certificates curl ;;
        dnf|yum)
            retry 3 5 pkg_install gcc make tar gzip ca-certificates curl
            pkg_install libxcrypt-devel 2>/dev/null || true ;;
        apk)     retry 3 5 pkg_install build-base linux-headers tar gzip curl ;;
        zypper)
            retry 3 5 pkg_install gcc make tar gzip curl
            pkg_install libxcrypt-devel 2>/dev/null || true ;;
        pacman)  retry 3 5 pkg_install base-devel tar gzip curl ;;
    esac || log_warn "部分编译依赖安装失败，尝试继续编译"

    local c
    for c in gcc make tar; do
        has_cmd "$c" || die "缺少编译工具 ${c}，且无法自动安装 (请检查软件源)"
    done
}

download_file() {
    local url=$1 out=$2
    if has_cmd curl; then
        curl -fL --retry 3 --retry-delay 3 --connect-timeout 15 --max-time 600 -sS -o "$out" "$url"
    elif has_cmd wget; then
        wget -q --tries=3 --timeout=30 -O "$out" "$url"
    else
        die "缺少 curl / wget，无法下载源码"
    fi
}

verify_sha256() {
    local file=$1 expect=$2 actual=""
    if has_cmd sha256sum; then
        actual=$(sha256sum "$file" | awk '{print $1}')
    elif has_cmd openssl; then
        actual=$(openssl dgst -sha256 "$file" | awk '{print $NF}')
    else
        die "缺少 sha256sum / openssl，无法校验源码完整性"
    fi
    [[ ${actual,,} == "${expect,,}" ]]
}

build_dante_from_source() {
    local url=${DANTE_SRC_URL:-$DANTE_SRC_URL_DEFAULT} tarball src jobs log
    log_info "源码编译 Dante v${DANTE_SRC_VERSION}"
    install_build_deps

    TMP_DIR=$(mktemp -d /tmp/socks5-build.XXXXXX)
    tarball="${TMP_DIR}/dante-${DANTE_SRC_VERSION}.tar.gz"
    src="${TMP_DIR}/dante-${DANTE_SRC_VERSION}"
    log="${TMP_DIR}/build.log"
    jobs=$(cpu_count)

    log_info "下载: ${url}"
    download_file "$url" "$tarball" || die "源码下载失败: ${url} (可通过 DANTE_SRC_URL 指定镜像地址)"
    verify_sha256 "$tarball" "$DANTE_SRC_SHA256" || die "源码 SHA256 校验失败，文件可能被篡改或损坏"
    log_info "SHA256 校验通过"

    tar -xzf "$tarball" -C "$TMP_DIR"
    [[ -d $src ]] || die "源码解压失败"

    # GCC 10+ 默认 -fno-common；GCC 14+ 将隐式声明等旧式写法视为错误，需放宽以兼容 configure 探测
    local cflags="-O2 -fcommon" gcc_major
    gcc_major=$(gcc -dumpversion 2>/dev/null || echo 0)
    gcc_major=${gcc_major%%.*}
    if [[ $gcc_major =~ ^[0-9]+$ ]] && (( gcc_major >= 14 )); then
        cflags+=" -fpermissive"
    fi

    log_info "编译中 (并行 ${jobs} 任务)，请稍候..."
    if ! ( cd "$src" && ./configure \
            --prefix=/usr/local \
            --sysconfdir=/etc \
            --disable-client \
            --disable-preload \
            --without-libwrap \
            --without-pam \
            --without-bsdauth \
            --without-gssapi \
            --without-krb5 \
            --without-upnp \
            --without-ldap \
            --without-sasl \
            --without-pac \
            CFLAGS="$cflags" ) >"$log" 2>&1; then
        log_error "configure 失败，输出末尾如下:"
        tail -n 30 "$log" >&2 || true
        exit 1
    fi
    if ! ( cd "$src" && make -j"$jobs" && make install ) >>"$log" 2>&1; then
        log_error "编译或安装失败，输出末尾如下:"
        tail -n 30 "$log" >&2 || true
        exit 1
    fi

    use_dante_bin "$DANTE_SRC_BIN" || die "编译完成但未找到 ${DANTE_SRC_BIN}"
    DANTE_ORIGIN="source"
}

install_dante() {
    log_step "安装 Dante SOCKS5 服务端"

    # 上次为源码编译且二进制完好，直接复用
    if (( ! OPT_FORCE_SOURCE )) && [[ $PREV_ORIGIN == "source" ]] \
        && use_dante_bin "$DANTE_SRC_BIN" && dante_version_ok "$DANTE_VERSION"; then
        DANTE_ORIGIN="source"
        log_info "复用已编译的 Dante v${DANTE_VERSION}: ${DANTE_BIN}"
        return 0
    fi

    if (( ! OPT_FORCE_SOURCE )); then
        if install_dante_package && find_package_dante; then
            if dante_version_ok "$DANTE_VERSION"; then
                DANTE_ORIGIN="package"
                log_info "已安装 Dante v${DANTE_VERSION} (系统软件包): ${DANTE_BIN}"
                return 0
            fi
            log_warn "系统软件包 Dante v${DANTE_VERSION} 过旧 (需要 >= ${DANTE_MIN_MAJOR}.${DANTE_MIN_MINOR})，卸载后改为源码编译"
            pkg_remove "$(dante_pkg_name)" || log_warn "旧版 Dante 软件包卸载失败，将以源码版本为准"
        else
            log_warn "系统软件源中没有可用的 Dante，改为源码编译"
        fi
    fi

    DANTE_BIN=""
    DANTE_VERSION=""
    build_dante_from_source
    dante_version_ok "$DANTE_VERSION" || die "Dante 版本异常: ${DANTE_VERSION}"
    log_info "已安装 Dante v${DANTE_VERSION} (源码编译): ${DANTE_BIN}"
}

# ----------------------------------------------------------------------------
# 网络识别
# ----------------------------------------------------------------------------
iface_ok() {
    [[ -n $1 && $1 != "lo" && -d /sys/class/net/$1 ]]
}

route_dev() {
    local family=$1 target=$2 out
    out=$(ip -"$family" route get "$target" 2>/dev/null) || return 0
    awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }' <<<"$out"
}

default_dev() {
    local out
    out=$(ip -"$1" route show default 2>/dev/null) || return 0
    awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }' <<<"$out"
}

first_global_iface() {
    local out
    out=$(ip -o addr show scope global 2>/dev/null) || return 0
    awk '$2 != "lo" { print $2; exit }' <<<"$out"
}

iface_addr() {
    local family=$1 dev=$2 out
    out=$(ip -"$family" -o addr show dev "$dev" scope global 2>/dev/null) || return 0
    awk '{ split($4, a, "/"); print a[1]; exit }' <<<"$out"
}

detect_egress() {
    log_step "识别外部出口网卡"
    local probe v4addrs="" v6addrs="" disable_v6=1

    if [[ -n $OPT_IFACE ]]; then
        iface_ok "$OPT_IFACE" || die "指定的网卡不存在: ${OPT_IFACE}"
        EGRESS_IF4=$OPT_IFACE
        if [[ -n "$(iface_addr 6 "$OPT_IFACE" || true)" ]]; then
            EGRESS_IF6=$OPT_IFACE
        fi
        log_info "使用指定出口网卡: ${OPT_IFACE}"
    elif has_cmd ip; then
        # 按实际路由决策识别 (兼容策略路由 / 多网卡)，国内外各取一个探测地址
        for probe in 1.1.1.1 223.5.5.5 8.8.8.8; do
            EGRESS_IF4=$(route_dev 4 "$probe")
            EGRESS_IF4=${EGRESS_IF4%%@*}
            if iface_ok "$EGRESS_IF4"; then
                break
            fi
            EGRESS_IF4=""
        done
        if [[ -z $EGRESS_IF4 ]]; then
            EGRESS_IF4=$(default_dev 4)
            EGRESS_IF4=${EGRESS_IF4%%@*}
        fi
        for probe in 2606:4700:4700::1111 2400:3200::1; do
            EGRESS_IF6=$(route_dev 6 "$probe")
            EGRESS_IF6=${EGRESS_IF6%%@*}
            if iface_ok "$EGRESS_IF6"; then
                break
            fi
            EGRESS_IF6=""
        done
        if [[ -z $EGRESS_IF6 ]]; then
            EGRESS_IF6=$(default_dev 6)
            EGRESS_IF6=${EGRESS_IF6%%@*}
        fi
    fi

    if [[ -z $EGRESS_IF4 && -z $OPT_IFACE && -r /proc/net/route ]]; then
        EGRESS_IF4=$(awk 'NR > 1 && $2 == "00000000" && $8 == "00000000" { print $1; exit }' /proc/net/route)
    fi
    iface_ok "$EGRESS_IF4" || EGRESS_IF4=""
    iface_ok "$EGRESS_IF6" || EGRESS_IF6=""
    if [[ -z $EGRESS_IF4 && -z $EGRESS_IF6 ]] && has_cmd ip; then
        EGRESS_IF4=$(first_global_iface)
        iface_ok "$EGRESS_IF4" || EGRESS_IF4=""
    fi
    [[ -n $EGRESS_IF4 || -n $EGRESS_IF6 ]] || die "无法识别出口网卡，请使用 -i <网卡名> 手动指定"

    # 实测 IPv6 出网。网卡上只要存在 IPv6 地址 (含 fe80:: 链路本地地址)，Dante 就会对域名
    # 同时解析 A/AAAA 并使用第一个结果 (通常是 IPv6)；IPv6 不通时，客户端以域名请求
    # (socks5h / 浏览器 / Clash 远程 DNS) 访问带 AAAA 记录的站点会全部失败，因此须限制为 IPv4 出口
    EGRESS_V6_OK=0
    if [[ -n $EGRESS_IF6 ]] && ipv6_egress_works; then
        EGRESS_V6_OK=1
    fi

    EXTERNAL_IFACES=()
    if [[ -n $EGRESS_IF4 ]]; then
        EXTERNAL_IFACES+=("$EGRESS_IF4")
    fi
    if [[ -n $EGRESS_IF6 && $EGRESS_IF6 != "$EGRESS_IF4" ]] && (( EGRESS_V6_OK || ${#EXTERNAL_IFACES[@]} == 0 )); then
        EXTERNAL_IFACES+=("$EGRESS_IF6")
    fi

    # 监听协议栈：有全局 IPv4 地址监听 0.0.0.0，有可用 IPv6 再监听 ::
    if has_cmd ip; then
        v4addrs=$(ip -4 -o addr show scope global 2>/dev/null || true)
        v6addrs=$(ip -6 -o addr show scope global 2>/dev/null || true)
    else
        v4addrs="unknown"
    fi
    if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
        disable_v6=$(</proc/sys/net/ipv6/conf/all/disable_ipv6)
    fi
    LISTEN_V4=0
    LISTEN_V6=0
    if [[ -n $v4addrs ]]; then
        LISTEN_V4=1
    fi
    if [[ -n $v6addrs && $disable_v6 == "0" ]]; then
        LISTEN_V6=1
    fi
    if (( ! LISTEN_V4 && ! LISTEN_V6 )); then
        LISTEN_V4=1
    fi

    if [[ -n $EGRESS_IF4 ]]; then
        log_info "IPv4 出口网卡: ${EGRESS_IF4} ($(iface_addr 4 "$EGRESS_IF4" || true))"
    fi
    if [[ -n $EGRESS_IF6 ]]; then
        log_info "IPv6 出口网卡: ${EGRESS_IF6} ($(iface_addr 6 "$EGRESS_IF6" || true))"
    fi
    if (( EGRESS_V6_OK )); then
        log_info "IPv6 出网: 可用 (双栈出口)"
    elif [[ -n $EGRESS_IF4 ]]; then
        log_info "IPv6 出网: 不可用，Dante 出口限定为 IPv4 (保证域名请求正常解析与连接)"
    fi
    log_info "监听协议栈: $( (( LISTEN_V4 )) && printf 'IPv4 ')$( (( LISTEN_V6 )) && printf 'IPv6')"
}

# ----------------------------------------------------------------------------
# 认证账号 (系统账号，无登录 shell，无家目录，仅用于 SOCKS5 认证)
# ----------------------------------------------------------------------------
nologin_shell() {
    local s
    for s in /usr/sbin/nologin /sbin/nologin /usr/bin/nologin /bin/false; do
        if [[ -x $s ]]; then
            printf '%s' "$s"
            return 0
        fi
    done
    printf '/bin/false'
}

group_gid() {
    local line
    line=$(getent group "$1" 2>/dev/null) || return 1
    printf '%s' "$line" | cut -d: -f3
}

managed_users() {
    local gid
    gid=$(group_gid "$PROXY_GROUP") || return 0
    [[ -n $gid ]] || return 0
    awk -F: -v g="$gid" '$4 == g { print $1 }' /etc/passwd
}

is_managed_user() {
    local gid ugid
    gid=$(group_gid "$PROXY_GROUP") || return 1
    ugid=$(id -g "$1" 2>/dev/null) || return 1
    [[ $gid == "$ugid" ]]
}

ensure_proxy_group() {
    if getent group "$PROXY_GROUP" >/dev/null 2>&1; then
        return 0
    fi
    if has_cmd groupadd; then
        groupadd -r "$PROXY_GROUP"
    else
        addgroup -S "$PROXY_GROUP"
    fi
}

delete_user() {
    if has_cmd userdel; then
        userdel "$1" >/dev/null 2>&1 || true
    else
        deluser "$1" >/dev/null 2>&1 || true
    fi
}

set_user_password() {
    local user=$1 pass=$2 chp
    chp=$(command -v chpasswd) || die "缺少 chpasswd 命令"
    # 统一使用 SHA-512 crypt：glibc / libxcrypt / musl 均可校验，兼容所有 Dante 构建
    if [[ "$(readlink -f "$chp" 2>/dev/null || printf '%s' "$chp")" == *busybox* ]]; then
        if printf '%s:%s\n' "$user" "$pass" | chpasswd -c sha512 >/dev/null 2>&1; then
            return 0
        fi
    elif printf '%s:%s\n' "$user" "$pass" | chpasswd -c SHA512 >/dev/null 2>&1; then
        return 0
    fi
    printf '%s:%s\n' "$user" "$pass" | chpasswd
}

ensure_unpriv_user() {
    if id nobody >/dev/null 2>&1; then
        UNPRIV_USER="nobody"
        return 0
    fi
    UNPRIV_USER="socks5d"
    if ! id "$UNPRIV_USER" >/dev/null 2>&1; then
        if has_cmd useradd; then
            useradd -r -M -d /nonexistent -s "$(nologin_shell)" "$UNPRIV_USER"
        else
            adduser -S -D -H -h /nonexistent -s "$(nologin_shell)" "$UNPRIV_USER"
        fi
    fi
}

setup_proxy_account() {
    log_step "配置认证账号"
    local old shell
    shell=$(nologin_shell)
    ensure_proxy_group
    ensure_unpriv_user

    if id "$SOCKS_USER" >/dev/null 2>&1; then
        is_managed_user "$SOCKS_USER" \
            || die "系统中已存在用户 '${SOCKS_USER}' 且不是本脚本创建的代理账号，为避免修改其密码，请更换用户名"
        log_info "更新已有代理账号: ${SOCKS_USER}"
    else
        if has_cmd useradd; then
            useradd -r -M -d /nonexistent -s "$shell" -g "$PROXY_GROUP" -c "SOCKS5 proxy account" "$SOCKS_USER"
        else
            adduser -S -D -H -h /nonexistent -s "$shell" -G "$PROXY_GROUP" -g "SOCKS5 proxy account" "$SOCKS_USER"
        fi
        log_info "已创建代理账号: ${SOCKS_USER} (禁止登录系统)"
    fi
    set_user_password "$SOCKS_USER" "$SOCKS_PASS"

    # 单账号模式：清理旧的托管账号
    while IFS= read -r old; do
        if [[ -n $old && $old != "$SOCKS_USER" ]]; then
            delete_user "$old"
            log_info "已删除旧代理账号: ${old}"
        fi
    done < <(managed_users)
}

# ----------------------------------------------------------------------------
# Dante 配置
# ----------------------------------------------------------------------------
backup_foreign_config() {
    if [[ -f $CONF_FILE ]] && ! grep -qF "$CONF_MARKER" "$CONF_FILE"; then
        local bak
        bak="${CONF_FILE}.bak.$(date +%Y%m%d%H%M%S)"
        cp -p "$CONF_FILE" "$bak"
        log_info "已备份原有配置: ${bak}"
    fi
}

write_dante_config() {
    log_step "生成 Dante 配置"
    local tmp listen="" external="" ifc out

    if (( LISTEN_V4 )); then
        listen+="internal: 0.0.0.0 port = ${SOCKS_PORT}"$'\n'
    fi
    if (( LISTEN_V6 )); then
        listen+="internal: :: port = ${SOCKS_PORT}"$'\n'
    fi
    # external.protocol 必须写在 external: 之前，否则 Dante 拒绝启动
    if [[ -n $EGRESS_IF4 ]] && (( ! EGRESS_V6_OK )); then
        external+="# IPv6 出网不可用：出口仅用 IPv4，域名只解析 A 记录"$'\n'
        external+="external.protocol: ipv4"$'\n'
    fi
    for ifc in "${EXTERNAL_IFACES[@]}"; do
        external+="external: ${ifc}"$'\n'
    done

    backup_foreign_config
    tmp=$(mktemp "${CONF_FILE}.XXXXXX")
    cat >"$tmp" <<EOF
${CONF_MARKER} v${SCRIPT_VERSION}，重新运行脚本会覆盖本文件
# 生成时间: $(date '+%F %T %z')
# 日志策略: 不保留 (未配置 logoutput，规则中不启用 log)

# ---------------- 监听 / 出口 ----------------
${listen}${external}
# ---------------- 认证 ----------------
clientmethod: none
socksmethod: username

# ---------------- 运行身份 ----------------
# 校验系统账号密码需读取 /etc/shadow，特权操作使用 root，其余时间降权运行
user.privileged: root
user.unprivileged: ${UNPRIV_USER}

# ---------------- 超时 ----------------
timeout.negotiate: 30
timeout.io: 0

# ---------------- 游戏 / UDP 优化 ----------------
# UDP 套接字不 connect 到单一目标：兼容多服务器、P2P、NAT 穿透类游戏 (接近 Full Cone)
udp.connectdst: no

# ---------------- 客户端规则：允许任意来源 IP 连接 ----------------
client pass {
    from: 0/0 to: 0/0
}

# ---------------- SOCKS 规则 ----------------
# 禁止经代理访问本机回环地址，避免暴露仅监听在本机的服务
socks block {
    from: 0/0 to: 127.0.0.0/8
    command: bind connect
}
socks block {
    from: 0/0 to: 0.0.0.0/32
    command: bind connect
}
socks block {
    from: 0/0 to: ::1/128
    command: bind connect
}
socks block {
    from: 0/0 to: ::/128
    command: bind connect
}

# 仅允许本脚本托管的账号在用户名/密码认证通过后使用
socks pass {
    from: 0/0 to: 0/0
    command: bind connect udpassociate
    socksmethod: username
    user: ${SOCKS_USER}
    udp.portrange: ${UDP_RANGE}
}

# 外部回包 (BIND 回连 / UDP 回包)
socks pass {
    from: 0/0 to: 0/0
    command: bindreply udpreply
}
EOF
    chmod 644 "$tmp"

    if ! out=$("$DANTE_BIN" -V -f "$tmp" 2>&1); then
        log_error "Dante 配置校验失败:"
        printf '%s\n' "$out" >&2
        rm -f "$tmp"
        exit 1
    fi
    mv -f "$tmp" "$CONF_FILE"
    log_info "配置已写入并校验通过: ${CONF_FILE}"
}

# ----------------------------------------------------------------------------
# 服务管理 (systemd / OpenRC)
# ----------------------------------------------------------------------------
service_exists() {
    case $INIT_SYS in
        systemd) [[ -f $SYSTEMD_UNIT ]] || systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1 ;;
        openrc)  [[ -x $OPENRC_SCRIPT ]] ;;
    esac
}

service_stop() {
    case $INIT_SYS in
        systemd) systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true ;;
        openrc)  rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true ;;
    esac
}

service_restart() {
    case $INIT_SYS in
        systemd) systemctl restart "${SERVICE_NAME}.service" ;;
        openrc)  rc-service "$SERVICE_NAME" restart >/dev/null ;;
    esac
}

service_active() {
    case $INIT_SYS in
        systemd) systemctl is-active --quiet "${SERVICE_NAME}.service" ;;
        openrc)  rc-service "$SERVICE_NAME" status >/dev/null 2>&1 ;;
    esac
}

service_enabled_text() {
    case $INIT_SYS in
        systemd)
            if systemctl is-enabled --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
                printf '已启用'
            else
                printf '未启用'
            fi ;;
        openrc)
            if [[ " $(rc-update show default 2>/dev/null || true) " =~ [[:space:]]${SERVICE_NAME}[[:space:]] ]]; then
                printf '已启用'
            else
                printf '未启用'
            fi ;;
    esac
}

service_manage_hint() {
    case $INIT_SYS in
        systemd) printf 'systemctl {start|stop|restart|status} %s' "$SERVICE_NAME" ;;
        openrc)  printf 'rc-service %s {start|stop|restart|status}' "$SERVICE_NAME" ;;
    esac
}

# 停用发行版自带的同类服务，避免与托管服务冲突
disable_vendor_services() {
    local svc
    case $INIT_SYS in
        systemd)
            for svc in sockd.service dante-server.service; do
                if systemctl cat "$svc" >/dev/null 2>&1; then
                    systemctl disable --now "$svc" >/dev/null 2>&1 || true
                fi
            done ;;
        openrc)
            for svc in sockd dante-server; do
                if [[ -x /etc/init.d/$svc ]]; then
                    rc-service "$svc" stop >/dev/null 2>&1 || true
                    rc-update del "$svc" >/dev/null 2>&1 || true
                fi
            done ;;
    esac
}

write_systemd_unit() {
    local workers_arg=""
    if (( WORKERS > 1 )); then
        workers_arg=" -N ${WORKERS}"
    fi
    cat >"$SYSTEMD_UNIT" <<EOF
${CONF_MARKER} v${SCRIPT_VERSION}
[Unit]
Description=Dante SOCKS5 Proxy Server (managed by socks5.sh)
Documentation=man:sockd(8) man:sockd.conf(5)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStartPre=${DANTE_BIN} -V -f ${CONF_FILE}
ExecStart=${DANTE_BIN} -f ${CONF_FILE}${workers_arg}
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=2
KillMode=control-group
TimeoutStopSec=15

# 不保留日志
StandardOutput=null
StandardError=null

# 性能：大量并发连接 / 子进程，转发进程优先调度以降低延迟
LimitNOFILE=1048576
LimitNPROC=infinity
TasksMax=infinity
Nice=-10

# 安全加固
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SYSTEMD_UNIT"
    systemctl daemon-reload
    systemctl enable "${SERVICE_NAME}.service" >/dev/null 2>&1
}

write_openrc_script() {
    local workers_arg=""
    if (( WORKERS > 1 )); then
        workers_arg=" -N ${WORKERS}"
    fi
    cat >"$OPENRC_SCRIPT" <<EOF
#!/sbin/openrc-run
${CONF_MARKER} v${SCRIPT_VERSION}

name="danted"
description="Dante SOCKS5 Proxy Server (managed by socks5.sh)"
command="${DANTE_BIN}"
command_args="-f ${CONF_FILE}${workers_arg}"
supervisor="supervise-daemon"
supervise_daemon_args="--nicelevel -10"
respawn_delay=2
respawn_max=0
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/dev/null"
error_log="/dev/null"
rc_ulimit="-n 1048576"

depend() {
    need net
    after firewall
}

start_pre() {
    "\${command}" -V -f "${CONF_FILE}" >/dev/null 2>&1 || {
        eerror "Dante 配置校验失败: ${CONF_FILE}"
        return 1
    }
}
EOF
    chmod 755 "$OPENRC_SCRIPT"
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1
}

setup_service() {
    log_step "配置系统服务与开机自启"
    case $INIT_SYS in
        systemd) write_systemd_unit ;;
        openrc)  write_openrc_script ;;
    esac
    log_info "开机自启: $(service_enabled_text)"
}

start_service() {
    log_step "启动服务"
    local i
    if ! service_restart; then
        log_error "服务启动失败，配置自检输出:"
        "$DANTE_BIN" -V -f "$CONF_FILE" >&2 || true
        exit 1
    fi
    for (( i = 0; i < 15; i++ )); do
        if port_listening "$SOCKS_PORT"; then
            break
        fi
        sleep 1
    done
    service_active || die "服务未处于运行状态，请执行: $(service_manage_hint)"
    port_listening "$SOCKS_PORT" || die "服务已启动但端口 ${SOCKS_PORT} 未监听"
    log_info "服务运行中，端口 ${SOCKS_PORT} 已监听 (主进程数: ${WORKERS})"
}

# ----------------------------------------------------------------------------
# 防火墙 (ufw / firewalld / iptables)
# ----------------------------------------------------------------------------
iptables_restrictive() {
    local bin=$1 rules
    rules=$("$bin" -S INPUT 2>/dev/null) || return 1
    grep -qE '^-P INPUT (DROP|REJECT)' <<<"$rules" && return 0
    grep -qE -- '-j (DROP|REJECT)' <<<"$rules"
}

ipt_rule_add() {
    local bin=$1; shift
    if "$bin" -C INPUT "$@" -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null; then
        return 0
    fi
    "$bin" -I INPUT "$@" -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null \
        || "$bin" -I INPUT "$@" -j ACCEPT
}

ipt_rule_del() {
    local bin=$1; shift
    while "$bin" -D INPUT "$@" -m comment --comment "$FW_TAG" -j ACCEPT 2>/dev/null; do :; done
    while "$bin" -D INPUT "$@" -j ACCEPT 2>/dev/null; do :; done
}

# firewalld 永久规则操作，zone 为空时作用于默认区域
firewalld_perm() {
    local zone=$1
    shift
    if [[ -n $zone ]]; then
        firewall-cmd --permanent --zone="$zone" "$@"
    else
        firewall-cmd --permanent "$@"
    fi
}

iptables_persist() {
    if has_cmd netfilter-persistent && netfilter-persistent save >/dev/null 2>&1; then
        return 0
    fi
    if [[ -d /etc/iptables ]]; then
        iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
        if has_cmd ip6tables-save; then
            ip6tables-save >/etc/iptables/rules.v6 2>/dev/null || true
        fi
        return 0
    fi
    if [[ -f /etc/sysconfig/iptables ]]; then
        iptables-save >/etc/sysconfig/iptables 2>/dev/null || true
        if [[ -f /etc/sysconfig/ip6tables ]] && has_cmd ip6tables-save; then
            ip6tables-save >/etc/sysconfig/ip6tables 2>/dev/null || true
        fi
        return 0
    fi
    if [[ $INIT_SYS == "openrc" ]] && rc-service iptables save >/dev/null 2>&1; then
        return 0
    fi
    log_warn "未找到 iptables 持久化机制，重启后需重新放行端口 (可重新执行本脚本)"
}

firewall_cleanup() {
    local kind=$1 zone=$2 port=$3 urange=$4
    [[ -n $port ]] || return 0
    case $kind in
        ufw)
            if has_cmd ufw; then
                ufw delete allow "${port}/tcp" >/dev/null 2>&1 || true
                if [[ -n $urange ]]; then
                    ufw delete allow "${urange/-/:}/udp" >/dev/null 2>&1 || true
                fi
            fi ;;
        firewalld)
            if has_cmd firewall-cmd; then
                firewalld_perm "$zone" --remove-port="${port}/tcp" >/dev/null 2>&1 || true
                if [[ -n $urange ]]; then
                    firewalld_perm "$zone" --remove-port="${urange}/udp" >/dev/null 2>&1 || true
                fi
                firewall-cmd --reload >/dev/null 2>&1 || true
            fi ;;
        iptables)
            local b
            for b in iptables ip6tables; do
                if has_cmd "$b"; then
                    ipt_rule_del "$b" -p tcp --dport "$port"
                    if [[ -n $urange ]]; then
                        ipt_rule_del "$b" -p udp --dport "${urange/-/:}"
                    fi
                fi
            done
            iptables_persist ;;
    esac
}

open_firewall() {
    log_step "配置防火墙"

    # 端口变更时先撤销旧规则
    if [[ -n $PREV_FIREWALL && $PREV_FIREWALL != "none" ]] \
        && [[ $PREV_PORT != "$SOCKS_PORT" || $PREV_UDP_RANGE != "$UDP_RANGE" ]]; then
        firewall_cleanup "$PREV_FIREWALL" "$PREV_FW_ZONE" "$PREV_PORT" "$PREV_UDP_RANGE"
    fi

    local ufw_status=""
    if has_cmd ufw; then
        ufw_status=$(ufw status 2>/dev/null || true)
    fi

    if [[ $ufw_status == *"Status: active"* ]]; then
        FIREWALL_KIND="ufw"
        if { ufw allow "${SOCKS_PORT}/tcp" comment "$FW_TAG" >/dev/null 2>&1 \
                || ufw allow "${SOCKS_PORT}/tcp" >/dev/null 2>&1; } \
            && { ufw allow "${UDP_RANGE/-/:}/udp" comment "$FW_TAG" >/dev/null 2>&1 \
                || ufw allow "${UDP_RANGE/-/:}/udp" >/dev/null 2>&1; }; then
            log_info "ufw 已放行 ${SOCKS_PORT}/tcp 与 ${UDP_RANGE}/udp"
        else
            log_warn "ufw 放行失败，请手动执行: ufw allow ${SOCKS_PORT}/tcp && ufw allow ${UDP_RANGE/-/:}/udp"
        fi
    elif has_cmd firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        local ifc="${EGRESS_IF4:-$EGRESS_IF6}"
        FIREWALL_KIND="firewalld"
        FIREWALL_ZONE=$(firewall-cmd --get-zone-of-interface="$ifc" 2>/dev/null \
            || firewall-cmd --get-default-zone 2>/dev/null || true)
        if firewalld_perm "$FIREWALL_ZONE" --add-port="${SOCKS_PORT}/tcp" >/dev/null 2>&1 \
            && firewalld_perm "$FIREWALL_ZONE" --add-port="${UDP_RANGE}/udp" >/dev/null 2>&1 \
            && firewall-cmd --reload >/dev/null 2>&1; then
            log_info "firewalld (zone=${FIREWALL_ZONE:-默认}) 已放行 ${SOCKS_PORT}/tcp 与 ${UDP_RANGE}/udp"
        else
            log_warn "firewalld 放行失败，请手动放行 ${SOCKS_PORT}/tcp 与 ${UDP_RANGE}/udp"
        fi
    else
        local b changed=0
        for b in iptables ip6tables; do
            if has_cmd "$b" && iptables_restrictive "$b"; then
                if ipt_rule_add "$b" -p tcp --dport "$SOCKS_PORT" \
                    && ipt_rule_add "$b" -p udp --dport "${UDP_RANGE/-/:}"; then
                    changed=1
                else
                    log_warn "${b} 放行失败，请手动放行 ${SOCKS_PORT}/tcp 与 ${UDP_RANGE}/udp"
                fi
            fi
        done
        if (( changed )); then
            iptables_persist
            FIREWALL_KIND="iptables"
            log_info "iptables 已放行 ${SOCKS_PORT}/tcp 与 ${UDP_RANGE}/udp"
        else
            FIREWALL_KIND="none"
            log_info "未检测到启用中的本机防火墙，无需放行"
        fi
    fi
}

# ----------------------------------------------------------------------------
# 内核网络调优 (高并发 + 游戏低延迟)
# ----------------------------------------------------------------------------
sysctl_key_path() {
    printf '/proc/sys/%s' "${1//.//}"
}

systemd_version() {
    local out
    out=$(systemctl --version 2>/dev/null || true)
    if [[ $out =~ systemd[[:space:]]+([0-9]+) ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '0'
    fi
}

tune_kernel() {
    log_step "内核网络调优 (高并发 / 游戏低延迟)"
    TUNED=0
    if (( ! OPT_TUNE )); then
        log_info "已按参数跳过 (--no-tune)"
        return 0
    fi
    if is_container; then
        log_warn "检测到容器环境，内核参数由宿主机控制，跳过调优"
        return 0
    fi

    local -a params=(
        # 连接队列与文件句柄
        "net.core.somaxconn=32768"
        "net.core.netdev_max_backlog=32768"
        "net.ipv4.tcp_max_syn_backlog=16384"
        "net.ipv4.tcp_syncookies=1"
        # 收发缓冲区 (TCP 大吞吐 + UDP 游戏包不丢)
        "net.core.rmem_default=1048576"
        "net.core.wmem_default=1048576"
        "net.core.rmem_max=33554432"
        "net.core.wmem_max=33554432"
        "net.core.optmem_max=65536"
        "net.ipv4.tcp_rmem=4096 131072 33554432"
        "net.ipv4.tcp_wmem=4096 65536 33554432"
        "net.ipv4.udp_rmem_min=16384"
        "net.ipv4.udp_wmem_min=16384"
        # 低延迟：限制未发送缓冲、空闲后不降速、MTU 探测
        "net.ipv4.tcp_notsent_lowat=16384"
        "net.ipv4.tcp_slow_start_after_idle=0"
        "net.ipv4.tcp_mtu_probing=1"
        "net.ipv4.tcp_fastopen=3"
        # 连接回收与保活 (及时清理掉线客户端)
        "net.ipv4.tcp_fin_timeout=15"
        "net.ipv4.tcp_tw_reuse=1"
        "net.ipv4.tcp_keepalive_time=300"
        "net.ipv4.tcp_keepalive_intvl=30"
        "net.ipv4.tcp_keepalive_probes=5"
    )

    local cur_files
    cur_files=$(cat /proc/sys/fs/file-max 2>/dev/null || echo 0)
    if [[ $cur_files =~ ^[0-9]+$ ]] && (( cur_files < 2097152 )); then
        params+=("fs.file-max=2097152")
    fi

    # 为 UDP 转发端口段与监听端口预留，避免被临时端口占用
    local reserved="" cur_res
    cur_res=$(cat /proc/sys/net/ipv4/ip_local_reserved_ports 2>/dev/null || true)
    reserved="${UDP_RANGE},${SOCKS_PORT}"
    if [[ -n $cur_res ]]; then
        reserved="${cur_res},${reserved}"
    fi
    params+=("net.ipv4.ip_local_reserved_ports=${reserved}")

    # BBR + fq：降低排队延迟，提升弱网吞吐
    modprobe tcp_bbr >/dev/null 2>&1 || true
    local bbr=0
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        bbr=1
        params+=("net.core.default_qdisc=fq" "net.ipv4.tcp_congestion_control=bbr")
    fi

    # 连接跟踪 (仅在已加载时调整，防止高并发 UDP 时表满丢包)
    local -a ct_params=()
    if [[ -e /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        ct_params=(
            "net.netfilter.nf_conntrack_max=1048576"
            "net.netfilter.nf_conntrack_udp_timeout=60"
            "net.netfilter.nf_conntrack_udp_timeout_stream=180"
        )
    fi
    local ct_prefix=""
    if (( $(systemd_version) >= 236 )); then
        ct_prefix="-"
    fi

    local tmp item key val path applied=0 failed=0
    tmp=$(mktemp /tmp/socks5-sysctl.XXXXXX)
    {
        printf '%s v%s\n' "$CONF_MARKER" "$SCRIPT_VERSION"
        printf '# SOCKS5 代理内核网络调优 (高并发 / 游戏低延迟)\n'
    } >"$tmp"

    # ${arr[@]+...} 写法兼容 bash 4.2 在 set -u 下展开空数组
    for item in "${params[@]}" ${ct_params[@]+"${ct_params[@]}"}; do
        key=${item%%=*}
        val=${item#*=}
        path=$(sysctl_key_path "$key")
        [[ -e $path ]] || continue
        if printf '%s\n' "$val" >"$path" 2>/dev/null; then
            applied=$((applied + 1))
        else
            failed=$((failed + 1))
            continue
        fi
        if [[ $key == net.netfilter.* ]]; then
            if [[ -n $ct_prefix ]]; then
                printf '%s%s = %s\n' "$ct_prefix" "$key" "$val" >>"$tmp"
            fi
        else
            printf '%s = %s\n' "$key" "$val" >>"$tmp"
        fi
    done

    install -m 644 "$tmp" "$SYSCTL_FILE"
    rm -f "$tmp"

    if (( bbr )) && [[ -d /etc/modules-load.d || $INIT_SYS == "systemd" ]]; then
        install -d -m 755 /etc/modules-load.d
        printf '%s\ntcp_bbr\n' "$CONF_MARKER" >"$MODULES_FILE"
        chmod 644 "$MODULES_FILE"
    fi

    TUNED=1
    log_info "已应用 ${applied} 项内核参数$( (( failed )) && printf '，%s 项不受支持已跳过' "$failed")；持久化: ${SYSCTL_FILE}"
    if (( bbr )); then
        log_info "拥塞控制: BBR + fq"
    else
        log_warn "内核不支持 BBR (需 4.9+)，保持默认拥塞控制"
    fi
}

# ----------------------------------------------------------------------------
# 自检与公网信息
# ----------------------------------------------------------------------------
# SOCKS5 握手 + RFC1929 认证探测；凭据经环境变量传递，不出现在进程参数中
# 返回: 0 认证成功；1 认证被拒；2 连接或协议错误
socks5_auth_probe() {
    local rc=0
    # shellcheck disable=SC2016  # 单引号内脚本由子 bash 展开
    PROBE_USER=$1 PROBE_PASS=$2 PROBE_PORT=$3 timeout 10 bash -c '
        exec 3<>"/dev/tcp/127.0.0.1/${PROBE_PORT}" || exit 2
        printf "\x05\x01\x02" >&3
        resp=$(dd bs=1 count=2 <&3 2>/dev/null | od -An -tx1 | tr -d " \n")
        [[ $resp == "0502" ]] || exit 2
        {
            printf "\x01"
            printf "\\$(printf "%03o" "${#PROBE_USER}")"
            printf "%s" "$PROBE_USER"
            printf "\\$(printf "%03o" "${#PROBE_PASS}")"
            printf "%s" "$PROBE_PASS"
        } >&3
        resp=$(dd bs=1 count=2 <&3 2>/dev/null | od -An -tx1 | tr -d " \n")
        [[ $resp == "0100" ]] && exit 0
        exit 1
    ' 2>/dev/null || rc=$?
    return "$rc"
}

# 经本机代理访问 URL；凭据经 curl 配置 (stdin) 传入，不出现在进程参数中
# $1: socks5 (curl 本地解析域名，向代理发送 IP) | socks5h (向代理发送域名，由代理端解析)
curl_via_proxy() {
    local scheme=$1 url=$2 u p
    u=$(curl_cfg_escape "$SOCKS_USER")
    p=$(curl_cfg_escape "$SOCKS_PASS")
    printf 'proxy = "%s://127.0.0.1:%s"\nproxy-user = "%s:%s"\n' "$scheme" "$SOCKS_PORT" "$u" "$p" \
        | curl -K - -4 -fsS --max-time 8 "$url" 2>/dev/null
}

readonly IP4_APIS=(https://api.ipify.org https://ipv4.icanhazip.com https://4.ipw.cn https://ifconfig.me/ip https://ip.3322.net)
readonly IP6_APIS=(https://api6.ipify.org https://ipv6.icanhazip.com https://6.ipw.cn)

# 经代理获取出口 IPv4，成功时输出 IP
proxy_fetch_ip() {
    local scheme=$1 url ip
    has_cmd curl || return 1
    for url in "${IP4_APIS[@]}"; do
        ip=$(curl_via_proxy "$scheme" "$url" | tr -d '[:space:]' || true)
        if is_ipv4 "$ip"; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

# 实测 IPv6 出网 (只分配了地址 / 路由却不通的 VPS 很常见)
ipv6_egress_works() {
    local url target
    if has_cmd curl; then
        for url in "${IP6_APIS[@]}"; do
            if curl -6 -fsS --max-time 4 -o /dev/null "$url" 2>/dev/null; then
                return 0
            fi
        done
    fi
    if has_cmd ping; then
        for target in 2606:4700:4700::1111 2400:3200::1; do
            if ping -6 -c 1 -W 2 "$target" >/dev/null 2>&1; then
                return 0
            fi
        done
    fi
    return 1
}

detect_public_ip() {
    local url ip
    PUBLIC_IP4=""
    PUBLIC_IP6=""
    has_cmd curl || return 0

    for url in "${IP4_APIS[@]}"; do
        ip=$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if is_ipv4 "$ip"; then
            PUBLIC_IP4=$ip
            break
        fi
    done
    if (( EGRESS_V6_OK )); then
        for url in "${IP6_APIS[@]}"; do
            ip=$(curl -6 -fsS --max-time 4 "$url" 2>/dev/null | tr -d '[:space:]' || true)
            if is_ipv6 "$ip"; then
                PUBLIC_IP6=$ip
                break
            fi
        done
    fi
    if [[ -z $PUBLIC_IP4 && -n $EGRESS_IF4 ]] && has_cmd ip; then
        PUBLIC_IP4=$(iface_addr 4 "$EGRESS_IF4" || true)
    fi
}

verify_deployment() {
    log_step "部署自检"
    local rc=0
    socks5_auth_probe "$SOCKS_USER" "$SOCKS_PASS" "$SOCKS_PORT" || rc=$?
    case $rc in
        0) log_info "认证自检通过：正确的用户名密码可以登录" ;;
        1) die "认证自检失败：正确的用户名密码被拒绝，请检查 ${CONF_FILE}" ;;
        *) die "认证自检失败：无法完成 SOCKS5 握手 (端口 ${SOCKS_PORT})" ;;
    esac

    rc=0
    socks5_auth_probe "$SOCKS_USER" "wrong-$(rand_str 12 'a-z0-9')" "$SOCKS_PORT" || rc=$?
    if (( rc == 0 )); then
        die "安全自检失败：错误密码竟然可以登录，已中止"
    fi
    log_info "安全自检通过：错误的密码会被拒绝"

    detect_public_ip

    # 分别验证两种目标地址形式：IP (客户端本地解析) 与 域名 (代理端解析，浏览器 / Clash 等默认方式)
    local via_ip via_host
    via_ip=$(proxy_fetch_ip socks5 || true)
    via_host=$(proxy_fetch_ip socks5h || true)
    if [[ -z $PUBLIC_IP4 ]]; then
        PUBLIC_IP4=${via_ip:-$via_host}
    fi
    if [[ -n $via_ip ]]; then
        log_info "出网自检通过 (IP 目标)：出口 IP ${via_ip}"
    fi
    if [[ -n $via_host ]]; then
        log_info "出网自检通过 (域名目标，代理端解析)：出口 IP ${via_host}"
    fi
    if [[ -n $via_ip && -z $via_host ]]; then
        log_warn "代理端域名解析失败：浏览器 / Clash 等以域名请求的客户端将无法访问，请检查服务器 DNS (/etc/resolv.conf)"
    elif [[ -z $via_ip && -z $via_host ]]; then
        log_warn "经代理访问公网检测站点失败 (可能是服务器限制出网或检测站点不可达)，不影响代理本身"
    fi
    if [[ -z $PUBLIC_IP4 && -n $EGRESS_IF4 ]] && has_cmd ip; then
        PUBLIC_IP4=$(iface_addr 4 "$EGRESS_IF4" || true)
    fi
}

# ----------------------------------------------------------------------------
# 管理脚本安装
# ----------------------------------------------------------------------------
install_ctl() {
    local self="${BASH_SOURCE[0]:-}"
    if [[ -n $self && -f $self ]]; then
        local real
        real=$(readlink -f "$self" 2>/dev/null || printf '%s' "$self")
        if [[ $real != "$CTL_PATH" ]]; then
            install -m 700 "$real" "$CTL_PATH"
        fi
    fi
}

ctl_hint() {
    if [[ -x $CTL_PATH ]]; then
        printf '%s' "$CTL_PATH"
    elif [[ -f $0 ]]; then
        printf 'bash %s' "$0"
    else
        printf 'bash socks5.sh'
    fi
}

# ----------------------------------------------------------------------------
# 信息输出
# ----------------------------------------------------------------------------
# 按终端显示宽度对齐输出 "键: 值" (UTF-8 中文占 3 字节、显示 2 列)
kv() {
    local key=$1 val=$2 color=${3:-} ascii width pad
    ascii=${key//[^[:ascii:]]/}
    width=$(( ${#ascii} + (${#key} - ${#ascii}) * 2 / 3 ))
    pad=$(( 12 - width ))
    if (( pad < 1 )); then
        pad=1
    fi
    printf '  %s%*s%s%s%s\n' "$key" "$pad" '' "$color" "$val" "${color:+$C_RESET}"
}

print_info() {
    local host="${PUBLIC_IP4:-${PUBLIC_IP6:-<服务器IP>}}" url_host eu ep origin
    url_host=$host
    if is_ipv6 "$host"; then
        url_host="[${host}]"
    fi
    eu=$(urlencode "$SOCKS_USER")
    ep=$(urlencode "$SOCKS_PASS")
    if [[ $DANTE_ORIGIN == "source" ]]; then
        origin="源码编译"
    else
        origin="系统软件包"
    fi

    local line="================================================================"
    local thin="----------------------------------------------------------------"
    printf '\n%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
    printf '%s                      SOCKS5 代理服务信息%s\n' "$C_BOLD" "$C_RESET"
    printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
    kv "操作系统:" "${OS_NAME} (${ARCH})"
    kv "Dante:" "v${DANTE_VERSION:-未知} (${origin})"
    kv "出口网卡:" "${EXTERNAL_IFACES[*]:-未知}"
    kv "服务器IP:" "${PUBLIC_IP4:-未检测到}" "$C_CYAN"
    if [[ -n $PUBLIC_IP6 ]]; then
        kv "IPv6地址:" "$PUBLIC_IP6" "$C_CYAN"
    fi
    kv "端口:" "$SOCKS_PORT" "$C_CYAN"
    kv "用户名:" "$SOCKS_USER" "$C_CYAN"
    kv "密码:" "$SOCKS_PASS" "$C_CYAN"
    kv "认证方式:" "用户名/密码 (RFC 1929)，允许任意来源 IP 连接"
    kv "UDP转发:" "已启用，端口段 ${UDP_RANGE}/udp (游戏 / 语音)"
    printf '%s\n' "$thin"
    kv "代理链接:" "socks5://${eu}:${ep}@${url_host}:${SOCKS_PORT}"
    kv "Telegram:" "tg://socks?server=${host}&port=${SOCKS_PORT}&user=${eu}&pass=${ep}"
    kv "测试命令:" "curl -x 'socks5://${eu}:${ep}@${url_host}:${SOCKS_PORT}' https://api.ipify.org"
    printf '%s\n' "$thin"
    kv "服务管理:" "$(service_manage_hint)"
    kv "开机自启:" "$(service_enabled_text)"
    kv "查看信息:" "$(ctl_hint) info"
    kv "卸载:" "$(ctl_hint) uninstall"
    kv "配置文件:" "$CONF_FILE"
    kv "日志:" "不保留"
    printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
    printf '%s  提示: 云服务器需在安全组放行 TCP %s 与 UDP %s%s\n' "$C_YELLOW" "$SOCKS_PORT" "$UDP_RANGE" "$C_RESET"
    printf '%s  游戏: 客户端需支持 SOCKS5 UDP (如 Proxifier / Netch / SocksCap64)%s\n\n' "$C_YELLOW" "$C_RESET"
}

# ----------------------------------------------------------------------------
# 命令实现
# ----------------------------------------------------------------------------
cmd_install() {
    log_step "环境识别"
    detect_os
    detect_init
    WORKERS=$(cpu_count)
    if (( WORKERS > MAX_WORKERS )); then
        WORKERS=$MAX_WORKERS
    fi
    print_env_summary
    load_state
    resolve_settings

    install_base_deps
    install_dante
    detect_egress

    # 停止旧实例后再检查端口占用
    if service_exists; then
        service_stop
    fi
    disable_vendor_services
    if port_listening "$SOCKS_PORT"; then
        die "端口 ${SOCKS_PORT} 已被占用 (进程: $(port_owner "$SOCKS_PORT"))，请使用 -P 指定其他端口"
    fi

    setup_proxy_account
    # 尽早落盘部署状态，保证中途失败时 uninstall 仍能完整清理
    save_state
    write_dante_config
    tune_kernel
    setup_service
    open_firewall
    save_state
    start_service
    install_ctl
    verify_deployment
    print_info
}

load_runtime_from_state() {
    detect_os
    detect_init
    load_state
    [[ -n $PREV_USER ]] || die "未找到部署信息 (${STATE_FILE})，请先执行安装"
    SOCKS_USER=$PREV_USER
    SOCKS_PASS=$PREV_PASS
    SOCKS_PORT=$PREV_PORT
    UDP_RANGE=$PREV_UDP_RANGE
    DANTE_ORIGIN=$PREV_ORIGIN
    DANTE_BIN=$PREV_BIN
    if [[ -x $DANTE_BIN ]]; then
        DANTE_VERSION=$(dante_version_of "$DANTE_BIN")
    fi
    EXTERNAL_IFACES=()
    if [[ -r $CONF_FILE ]]; then
        local ifc
        while IFS= read -r ifc; do
            EXTERNAL_IFACES+=("$ifc")
        done < <(awk '/^external:/ { print $2 }' "$CONF_FILE")
        if grep -q '^internal: :: ' "$CONF_FILE"; then
            LISTEN_V6=1
        fi
        if grep -q '^internal: 0.0.0.0 ' "$CONF_FILE"; then
            LISTEN_V4=1
        fi
        # 未限定 IPv4 出口且监听 IPv6，说明部署时 IPv6 出网实测可用
        if (( LISTEN_V6 )) && ! grep -q '^external.protocol: ipv4' "$CONF_FILE"; then
            EGRESS_V6_OK=1
        fi
    fi
    EGRESS_IF4=${EXTERNAL_IFACES[0]:-}
}

cmd_info() {
    load_runtime_from_state
    if ! service_active; then
        log_warn "服务当前未运行，可通过以下命令启动: $(service_manage_hint)"
    fi
    detect_public_ip
    print_info
}

cmd_status() {
    load_runtime_from_state
    local rc=0
    case $INIT_SYS in
        systemd) systemctl status "${SERVICE_NAME}.service" --no-pager || true ;;
        openrc)  rc-service "$SERVICE_NAME" status || true ;;
    esac
    printf '\n'
    if port_listening "$SOCKS_PORT"; then
        log_info "端口 ${SOCKS_PORT}/tcp 监听中"
    else
        log_warn "端口 ${SOCKS_PORT}/tcp 未监听"
    fi
    socks5_auth_probe "$SOCKS_USER" "$SOCKS_PASS" "$SOCKS_PORT" || rc=$?
    case $rc in
        0) log_info "认证自检: 通过" ;;
        1) log_error "认证自检: 用户名密码被拒绝" ;;
        *) log_error "认证自检: SOCKS5 握手失败" ;;
    esac
    log_info "开机自启: $(service_enabled_text)"
}

cmd_restart() {
    load_runtime_from_state
    service_restart
    sleep 1
    if service_active; then
        log_info "服务已重启"
    else
        die "服务重启失败，配置自检: $("$DANTE_BIN" -V -f "$CONF_FILE" 2>&1 || true)"
    fi
}

confirm() {
    local answer=""
    if (( OPT_YES )); then
        return 0
    fi
    if [[ -r /dev/tty ]]; then
        printf '%s [y/N]: ' "$1" >/dev/tty
        read -r answer </dev/tty || true
    fi
    [[ $answer =~ ^[Yy]([Ee][Ss])?$ ]]
}

cmd_uninstall() {
    detect_os
    detect_init
    load_state
    confirm "确认卸载 SOCKS5 代理服务 (含账号、防火墙规则、调优配置)?" || die "已取消卸载"

    log_step "停止并移除服务"
    case $INIT_SYS in
        systemd)
            systemctl disable --now "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
            rm -f "$SYSTEMD_UNIT"
            systemctl daemon-reload || true
            systemctl reset-failed "${SERVICE_NAME}.service" >/dev/null 2>&1 || true ;;
        openrc)
            rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
            rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
            rm -f "$OPENRC_SCRIPT" ;;
    esac

    log_step "删除代理账号"
    local u
    while IFS= read -r u; do
        if [[ -n $u ]]; then
            delete_user "$u"
            log_info "已删除账号: ${u}"
        fi
    done < <(managed_users)
    if getent group "$PROXY_GROUP" >/dev/null 2>&1; then
        if has_cmd groupdel; then
            groupdel "$PROXY_GROUP" >/dev/null 2>&1 || true
        else
            delgroup "$PROXY_GROUP" >/dev/null 2>&1 || true
        fi
    fi
    if id socks5d >/dev/null 2>&1; then
        delete_user socks5d
    fi

    log_step "撤销防火墙规则"
    firewall_cleanup "${PREV_FIREWALL:-none}" "$PREV_FW_ZONE" "$PREV_PORT" "$PREV_UDP_RANGE"

    log_step "移除内核调优配置"
    rm -f "$SYSCTL_FILE" "$MODULES_FILE"
    if has_cmd sysctl; then
        sysctl --system >/dev/null 2>&1 || true
    fi
    log_info "调优配置已删除 (部分运行时参数在重启后完全恢复默认)"

    log_step "卸载 Dante"
    if [[ $PREV_ORIGIN == "source" ]]; then
        rm -f "$DANTE_SRC_BIN" /usr/local/share/man/man8/sockd.8 /usr/local/share/man/man5/sockd.conf.5
        log_info "已删除源码编译的 Dante"
    elif pkg_installed "$(dante_pkg_name)"; then
        pkg_remove "$(dante_pkg_name)" || log_warn "Dante 软件包卸载失败，可手动卸载"
        log_info "已卸载 Dante 软件包"
    fi
    if [[ -f $CONF_FILE ]] && grep -qF "$CONF_MARKER" "$CONF_FILE"; then
        rm -f "$CONF_FILE"
    fi

    rm -rf "$STATE_DIR"
    rm -f "$CTL_PATH"
    log_info "卸载完成"
}

main() {
    parse_args "$@"
    require_root "$@"
    acquire_lock
    case $CMD in
        install)   cmd_install ;;
        info)      cmd_info ;;
        status)    cmd_status ;;
        restart)   cmd_restart ;;
        uninstall) cmd_uninstall ;;
    esac
}

main "$@"

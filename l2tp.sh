#!/usr/bin/env bash
#
# =============================================================================
#  l2tp.sh —— L2TP/IPsec VPN 服务端一键部署脚本 (libreswan + xl2tpd)
# -----------------------------------------------------------------------------
#  功能
#    * 自动识别发行版 / 版本 / 架构，默认按 Ubuntu 流程部署
#    * 自动识别外部出口网卡与公网 IP
#    * IPsec 预共享密钥 (PSK) + 用户名/密码 (MS-CHAPv2) 认证，允许任意来源 IP 连接
#    * 用户名 / 密码 / PSK 默认随机生成，均可通过参数或环境变量指定
#    * 使用默认端口: UDP 500 / 4500 (IPsec)，UDP 1701 (L2TP，仅允许经 IPsec 封装)
#    * 开机自启，异常自动重启；NAT / 转发 / 防火墙规则开机自动恢复
#    * 游戏优化: 内核态 L2TP 数据通道、MTU/MSS 防分片、BBR+fq、UDP 缓冲、客户端互访联机
#    * 不保留任何服务日志
#
#  支持系统
#    Ubuntu 18.04+ / Debian 10+ (首选)                       apt
#    CentOS / RHEL / Rocky / Alma / Oracle / Fedora /
#    Amazon Linux / openEuler / Anolis / OpenCloudOS 等       dnf / yum (+EPEL，缺包时源码编译 xl2tpd)
#
#  用法
#    bash l2tp.sh                                       安装：随机用户名/密码/PSK
#    bash l2tp.sh -u alice -p 'S3cret_pw' -k 'MyPsk_123'  安装：指定用户名/密码/PSK
#    bash l2tp.sh info | status | restart | uninstall
#    bash l2tp.sh -h                                    查看全部参数
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
readonly SCRIPT_VERSION="1.1.1"
readonly DEFAULT_NET="192.168.42"
readonly DEFAULT_DNS="8.8.8.8,1.1.1.1"
readonly DEFAULT_MTU=1280
readonly IKE_PORT=500
readonly NATT_PORT=4500
readonly L2TP_PORT=1701

readonly XL2TPD_SRC_VERSION="1.3.20"
readonly XL2TPD_SRC_SHA256="3db95450c5e1efaeea7547af344b5621f4453af3c227f26ec43bcbc79087b045"
readonly XL2TPD_SRC_TARBALL="xl2tpd-${XL2TPD_SRC_VERSION}.tar.gz"
# Debian / Ubuntu 软件池的 orig 包与 GitHub tag 归档逐字节一致 (国内各镜像站均同步软件池)
readonly XL2TPD_SRC_ORIG="xl2tpd_${XL2TPD_SRC_VERSION}.orig.tar.gz"
# Gentoo distfiles 按 BLAKE2B(文件名) 的前 2 位十六进制分目录，升级 XL2TPD_SRC_VERSION 时同步更新:
#   printf 'xl2tpd-x.y.z.tar.gz' | b2sum | cut -c1-2
readonly XL2TPD_SRC_GENTOO_DIR="58"
# 源码包候选地址：GitHub + 原样收录上游归档的发行版镜像 (国内 / 海外)。
# 下载前并发测速排序，逐个尝试直到 SHA256 校验通过；HTTP 地址同样强制校验，内容无法被篡改
readonly XL2TPD_SRC_MIRRORS=(
    "https://github.com/xelerance/xl2tpd/archive/refs/tags/v${XL2TPD_SRC_VERSION}.tar.gz"
    "https://codeload.github.com/xelerance/xl2tpd/tar.gz/refs/tags/v${XL2TPD_SRC_VERSION}"
    "https://mirrors.aliyun.com/debian/pool/main/x/xl2tpd/${XL2TPD_SRC_ORIG}"
    "https://mirrors.tuna.tsinghua.edu.cn/debian/pool/main/x/xl2tpd/${XL2TPD_SRC_ORIG}"
    "https://mirrors.ustc.edu.cn/debian/pool/main/x/xl2tpd/${XL2TPD_SRC_ORIG}"
    "https://mirrors.cloud.tencent.com/debian/pool/main/x/xl2tpd/${XL2TPD_SRC_ORIG}"
    "https://mirrors.huaweicloud.com/debian/pool/main/x/xl2tpd/${XL2TPD_SRC_ORIG}"
    "https://mirrors.aliyun.com/ubuntu/pool/universe/x/xl2tpd/${XL2TPD_SRC_ORIG}"
    "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/pool/universe/x/xl2tpd/${XL2TPD_SRC_ORIG}"
    "https://mirrors.ustc.edu.cn/ubuntu/pool/universe/x/xl2tpd/${XL2TPD_SRC_ORIG}"
    "https://mirrors.cloud.tencent.com/ubuntu/pool/universe/x/xl2tpd/${XL2TPD_SRC_ORIG}"
    "https://mirrors.huaweicloud.com/ubuntu/pool/universe/x/xl2tpd/${XL2TPD_SRC_ORIG}"
    "https://mirrors.ustc.edu.cn/gentoo/distfiles/${XL2TPD_SRC_GENTOO_DIR}/${XL2TPD_SRC_TARBALL}"
    "https://mirrors.tuna.tsinghua.edu.cn/gentoo/distfiles/${XL2TPD_SRC_GENTOO_DIR}/${XL2TPD_SRC_TARBALL}"
    "https://mirrors.aliyun.com/gentoo/distfiles/${XL2TPD_SRC_GENTOO_DIR}/${XL2TPD_SRC_TARBALL}"
    "https://mirrors.nju.edu.cn/gentoo/distfiles/${XL2TPD_SRC_GENTOO_DIR}/${XL2TPD_SRC_TARBALL}"
    "https://deb.debian.org/debian/pool/main/x/xl2tpd/${XL2TPD_SRC_ORIG}"
    "https://distfiles.gentoo.org/distfiles/${XL2TPD_SRC_GENTOO_DIR}/${XL2TPD_SRC_TARBALL}"
    "https://distfiles.alpinelinux.org/distfiles/edge/${XL2TPD_SRC_TARBALL}"
    "http://archive.ubuntu.com/ubuntu/pool/universe/x/xl2tpd/${XL2TPD_SRC_ORIG}"
)
readonly XL2TPD_SRC_BIN="/usr/local/sbin/xl2tpd"
readonly XL2TPD_SRC_CTL="/usr/local/sbin/xl2tpd-control"

readonly MARKER_TEXT="Managed by l2tp.sh"
readonly STATE_DIR="/etc/l2tp-vpn"
readonly STATE_FILE="${STATE_DIR}/l2tp.env"
readonly IPSEC_CONF="/etc/ipsec.conf"
readonly IPSEC_SECRETS="/etc/ipsec.secrets"
readonly XL2TPD_CONF="/etc/xl2tpd/xl2tpd.conf"
readonly PPP_OPTIONS="/etc/ppp/options.xl2tpd"
readonly CHAP_SECRETS="/etc/ppp/chap-secrets"
readonly XL2TPD_UNIT="/etc/systemd/system/xl2tpd.service"
readonly IPSEC_DROPIN_DIR="/etc/systemd/system/ipsec.service.d"
readonly IPSEC_DROPIN="${IPSEC_DROPIN_DIR}/l2tp-vpn.conf"
readonly FW_SCRIPT="/usr/local/sbin/l2tp-vpn-fw"
readonly FW_UNIT_NAME="l2tp-vpn-firewall.service"
readonly FW_UNIT="/etc/systemd/system/${FW_UNIT_NAME}"
readonly SYSCTL_BASE="/etc/sysctl.d/98-l2tp-vpn.conf"
readonly SYSCTL_TUNE="/etc/sysctl.d/99-l2tp-vpn-tuning.conf"
readonly MODULES_FILE="/etc/modules-load.d/l2tp-vpn.conf"
readonly CTL_PATH="/usr/local/sbin/l2tpctl"
readonly CONN_NAME="l2tp-psk"
readonly PPP_SERVER_NAME="l2tpd"
# 便于手机输入：排除易混淆字符 0 O 1 I l
readonly SAFE_CHARSET="A-HJ-NP-Za-km-z2-9"

# ----------------------------------------------------------------------------
# 运行期变量
# ----------------------------------------------------------------------------
CMD="install"
OPT_USER="${VPN_USER:-}"
OPT_PASS="${VPN_PASSWORD:-}"
OPT_PSK="${VPN_IPSEC_PSK:-}"
OPT_NET="${VPN_NET:-}"
OPT_DNS="${VPN_DNS:-}"
OPT_MTU="${VPN_MTU:-}"
OPT_IFACE="${VPN_IFACE:-}"
OPT_TUNE=1
OPT_RENEW=0
OPT_FORCE_SOURCE=0
OPT_YES=0

OS_ID=""
OS_VERSION=""
OS_MAJOR=""
OS_NAME=""
OS_LIKE=""
OS_FAMILY=""
PKG_MGR=""
ARCH=""

SWAN_VERSION=""
SWAN_MAJOR=0
SWAN_MINOR=0
SWAN_PREINSTALLED=0
XL2TPD_BIN=""
XL2TPD_VERSION=""
XL2TPD_ORIGIN=""
XL2TPD_PREINSTALLED=0

EGRESS_IF=""
EGRESS_IP=""
PUBLIC_IP=""

VPN_USER_NAME=""
VPN_PASS=""
VPN_PSK=""
VPN_NET_PREFIX=""
VPN_CIDR=""
VPN_LOCAL_IP=""
VPN_POOL=""
DNS1=""
DNS2=""
PPP_MTU=""

FIREWALL_MODE=""
FIREWALL_ZONE=""
POLICY_MATCH=0
TUNED=0
TUNED_BBR=0
SYSCTL_APPLIED=0
SYSCTL_FAILED=0

PREV_USER=""
PREV_PASS=""
PREV_PSK=""
PREV_NET=""
PREV_DNS=""
PREV_MTU=""
PREV_FIREWALL=""
PREV_FW_ZONE=""
PREV_XL2TPD_ORIGIN=""
PREV_SWAN_PRE=""
PREV_XL2TPD_PRE=""

TMP_DIR=""
POLICY_RC_CREATED=0
CURL_RETRY_ALL=0

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

# 读取定长随机字节后过滤，避免 SIGPIPE 与 pipefail 冲突
rand_str() {
    local len=$1 charset=$2 out="" chunk
    while (( ${#out} < len )); do
        chunk=$(head -c 512 /dev/urandom | tr -dc "$charset")
        out+=$chunk
    done
    printf '%s' "${out:0:len}"
}

is_ipv4() {
    local ip=$1 o
    [[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    for o in "${BASH_REMATCH[@]:1}"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
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

# 判断 UDP 端口是否已绑定 (直接解析 /proc，不依赖 ss/netstat)
udp_bound() {
    local hex files=() f
    printf -v hex ':%04X' "$1"
    for f in /proc/net/udp /proc/net/udp6; do
        if [[ -r $f ]]; then
            files+=("$f")
        fi
    done
    (( ${#files[@]} > 0 )) || return 1
    awk -v h="$hex" 'NR > 1 && toupper(substr($2, length($2) - 4)) == h { found = 1 } END { exit !found }' "${files[@]}"
}

udp_owner() {
    local out
    if has_cmd ss; then
        out=$(ss -lunpH "sport = :$1" 2>/dev/null || true)
        if [[ $out =~ \"([^\"]+)\" ]]; then
            printf '%s' "${BASH_REMATCH[1]}"
            return 0
        fi
    fi
    printf '%s' "未知进程"
}

# 文件是否由本脚本生成
is_managed_file() {
    [[ -f $1 ]] && grep -qF "$MARKER_TEXT" "$1"
}

backup_foreign() {
    local f=$1 bak
    if [[ -f $f ]] && ! is_managed_file "$f"; then
        bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
        cp -p "$f" "$bak"
        log_info "已备份原有文件: ${bak}"
    fi
}

# 原子写入：同目录临时文件 + mv，保证 SELinux 上下文与目录一致
write_file() {
    local target=$1 mode=$2 tmp dir
    dir=$(dirname "$target")
    if [[ ! -d $dir ]]; then
        install -d -m 755 "$dir"
    fi
    tmp=$(mktemp "${dir}/.l2tp-vpn.XXXXXX")
    cat >"$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$target"
    if has_cmd restorecon; then
        restorecon "$target" >/dev/null 2>&1 || true
    fi
}

# ----------------------------------------------------------------------------
# 帮助与参数
# ----------------------------------------------------------------------------
usage() {
    cat <<EOF
L2TP/IPsec VPN 一键部署脚本 v${SCRIPT_VERSION} (libreswan + xl2tpd)

用法: bash $0 [命令] [选项]

命令:
  install              安装 / 重新部署 (默认)
  info                 显示连接信息
  status               查看服务状态与在线客户端
  restart              重启服务
  uninstall            卸载服务、配置、防火墙规则与调优配置

选项:
  -u, --user USER      VPN 用户名 (默认随机；字母/数字/._@-，最长 64)
  -p, --pass PASS      VPN 密码   (默认随机 16 位；可见 ASCII，不含空格 " \\ ')
  -k, --psk PSK        IPsec 预共享密钥 (默认随机 20 位；规则同密码)
      --net A.B.C      客户端网段前缀，/24 (默认 ${DEFAULT_NET} -> ${DEFAULT_NET}.0/24)
      --dns D1[,D2]    下发给客户端的 DNS (默认 ${DEFAULT_DNS})
      --mtu N          PPP MTU/MRU 1200~1460 (默认 ${DEFAULT_MTU}，兼容 PPPoE/移动网络，避免分片)
  -i, --iface IFACE    指定外部出口网卡 (默认自动识别)
      --renew          重新随机生成用户名/密码/PSK (默认重装时沿用)
      --no-tune        跳过内核网络 / 游戏低延迟调优
      --source         强制源码编译 xl2tpd v${XL2TPD_SRC_VERSION}
  -y, --yes            卸载时不再确认
  -h, --help           显示帮助
  -v, --version        显示版本

端口 (默认，不可更改): UDP ${IKE_PORT} / ${NATT_PORT} (IPsec)，UDP ${L2TP_PORT} (L2TP，仅经 IPsec)

环境变量 (优先级低于命令行参数):
  VPN_USER  VPN_PASSWORD  VPN_IPSEC_PSK  VPN_NET  VPN_DNS  VPN_MTU  VPN_IFACE
  XL2TPD_SRC_URL   源码包下载地址，最先尝试，失败后仍回退到内置镜像 (SHA256 强制校验)
  XL2TPD_SRC_FILE  本地源码包路径 (离线部署：先上传 ${XL2TPD_SRC_TARBALL}，SHA256 强制校验)
  未指定时自动并发测速国内外 ${#XL2TPD_SRC_MIRRORS[@]} 个镜像，按速度依次尝试

示例:
  sudo bash $0
  sudo bash $0 -u alice -p 'S3cret_pw' -k 'MyPsk_123'
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
            -k|--psk)       need_arg "$1" $#; OPT_PSK=$2; shift ;;
            --psk=*)        OPT_PSK=${1#*=} ;;
            --net)          need_arg "$1" $#; OPT_NET=$2; shift ;;
            --net=*)        OPT_NET=${1#*=} ;;
            --dns)          need_arg "$1" $#; OPT_DNS=$2; shift ;;
            --dns=*)        OPT_DNS=${1#*=} ;;
            --mtu)          need_arg "$1" $#; OPT_MTU=$2; shift ;;
            --mtu=*)        OPT_MTU=${1#*=} ;;
            -i|--iface)     need_arg "$1" $#; OPT_IFACE=$2; shift ;;
            --iface=*)      OPT_IFACE=${1#*=} ;;
            --renew)        OPT_RENEW=1 ;;
            --no-tune)      OPT_TUNE=0 ;;
            --source)       OPT_FORCE_SOURCE=1 ;;
            -y|--yes)       OPT_YES=1 ;;
            -h|--help)      usage; exit 0 ;;
            -v|--version)   printf 'l2tp.sh v%s\n' "$SCRIPT_VERSION"; exit 0 ;;
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
    local lock="/run/l2tp-vpn-deploy.lock"
    [[ -d /run ]] || lock="/tmp/l2tp-vpn-deploy.lock"
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
    OS_MAJOR=${OS_VERSION%%.*}
    ARCH=$(uname -m)

    case $OS_ID in
        ubuntu|debian|linuxmint|pop|kali|deepin|uos|raspbian|devuan|elementary|zorin|neon|armbian|pureos)
            OS_FAMILY="debian" ;;
        centos|rhel|rocky|almalinux|ol|fedora|amzn|anolis|openeuler|opencloudos|tencentos|alinux|euleros|kylin|circle|eurolinux|navylinux|miraclelinux|virtuozzo|cloudlinux|scientific|bclinux|hce)
            OS_FAMILY="rhel" ;;
        *)
            case " ${OS_LIKE} " in
                *" debian "*|*" ubuntu "*)            OS_FAMILY="debian" ;;
                *" rhel "*|*" fedora "*|*" centos "*) OS_FAMILY="rhel" ;;
                *)                                    OS_FAMILY="" ;;
            esac ;;
    esac

    case $OS_FAMILY in
        debian)
            if has_cmd apt-get; then
                PKG_MGR="apt"
            fi ;;
        rhel)
            if has_cmd dnf; then
                PKG_MGR="dnf"
            elif has_cmd yum; then
                PKG_MGR="yum"
            fi ;;
    esac

    # 发行版标识与包管理器不一致时以实际包管理器为准，优先 apt (Ubuntu 流程)
    if [[ -z $PKG_MGR ]]; then
        if has_cmd apt-get; then
            PKG_MGR="apt"; OS_FAMILY="debian"
        elif has_cmd dnf; then
            PKG_MGR="dnf"; OS_FAMILY="rhel"
        elif has_cmd yum; then
            PKG_MGR="yum"; OS_FAMILY="rhel"
        else
            die "暂不支持该系统 (${OS_NAME})：L2TP/IPsec 依赖 libreswan + xl2tpd，仅支持 Debian/Ubuntu 与 RHEL 系发行版"
        fi
    fi
}

detect_init() {
    if ! [[ -d /run/systemd/system ]] || ! has_cmd systemctl; then
        die "未检测到 systemd，无法配置开机自启 (L2TP/IPsec 需在 systemd 主机上运行)"
    fi
}

check_virtualization() {
    if is_container; then
        log_warn "检测到容器环境：IPsec 需要内核 XFRM 支持，容器 (LXC/OpenVZ/Docker) 内通常无法正常工作"
    fi
    if [[ ! -e /dev/ppp ]] && ! modprobe ppp_generic >/dev/null 2>&1; then
        log_warn "未检测到 /dev/ppp，PPP 会话可能无法建立 (VPS 需在控制面板开启 PPP/TUN)"
    fi
}

# ----------------------------------------------------------------------------
# 状态文件 (仅 root 可读；逐行解析，不 source，杜绝代码注入)
# ----------------------------------------------------------------------------
load_state() {
    local key val
    [[ -r $STATE_FILE ]] || return 0
    while IFS='=' read -r key val; do
        case $key in
            VPN_USER)              PREV_USER=$val ;;
            VPN_PASSWORD)          PREV_PASS=$val ;;
            VPN_IPSEC_PSK)         PREV_PSK=$val ;;
            VPN_NET)               PREV_NET=$val ;;
            VPN_DNS)               PREV_DNS=$val ;;
            VPN_MTU)               PREV_MTU=$val ;;
            FIREWALL_MODE)         PREV_FIREWALL=$val ;;
            FIREWALL_ZONE)         PREV_FW_ZONE=$val ;;
            XL2TPD_ORIGIN)         PREV_XL2TPD_ORIGIN=$val ;;
            SWAN_PREINSTALLED)     PREV_SWAN_PRE=$val ;;
            XL2TPD_PREINSTALLED)   PREV_XL2TPD_PRE=$val ;;
            EGRESS_IF)             EGRESS_IF=$val ;;
            PUBLIC_IP)             PUBLIC_IP=$val ;;
        esac
    done <"$STATE_FILE"
}

save_state() {
    local tmp dns_list="$DNS1"
    if [[ -n $DNS2 ]]; then
        dns_list+=",${DNS2}"
    fi
    install -d -m 700 "$STATE_DIR"
    tmp=$(mktemp "${STATE_DIR}/.l2tp.env.XXXXXX")
    {
        printf '# %s，请勿手动修改\n' "$MARKER_TEXT"
        printf 'VPN_USER=%s\n' "$VPN_USER_NAME"
        printf 'VPN_PASSWORD=%s\n' "$VPN_PASS"
        printf 'VPN_IPSEC_PSK=%s\n' "$VPN_PSK"
        printf 'VPN_NET=%s\n' "$VPN_NET_PREFIX"
        printf 'VPN_DNS=%s\n' "$dns_list"
        printf 'VPN_MTU=%s\n' "$PPP_MTU"
        printf 'EGRESS_IF=%s\n' "$EGRESS_IF"
        printf 'PUBLIC_IP=%s\n' "$PUBLIC_IP"
        printf 'FIREWALL_MODE=%s\n' "$FIREWALL_MODE"
        printf 'FIREWALL_ZONE=%s\n' "$FIREWALL_ZONE"
        printf 'XL2TPD_ORIGIN=%s\n' "$XL2TPD_ORIGIN"
        printf 'SWAN_PREINSTALLED=%s\n' "$SWAN_PREINSTALLED"
        printf 'XL2TPD_PREINSTALLED=%s\n' "$XL2TPD_PREINSTALLED"
        printf 'TUNED=%s\n' "$TUNED"
        printf 'UPDATED_AT=%s\n' "$(date '+%F %T %z')"
    } >"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$STATE_FILE"
}

# ----------------------------------------------------------------------------
# 参数决策与校验
# ----------------------------------------------------------------------------
validate_user() {
    [[ $1 =~ ^[A-Za-z0-9._@-]{1,64}$ ]] \
        || die "用户名不合法: '$1' (字母/数字/._@-，1~64 位)"
}

# 密码与 PSK：可见 ASCII，排除空白与 " \ '，避免各类客户端及配置文件转义问题
validate_secret() {
    local name=$1 val=$2 min_warn=$3 len=${#2}
    (( len >= 1 && len <= 128 )) || die "${name}长度必须在 1~128 之间"
    [[ $val =~ ^[[:graph:]]+$ ]] || die "${name}只能包含可见 ASCII 字符 (不含空格、中文)"
    case $val in
        *\"*|*\\*|*\'*) die "${name}不能包含双引号、单引号或反斜杠" ;;
    esac
    if (( len < min_warn )); then
        log_warn "${name}长度小于 ${min_warn} 位，公网环境下存在被暴力破解风险"
    fi
}

validate_net() {
    local a b c
    [[ $1 =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || die "网段前缀格式错误: '$1' (示例: 192.168.42)"
    a=$((10#${BASH_REMATCH[1]})); b=$((10#${BASH_REMATCH[2]})); c=$((10#${BASH_REMATCH[3]}))
    (( a <= 255 && b <= 255 && c <= 255 )) || die "网段前缀不合法: '$1'"
    if ! (( a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) )); then
        die "客户端网段必须为私有地址 (10.x / 172.16-31.x / 192.168.x)"
    fi
    VPN_NET_PREFIX="${a}.${b}.${c}"
}

validate_dns() {
    local list=$1 d
    local -a arr=()
    IFS=',' read -r -a arr <<<"$list"
    (( ${#arr[@]} >= 1 && ${#arr[@]} <= 2 )) || die "DNS 需为 1~2 个 IPv4 地址，逗号分隔"
    for d in "${arr[@]}"; do
        is_ipv4 "$d" || die "DNS 地址不合法: '$d'"
    done
    DNS1=${arr[0]}
    DNS2=${arr[1]:-}
}

validate_mtu() {
    if ! [[ $1 =~ ^[0-9]{3,4}$ ]] || (( 10#$1 < 1200 || 10#$1 > 1460 )); then
        die "MTU 必须在 1200~1460 之间"
    fi
    PPP_MTU=$((10#$1))
}

resolve_settings() {
    log_step "确定部署参数"

    validate_net "${OPT_NET:-${PREV_NET:-$DEFAULT_NET}}"
    VPN_CIDR="${VPN_NET_PREFIX}.0/24"
    VPN_LOCAL_IP="${VPN_NET_PREFIX}.1"
    VPN_POOL="${VPN_NET_PREFIX}.10-${VPN_NET_PREFIX}.250"
    validate_dns "${OPT_DNS:-${PREV_DNS:-$DEFAULT_DNS}}"
    validate_mtu "${OPT_MTU:-${PREV_MTU:-$DEFAULT_MTU}}"

    if [[ -n $OPT_USER ]]; then
        VPN_USER_NAME=$OPT_USER
    elif (( ! OPT_RENEW )) && [[ -n $PREV_USER ]]; then
        VPN_USER_NAME=$PREV_USER
        log_info "沿用已有账号 (如需重新随机生成请加 --renew)"
    else
        VPN_USER_NAME="vpn$(rand_str 5 'a-km-z2-9')"
    fi
    validate_user "$VPN_USER_NAME"

    if [[ -n $OPT_PASS ]]; then
        VPN_PASS=$OPT_PASS
    elif (( ! OPT_RENEW )) && [[ -n $PREV_PASS && $VPN_USER_NAME == "$PREV_USER" ]]; then
        VPN_PASS=$PREV_PASS
    else
        VPN_PASS=$(rand_str 16 "$SAFE_CHARSET")
    fi
    validate_secret "密码" "$VPN_PASS" 8

    if [[ -n $OPT_PSK ]]; then
        VPN_PSK=$OPT_PSK
    elif (( ! OPT_RENEW )) && [[ -n $PREV_PSK ]]; then
        VPN_PSK=$PREV_PSK
    else
        VPN_PSK=$(rand_str 20 "$SAFE_CHARSET")
    fi
    validate_secret "PSK" "$VPN_PSK" 12

    log_info "客户端网段: ${VPN_CIDR} (网关 ${VPN_LOCAL_IP})，DNS: ${DNS1}${DNS2:+, $DNS2}，MTU: ${PPP_MTU}"
    log_info "VPN 用户: ${VPN_USER_NAME}"
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
        dnf) dnf install -y -q "$@" >/dev/null ;;
        yum) yum install -y -q "$@" >/dev/null ;;
    esac
}

pkg_remove() {
    case $PKG_MGR in
        apt) DEBIAN_FRONTEND=noninteractive apt-get purge -y -q -o DPkg::Lock::Timeout=300 "$@" >/dev/null ;;
        dnf) dnf remove -y -q "$@" >/dev/null ;;
        yum) yum remove -y -q "$@" >/dev/null ;;
    esac
}

pkg_installed() {
    case $PKG_MGR in
        apt)     [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null || true)" == *"install ok installed"* ]] ;;
        dnf|yum) rpm -q "$1" >/dev/null 2>&1 ;;
        *)       return 1 ;;
    esac
}

# 软件源中是否存在可安装的候选版本；确定不存在时不再重试，直接走后备方案
pkg_has_candidate() {
    local out re='Candidate: *([^[:space:]]+)'
    case $PKG_MGR in
        apt)
            out=$(apt-cache policy "$1" 2>/dev/null || true)
            [[ $out =~ $re ]] && [[ ${BASH_REMATCH[1]} != "(none)" ]] ;;
        *)  return 0 ;;
    esac
}

# Debian 系安装软件包时阻止服务被自动拉起 (默认配置下启动无意义且可能报错)
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

enable_epel() {
    log_info "启用 EPEL 软件源 (提供 xl2tpd)"
    case $OS_ID in
        fedora)
            return 1 ;;
        amzn)
            if [[ $OS_MAJOR == "2" ]] && has_cmd amazon-linux-extras; then
                amazon-linux-extras install -y epel >/dev/null 2>&1
            else
                return 1
            fi ;;
        ol)
            pkg_install "oracle-epel-release-el${OS_MAJOR}" 2>/dev/null ;;
        rhel)
            pkg_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_MAJOR}.noarch.rpm" 2>/dev/null ;;
        *)
            pkg_install epel-release 2>/dev/null \
                || pkg_install "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_MAJOR}.noarch.rpm" 2>/dev/null ;;
    esac
}

# curl 是否支持某个选项 (先取完整帮助再匹配，避免 grep -q 提前退出触发 SIGPIPE + pipefail)
curl_supports() {
    local help
    help=$(curl --help all 2>/dev/null || true)
    [[ $help == *"$1"* ]]
}

# 下载单个地址；$3=1 为快速模式 (用于测速未响应的地址：不重试、缩短连接超时，出网受阻时不长时间空等)。
# --retry-all-errors (curl 7.71+) 让 TLS 握手 / 传输被中途重置 (curl 35/56，国内访问海外站点常见)
# 也能重试；20 秒内速度低于 1KB/s 视为卡死，立即放弃以便切换镜像
download_file() {
    local url=$1 out=$2 quick=${3:-0} opts=()
    rm -f -- "$out"
    if has_cmd curl; then
        opts=(-fL -sS --max-time 300 --speed-limit 1024 --speed-time 20)
        if (( quick )); then
            opts+=(--connect-timeout 5)
        else
            opts+=(--connect-timeout 10 --retry 2 --retry-delay 2)
            if (( CURL_RETRY_ALL )); then
                opts+=(--retry-all-errors)
            fi
        fi
        curl "${opts[@]}" -o "$out" "$url"
    elif has_cmd wget; then
        if (( quick )); then
            wget -q --tries=1 --timeout=10 -O "$out" "$url"
        else
            wget -q --tries=3 --timeout=20 -O "$out" "$url"
        fi
    else
        return 127
    fi
}

# 并发测速：每个地址一个后台 curl 只取首字节 (Range 0-0)，总耗时取决于最慢的超时 (<= 8 秒)。
# 每行输出 "<状态> <地址>"：ok 为可达 (按耗时升序)，na 为测速未响应 (保留作兜底)，- 为未测速
rank_urls() {
    local dir=$1 i t idx seen=" "
    shift
    local urls=("$@") pids=()
    if ! has_cmd curl; then
        printf -- '- %s\n' "${urls[@]}"
        return 0
    fi
    mkdir -p -- "$dir"
    for i in "${!urls[@]}"; do
        (
            if t=$(curl -fsS -L -r 0-0 -o /dev/null --connect-timeout 5 --max-time 8 \
                    -w '%{time_total}' "${urls[i]}" 2>/dev/null); then
                printf '%s %s\n' "$t" "$i" >"${dir}/${i}"
            fi
        ) &
        pids+=("$!")
    done
    for i in "${pids[@]}"; do
        wait "$i" || true
    done
    while read -r t idx; do
        [[ $idx =~ ^[0-9]+$ && -n ${urls[idx]:-} ]] || continue
        printf 'ok %s\n' "${urls[idx]}"
        seen+="${idx} "
    done < <(cat -- "$dir"/* 2>/dev/null | sort -n -k1,1 -k2,2n || true)
    for i in "${!urls[@]}"; do
        if [[ $seen != *" ${i} "* ]]; then
            printf 'na %s\n' "${urls[i]}"
        fi
    done
}

# 获取 xl2tpd 源码包到 $1：XL2TPD_SRC_FILE (本地) > XL2TPD_SRC_URL > 内置镜像 (并发测速排序)。
# 逐个地址尝试直到 SHA256 校验通过，单个镜像被阻断 / 限速 / 劫持都会自动切换到下一个
fetch_xl2tpd_source() {
    local out=$1 url state i urls=() quick=() added=0 reachable=0 total
    if [[ -n ${XL2TPD_SRC_FILE:-} ]]; then
        [[ -f $XL2TPD_SRC_FILE && -r $XL2TPD_SRC_FILE ]] \
            || die "XL2TPD_SRC_FILE 指定的文件不存在或不可读: ${XL2TPD_SRC_FILE}"
        verify_sha256 "$XL2TPD_SRC_FILE" "$XL2TPD_SRC_SHA256" \
            || die "XL2TPD_SRC_FILE SHA256 校验失败 (需要原始的 ${XL2TPD_SRC_TARBALL}): ${XL2TPD_SRC_FILE}"
        cp -f -- "$XL2TPD_SRC_FILE" "$out"
        log_info "使用本地源码包: ${XL2TPD_SRC_FILE} (SHA256 校验通过)"
        return 0
    fi

    has_cmd curl || has_cmd wget || die "缺少 curl / wget，无法下载源码 (可通过 XL2TPD_SRC_FILE 指定本地源码包)"
    CURL_RETRY_ALL=0
    if has_cmd curl && curl_supports --retry-all-errors; then
        CURL_RETRY_ALL=1
    fi

    if [[ -n ${XL2TPD_SRC_URL:-} ]]; then
        urls+=("$XL2TPD_SRC_URL")
        quick+=(0)
    fi
    log_info "并发测速 ${#XL2TPD_SRC_MIRRORS[@]} 个源码镜像..."
    while read -r state url; do
        [[ -n $url && $url != "${XL2TPD_SRC_URL:-}" ]] || continue
        urls+=("$url")
        added=$((added + 1))
        if [[ $state == "na" ]]; then
            quick+=(1)
        else
            quick+=(0)
        fi
        if [[ $state == "ok" ]]; then
            reachable=$((reachable + 1))
        fi
    done < <(rank_urls "${TMP_DIR}/probe" "${XL2TPD_SRC_MIRRORS[@]}")
    if (( added == 0 )); then
        for url in "${XL2TPD_SRC_MIRRORS[@]}"; do
            urls+=("$url")
            quick+=(0)
        done
    fi
    if (( reachable > 0 )); then
        log_info "测速完成: ${reachable}/${#XL2TPD_SRC_MIRRORS[@]} 个镜像可达，按响应速度依次尝试"
    elif has_cmd curl; then
        log_warn "测速未发现可达镜像 (出网可能受限)，仍逐个快速尝试"
    fi

    total=${#urls[@]}
    for i in "${!urls[@]}"; do
        url=${urls[i]}
        log_info "下载源码 ($((i + 1))/${total}): ${url}"
        if ! download_file "$url" "$out" "${quick[i]}"; then
            log_warn "下载失败，切换下一个地址"
            continue
        fi
        if verify_sha256 "$out" "$XL2TPD_SRC_SHA256"; then
            log_info "SHA256 校验通过"
            return 0
        fi
        log_warn "SHA256 不一致 (文件损坏、被劫持或不是原始源码包)，切换下一个地址"
    done

    rm -f -- "$out"
    log_error "全部 ${total} 个源码地址均下载失败，请检查服务器出网 (DNS / 防火墙 / 安全组出站规则)，或:"
    log_error "  1) 指定可访问的地址: XL2TPD_SRC_URL=<URL> bash $0"
    log_error "  2) 离线部署: 上传 ${XL2TPD_SRC_TARBALL} 后执行 XL2TPD_SRC_FILE=<文件路径> bash $0"
    log_error "     (SHA256 ${XL2TPD_SRC_SHA256})"
    exit 1
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

build_xl2tpd_from_source() {
    local tarball src jobs log
    log_info "源码编译 xl2tpd v${XL2TPD_SRC_VERSION}"
    case $PKG_MGR in
        apt)     retry 3 10 pkg_install gcc make libc6-dev linux-libc-dev tar gzip curl ;;
        dnf|yum) retry 3 5 pkg_install gcc make glibc-devel kernel-headers tar gzip curl ;;
    esac || log_warn "部分编译依赖安装失败，尝试继续编译"
    local c
    for c in gcc make tar; do
        has_cmd "$c" || die "缺少编译工具 ${c}，且无法自动安装 (请检查软件源)"
    done

    TMP_DIR=$(mktemp -d /tmp/l2tp-build.XXXXXX)
    tarball="${TMP_DIR}/${XL2TPD_SRC_TARBALL}"
    src="${TMP_DIR}/xl2tpd-${XL2TPD_SRC_VERSION}"
    log="${TMP_DIR}/build.log"
    jobs=$(cpu_count)

    fetch_xl2tpd_source "$tarball"
    tar -xzf "$tarball" -C "$TMP_DIR"
    [[ -d $src ]] || die "源码解压失败"

    # 只编译守护进程与控制工具 (pfc 依赖 libpcap，不需要)；启用内核态 L2TP 数据通道
    if ! ( cd "$src" && make -j"$jobs" xl2tpd xl2tpd-control ) >"$log" 2>&1; then
        log_error "编译失败，输出末尾如下:"
        tail -n 30 "$log" >&2 || true
        exit 1
    fi
    install -m 755 "${src}/xl2tpd" "$XL2TPD_SRC_BIN"
    install -m 755 "${src}/xl2tpd-control" "$XL2TPD_SRC_CTL"
    XL2TPD_ORIGIN="source"
}

# 记录部署前已存在的软件 (首次部署时判定，重装沿用)，卸载时予以保留
record_preinstalled() {
    if [[ -n $PREV_SWAN_PRE ]]; then
        SWAN_PREINSTALLED=$PREV_SWAN_PRE
    elif pkg_installed libreswan; then
        SWAN_PREINSTALLED=1
    fi
    if [[ -n $PREV_XL2TPD_PRE ]]; then
        XL2TPD_PREINSTALLED=$PREV_XL2TPD_PRE
    elif pkg_installed xl2tpd; then
        XL2TPD_PREINSTALLED=1
    fi
}

# strongSwan 与 libreswan 互斥，apt 会静默卸载对方，必须在安装前拦截
check_strongswan() {
    local p
    for p in strongswan strongswan-starter strongswan-charon strongswan-swanctl charon-systemd; do
        if pkg_installed "$p"; then
            die "检测到已安装 ${p}，与 libreswan 冲突；为避免破坏现有 IPsec 服务，请先手动卸载 strongSwan 后重试"
        fi
    done
}

install_packages() {
    log_step "安装 libreswan / xl2tpd / ppp"
    check_strongswan

    case $PKG_MGR in
        apt)
            retry 3 10 apt_update || log_warn "apt-get update 失败，尝试使用现有软件源索引继续"
            pkg_has_candidate libreswan \
                || die "当前系统软件源未收录 libreswan (Ubuntu 18.04+ / Debian 10+ 软件源均提供；Ubuntu 需启用 universe 源)"
            block_service_autostart
            if ! retry 3 10 pkg_install ca-certificates curl iproute2 procps kmod iptables ppp libreswan; then
                unblock_service_autostart
                die "安装 libreswan/ppp 失败 (Ubuntu 18.04+ / Debian 10+ 软件源均提供；Ubuntu 需启用 universe 源)"
            fi
            if (( OPT_FORCE_SOURCE )); then
                build_xl2tpd_from_source
            elif ! pkg_has_candidate xl2tpd; then
                log_warn "当前系统软件源未收录 xl2tpd，改为源码编译"
                build_xl2tpd_from_source
            elif retry 2 10 pkg_install xl2tpd; then
                XL2TPD_ORIGIN="package"
            else
                log_warn "软件源中没有可用的 xl2tpd，改为源码编译"
                build_xl2tpd_from_source
            fi
            unblock_service_autostart ;;
        dnf|yum)
            retry 3 5 pkg_install ca-certificates curl iproute procps-ng kmod ppp libreswan \
                || die "安装 libreswan/ppp 失败，请检查软件源"
            if ! has_cmd iptables; then
                pkg_install iptables-nft 2>/dev/null || pkg_install iptables 2>/dev/null || true
            fi
            if (( OPT_FORCE_SOURCE )); then
                build_xl2tpd_from_source
            elif pkg_install xl2tpd 2>/dev/null; then
                XL2TPD_ORIGIN="package"
            elif enable_epel && pkg_install xl2tpd 2>/dev/null; then
                XL2TPD_ORIGIN="package"
            else
                log_warn "软件源 / EPEL 中没有可用的 xl2tpd，改为源码编译"
                build_xl2tpd_from_source
            fi ;;
    esac

    has_cmd iptables || die "未找到 iptables 命令，无法配置 NAT 转发"
    # xl2tpd 固定调用 /usr/sbin/pppd
    [[ -x /usr/sbin/pppd ]] || die "未找到 /usr/sbin/pppd (ppp 软件包安装失败)"
}

detect_versions() {
    local out
    has_cmd ipsec || die "未找到 ipsec 命令 (libreswan 安装失败)"
    out=$(ipsec --version 2>&1 || true)
    if [[ $out != *[Ll]ibreswan* ]]; then
        die "当前 ipsec 实现不是 libreswan (${out%%$'\n'*})，请先卸载 strongSwan 等其他 IPsec 软件"
    fi
    [[ $out =~ [Ll]ibreswan[^0-9]*([0-9]+)\.([0-9]+) ]] || die "无法识别 libreswan 版本: ${out}"
    SWAN_MAJOR=$((10#${BASH_REMATCH[1]}))
    SWAN_MINOR=$((10#${BASH_REMATCH[2]}))
    SWAN_VERSION="${SWAN_MAJOR}.${SWAN_MINOR}"
    if (( SWAN_MAJOR < 3 || (SWAN_MAJOR == 3 && SWAN_MINOR < 19) )); then
        die "libreswan ${SWAN_VERSION} 过旧 (需要 >= 3.19)"
    fi

    if [[ $XL2TPD_ORIGIN == "source" && -x $XL2TPD_SRC_BIN ]]; then
        XL2TPD_BIN=$XL2TPD_SRC_BIN
    else
        local b
        for b in /usr/sbin/xl2tpd /usr/local/sbin/xl2tpd /sbin/xl2tpd; do
            if [[ -x $b ]]; then
                XL2TPD_BIN=$b
                break
            fi
        done
    fi
    [[ -n $XL2TPD_BIN ]] || die "未找到 xl2tpd 可执行文件"
    out=$("$XL2TPD_BIN" -v 2>&1 || true)
    if [[ $out =~ xl2tpd-([0-9]+(\.[0-9]+)+) ]]; then
        XL2TPD_VERSION=${BASH_REMATCH[1]}
    fi
    log_info "libreswan ${SWAN_VERSION}，xl2tpd ${XL2TPD_VERSION:-未知} ($( [[ $XL2TPD_ORIGIN == "source" ]] && printf '源码编译' || printf '系统软件包'))"
}

swan_at_least() {
    (( SWAN_MAJOR > $1 || (SWAN_MAJOR == $1 && SWAN_MINOR >= $2) ))
}

# ----------------------------------------------------------------------------
# 网络识别
# ----------------------------------------------------------------------------
iface_ok() {
    [[ -n $1 && $1 != "lo" && -d /sys/class/net/$1 ]]
}

route_dev() {
    local out
    out=$(ip -4 route get "$1" 2>/dev/null) || return 0
    awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }' <<<"$out"
}

default_dev() {
    local out
    out=$(ip -4 route show default 2>/dev/null) || return 0
    awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }' <<<"$out"
}

iface_addr() {
    local out
    out=$(ip -4 -o addr show dev "$1" scope global 2>/dev/null) || return 0
    awk '{ split($4, a, "/"); print a[1]; exit }' <<<"$out"
}

detect_egress() {
    log_step "识别外部出口网卡"
    local probe

    if [[ -n $OPT_IFACE ]]; then
        iface_ok "$OPT_IFACE" || die "指定的网卡不存在: ${OPT_IFACE}"
        EGRESS_IF=$OPT_IFACE
    else
        EGRESS_IF=""
        # 按实际路由决策识别 (兼容策略路由 / 多网卡)，国内外各取探测地址
        for probe in 1.1.1.1 223.5.5.5 8.8.8.8; do
            EGRESS_IF=$(route_dev "$probe")
            EGRESS_IF=${EGRESS_IF%%@*}
            if iface_ok "$EGRESS_IF"; then
                break
            fi
            EGRESS_IF=""
        done
        if [[ -z $EGRESS_IF ]]; then
            EGRESS_IF=$(default_dev)
            EGRESS_IF=${EGRESS_IF%%@*}
        fi
        if ! iface_ok "$EGRESS_IF" && [[ -r /proc/net/route ]]; then
            EGRESS_IF=$(awk 'NR > 1 && $2 == "00000000" && $8 == "00000000" { print $1; exit }' /proc/net/route)
        fi
        iface_ok "$EGRESS_IF" || die "无法识别 IPv4 出口网卡 (需要 IPv4 默认路由)，请使用 -i <网卡名> 指定"
    fi
    EGRESS_IP=$(iface_addr "$EGRESS_IF" || true)
    [[ -n $EGRESS_IP ]] || die "出口网卡 ${EGRESS_IF} 没有 IPv4 地址"
    log_info "出口网卡: ${EGRESS_IF} (${EGRESS_IP})"

    # 客户端网段不能与本机已有网段冲突 (忽略上次部署产生的 ppp 接口)
    local conflict
    conflict=$(ip -4 -o addr show 2>/dev/null \
        | awk -v p="${VPN_NET_PREFIX}." '$2 !~ /^ppp/ && index($4, p) == 1 { print $2; exit }' || true)
    if [[ -n $conflict ]]; then
        die "客户端网段 ${VPN_CIDR} 与本机网卡 ${conflict} 冲突，请使用 --net 指定其他网段 (如 --net 10.66.66)"
    fi
}

readonly IP4_APIS=(https://api.ipify.org https://ipv4.icanhazip.com https://4.ipw.cn https://ifconfig.me/ip https://ip.3322.net)

detect_public_ip() {
    local url ip
    PUBLIC_IP=""
    if has_cmd curl; then
        for url in "${IP4_APIS[@]}"; do
            ip=$(curl -4 -fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
            if is_ipv4 "$ip"; then
                PUBLIC_IP=$ip
                break
            fi
        done
    fi
    if [[ -z $PUBLIC_IP ]]; then
        PUBLIC_IP=$EGRESS_IP
        log_warn "公网 IP 检测失败，使用网卡地址 ${EGRESS_IP}"
    fi
    if [[ $PUBLIC_IP != "$EGRESS_IP" ]]; then
        log_info "公网 IP: ${PUBLIC_IP} (服务器位于 NAT 之后，已启用 NAT-T)"
    else
        log_info "公网 IP: ${PUBLIC_IP}"
    fi
}

# ----------------------------------------------------------------------------
# 冲突检查
# ----------------------------------------------------------------------------
stop_vpn_services() {
    local svc
    for svc in xl2tpd ipsec; do
        if systemctl cat "${svc}.service" >/dev/null 2>&1; then
            systemctl stop "${svc}.service" >/dev/null 2>&1 || true
        fi
    done
}

check_conflicts() {
    log_step "检查端口与服务冲突"
    local svc port
    for svc in strongswan strongswan-starter strongswan-swanctl; do
        if systemctl is-active --quiet "${svc}.service" 2>/dev/null; then
            die "检测到 ${svc} 正在运行，与 libreswan 冲突；请先执行: systemctl disable --now ${svc}"
        fi
    done
    stop_vpn_services
    sleep 1
    for port in "$IKE_PORT" "$NATT_PORT" "$L2TP_PORT"; do
        if udp_bound "$port"; then
            die "UDP 端口 ${port} 已被占用 (进程: $(udp_owner "$port"))，请先停止相关服务"
        fi
    done
    log_info "UDP ${IKE_PORT} / ${NATT_PORT} / ${L2TP_PORT} 可用"
}

# ----------------------------------------------------------------------------
# 配置生成
# ----------------------------------------------------------------------------
write_ipsec_config() {
    local setup_extra="" conn_extra="" phase2
    phase2="aes_gcm-null,aes128-sha1,aes256-sha1,aes256-sha2_512,aes128-sha2,aes256-sha2"
    # 32 位 ARM 内核缺少 sha512 时去掉对应算法
    if [[ $ARCH == arm* ]] && ! modprobe -q sha512 2>/dev/null; then
        phase2=${phase2/,aes256-sha2_512/}
    fi
    # 版本差异: 4.2+ 支持 ikev1-policy (5.x 默认 drop，需显式 accept)；
    #           5.x 以 keyexchange= 取代 ikev2=，并忽略 dpdaction=
    if swan_at_least 4 2; then
        setup_extra+=$'\n  ikev1-policy=accept'
    fi
    if swan_at_least 5 0; then
        conn_extra+=$'\n  keyexchange=ikev1'
    else
        conn_extra+=$'\n  ikev2=never'
        conn_extra+=$'\n  dpdaction=clear'
    fi

    backup_foreign "$IPSEC_CONF"
    write_file "$IPSEC_CONF" 644 <<EOF
# ${MARKER_TEXT} v${SCRIPT_VERSION} - regenerated on every run, do not edit
# Logging disabled (logfile=/dev/null)
version 2.0

config setup${setup_extra}
  virtual-private=%v4:10.0.0.0/8,%v4:192.168.0.0/16,%v4:172.16.0.0/12,%v4:!${VPN_CIDR}
  uniqueids=no
  logfile=/dev/null

conn shared
  left=%defaultroute
  leftid=${PUBLIC_IP}
  right=%any
  encapsulation=yes
  authby=secret
  pfs=no
  rekey=no
  dpddelay=30
  dpdtimeout=300${conn_extra}
  ike=aes256-sha2;modp2048,aes128-sha2;modp2048,aes256-sha1;modp2048,aes128-sha1;modp2048
  phase2alg=${phase2}
  ikelifetime=24h
  salifetime=24h
  sha2-truncbug=no

conn ${CONN_NAME}
  auto=add
  leftprotoport=17/${L2TP_PORT}
  rightprotoport=17/%any
  type=transport
  also=shared
EOF

    backup_foreign "$IPSEC_SECRETS"
    write_file "$IPSEC_SECRETS" 600 <<EOF
# ${MARKER_TEXT}
%any %any : PSK "${VPN_PSK}"
EOF
}

check_ipsec_config() {
    local out
    if out=$(ipsec addconn --config "$IPSEC_CONF" --checkconfig 2>&1); then
        log_info "IPsec 配置校验通过"
        return 0
    fi
    if [[ $out == *nrecognized* || $out == *nknown\ option* || $out == *sage:* ]]; then
        log_warn "当前 libreswan 不支持离线配置校验，跳过"
        return 0
    fi
    log_error "IPsec 配置校验失败:"
    printf '%s\n' "$out" >&2
    if [[ $out == *[Ii][Kk][Ee][Vv]1* ]]; then
        log_error "当前 libreswan 可能在编译时禁用了 IKEv1 (L2TP/IPsec 必需)，请更换发行版或使用官方源码构建的 libreswan"
    fi
    exit 1
}

write_l2tp_config() {
    backup_foreign "$XL2TPD_CONF"
    write_file "$XL2TPD_CONF" 644 <<EOF
; ${MARKER_TEXT} v${SCRIPT_VERSION} - regenerated on every run, do not edit
[global]
port = ${L2TP_PORT}

[lns default]
ip range = ${VPN_POOL}
local ip = ${VPN_LOCAL_IP}
require chap = yes
refuse pap = yes
require authentication = yes
name = ${PPP_SERVER_NAME}
pppoptfile = ${PPP_OPTIONS}
length bit = yes
EOF

    local dns_lines="ms-dns ${DNS1}"
    if [[ -n $DNS2 ]]; then
        dns_lines+=$'\n'"ms-dns ${DNS2}"
    fi
    backup_foreign "$PPP_OPTIONS"
    write_file "$PPP_OPTIONS" 644 <<EOF
# ${MARKER_TEXT} v${SCRIPT_VERSION} - regenerated on every run, do not edit
# Peer must authenticate (MS-CHAPv2 preferred; xl2tpd adds auth/require-chap)
+mschap-v2
auth
ipcp-accept-local
ipcp-accept-remote
# Encryption is provided by IPsec; disable PPP compression/CCP to save CPU and latency
noccp
novj
novjccomp
# MTU/MRU sized for IPsec + L2TP overhead to avoid fragmentation (PPPoE / mobile safe)
mtu ${PPP_MTU}
mru ${PPP_MTU}
# Dead peer detection
lcp-echo-failure 4
lcp-echo-interval 30
connect-delay 5000
${dns_lines}
# No logging
logfile /dev/null
EOF

    backup_foreign "$CHAP_SECRETS"
    write_file "$CHAP_SECRETS" 600 <<EOF
# ${MARKER_TEXT} v${SCRIPT_VERSION} - regenerated on every run, do not edit
# client  server  secret  IP-addresses
"${VPN_USER_NAME}" ${PPP_SERVER_NAME} "${VPN_PASS}" *
EOF
    log_info "已生成 IPsec / xl2tpd / PPP 配置"
}

# ----------------------------------------------------------------------------
# 内核参数 (转发必需项) 与调优 (高并发 / 游戏低延迟)
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

# 写入并即时应用一组 sysctl；结果通过 SYSCTL_APPLIED / SYSCTL_FAILED 输出
apply_sysctl_set() {
    local file=$1 title=$2 tmp item key val path ct_prefix=""
    shift 2
    SYSCTL_APPLIED=0
    SYSCTL_FAILED=0
    if (( $(systemd_version) >= 236 )); then
        ct_prefix="-"
    fi
    tmp=$(mktemp /tmp/l2tp-sysctl.XXXXXX)
    printf '# %s v%s\n# %s\n' "$MARKER_TEXT" "$SCRIPT_VERSION" "$title" >"$tmp"
    for item in "$@"; do
        key=${item%%=*}
        val=${item#*=}
        path=$(sysctl_key_path "$key")
        [[ -e $path ]] || continue
        if printf '%s\n' "$val" >"$path" 2>/dev/null; then
            SYSCTL_APPLIED=$((SYSCTL_APPLIED + 1))
        else
            SYSCTL_FAILED=$((SYSCTL_FAILED + 1))
            continue
        fi
        # 连接跟踪参数依赖模块加载时机，systemd 236+ 用 "-" 前缀忽略开机早期的缺失
        if [[ $key == net.netfilter.* ]]; then
            if [[ -n $ct_prefix ]]; then
                printf '%s%s = %s\n' "$ct_prefix" "$key" "$val" >>"$tmp"
            fi
        else
            printf '%s = %s\n' "$key" "$val" >>"$tmp"
        fi
    done
    install -m 644 "$tmp" "$file"
    rm -f "$tmp"
}

apply_base_sysctl() {
    log_step "开启 IP 转发"
    apply_sysctl_set "$SYSCTL_BASE" "L2TP/IPsec VPN 必需内核参数" \
        "net.ipv4.ip_forward=1" \
        "net.ipv4.conf.all.accept_redirects=0" \
        "net.ipv4.conf.all.send_redirects=0" \
        "net.ipv4.conf.default.accept_redirects=0" \
        "net.ipv4.conf.default.send_redirects=0" \
        "net.ipv4.conf.all.rp_filter=0" \
        "net.ipv4.conf.default.rp_filter=0" \
        "net.ipv4.conf.${EGRESS_IF}.rp_filter=0" \
        "net.ipv4.conf.${EGRESS_IF}.send_redirects=0"
    [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" == "1" ]] \
        || die "无法开启 IPv4 转发 (容器环境需在宿主机开启)"
    log_info "IPv4 转发已开启，持久化: ${SYSCTL_BASE}"
}

load_kernel_modules() {
    local mods=("l2tp_ppp")
    # 内核态 L2TP：数据面不经用户态拷贝，显著降低延迟与 CPU 占用
    if modprobe -q l2tp_ppp 2>/dev/null; then
        log_info "内核态 L2TP (l2tp_ppp) 已加载"
    else
        log_warn "内核不支持 l2tp_ppp，xl2tpd 将使用用户态转发 (性能较低)"
    fi
    if (( TUNED_BBR )); then
        mods+=("tcp_bbr")
    fi
    {
        printf '# %s\n' "$MARKER_TEXT"
        printf '%s\n' "${mods[@]}"
    } | write_file "$MODULES_FILE" 644
}

tune_kernel() {
    log_step "内核网络调优 (高并发 / 游戏低延迟)"
    TUNED=0
    TUNED_BBR=0
    if (( ! OPT_TUNE )); then
        rm -f "$SYSCTL_TUNE"
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
        # 收发缓冲区 (UDP 封装的 ESP / 游戏包高峰不丢包)
        "net.core.rmem_default=1048576"
        "net.core.wmem_default=1048576"
        "net.core.rmem_max=33554432"
        "net.core.wmem_max=33554432"
        "net.core.optmem_max=65536"
        "net.ipv4.tcp_rmem=4096 131072 33554432"
        "net.ipv4.tcp_wmem=4096 65536 33554432"
        "net.ipv4.udp_rmem_min=16384"
        "net.ipv4.udp_wmem_min=16384"
        # 低延迟
        "net.ipv4.tcp_notsent_lowat=16384"
        "net.ipv4.tcp_slow_start_after_idle=0"
        "net.ipv4.tcp_mtu_probing=1"
        "net.ipv4.tcp_fastopen=3"
        # 连接回收与保活
        "net.ipv4.tcp_fin_timeout=15"
        "net.ipv4.tcp_tw_reuse=1"
        "net.ipv4.tcp_keepalive_time=300"
        "net.ipv4.tcp_keepalive_intvl=30"
        "net.ipv4.tcp_keepalive_probes=5"
        # 连接跟踪：NAT 转发大量游戏 UDP 流时防止表满丢包
        "net.netfilter.nf_conntrack_max=1048576"
        "net.netfilter.nf_conntrack_udp_timeout=60"
        "net.netfilter.nf_conntrack_udp_timeout_stream=180"
        "net.netfilter.nf_conntrack_tcp_timeout_established=7200"
    )

    local cur_files
    cur_files=$(cat /proc/sys/fs/file-max 2>/dev/null || echo 0)
    if [[ $cur_files =~ ^[0-9]+$ ]] && (( cur_files < 2097152 )); then
        params+=("fs.file-max=2097152")
    fi

    # BBR + fq：降低排队延迟，提升弱网吞吐
    modprobe tcp_bbr >/dev/null 2>&1 || true
    if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
        TUNED_BBR=1
        params+=("net.core.default_qdisc=fq" "net.ipv4.tcp_congestion_control=bbr")
    fi

    apply_sysctl_set "$SYSCTL_TUNE" "L2TP/IPsec VPN 网络调优 (高并发 / 游戏低延迟)" "${params[@]}"
    TUNED=1
    log_info "已应用 ${SYSCTL_APPLIED} 项内核参数$( (( SYSCTL_FAILED )) && printf '，%s 项不受支持已跳过' "$SYSCTL_FAILED")；持久化: ${SYSCTL_TUNE}"
    if (( TUNED_BBR )); then
        log_info "拥塞控制: BBR + fq"
    else
        log_warn "内核不支持 BBR (需 4.9+)，保持默认拥塞控制"
    fi
}

# ----------------------------------------------------------------------------
# 防火墙 / NAT
# ----------------------------------------------------------------------------
# 探测 iptables 是否支持 policy 匹配 (用于只放行经 IPsec 解封装的 L2TP)
probe_policy_match() {
    local chain="L2TP_PROBE_$$" ok=1
    iptables -w -N "$chain" >/dev/null 2>&1 || return 1
    if iptables -w -A "$chain" -p udp --dport "$L2TP_PORT" -m policy --dir in --pol ipsec -j RETURN >/dev/null 2>&1; then
        ok=0
    fi
    iptables -w -F "$chain" >/dev/null 2>&1 || true
    iptables -w -X "$chain" >/dev/null 2>&1 || true
    return "$ok"
}

write_fw_script() {
    write_file "$FW_SCRIPT" 755 <<EOF
#!/bin/sh
# ${MARKER_TEXT} v${SCRIPT_VERSION}
# L2TP/IPsec VPN firewall & NAT rules (dedicated chains, idempotent)
#   up   : install rules        down : remove rules
VPN_CIDR="${VPN_CIDR}"
FALLBACK_IF="${EGRESS_IF}"
IKE_PORT="${IKE_PORT}"
NATT_PORT="${NATT_PORT}"
L2TP_PORT="${L2TP_PORT}"
IPT="iptables -w"

egress_if() {
    dev=\$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if (\$i == "dev") { print \$(i + 1); exit }}')
    [ -n "\$dev" ] || dev="\$FALLBACK_IF"
    echo "\${dev%%@*}"
}

has_policy() {
    \$IPT -N L2TP_PROBE >/dev/null 2>&1 || return 1
    rc=1
    \$IPT -A L2TP_PROBE -p udp --dport "\$L2TP_PORT" -m policy --dir in --pol ipsec -j RETURN >/dev/null 2>&1 && rc=0
    \$IPT -F L2TP_PROBE >/dev/null 2>&1
    \$IPT -X L2TP_PROBE >/dev/null 2>&1
    return \$rc
}

down() {
    while \$IPT -D INPUT -j L2TP_IN >/dev/null 2>&1; do :; done
    while \$IPT -D FORWARD -j L2TP_FWD >/dev/null 2>&1; do :; done
    while \$IPT -t nat -D POSTROUTING -j L2TP_NAT >/dev/null 2>&1; do :; done
    while \$IPT -t mangle -D FORWARD -j L2TP_MSS >/dev/null 2>&1; do :; done
    \$IPT -F L2TP_IN >/dev/null 2>&1; \$IPT -X L2TP_IN >/dev/null 2>&1
    \$IPT -F L2TP_FWD >/dev/null 2>&1; \$IPT -X L2TP_FWD >/dev/null 2>&1
    \$IPT -t nat -F L2TP_NAT >/dev/null 2>&1; \$IPT -t nat -X L2TP_NAT >/dev/null 2>&1
    \$IPT -t mangle -F L2TP_MSS >/dev/null 2>&1; \$IPT -t mangle -X L2TP_MSS >/dev/null 2>&1
    return 0
}

up() {
    down
    wan=\$(egress_if)
    \$IPT -N L2TP_IN || return 1
    \$IPT -N L2TP_FWD || return 1
    \$IPT -t nat -N L2TP_NAT || return 1
    \$IPT -t mangle -N L2TP_MSS || return 1

    # L2TP must arrive inside IPsec; plain L2TP is dropped
    if has_policy; then
        \$IPT -A L2TP_IN -p udp --dport "\$L2TP_PORT" -m policy --dir in --pol ipsec -j ACCEPT
        \$IPT -A L2TP_IN -p udp --dport "\$L2TP_PORT" -j DROP
    else
        \$IPT -A L2TP_IN -p udp --dport "\$L2TP_PORT" -j ACCEPT
    fi
    \$IPT -A L2TP_IN -p udp -m multiport --dports "\$IKE_PORT,\$NATT_PORT" -j ACCEPT
    \$IPT -A L2TP_IN -p esp -j ACCEPT

    # Forwarding: VPN clients -> Internet and client <-> client (LAN gaming)
    \$IPT -A L2TP_FWD -s "\$VPN_CIDR" -j ACCEPT
    \$IPT -A L2TP_FWD -d "\$VPN_CIDR" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    # NAT to the egress interface
    \$IPT -t nat -A L2TP_NAT -s "\$VPN_CIDR" ! -d "\$VPN_CIDR" -o "\$wan" -j MASQUERADE

    # Clamp TCP MSS to path MTU to avoid fragmentation / black holes
    \$IPT -t mangle -A L2TP_MSS -p tcp --tcp-flags SYN,RST SYN -s "\$VPN_CIDR" -j TCPMSS --clamp-mss-to-pmtu
    \$IPT -t mangle -A L2TP_MSS -p tcp --tcp-flags SYN,RST SYN -d "\$VPN_CIDR" -j TCPMSS --clamp-mss-to-pmtu

    \$IPT -I INPUT 1 -j L2TP_IN
    \$IPT -I FORWARD 1 -j L2TP_FWD
    \$IPT -t nat -I POSTROUTING 1 -j L2TP_NAT
    \$IPT -t mangle -I FORWARD 1 -j L2TP_MSS
}

case "\$1" in
    up)   up ;;
    down) down ;;
    *)    echo "usage: \$0 {up|down}" >&2; exit 2 ;;
esac
EOF
}

write_fw_unit() {
    write_file "$FW_UNIT" 644 <<EOF
# ${MARKER_TEXT} v${SCRIPT_VERSION}
[Unit]
Description=L2TP/IPsec VPN firewall and NAT rules (managed by l2tp.sh)
After=network-online.target firewalld.service ufw.service netfilter-persistent.service iptables.service nftables.service docker.service
Wants=network-online.target
Before=ipsec.service xl2tpd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${FW_SCRIPT} up
ExecStop=${FW_SCRIPT} down
StandardOutput=null
StandardError=null

[Install]
WantedBy=multi-user.target
EOF
}

firewalld_perm() {
    local zone=$1
    shift
    if [[ -n $zone ]]; then
        firewall-cmd --permanent --zone="$zone" "$@"
    else
        firewall-cmd --permanent "$@"
    fi
}

firewalld_direct_rules() {
    # 输出 firewalld direct 规则参数 (每行一条：family table chain priority args...)
    if (( POLICY_MATCH )); then
        printf '%s\n' "ipv4 filter INPUT 0 -p udp --dport ${L2TP_PORT} -m policy --dir in --pol none -j DROP"
    fi
    printf '%s\n' \
        "ipv4 filter FORWARD 0 -s ${VPN_CIDR} -j ACCEPT" \
        "ipv4 filter FORWARD 0 -d ${VPN_CIDR} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT" \
        "ipv4 nat POSTROUTING 0 -s ${VPN_CIDR} ! -d ${VPN_CIDR} -j MASQUERADE" \
        "ipv4 mangle FORWARD 0 -p tcp --tcp-flags SYN,RST SYN -s ${VPN_CIDR} -j TCPMSS --clamp-mss-to-pmtu" \
        "ipv4 mangle FORWARD 0 -p tcp --tcp-flags SYN,RST SYN -d ${VPN_CIDR} -j TCPMSS --clamp-mss-to-pmtu"
}

firewalld_apply() {
    local zone=$1 rule
    local -a args
    firewalld_perm "$zone" --add-service=ipsec >/dev/null 2>&1 \
        || log_warn "firewalld 放行 ipsec 服务失败"
    firewalld_perm "$zone" --add-port="${L2TP_PORT}/udp" >/dev/null 2>&1 \
        || log_warn "firewalld 放行 UDP ${L2TP_PORT} 失败"
    firewalld_perm "$zone" --add-masquerade >/dev/null 2>&1 \
        || log_warn "firewalld 开启 masquerade 失败"
    firewall-cmd --permanent --zone=trusted --add-source="$VPN_CIDR" >/dev/null 2>&1 \
        || log_warn "VPN 网段 ${VPN_CIDR} 已绑定到其他 zone，依赖 direct 规则放行转发"
    while IFS= read -r rule; do
        read -r -a args <<<"$rule"
        if ! firewall-cmd --permanent --direct --query-rule "${args[@]}" >/dev/null 2>&1; then
            firewall-cmd --permanent --direct --add-rule "${args[@]}" >/dev/null 2>&1 \
                || log_warn "firewalld direct 规则添加失败: ${rule}"
        fi
    done < <(firewalld_direct_rules)
    firewall-cmd --reload >/dev/null 2>&1 || die "firewalld 重载失败"
}

firewalld_remove() {
    local zone=$1 cidr=$2 rule
    local -a args
    has_cmd firewall-cmd || return 0
    firewall-cmd --state >/dev/null 2>&1 || return 0
    firewalld_perm "$zone" --remove-service=ipsec >/dev/null 2>&1 || true
    firewalld_perm "$zone" --remove-port="${L2TP_PORT}/udp" >/dev/null 2>&1 || true
    firewalld_perm "$zone" --remove-masquerade >/dev/null 2>&1 || true
    if [[ -n $cidr ]]; then
        firewall-cmd --permanent --zone=trusted --remove-source="$cidr" >/dev/null 2>&1 || true
    fi
    # 删除所有引用 VPN 网段或 L2TP 端口的 direct 规则
    while IFS= read -r rule; do
        if [[ -n $rule && ( ( -n $cidr && $rule == *"$cidr"* ) || $rule == *"--dport ${L2TP_PORT} -m policy"* ) ]]; then
            read -r -a args <<<"$rule"
            firewall-cmd --permanent --direct --remove-rule "${args[@]}" >/dev/null 2>&1 || true
        fi
    done < <(firewall-cmd --permanent --direct --get-all-rules 2>/dev/null || true)
    firewall-cmd --reload >/dev/null 2>&1 || true
}

setup_firewall() {
    log_step "配置防火墙 / NAT 转发"
    POLICY_MATCH=0
    if probe_policy_match; then
        POLICY_MATCH=1
    else
        log_warn "iptables 不支持 policy 匹配，无法限制 L2TP 必须经 IPsec (仍可正常使用)"
    fi

    if has_cmd firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
        FIREWALL_MODE="firewalld"
        FIREWALL_ZONE=$(firewall-cmd --get-zone-of-interface="$EGRESS_IF" 2>/dev/null \
            || firewall-cmd --get-default-zone 2>/dev/null || true)
        # 网段变化时先清理旧规则
        if [[ $PREV_FIREWALL == "firewalld" && -n $PREV_NET && $PREV_NET != "$VPN_NET_PREFIX" ]]; then
            firewalld_remove "$PREV_FW_ZONE" "${PREV_NET}.0/24"
        fi
        # 从 iptables 模式切换过来时撤销旧链
        if [[ -f $FW_UNIT ]]; then
            systemctl disable --now "$FW_UNIT_NAME" >/dev/null 2>&1 || true
            rm -f "$FW_UNIT"
            systemctl daemon-reload
        fi
        firewalld_apply "$FIREWALL_ZONE"
        log_info "firewalld (zone=${FIREWALL_ZONE:-默认}) 已放行 IPsec (UDP ${IKE_PORT}/${NATT_PORT}, ESP) 并开启 NAT 转发"
    else
        FIREWALL_MODE="iptables"
        if [[ $PREV_FIREWALL == "firewalld" ]]; then
            firewalld_remove "$PREV_FW_ZONE" "${PREV_NET:-$VPN_NET_PREFIX}.0/24"
        fi
        write_fw_script
        write_fw_unit
        systemctl daemon-reload
        systemctl enable "$FW_UNIT_NAME" >/dev/null 2>&1
        systemctl restart "$FW_UNIT_NAME" || die "防火墙规则加载失败，请执行 ${FW_SCRIPT} up 查看原因"
        if [[ "$(iptables -w -t nat -S L2TP_NAT 2>/dev/null || true)" != *MASQUERADE* ]]; then
            die "NAT 规则未生效，请执行 ${FW_SCRIPT} up 查看原因"
        fi
        log_info "iptables 专用链已加载 (L2TP_IN / L2TP_FWD / L2TP_NAT / L2TP_MSS)，开机自动恢复"
    fi
}

# ----------------------------------------------------------------------------
# 服务
# ----------------------------------------------------------------------------
write_service_units() {
    log_step "配置系统服务与开机自启"
    local modprobe_bin
    modprobe_bin=$(command -v modprobe || printf '/sbin/modprobe')

    # xl2tpd：前台运行 (-D，日志走 stderr 后丢弃)，内核态 L2TP，自动重启
    write_file "$XL2TPD_UNIT" 644 <<EOF
# ${MARKER_TEXT} v${SCRIPT_VERSION}
[Unit]
Description=xl2tpd L2TP server (managed by l2tp.sh)
After=network-online.target ipsec.service ${FW_UNIT_NAME}
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
RuntimeDirectory=xl2tpd
ExecStartPre=-${modprobe_bin} -q l2tp_ppp
ExecStart=${XL2TPD_BIN} -D -c ${XL2TPD_CONF} -p /run/xl2tpd.pid -C /run/xl2tpd/l2tp-control
ExecReload=/bin/kill -HUP \$MAINPID
Restart=always
RestartSec=2
LimitNOFILE=65536
Nice=-10

# 不保留日志 (含其派生的 pppd)
StandardOutput=null
StandardError=null
LogLevelMax=emerg

[Install]
WantedBy=multi-user.target
EOF

    install -d -m 755 "$IPSEC_DROPIN_DIR"
    write_file "$IPSEC_DROPIN" 644 <<EOF
# ${MARKER_TEXT} v${SCRIPT_VERSION}
[Unit]
After=${FW_UNIT_NAME}
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=2
Nice=-10
# 不保留日志
StandardOutput=null
StandardError=null
LogLevelMax=emerg
EOF

    systemctl daemon-reload
    systemctl enable ipsec.service >/dev/null 2>&1
    systemctl enable xl2tpd.service >/dev/null 2>&1
    log_info "ipsec / xl2tpd 已设为开机自启"
}

init_nss() {
    # libreswan 需要 NSS 数据库；新版服务启动时自动创建，旧版需手动初始化
    ipsec --checknss >/dev/null 2>&1 \
        || ipsec checknss >/dev/null 2>&1 \
        || ipsec initnss >/dev/null 2>&1 \
        || true
}

start_services() {
    log_step "启动服务"
    init_nss
    if ! systemctl restart ipsec.service; then
        log_error "ipsec 服务启动失败，配置自检输出:"
        ipsec addconn --config "$IPSEC_CONF" --checkconfig >&2 || true
        exit 1
    fi
    systemctl restart xl2tpd.service || die "xl2tpd 服务启动失败"

    local i
    for (( i = 0; i < 20; i++ )); do
        if udp_bound "$IKE_PORT" && udp_bound "$NATT_PORT" && udp_bound "$L2TP_PORT"; then
            break
        fi
        sleep 1
    done
}

ipsec_status_text() {
    ipsec status 2>/dev/null || ipsec auto --status 2>/dev/null || true
}

verify_deployment() {
    log_step "部署自检"
    local failed=0 status

    if systemctl is-active --quiet ipsec.service; then
        log_info "ipsec 服务运行中"
    else
        log_error "ipsec 服务未运行"; failed=1
    fi
    if systemctl is-active --quiet xl2tpd.service; then
        log_info "xl2tpd 服务运行中"
    else
        log_error "xl2tpd 服务未运行"; failed=1
    fi

    local port
    for port in "$IKE_PORT" "$NATT_PORT" "$L2TP_PORT"; do
        if udp_bound "$port"; then
            log_info "UDP ${port} 监听中"
        else
            log_error "UDP ${port} 未监听"; failed=1
        fi
    done

    status=$(ipsec_status_text)
    if [[ $status == *"\"${CONN_NAME}\""* ]]; then
        log_info "IPsec 连接配置 ${CONN_NAME} 已加载"
    else
        log_error "IPsec 连接配置 ${CONN_NAME} 未加载"; failed=1
    fi

    if [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)" == "1" ]]; then
        log_info "IPv4 转发已开启"
    else
        log_error "IPv4 转发未开启"; failed=1
    fi

    if [[ $FIREWALL_MODE == "iptables" ]]; then
        if [[ "$(iptables -w -t nat -S L2TP_NAT 2>/dev/null || true)" == *MASQUERADE* ]]; then
            log_info "NAT 转发规则已生效"
        else
            log_error "NAT 转发规则未生效"; failed=1
        fi
    elif [[ $FIREWALL_MODE == "firewalld" ]]; then
        if firewall-cmd ${FIREWALL_ZONE:+--zone="$FIREWALL_ZONE"} --query-masquerade >/dev/null 2>&1; then
            log_info "firewalld NAT 转发已生效"
        else
            log_error "firewalld NAT 转发未生效"; failed=1
        fi
    fi

    if (( failed )); then
        die "自检未通过，请执行: systemctl status ipsec xl2tpd ${FW_UNIT_NAME}"
    fi
}

# ----------------------------------------------------------------------------
# 管理脚本安装
# ----------------------------------------------------------------------------
install_ctl() {
    local self="${BASH_SOURCE[0]:-}" real
    if [[ -n $self && -f $self ]]; then
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
        printf 'bash l2tp.sh'
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
    pad=$(( 13 - width ))
    if (( pad < 1 )); then
        pad=1
    fi
    printf '  %s%*s%s%s%s\n' "$key" "$pad" '' "$color" "$val" "${color:+$C_RESET}"
}

autostart_text() {
    if systemctl is-enabled --quiet ipsec.service 2>/dev/null \
        && systemctl is-enabled --quiet xl2tpd.service 2>/dev/null; then
        printf '已启用'
    else
        printf '未启用'
    fi
}

print_info() {
    local line="================================================================"
    local thin="----------------------------------------------------------------"
    local fw_text
    case $FIREWALL_MODE in
        firewalld) fw_text="firewalld (zone=${FIREWALL_ZONE:-默认})" ;;
        iptables)  fw_text="iptables 专用链 (${FW_UNIT_NAME})" ;;
        *)         fw_text="未知" ;;
    esac

    printf '\n%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
    printf '%s                    L2TP/IPsec VPN 服务信息%s\n' "$C_BOLD" "$C_RESET"
    printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
    kv "操作系统:" "${OS_NAME} (${ARCH})"
    kv "IPsec:" "libreswan ${SWAN_VERSION:-未知}"
    kv "L2TP:" "xl2tpd ${XL2TPD_VERSION:-未知} ($( [[ $XL2TPD_ORIGIN == "source" ]] && printf '源码编译' || printf '系统软件包'))"
    kv "出口网卡:" "${EGRESS_IF:-未知}${EGRESS_IP:+ (${EGRESS_IP})}"
    printf '%s\n' "$thin"
    kv "服务器地址:" "${PUBLIC_IP:-未检测到}" "$C_CYAN"
    kv "IPsec PSK:" "$VPN_PSK" "$C_CYAN"
    kv "用户名:" "$VPN_USER_NAME" "$C_CYAN"
    kv "密码:" "$VPN_PASS" "$C_CYAN"
    kv "VPN 类型:" "L2TP/IPsec PSK (预共享密钥)，允许任意来源 IP 连接"
    kv "端口:" "UDP ${IKE_PORT} / ${NATT_PORT} (IPsec)，UDP ${L2TP_PORT} (L2TP，仅经 IPsec)"
    kv "客户端网段:" "${VPN_CIDR} (网关 ${VPN_LOCAL_IP})"
    kv "DNS:" "${DNS1}${DNS2:+, $DNS2}"
    kv "MTU/MRU:" "$PPP_MTU"
    printf '%s\n' "$thin"
    kv "服务管理:" "systemctl {start|stop|restart|status} ipsec xl2tpd"
    kv "开机自启:" "$(autostart_text)"
    kv "防火墙:" "$fw_text"
    kv "查看信息:" "$(ctl_hint) info"
    kv "状态/在线:" "$(ctl_hint) status"
    kv "卸载:" "$(ctl_hint) uninstall"
    kv "配置文件:" "${IPSEC_CONF} ${XL2TPD_CONF} ${CHAP_SECRETS}"
    kv "日志:" "不保留"
    printf '%s%s%s\n' "$C_GREEN" "$line" "$C_RESET"
    printf '%s  提示: 云服务器安全组需放行 UDP %s 与 %s (UDP %s 无需对外放行)%s\n' \
        "$C_YELLOW" "$IKE_PORT" "$NATT_PORT" "$L2TP_PORT" "$C_RESET"
    printf '%s  Windows: 服务器在 NAT 后 (云主机) 时，需以管理员身份执行一次并重启:%s\n' "$C_YELLOW" "$C_RESET"
    printf '    REG ADD HKLM\\SYSTEM\\CurrentControlSet\\Services\\PolicyAgent /v AssumeUDPEncapsulationContextOnSendRule /t REG_DWORD /d 0x2 /f\n'
    printf '%s  Android 12+ 已移除系统 L2TP，需使用第三方客户端；iOS / macOS 选择 "L2TP"，密钥填 PSK%s\n' "$C_YELLOW" "$C_RESET"
    printf '%s  游戏: 内核态转发 + MSS 钳制防分片；同一 VPN 内客户端可直接互访 (局域网联机)%s\n\n' "$C_YELLOW" "$C_RESET"
}

# ----------------------------------------------------------------------------
# 命令实现
# ----------------------------------------------------------------------------
cmd_install() {
    log_step "环境识别"
    detect_os
    detect_init
    log_info "操作系统: ${OS_NAME} (ID=${OS_ID}, 版本=${OS_VERSION:-未知}, 系列=${OS_FAMILY})"
    log_info "系统架构: ${ARCH}，内核 $(uname -r)，CPU $(cpu_count) 核，包管理器: ${PKG_MGR}"
    check_virtualization
    load_state
    FIREWALL_MODE=$PREV_FIREWALL
    FIREWALL_ZONE=$PREV_FW_ZONE
    XL2TPD_ORIGIN=$PREV_XL2TPD_ORIGIN
    resolve_settings
    record_preinstalled
    # 尽早落盘部署状态，保证中途失败时 uninstall 仍能完整清理
    save_state

    install_packages
    save_state
    detect_versions
    detect_egress
    detect_public_ip
    check_conflicts

    write_ipsec_config
    check_ipsec_config
    write_l2tp_config
    save_state

    apply_base_sysctl
    tune_kernel
    load_kernel_modules
    setup_firewall
    save_state

    write_service_units
    start_services
    install_ctl
    verify_deployment
    print_info
}

load_runtime_from_state() {
    detect_os
    detect_init
    load_state
    [[ -n $PREV_USER ]] || die "未找到部署信息 (${STATE_FILE})，请先执行安装"
    VPN_USER_NAME=$PREV_USER
    VPN_PASS=$PREV_PASS
    VPN_PSK=$PREV_PSK
    VPN_NET_PREFIX=${PREV_NET:-$DEFAULT_NET}
    VPN_CIDR="${VPN_NET_PREFIX}.0/24"
    VPN_LOCAL_IP="${VPN_NET_PREFIX}.1"
    validate_dns "${PREV_DNS:-$DEFAULT_DNS}"
    PPP_MTU=${PREV_MTU:-$DEFAULT_MTU}
    FIREWALL_MODE=$PREV_FIREWALL
    FIREWALL_ZONE=$PREV_FW_ZONE
    XL2TPD_ORIGIN=$PREV_XL2TPD_ORIGIN
    if [[ -n $EGRESS_IF ]] && has_cmd ip; then
        EGRESS_IP=$(iface_addr "$EGRESS_IF" || true)
    fi
    local out
    out=$(ipsec --version 2>&1 || true)
    if [[ $out =~ [Ll]ibreswan[^0-9]*([0-9]+)\.([0-9]+) ]]; then
        SWAN_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
    fi
    local b
    for b in "$XL2TPD_SRC_BIN" /usr/sbin/xl2tpd; do
        if [[ -x $b ]]; then
            out=$("$b" -v 2>&1 || true)
            if [[ $out =~ xl2tpd-([0-9]+(\.[0-9]+)+) ]]; then
                XL2TPD_VERSION=${BASH_REMATCH[1]}
            fi
            break
        fi
    done
}

cmd_info() {
    load_runtime_from_state
    if ! systemctl is-active --quiet ipsec.service || ! systemctl is-active --quiet xl2tpd.service; then
        log_warn "服务当前未完全运行，可执行: systemctl restart ipsec xl2tpd"
    fi
    print_info
}

cmd_status() {
    load_runtime_from_state
    local svc port clients
    for svc in ipsec xl2tpd "${FW_UNIT_NAME%.service}"; do
        if ! systemctl cat "${svc}.service" >/dev/null 2>&1; then
            continue
        fi
        if systemctl is-active --quiet "${svc}.service"; then
            log_info "服务 ${svc}: 运行中 (开机自启: $(systemctl is-enabled "${svc}.service" 2>/dev/null || true))"
        else
            log_error "服务 ${svc}: 未运行"
        fi
    done
    for port in "$IKE_PORT" "$NATT_PORT" "$L2TP_PORT"; do
        if udp_bound "$port"; then
            log_info "UDP ${port}: 监听中"
        else
            log_warn "UDP ${port}: 未监听"
        fi
    done

    clients=$(ip -4 -o addr show 2>/dev/null \
        | awk '$2 ~ /^ppp/ { for (i = 1; i < NF; i++) if ($i == "peer") { split($(i + 1), a, "/"); print $2 " -> " a[1] } }' || true)
    if [[ -n $clients ]]; then
        log_info "在线客户端 ($(wc -l <<<"$clients" | tr -d ' ') 个):"
        printf '    %s\n' "${clients//$'\n'/$'\n'    }"
    else
        log_info "在线客户端: 0"
    fi
    local traffic
    traffic=$(ipsec trafficstatus 2>/dev/null || ipsec whack --trafficstatus 2>/dev/null || true)
    if [[ -n $traffic ]]; then
        log_info "IPsec 会话:"
        printf '%s\n' "$traffic"
    fi
}

cmd_restart() {
    load_runtime_from_state
    if [[ $FIREWALL_MODE == "iptables" ]]; then
        systemctl restart "$FW_UNIT_NAME"
    fi
    systemctl restart ipsec.service
    systemctl restart xl2tpd.service
    sleep 1
    if systemctl is-active --quiet ipsec.service && systemctl is-active --quiet xl2tpd.service; then
        log_info "服务已重启"
    else
        die "服务重启失败，请执行: systemctl status ipsec xl2tpd"
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

# 删除本脚本生成的文件；若存在安装前的备份则还原最近一份
remove_or_restore() {
    local f=$1 b latest=""
    if ! is_managed_file "$f"; then
        return 0
    fi
    for b in "$f".bak.*; do
        if [[ -e $b ]]; then
            latest=$b
        fi
    done
    if [[ -n $latest ]]; then
        mv -f "$latest" "$f"
        log_info "已还原原有文件: ${f}"
    else
        rm -f "$f"
    fi
}

cmd_uninstall() {
    detect_os
    detect_init
    load_state
    confirm "确认卸载 L2TP/IPsec VPN (含配置、防火墙规则、调优配置)?" || die "已取消卸载"

    log_step "停止并移除服务"
    if [[ $PREV_XL2TPD_PRE == "1" ]]; then
        systemctl stop xl2tpd.service >/dev/null 2>&1 || true
    else
        systemctl disable --now xl2tpd.service >/dev/null 2>&1 || true
    fi
    if [[ $PREV_SWAN_PRE == "1" ]]; then
        systemctl stop ipsec.service >/dev/null 2>&1 || true
    else
        systemctl disable --now ipsec.service >/dev/null 2>&1 || true
    fi
    rm -f "$XL2TPD_UNIT" "$IPSEC_DROPIN"
    rmdir "$IPSEC_DROPIN_DIR" 2>/dev/null || true

    log_step "撤销防火墙 / NAT 规则"
    if [[ -f $FW_UNIT ]]; then
        systemctl disable --now "$FW_UNIT_NAME" >/dev/null 2>&1 || true
    fi
    if [[ -x $FW_SCRIPT ]]; then
        "$FW_SCRIPT" down || true
    fi
    rm -f "$FW_UNIT" "$FW_SCRIPT"
    if [[ $PREV_FIREWALL == "firewalld" ]]; then
        firewalld_remove "$PREV_FW_ZONE" "${PREV_NET:-$DEFAULT_NET}.0/24"
    fi
    systemctl daemon-reload || true
    systemctl reset-failed >/dev/null 2>&1 || true

    log_step "移除配置文件"
    remove_or_restore "$IPSEC_CONF"
    remove_or_restore "$IPSEC_SECRETS"
    remove_or_restore "$XL2TPD_CONF"
    remove_or_restore "$PPP_OPTIONS"
    remove_or_restore "$CHAP_SECRETS"

    log_step "移除内核参数配置"
    rm -f "$SYSCTL_BASE" "$SYSCTL_TUNE" "$MODULES_FILE"
    if has_cmd sysctl; then
        sysctl --system >/dev/null 2>&1 || true
    fi
    log_info "已删除 (IP 转发等运行时参数在重启后恢复系统默认)"

    log_step "卸载软件"
    if [[ $PREV_XL2TPD_ORIGIN == "source" ]]; then
        rm -f "$XL2TPD_SRC_BIN" "$XL2TPD_SRC_CTL"
        log_info "已删除源码编译的 xl2tpd"
    elif [[ $PREV_XL2TPD_PRE != "1" ]] && pkg_installed xl2tpd; then
        pkg_remove xl2tpd || log_warn "xl2tpd 卸载失败，可手动卸载"
        log_info "已卸载 xl2tpd"
    fi
    if [[ $PREV_SWAN_PRE != "1" ]] && pkg_installed libreswan; then
        pkg_remove libreswan || log_warn "libreswan 卸载失败，可手动卸载"
        log_info "已卸载 libreswan"
    fi

    # 部署前已存在的 IPsec / L2TP 服务：已还原其原有配置，恢复运行
    local svc
    for svc in ipsec xl2tpd; do
        if [[ ( $svc == "ipsec" && $PREV_SWAN_PRE == "1" ) || ( $svc == "xl2tpd" && $PREV_XL2TPD_PRE == "1" ) ]]; then
            if systemctl is-enabled --quiet "${svc}.service" 2>/dev/null; then
                systemctl restart "${svc}.service" >/dev/null 2>&1 \
                    || log_warn "${svc} 为部署前已有服务，按原配置重启失败，请手动检查"
            fi
            log_info "${svc} 为部署前已有软件，已保留并还原原有配置"
        fi
    done

    rm -rf "$STATE_DIR"
    rm -f "$CTL_PATH"
    log_info "卸载完成"
}

main() {
    parse_args "$@"
    # 首行输出版本号，便于确认下载到的不是 CDN 缓存的旧脚本
    printf '%sL2TP/IPsec VPN 一键部署脚本 v%s%s\n' "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET"
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

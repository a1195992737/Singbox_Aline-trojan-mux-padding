#!/bin/sh
#===============================================================================
#  sing-box-lite  ·  Trojan + TLS + Mux + Padding
#  面向 Alpine / 低内存 VPS 的精简安装脚本
#
#  设计目标：只做一件事——跑好一个 Trojan 服务端
#    · 单进程、单配置文件，无 nginx / 无 cloudflared(Argo) / 无订阅服务
#    · 无 jq / 无 bash 依赖，Alpine 上只需 openssl
#    · 用 GOMEMLIMIT 约束 Go 堆上限，从根本上避免小内存机器被 OOM 杀进程
#    · OpenRC / systemd 均支持，崩了自动拉起
#
#  用法：
#    sh sb.sh               交互式安装；已安装则显示节点信息
#    sh sb.sh install       重新安装 / 覆盖
#    sh sb.sh info          查看节点信息
#    sh sb.sh clients       只输出客户端配置片段（Mihomo / sing-box）
#    sh sb.sh restart       重启
#    sh sb.sh log           查看日志
#    sh sb.sh update        升级内核
#    sh sb.sh upgrade       更新脚本自身
#    sh sb.sh renew         重签自签证书
#    sh sb.sh uninstall     卸载
#
#  非交互安装（可写在自动化里）：
#    SB_PORT=443 SB_PASS=xxx SB_SNI=www.bing.com SB_NAME=HK SB_NONINTERACTIVE=1 sh sb.sh
#    SB_MEMLIMIT=48MiB  覆盖内存上限（默认按物理内存自动推算）
#    SB_VERSION=1.14.4  固定内核版本（默认取最新）
#===============================================================================

SCRIPT_VER='1.1.0'
# 脚本自身的下载地址：`curl ... | sh` 时 $0 不是文件，装 sb 命令 / sb upgrade 都靠它
# 换仓库或换分支时只改这一行
SCRIPT_URL="${SB_SCRIPT_URL:-https://raw.githubusercontent.com/a1195992737/Singbox_Aline-trojan-mux-padding/main/sb.sh}"
WORK_DIR='/etc/sing-box'
CORE="$WORK_DIR/sing-box"
CONF="$WORK_DIR/config.json"
CERT="$WORK_DIR/cert.pem"
KEY="$WORK_DIR/key.pem"
LOGFILE="$WORK_DIR/sing-box.log"
NODEFILE="$WORK_DIR/.node"
INIT_FILE=''
INIT_TYPE=''
ARCH=''
OS_NAME=''
DEFAULT_VER='1.14.4'
# 仅用于生成客户端配置片段；服务端 inbound 的 multiplex 只认 enabled/padding
SB_MUX_MAXCONN="${SB_MUX_MAXCONN:-8}"
SB_MUX_MINSTR="${SB_MUX_MINSTR:-16}"
GH_MIRRORS='|https://ghproxy.lvedong.eu.org/|https://ghfast.top/|https://gh-proxy.com/'

# ---------- 输出 ----------
R=$(printf '\033[31;1m'); G=$(printf '\033[32;1m'); Y=$(printf '\033[33;1m')
B=$(printf '\033[36;1m'); W=$(printf '\033[37;1m'); N=$(printf '\033[0m')
info() { printf '%s\n' "${G}$*${N}"; }
hint() { printf '%s\n' "${Y}$*${N}"; }
warn() { printf '%s\n' "${R}[!] $*${N}"; }
die()  { printf '%s\n' "${R}[x] $*${N}"; exit 1; }
hr()   { printf '%s\n' "${B}------------------------------------------------------------${N}"; }

# ---------- 环境探测 ----------
need_root() {
    [ "$(id -u)" -eq 0 ] || die '请用 root 运行'
}

detect_os() {
    if [ -f /etc/alpine-release ]; then
        OS_NAME="Alpine $(cat /etc/alpine-release)"
        INIT_TYPE='openrc'
    elif command -v systemctl >/dev/null 2>&1; then
        OS_NAME=$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release 2>/dev/null)
        INIT_TYPE='systemd'
    elif command -v rc-service >/dev/null 2>&1; then
        OS_NAME='OpenRC'
        INIT_TYPE='openrc'
    else
        die '不支持的系统：需要 Alpine(OpenRC) 或 systemd'
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   ARCH='amd64' ;;
        aarch64|arm64)  ARCH='arm64' ;;
        armv7l|armv7)   ARCH='armv7' ;;
        *) die "不支持的架构：$(uname -m)" ;;
    esac
    # Alpine 走 musl 静态版，不依赖 glibc
    case "$OS_NAME" in Alpine*) ARCH="$ARCH-musl" ;; esac
}

# ---------- 网络 ----------
# fetch <超时秒> <url>  —— 优先 curl，退回 busybox wget
fetch() {
    _to=$1; _u=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time "$_to" "$_u" 2>/dev/null
    else
        wget -q --no-check-certificate -T "$_to" -t 1 -O - "$_u" 2>/dev/null
    fi
}

# dl <github 上的路径> <输出文件>  —— 依次尝试直连与多个加速镜像
dl() {
    _path=$1; _out=$2
    _ifs=$IFS
    IFS='|'
    for _m in $GH_MIRRORS; do
        IFS=$_ifs
        _url="${_m}https://github.com/${_path}"
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --max-time 300 -o "$_out" "$_url" 2>/dev/null
        else
            wget -q --no-check-certificate -T 60 -t 1 -O "$_out" "$_url" 2>/dev/null
        fi
        [ -s "$_out" ] && return 0
    done
    IFS=$_ifs
    return 1
}

get_latest_ver() {
    [ -n "$SB_VERSION" ] && { printf '%s' "$SB_VERSION"; return; }
    _v=$(fetch 8 'https://api.github.com/repos/SagerNet/sing-box/releases/latest' \
         | sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' | head -1)
    [ -z "$_v" ] && _v=$(fetch 8 'https://github.com/SagerNet/sing-box/releases.atom' \
         | sed -n 's#.*/tag/v\([^"]*\)".*#\1#p' | head -1)
    [ -z "$_v" ] && _v="$DEFAULT_VER"
    printf '%s' "$_v"
}

# ---------- 依赖 ----------
ensure_cmd() {
    # $1 = 命令, $2 = apk 包名, $3 = apt/dnf 包名
    command -v "$1" >/dev/null 2>&1 && return 0
    hint "安装依赖：$2"
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache "$2" >/dev/null 2>&1
    elif command -v apt-get >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$3" >/dev/null 2>&1
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y "$3" >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
        yum install -y "$3" >/dev/null 2>&1
    fi
    command -v "$1" >/dev/null 2>&1
}

ensure_deps() {
    # 只需要 openssl 签自签证书；wget/tar/sha256sum 在 Alpine 的 busybox 里自带
    ensure_cmd openssl openssl openssl || die 'openssl 安装失败'
    if ! command -v wget >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
        ensure_cmd wget wget wget || die '缺少 wget/curl'
    fi
}

# ---------- 参数 ----------
valid_pass() {
    case "$1" in
        ''|*[!A-Za-z0-9._~-]*) return 1 ;;
        *) [ ${#1} -ge 8 ] && return 0 || return 1 ;;
    esac
}

gen_pass() {
    # 32 位十六进制，纯 ASCII，链接里无需转义
    od -An -tx1 -N16 /dev/urandom 2>/dev/null | tr -d ' \n'
}

valid_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_sni() {
    case "$1" in
        ''|*[!A-Za-z0-9.-]*) return 1 ;;
    esac
    case "$1" in
        *.*) return 0 ;;
        *) return 1 ;;
    esac
}

port_in_use() {
    if command -v ss >/dev/null 2>&1; then
        ss -lntu 2>/dev/null | awk '{print $5}' | grep -q ":$1\$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -lntu 2>/dev/null | awk '{print $4}' | grep -q ":$1\$"
    else
        return 1
    fi
}

ask() {
    # ask <提示> <默认值> <变量名> [校验函数]
    _prompt=$1; _def=$2
    if [ "$SB_NONINTERACTIVE" = '1' ]; then
        eval "$3=\"\$_def\""
        return 0
    fi
    _i=0
    while :; do
        if [ -n "$_def" ]; then
            printf '%s %s[%s]%s: ' "${W}${_prompt}${N}" "$Y" "$_def" "$N"
        else
            printf '%s: ' "${W}${_prompt}${N}"
        fi
        IFS= read -r _in <&3 || _in=''
        [ -z "$_in" ] && _in=$_def
        if [ -z "$4" ] || "$4" "$_in"; then
            eval "$3=\"\$_in\""
            return 0
        fi
        _i=$((_i+1))
        warn '输入无效，请重试'
        [ "$_i" -ge 5 ] && die '输入错误次数过多'
    done
}

input_params() {
    # 环境变量值不合法时静默丢回默认值，避免非交互安装被卡住
    valid_port "$SB_PORT" || SB_PORT=''
    valid_pass "$SB_PASS" || SB_PASS=''

    ask 'Trojan 监听端口' "${SB_PORT:-443}" SB_PORT valid_port
    valid_sni "$SB_SNI" || SB_SNI='addons.mozilla.org'
    ask '证书伪装域名(SNI)' "$SB_SNI" SB_SNI valid_sni
    if [ -n "$SB_PASS" ]; then
        PASS="$SB_PASS"
    else
        _def=$(gen_pass)
        ask 'Trojan 密码(8位以上字母数字)' "$_def" PASS valid_pass
    fi
    ask '节点名称' "${SB_NAME:-Trojan-$(hostname 2>/dev/null || echo node)}" NODE_NAME ''

    if port_in_use "$SB_PORT"; then
        warn "端口 $SB_PORT 已被占用，请确认是否被其他程序使用"
    fi
}

# ---------- 证书 ----------
gen_cert() {
    _sni=$1
    openssl ecparam -genkey -name prime256v1 -out "$KEY" 2>/dev/null || die '生成私钥失败'
    chmod 600 "$KEY"
    openssl req -new -x509 -days 3650 -key "$KEY" -out "$CERT" \
        -subj "/CN=$_sni" -addext "subjectAltName=DNS:$_sni" 2>/dev/null \
        || die '生成证书失败'
    chmod 644 "$CERT"
}

cert_sha256() {
    openssl x509 -noout -fingerprint -sha256 -in "$CERT" 2>/dev/null | sed 's/.*=//; s/://g' | tr 'A-Z' 'a-z'
}

# 客户端 pin 用：证书公钥的 sha256(base64)，等价于 sing-box 的 certificate_public_key_sha256
cert_pin() {
    openssl x509 -pubkey -noout -in "$CERT" 2>/dev/null \
        | openssl pkey -pubin -outform der 2>/dev/null \
        | openssl dgst -sha256 -binary 2>/dev/null | base64 | tr -d '\n'
}

# ---------- 内存上限 ----------
mem_limit() {
    [ -n "$SB_MEMLIMIT" ] && { printf '%s' "$SB_MEMLIMIT"; return; }
    _kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
    [ -z "$_kb" ] && { printf '96MiB'; return; }
    _mb=$((_kb / 1024))
    if   [ "$_mb" -le 192 ];  then printf '48MiB'
    elif [ "$_mb" -le 256 ];  then printf '64MiB'
    elif [ "$_mb" -le 512 ];  then printf '128MiB'
    elif [ "$_mb" -le 1024 ]; then printf '192MiB'
    else                           printf '256MiB'
    fi
}

# ---------- 配置文件 ----------
listen_addr() {
    # 没有 IPv6 的机器上 listen "::" 会导致绑定失败，退化为 0.0.0.0
    if [ -s /proc/net/if_inet6 ]; then printf '::'; else printf '0.0.0.0'; fi
}

write_conf() {
    _listen=$(listen_addr)
    # 节点名写进 .node 时会被 source，去掉引号避免破坏赋值
    NODE_NAME_SAFE=$(printf '%s' "$NODE_NAME" | tr -d "'\"\\\\")
    # SB_PADDING=0 可关闭 padding（客户端不支持 mux 填充时用）
    case "${SB_PADDING:-1}" in
        0|false|off|no) _pad='false' ;;
        *)              _pad='true'  ;;
    esac
    cat > "$CONF" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "dns": {
    "servers": [
      { "type": "local", "tag": "local" }
    ],
    "strategy": "prefer_ipv4"
  },
  "inbounds": [
    {
      "type": "trojan",
      "tag": "trojan-in",
      "listen": "$_listen",
      "listen_port": $SB_PORT,
      "users": [
        { "name": "user", "password": "$PASS" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SB_SNI",
        "alpn": [ "h2", "http/1.1" ],
        "certificate_path": "$CERT",
        "key_path": "$KEY"
      },
      "multiplex": {
        "enabled": true,
        "padding": $_pad
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF
    chmod 600 "$CONF"

    cat > "$NODEFILE" <<EOF
SB_PORT=$SB_PORT
SB_PASS='$PASS'
SB_SNI='$SB_SNI'
SB_NODE_NAME='$NODE_NAME_SAFE'
SB_MEM='$MEM_LIMIT'
SB_PADDING='$_pad'
SB_MUX_MAXCONN='$SB_MUX_MAXCONN'
SB_MUX_MINSTR='$SB_MUX_MINSTR'
EOF
    chmod 600 "$NODEFILE"
}

# ---------- 守护 ----------
write_service() {
    if [ "$INIT_TYPE" = 'openrc' ]; then
        INIT_FILE='/etc/init.d/sing-box'
        _sup=''
        if [ -x /sbin/supervise-daemon ]; then
            _sup='supervisor="supervise-daemon"
respawn_delay="10"
respawn_period="3600"
respawn_max="0"'
        else
            _sup='command_background="yes"'
        fi

        cat > "$INIT_FILE" <<EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box (trojan only)"

command="$CORE"
command_args="run -c $CONF"
pidfile="/run/sing-box.pid"
output_log="$LOGFILE"
error_log="$LOGFILE"
rc_ulimit="-n 65535"
$_sup

# 约束 Go 堆上限：小内存机器被 OOM 杀掉的主因就是堆无节制增长
export GOMEMLIMIT="$MEM_LIMIT"

depend() {
    need net
    after firewall
}

start_pre() {
    mkdir -p /run "$WORK_DIR"
    # 日志超过 1MB 自动清空，避免长期运行把根分区写满
    if [ -f "$LOGFILE" ]; then
        _sz=\$(wc -c < "$LOGFILE" 2>/dev/null || echo 0)
        [ "\$_sz" -gt 1048576 ] && : > "$LOGFILE"
    fi
    rm -f "\$pidfile"
}
EOF
        chmod +x "$INIT_FILE"
    else
        INIT_FILE='/etc/systemd/system/sing-box.service'
        cat > "$INIT_FILE" <<EOF
[Unit]
Description=sing-box (trojan only)
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
User=root
Type=simple
WorkingDirectory=$WORK_DIR
Environment="GOMEMLIMIT=$MEM_LIMIT"
LimitNOFILE=65535
ExecStart=$CORE run -c $CONF
Restart=always
RestartSec=10
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
    fi
}

svc() {
    _a=$1
    if [ "$INIT_TYPE" = 'openrc' ]; then
        rc-service sing-box "$_a" >/dev/null 2>&1
    else
        systemctl "$_a" sing-box >/dev/null 2>&1
    fi
}

svc_enable() {
    if [ "$INIT_TYPE" = 'openrc' ]; then
        rc-update add sing-box default >/dev/null 2>&1
    else
        systemctl enable sing-box >/dev/null 2>&1
    fi
}

svc_running() {
    if [ "$INIT_TYPE" = 'openrc' ]; then
        rc-service sing-box status >/dev/null 2>&1
    else
        systemctl is-active --quiet sing-box
    fi
}

svc_pid() {
    pidof sing-box 2>/dev/null | awk '{print $1}'
}

# ---------- 旧版清理 ----------
# 从 fscarmen/sing-box 全家桶迁移过来时，把 nginx / argo / 多协议配置停掉并改名备份
cleanup_legacy() {
    _legacy=''
    [ -d "$WORK_DIR/conf" ] && _legacy=1
    [ -s "$WORK_DIR/cloudflared" ] && _legacy=1
    [ -s "$WORK_DIR/nginx.conf" ] && _legacy=1
    if [ -f /etc/init.d/argo ] || [ -f /etc/systemd/system/argo.service ]; then _legacy=1; fi
    [ -n "$_legacy" ] || return 0

    hint '检测到旧版全协议安装，清理 nginx / argo / 订阅等无关组件 ...'

    # 1. argo (cloudflared) 服务
    if [ "$INIT_TYPE" = 'openrc' ]; then
        rc-service argo stop >/dev/null 2>&1
        rc-update del argo default >/dev/null 2>&1
        rm -f /etc/init.d/argo
    else
        systemctl stop argo >/dev/null 2>&1
        systemctl disable argo >/dev/null 2>&1
        rm -f /etc/systemd/system/argo.service
        systemctl daemon-reload >/dev/null 2>&1
    fi
    [ -x "$WORK_DIR/cloudflared" ] && mv -f "$WORK_DIR/cloudflared" "$WORK_DIR/cloudflared.bak"
    # 2. 本项目自管的 nginx（只杀带本项目配置路径的进程，不动系统 nginx）
    if [ -s "$WORK_DIR/nginx.conf" ]; then
        for _np in $(ps -eo pid,args 2>/dev/null | awk -v p="$WORK_DIR/nginx.conf" '$0 ~ p && /nginx/ {print $1}'); do
            kill -TERM "$_np" 2>/dev/null
        done
        mv -f "$WORK_DIR/nginx.conf" "$WORK_DIR/nginx.conf.bak"
    fi

    # 3. 旧的多协议配置与订阅目录，整体改名备份（不删，可回退）
    for _d in conf subscribe; do
        [ -d "$WORK_DIR/$_d" ] || continue
        if [ -e "$WORK_DIR/$_d.bak" ]; then
            mv -f "$WORK_DIR/$_d" "$WORK_DIR/$_d.bak.$(date +%s)"
        else
            mv -f "$WORK_DIR/$_d" "$WORK_DIR/$_d.bak"
        fi
    done

    info '旧组件已停用，原文件保留为 *.bak'
}

# ---------- 安装 ----------
do_install() {
    need_root; detect_os; detect_arch

    hr
    printf '%s\n' "${B} sing-box-lite 安装${N}"
    printf '%s\n' " 系统：$OS_NAME   架构：$ARCH"
    hr

    ensure_deps
    input_params
    MEM_LIMIT=$(mem_limit)

    mkdir -p "$WORK_DIR"
    chmod 700 "$WORK_DIR"

    # 1. 内核
    VER=$(get_latest_ver)
    if [ -x "$CORE" ] && [ "$SB_FORCE_CORE" != '1' ]; then
        _cur=$("$CORE" version 2>/dev/null | awk '/version/{print $3}')
        hint "已存在内核 v${_cur:-未知}，跳过下载（重新安装请加 SB_FORCE_CORE=1）"
    else
        hint "下载 sing-box v${VER} (linux-${ARCH}) ..."
        _tmp="$WORK_DIR/.dl"
        rm -f "$_tmp"
        dl "SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-${ARCH}.tar.gz" "$_tmp" \
            || die '内核下载失败，请检查网络或设置 SB_VERSION 换个版本'
        tar xzf "$_tmp" -C "$WORK_DIR" 2>/dev/null \
            || die '内核解压失败'
        _bin="$WORK_DIR/sing-box-${VER}-linux-${ARCH}/sing-box"
        [ -s "$_bin" ] || die '压缩包内未找到 sing-box 可执行文件'
        mv -f "$_bin" "$CORE"
        chmod +x "$CORE"
        rm -rf "$_tmp" "$WORK_DIR/sing-box-${VER}-linux-${ARCH}"
        info "内核已就位：v$("$CORE" version 2>/dev/null | awk '/version/{print $3}')"
    fi

    # 2. 证书
    if [ -s "$CERT" ] && [ -s "$KEY" ]; then
        _old=$(openssl x509 -noout -ext subjectAltName -in "$CERT" 2>/dev/null | sed -n 's/.*DNS:\([^,]*\).*/\1/p')
        if [ "$_old" != "$SB_SNI" ]; then
            hint "SNI 变更（$_old -> $SB_SNI），重签证书"
            gen_cert "$SB_SNI"
        fi
    else
        hint '生成自签证书 ...'
        gen_cert "$SB_SNI"
    fi

    # 3. 清掉旧版的大组件，再写配置与守护
    cleanup_legacy
    write_conf
    write_service

    # 4. 校验并启动
    if ! "$CORE" check -c "$CONF" >/dev/null 2>&1; then
        warn '配置校验失败：'
        "$CORE" check -c "$CONF"
        die '安装中止'
    fi

    svc stop >/dev/null 2>&1
    sleep 1
    svc_enable
    svc start
    sleep 2

    if svc_running; then
        info "安装完成，sing-box 已启动"
        hint "别忘了在云厂商安全组 / 防火墙放行 TCP $SB_PORT"
    else
        warn '服务未能启动，日志如下：'
        tail -n 20 "$LOGFILE" 2>/dev/null
        die '请根据日志排查'
    fi
    show_info
}

# ---------- 信息展示 ----------
get_ip() {
    _ip=''
    for _u in 'https://api.ipify.org' 'https://ipv4.icanhazip.com' 'https://ifconfig.me/ip'; do
        _ip=$(fetch 5 "$_u" | tr -d ' \r\n')
        case "$_ip" in
            *[!0-9.]*|'') _ip='' ;;
            *) break ;;
        esac
    done
    [ -z "$_ip" ] && _ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
    [ -z "$_ip" ] && _ip='<你的服务器IP>'
    printf '%s' "$_ip"
}

# trojan:// 链接没有定义 mux/smux 字段，客户端也不会从链接里读，
# 所以服务端强制的 h2mux + padding 只能通过配置片段下发
print_clients() {
    _cip=${1:-$SB_SNI}
    _cproto='h2mux'
    _cmax=${SB_MUX_MAXCONN:-8}
    _cmin=${SB_MUX_MINSTR:-16}
    if [ "${SB_PADDING:-true}" = 'false' ]; then _cpad='false'; else _cpad='true'; fi

    hr
    printf '%s\n' "${W}客户端配置${N}（服务端启用了 mux，这类参数写不进 trojan 链接，需按下面配置）"
    hr

    printf '%s\n' '[Mihomo / Clash Meta] proxy 段'
    cat <<EOF
- name: "$SB_NODE_NAME"
  type: trojan
  server: $_cip
  port: $SB_PORT
  password: "$SB_PASS"
  sni: $SB_SNI
  skip-cert-verify: true
  udp: true
  smux:
    enabled: true
    protocol: $_cproto
    max-connections: $_cmax
    min-streams: $_cmin
    padding: $_cpad
EOF

    printf '\n%s\n' '[sing-box 客户端] outbounds 段'
    cat <<EOF
{
  "type": "trojan",
  "tag": "proxy",
  "server": "$_cip",
  "server_port": $SB_PORT,
  "password": "$SB_PASS",
  "tls": { "enabled": true, "server_name": "$SB_SNI", "insecure": true },
  "multiplex": { "enabled": true, "protocol": "$_cproto", "max_connections": $_cmax, "min_streams": $_cmin, "padding": $_cpad }
}
EOF

    printf '\n%s\n' "${Y}说明：${N}h2mux + padding 是 sing-box 的扩展，Xray 系（v2rayN/v2rayNG/Shadowrocket）不支持，只能用 sing-box 内核或 Mihomo。"
}

show_info() {
    [ -s "$NODEFILE" ] || { warn '尚未安装，请先运行：sh sb.sh install'; return 0; }
    . "$NODEFILE"

    _ip=$(get_ip)
    _st='未运行'
    svc_running && _st='运行中'

    _rss='-'
    _p=$(svc_pid)
    if [ -n "$_p" ] && [ -r "/proc/$_p/status" ]; then
        _rss=$(awk '/VmRSS/{printf "%.1f MB", $2/1024}' "/proc/$_p/status")
    fi

    _ver=$("$CORE" version 2>/dev/null | awk '/version/{print $3}')

    hr
    printf '%s\n' "${G} sing-box-lite 节点信息${N}"
    hr
    printf ' %s：%s\n' '服务状态' "$_st"
    printf ' %s：%s\n' '内核版本' "v${_ver:-?}"
    printf ' %s：%s\n' '内存占用' "$_rss（堆上限 ${SB_MEM:-?}）"
    printf ' %s：%s\n' '监听端口' "$SB_PORT"
    printf ' %s：%s\n' '密码' "$SB_PASS"
    printf ' %s：%s\n' '伪装域名' "$SB_SNI"
    if [ "$SB_PADDING" = 'false' ]; then
        printf ' %s：%s\n' '多路复用' 'h2mux（padding 关）'
    else
        printf ' %s：%s\n' '多路复用' 'h2mux（padding 开）'
    fi
    hr

    _name=$(printf '%s' "$SB_NODE_NAME" | sed 's/ /%20/g')
    _uri="trojan://${SB_PASS}@${_ip}:${SB_PORT}?security=tls&sni=${SB_SNI}&type=tcp&allowInsecure=1#${_name}"
    printf '%s\n' "${W}节点链接（Trojan）${N}"
    printf '%s\n\n' "$_uri"
    if [ "$SB_PADDING" != 'false' ]; then
        printf '%s\n' "${Y}注意：${N}这条链接不含 mux 参数，直接导入的配置不带 mux，握手会被服务端拒绝。"
        printf '%s\n' "      请按下面的片段配置客户端；或 SB_PADDING=0 sh sb.sh install 关掉 padding。"
    fi
    print_clients "$_ip"
    printf '%s\n' "${Y}提示：${N}客户端若支持“证书指纹/公钥”，比 allowInsecure=1 更安全："
    printf '  SHA256(证书)   : %s\n' "$(cert_sha256)"
    printf '  SHA256(公钥b64): %s\n' "$(cert_pin)"
    hr
    printf '%s\n' " 管理：sb info | sb clients | sb restart | sb log | sb update | sb uninstall"
    hr

    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 "$_uri" 2>/dev/null
    fi
}

# ---------- 子命令 ----------
do_restart() {
    need_root; detect_os
    [ -s "$CONF" ] || die '尚未安装'
    svc restart
    sleep 2
    svc_running && info '已重启' || die '重启失败，查看 sb log'
}

do_log() {
    [ -s "$LOGFILE" ] || { warn '暂无日志'; return 0; }
    tail -n "${1:-40}" "$LOGFILE"
}

do_clients() {
    [ -s "$NODEFILE" ] || die '尚未安装'
    . "$NODEFILE"
    print_clients "$(get_ip)"
}

do_update() {
    need_root; detect_os; detect_arch
    [ -x "$CORE" ] || die '尚未安装'
    _cur=$("$CORE" version 2>/dev/null | awk '/version/{print $3}')
    _new=$(get_latest_ver)
    if [ "$_cur" = "$_new" ] && [ "$SB_FORCE_UPDATE" != '1' ]; then
        info "已是最新版本 v$_cur"
        return 0
    fi
    hint "升级 v$_cur -> v$_new"
    _tmp="$WORK_DIR/.dl"
    dl "SagerNet/sing-box/releases/download/v${_new}/sing-box-${_new}-linux-${ARCH}.tar.gz" "$_tmp" \
        || die '下载失败'
    tar xzf "$_tmp" -C "$WORK_DIR" 2>/dev/null || die '解压失败'
    _bin="$WORK_DIR/sing-box-${_new}-linux-${ARCH}/sing-box"
    [ -s "$_bin" ] || die '压缩包内未找到可执行文件'
    cp -f "$CORE" "$WORK_DIR/.bak"
    mv -f "$_bin" "$CORE"
    chmod +x "$CORE"
    rm -rf "$_tmp" "$WORK_DIR/sing-box-${_new}-linux-${ARCH}"

    svc restart
    sleep 3
    if svc_running; then
        rm -f "$WORK_DIR/.bak"
        info "已升级到 v$_new"
    else
        warn '新版本启动失败，回滚'
        mv -f "$WORK_DIR/.bak" "$CORE"
        chmod +x "$CORE"
        svc restart
        die '已回滚到 v'"$_cur"
    fi
}

do_renew() {
    need_root; detect_os
    [ -s "$NODEFILE" ] || die '尚未安装'
    . "$NODEFILE"
    gen_cert "$SB_SNI"
    svc restart
    sleep 2
    info '证书已重签（客户端需重新确认指纹）'
    show_info
}

do_uninstall() {
    need_root; detect_os
    printf '%s' "${R}确认卸载 sing-box 及全部配置？[y/N]: ${N}"
    if [ "$SB_NONINTERACTIVE" != '1' ]; then
        IFS= read -r _c <&3 || _c=''
        case "$_c" in y|Y|yes) ;; *) info '已取消'; return 0 ;; esac
    fi
    svc stop >/dev/null 2>&1
    if [ "$INIT_TYPE" = 'openrc' ]; then
        rc-update del sing-box default >/dev/null 2>&1
        rm -f /etc/init.d/sing-box
    else
        systemctl disable sing-box >/dev/null 2>&1
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
    fi
    rm -rf "$WORK_DIR" /usr/local/bin/sb
    info '卸载完成'
}

do_clean() {
    need_root
    _list=$(ls -1d "$WORK_DIR"/*.bak* 2>/dev/null)
    [ -n "$_list" ] || { info '没有可清理的备份文件'; return 0; }
    warn '以下旧版备份将被删除：'
    printf '%s\n' "$_list"
    if [ "$SB_NONINTERACTIVE" != '1' ]; then
        printf '%s' "${R}确认删除？[y/N]: ${N}"
        IFS= read -r _c <&3 || _c=''
        case "$_c" in y|Y|yes) ;; *) info '已取消'; return 0 ;; esac
    fi
    for _f in $_list; do
        rm -rf "$_f"
    done
    info '清理完成'
}

do_install_alias() {
    # 装个 sb 快捷命令，指向脚本自身的副本
    _target="$WORK_DIR/sb.sh"
    _r=$(readlink -f "$0" 2>/dev/null); [ -n "$_r" ] || _r="$0"

    # 1) 已经是通过 sb 命令 / 服务目录里的副本在跑，重新指一下链接即可
    if [ "$_r" = '/usr/local/bin/sb' ] || [ "$_r" = "$_target" ]; then
        [ -s "$_target" ] || return 0
        chmod +x "$_target" 2>/dev/null
        ln -sf "$_target" /usr/local/bin/sb 2>/dev/null
        return 0
    fi

    # 2) 从本地脚本文件运行（sh sb.sh）：拷一份
    if [ -f "${0}" ] && cp -f "$0" "$_target" 2>/dev/null; then
        chmod +x "$_target"
        ln -sf "$_target" /usr/local/bin/sb 2>/dev/null
        info '已安装命令：sb'
        return 0
    fi

    # 3) curl ... | sh：$0 是 sh 本身，从仓库拉一份
    hint '获取脚本副本（用于 sb 命令）'
    fetch 30 "$SCRIPT_URL" > "$_target.tmp" 2>/dev/null
    if [ -s "$_target.tmp" ] && head -n 1 "$_target.tmp" | grep -q '^#!'; then
        mv -f "$_target.tmp" "$_target"
        chmod +x "$_target"
        ln -sf "$_target" /usr/local/bin/sb 2>/dev/null
        info '已安装命令：sb'
    else
        rm -f "$_target.tmp"
        warn "未能获取脚本副本，sb 命令暂不可用；可手动下载：$SCRIPT_URL"
    fi
}

do_upgrade() {
    need_root
    [ -d "$WORK_DIR" ] || die '尚未安装'
    hint '从仓库获取最新脚本 ...'
    _tmp="$WORK_DIR/.sb.new"
    rm -f "$_tmp"
    fetch 30 "$SCRIPT_URL" > "$_tmp" 2>/dev/null
    [ -s "$_tmp" ] || { rm -f "$_tmp"; die "下载失败：$SCRIPT_URL"; }
    if ! sh -n "$_tmp" 2>/dev/null; then
        rm -f "$_tmp"
        die '下载到的脚本语法检查失败，已放弃替换'
    fi
    _old=$(awk -F"'" '/^SCRIPT_VER=/{print $2; exit}' "$WORK_DIR/sb.sh" 2>/dev/null)
    _new=$(awk -F"'" '/^SCRIPT_VER=/{print $2; exit}' "$_tmp")
    mv -f "$_tmp" "$WORK_DIR/sb.sh"
    chmod +x "$WORK_DIR/sb.sh"
    ln -sf "$WORK_DIR/sb.sh" /usr/local/bin/sb 2>/dev/null
    info "脚本已更新：v${_old:-?} -> v${_new:-?}（内核与配置未动）"
}

menu() {
    while :; do
        hr
        printf '%s\n' "${B} 1${N}) 查看节点   ${B}2${N}) 重启   ${B}3${N}) 更新内核   ${B}4${N}) 重签证书   ${B}5${N}) 卸载   ${B}6${N}) 更新脚本   ${B}0${N}) 退出"
        printf '选择: '
        IFS= read -r _c <&3 || _c='0'
        case "$_c" in
            1) show_info ;;
            2) do_restart ;;
            3) do_update ;;
            4) do_renew ;;
            5) do_uninstall; exit 0 ;;
            6) do_upgrade ;;
            0|'') exit 0 ;;
            *) warn '无效选项' ;;
        esac
    done
}

usage() {
    cat <<'EOF'
 sing-box-lite — Trojan + Mux + Padding 精简安装脚本

 用法: sb <命令>
   install     安装 / 覆盖安装
   info        查看节点信息与运行状态
   clients     只输出客户端配置片段（Mihomo / sing-box，含 smux）
   restart     重启服务
   log [n]     查看最近 n 行日志
   update      升级 sing-box 内核
   upgrade     更新脚本自身（从仓库重新拉取）
   renew       重签自签证书
   uninstall   卸载
   clean       清理旧版遗留的 *.bak 备份
   (无参数)    未安装则安装，已安装则显示信息并进入菜单

 环境变量:
   SB_PORT       监听端口，默认 443
   SB_PASS       密码，默认随机生成
   SB_SNI        伪装域名，默认 addons.mozilla.org
   SB_NAME       节点名称
   SB_MEMLIMIT   Go 堆上限，默认按物理内存自动推算
   SB_PADDING    0 = 关闭 padding（兼容不支持填充的客户端），默认开启
   SB_MUX_MAXCONN  客户端建议的最大 Mux 连接数，默认 8
   SB_MUX_MINSTR   客户端建议的单连接最小流数，默认 16
   SB_VERSION    固定内核版本
EOF
}

# ---------- 入口 ----------
main() {
    # 交互输入统一从 /dev/tty 读，兼容 `curl ... | sh` 的用法
    # 注意：无控制终端时（cron / CI）直接打开 /dev/tty 会让非交互 shell 退出，先探一下
    if ( : </dev/tty ) 2>/dev/null; then
        exec 3</dev/tty
    else
        exec 3<&0
    fi

    ACTION=${1:-auto}
    case "$ACTION" in
        -h|--help|help) usage; exit 0 ;;
    esac
    detect_os

    case "$ACTION" in
        install)   do_install; do_install_alias ;;
        info|status) show_info ;;
        restart)   do_restart ;;
        log)       do_log "$2" ;;
        clients|client) do_clients ;;
        update)    do_update ;;
        upgrade|self-update) do_upgrade ;;
        renew)     do_renew ;;
        uninstall|remove) do_uninstall ;;
        clean)     do_clean ;;
        auto)
            if [ -x "$CORE" ] && [ -s "$CONF" ]; then
                show_info
            else
                do_install
                do_install_alias
            fi
            [ "$SB_NONINTERACTIVE" = '1' ] || menu
            ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"

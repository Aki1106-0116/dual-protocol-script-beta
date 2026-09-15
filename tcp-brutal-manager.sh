#!/usr/bin/env bash
set -Eeuo pipefail

# TCP Brutal v2 is destination based. For a Reality proxy, the server's
# destination for client downloads is the client's public IP, so each client IP
# gets its own Brutal group. The server-side beta deliberately does not shape
# upload traffic: the only user-configurable value is this downlink total.

STATE_DIR="${DPS_TCP_BRUTAL_STATE_DIR:-/etc/dual-protocol-script}"
STATE_FILE="${DPS_TCP_BRUTAL_STATE_FILE:-${STATE_DIR}/tcp-brutal.env}"
RUNTIME_DIR="${DPS_TCP_BRUTAL_RUNTIME_DIR:-/run/dual-protocol-script}"
CLIENTS_FILE="${RUNTIME_DIR}/tcp-brutal-clients"
SERVICE_NAME="dual-protocol-tcp-brutal"
BRUTALCTL="${DPS_BRUTALCTL:-/usr/local/bin/brutalctl}"
OFFICIAL_INSTALLER_URL="https://tcp.hy2.sh/"
INSTALL_LOG="${DPS_TCP_BRUTAL_INSTALL_LOG:-/var/log/dual-protocol-script/tcp-brutal-install.log}"
MODULE_NAME="brutal"
MAX_CLIENTS=512

log() { printf '%s\n' "tcp-brutal: $*" >&2; }
warn() { printf 'tcp-brutal: warning: %s\n' "$*" >&2; }
die() { printf 'tcp-brutal: error: %s\n' "$*" >&2; exit 1; }

is_uint() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

valid_rate() {
  local value="${1:-}"
  is_uint "$value" || return 1
  value=$((10#$value))
  (( value >= 1 && value <= 100000 ))
}

write_state() {
  local enabled="$1" down="$2" tmp
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  tmp="$(mktemp "${STATE_FILE}.tmp.XXXXXX")"
  chmod 600 "$tmp"
  printf 'TCP_BRUTAL_ENABLED=%s\nTCP_BRUTAL_DOWN_MBPS=%s\n' \
    "$enabled" "$down" > "$tmp"
  mv -f -- "$tmp" "$STATE_FILE"
  chmod 600 "$STATE_FILE"
}

load_state() {
  TCP_BRUTAL_ENABLED=0
  TCP_BRUTAL_DOWN_MBPS=100
  if [[ -r "$STATE_FILE" ]]; then
    # This file is created atomically by this root-only script.
    # shellcheck disable=SC1090
    source "$STATE_FILE"
  fi
  [[ "${TCP_BRUTAL_ENABLED:-0}" == "0" || "${TCP_BRUTAL_ENABLED:-0}" == "1" ]] || TCP_BRUTAL_ENABLED=0
  valid_rate "${TCP_BRUTAL_DOWN_MBPS:-}" || TCP_BRUTAL_DOWN_MBPS=100
}

resolve_brutalctl() {
  local candidate
  if [[ -n "${DPS_BRUTALCTL:-}" && -x "$DPS_BRUTALCTL" ]]; then
    BRUTALCTL="$DPS_BRUTALCTL"
    return 0
  fi
  for candidate in \
    /usr/local/bin/brutalctl \
    /usr/local/sbin/brutalctl \
    /usr/bin/brutalctl \
    /usr/sbin/brutalctl; do
    if [[ -x "$candidate" ]]; then
      BRUTALCTL="$candidate"
      return 0
    fi
  done
  candidate="$(command -v brutalctl 2>/dev/null || true)"
  if [[ -n "$candidate" && -x "$candidate" ]]; then
    BRUTALCTL="$candidate"
    return 0
  fi
  return 1
}

build_brutalctl_from_source() {
  local source compiler
  resolve_brutalctl && return 0
  source="$(find /usr/src -type f -path '/usr/src/tcp-brutal-*/tools/brutalctl.c' 2>/dev/null \
    | sort -V | tail -n 1 || true)"
  [[ -n "$source" ]] || return 1
  compiler="$(command -v cc 2>/dev/null || command -v gcc 2>/dev/null || true)"
  [[ -n "$compiler" ]] || return 1

  log "官方 DKMS 源码已存在但 brutalctl 缺失，尝试补建 brutalctl"
  if [[ -f "$INSTALL_LOG" ]]; then
    if "$compiler" -O2 -Wall -o /usr/local/bin/brutalctl "$source" >>"$INSTALL_LOG" 2>&1; then
      chmod 755 /usr/local/bin/brutalctl
      log "brutalctl 补建完成"
      resolve_brutalctl
      return 0
    fi
  elif "$compiler" -O2 -Wall -o /usr/local/bin/brutalctl "$source" >/dev/null 2>&1; then
    chmod 755 /usr/local/bin/brutalctl
    log "brutalctl 补建完成"
    resolve_brutalctl
    return 0
  fi
  rm -f -- /usr/local/bin/brutalctl
  warn "brutalctl 补建失败；请检查 C 编译器和 libc 开发头文件"
  return 1
}

install_official_support() {
  local installer installer_rc=0 log_dir
  command -v curl >/dev/null 2>&1 || return 1
  mkdir -p "$RUNTIME_DIR"
  chmod 700 "$RUNTIME_DIR"
  log_dir="$(dirname -- "$INSTALL_LOG")"
  mkdir -p "$log_dir" || return 1
  chmod 700 "$log_dir" || true
  : > "$INSTALL_LOG" || return 1
  chmod 600 "$INSTALL_LOG" || true
  installer="$(mktemp "${RUNTIME_DIR}/tcp-brutal-installer.XXXXXX")" || return 1
  if ! curl -fsSL --retry 3 --retry-delay 2 "$OFFICIAL_INSTALLER_URL" -o "$installer"; then
    rm -f -- "$installer"
    return 1
  fi
  bash "$installer" install --force >>"$INSTALL_LOG" 2>&1 || installer_rc=$?
  rm -f -- "$installer"

  # The official installer intentionally treats brutalctl compilation as
  # non-fatal to DKMS. Finish that user-space step here when its source was
  # installed but the binary was not, then let ensure_v2_module validate both
  # the tool and the loaded v2 kernel module.
  build_brutalctl_from_source || true
  if resolve_brutalctl; then
    (( installer_rc == 0 )) || log "官方安装脚本返回 ${installer_rc}，但 brutalctl 已可用；继续检查内核模块"
    return 0
  fi
  warn "官方 TCP Brutal v2 安装未生成 brutalctl；安装日志：$INSTALL_LOG"
  return 1
}

distribution_kernel_packages() {
  local kernel="$1" arch image_package headers_package
  arch="$(dpkg --print-architecture 2>/dev/null || true)"
  case "${OS_ID:-}" in
    debian)
      case "$arch:$kernel" in
        amd64:*cloud*) image_package="linux-image-cloud-amd64"; headers_package="linux-headers-cloud-amd64" ;;
        arm64:*cloud*) image_package="linux-image-cloud-arm64"; headers_package="linux-headers-cloud-arm64" ;;
        amd64:*) image_package="linux-image-amd64"; headers_package="linux-headers-amd64" ;;
        arm64:*) image_package="linux-image-arm64"; headers_package="linux-headers-arm64" ;;
        *) return 1 ;;
      esac
      ;;
    ubuntu)
      image_package="linux-image-generic"
      headers_package="linux-headers-generic"
      ;;
    *)
      return 1
      ;;
  esac
  printf '%s\n%s\n' "$image_package" "$headers_package"
}

install_distribution_kernel() {
  local kernel="$1" image_package headers_package
  local -a packages
  [[ "${DPS_AUTO_INSTALL_TCP_BRUTAL_KERNEL:-1}" == "1" ]] || return 1
  command -v apt-get >/dev/null 2>&1 || return 1
  [[ -r /etc/os-release ]] || return 1
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  mapfile -t packages < <(distribution_kernel_packages "$kernel")
  (( ${#packages[@]} == 2 )) || return 1
  image_package="${packages[0]}"
  headers_package="${packages[1]}"
  log "当前内核 ${kernel} 没有精确匹配 headers，自动安装发行版内核 ${image_package} 和 headers ${headers_package}"
  apt-get update -qq >/dev/null 2>&1 || return 1
  if DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$image_package" "$headers_package"; then
    log "已自动安装 ${image_package} 和 ${headers_package}"
    return 0
  fi
  return 1
}

current_kernel_has_headers() {
  [[ -d "/lib/modules/$(uname -r)/build" ]]
}

ensure_v2_module() {
  local allow_install="${1:-0}" need_install=0 kernel
  resolve_brutalctl || need_install=1
  current_kernel_has_headers || need_install=1
  [[ -r "/sys/module/${MODULE_NAME}/version" ]] || need_install=1
  if (( need_install == 1 )) && [[ "$allow_install" == "1" ]]; then
    log "未找到完整的 TCP Brutal v2 支持，按当前网页启用请求自动重试官方安装"
    kernel="$(uname -r)"
    if ! current_kernel_has_headers; then
      install_distribution_kernel "$kernel" || true
      current_kernel_has_headers || die "当前运行内核 ${kernel} 没有匹配 headers；已尝试自动安装发行版内核和 headers，请重启进入新内核后再开启 TCP Brutal"
    fi
    install_official_support || true
  fi
  resolve_brutalctl || die "未找到 brutalctl（官方安装脚本应将它安装到 /usr/local/bin/brutalctl）；请检查 C 编译器、libc 开发头文件、DKMS/内核头文件和安装日志：$INSTALL_LOG"
  if [[ ! -r "/sys/module/${MODULE_NAME}/version" ]]; then
    command -v modprobe >/dev/null 2>&1 || die "未找到 modprobe，无法加载 TCP Brutal 内核模块"
    modprobe "$MODULE_NAME" || die "无法加载 TCP Brutal 内核模块"
  fi
  local version major
  version="$(cat "/sys/module/${MODULE_NAME}/version" 2>/dev/null || true)"
  major="${version%%.*}"
  major="${major#v}"
  is_uint "$major" && (( 10#$major >= 2 )) || {
    die "当前 TCP Brutal 模块不是 v2（检测到 ${version:-unknown}）"
  }
}

endpoint_ip() {
  local endpoint="$1"
  case "$endpoint" in
    \[*\]:*) endpoint="${endpoint#\[}"; endpoint="${endpoint%\]:*}" ;;
    *.*:*) endpoint="${endpoint%:*}" ;;
    *:*:*)
      [[ "${endpoint##*:}" =~ ^[0-9]+$ ]] && endpoint="${endpoint%:*}" ;;
  esac
  [[ "$endpoint" == *:* || "$endpoint" == *.* ]] && printf '%s\n' "$endpoint"
}

list_clients() {
  local endpoint
  ss -Hnt state established '( sport = :443 )' 2>/dev/null \
    | awk '{print $5}' \
    | while IFS= read -r endpoint; do endpoint_ip "$endpoint"; done \
    | sort -u \
    | head -n "$MAX_CLIENTS"
}

client_prefix() {
  if [[ "$1" == *:* ]]; then
    printf '%s/128\n' "$1"
  else
    printf '%s/32\n' "$1"
  fi
}

runtime_clients() {
  local first second rest
  [[ -r "$CLIENTS_FILE" ]] || return 0
  while IFS='|' read -r first second rest; do
    # Accept the former family|ip|tc-pref format while upgrading. New state
    # contains one IP per line.
    if [[ -n "$second" ]]; then
      printf '%s\n' "$second"
    elif [[ -n "$first" ]]; then
      printf '%s\n' "$first"
    fi
  done < "$CLIENTS_FILE"
}

remove_legacy_filters() {
  local first second pref iface
  [[ -r "$CLIENTS_FILE" ]] || return 0
  iface="${DPS_TCP_BRUTAL_IFACE:-}"
  while IFS='|' read -r first second pref; do
    [[ -n "$pref" ]] || continue
    if [[ -z "$iface" ]]; then
      iface="$(ip -o route get 1.1.1.1 2>/dev/null \
        | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')"
    fi
    [[ -n "$iface" ]] || continue
    command -v tc >/dev/null 2>&1 || return 0
    tc filter del dev "$iface" ingress pref "$pref" >/dev/null 2>&1 || true
  done < "$CLIENTS_FILE"
}

remove_runtime_clients() {
  local ip
  resolve_brutalctl >/dev/null 2>&1 || true
  remove_legacy_filters
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    "$BRUTALCTL" del "$(client_prefix "$ip")" >/dev/null 2>&1 || true
  done < <(runtime_clients)
  rm -f -- "$CLIENTS_FILE"
}

reconcile() {
  load_state
  [[ "$TCP_BRUTAL_ENABLED" == "1" ]] || return 0
  ensure_v2_module

  local clients old_clients signature old_signature ip prefix failed=0
  mkdir -p "$RUNTIME_DIR"
  remove_legacy_filters
  clients="$(list_clients || true)"
  old_clients="$(runtime_clients || true)"
  signature="$(printf '%s\n%s\n' "$TCP_BRUTAL_DOWN_MBPS" "$clients" | sha256sum | awk '{print $1}')"
  old_signature=""
  [[ -r "${RUNTIME_DIR}/tcp-brutal-signature" ]] && old_signature="$(cat "${RUNTIME_DIR}/tcp-brutal-signature")"
  if [[ "$signature" == "$old_signature" ]]; then
    return 0
  fi

  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    if ! grep -Fqx -- "$ip" <<< "$clients"; then
      "$BRUTALCTL" del "$(client_prefix "$ip")" >/dev/null 2>&1 || true
    fi
  done <<< "$old_clients"
  : > "$CLIENTS_FILE"
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    prefix="$(client_prefix "$ip")"
    "$BRUTALCTL" add "$prefix" "$TCP_BRUTAL_DOWN_MBPS" >/dev/null || {
      warn "无法为 $prefix 建立 Brutal 下行规则"
      failed=1
      continue
    }
    printf '%s\n' "$ip" >> "$CLIENTS_FILE"
  done <<< "$clients"
  chmod 600 "$CLIENTS_FILE"
  if (( failed == 0 )); then
    printf '%s\n' "$signature" > "${RUNTIME_DIR}/tcp-brutal-signature"
    chmod 600 "${RUNTIME_DIR}/tcp-brutal-signature"
  else
    rm -f -- "${RUNTIME_DIR}/tcp-brutal-signature"
  fi
}

cleanup() {
  load_state
  remove_runtime_clients
  rm -f -- "${RUNTIME_DIR}/tcp-brutal-signature"
}

apply_config() {
  local mode="reality" enabled="1" down=100
  while (( $# > 0 )); do
    case "$1" in
      --mode) mode="${2:-}"; shift 2 ;;
      --enabled) enabled="${2:-}"; shift 2 ;;
      --down) down="${2:-}"; shift 2 ;;
      *) die "未知参数：$1" ;;
    esac
  done
  [[ "$mode" == "reality" || "$mode" == "xhttp" ]] || die "TCP Brutal 只允许绑定 Reality 节点"
  [[ "$enabled" == "0" || "$enabled" == "1" ]] || die "TCP Brutal 开关参数无效"
  valid_rate "$down" || die "TCP Brutal 每个公网 IP 下行限速必须在 1-100000 Mbps"
  if [[ "$mode" != "reality" && "$enabled" == "1" ]]; then
    die "TCP Brutal 只允许用于 REALITY 节点"
  fi

  if [[ "$enabled" == "1" ]]; then
    ensure_v2_module 1
  fi
  write_state "$enabled" "$down"
  if [[ "$enabled" == "1" ]]; then
    systemctl enable --now "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
  else
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    cleanup
  fi
}

restore_config() {
  load_state
  if [[ "$TCP_BRUTAL_ENABLED" == "1" ]]; then
    ensure_v2_module 1
    systemctl enable --now "$SERVICE_NAME"
    systemctl restart "$SERVICE_NAME"
  else
    systemctl disable --now "$SERVICE_NAME" >/dev/null 2>&1 || true
    cleanup
  fi
}

run_daemon() {
  load_state
  [[ "$TCP_BRUTAL_ENABLED" == "1" ]] || exit 0
  trap cleanup EXIT
  trap 'exit 0' HUP INT TERM
  while true; do
    reconcile || warn "本轮连接规则同步失败，5 秒后重试"
    sleep 5
  done
}

init_state() {
  [[ -e "$STATE_FILE" ]] || write_state 0 100
}

case "${1:-}" in
  init) init_state ;;
  apply) shift; apply_config "$@" ;;
  restore) restore_config ;;
  run) run_daemon ;;
  cleanup) cleanup ;;
  *) die "用法：$0 {init|apply|restore|run|cleanup}" ;;
esac

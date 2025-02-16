#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
TAP_DEVICE="krjakbrjaktap0"
CLOUD_INIT_SERVER="http.server"
CLOUD_INIT_PORT="8000"
CLOUD_INIT_LOG="http.log"
CLOUD_INIT=""

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-f] -t TAP [-c PATH]

Launches a VM and bridges to the TAP interface.

Available options:

-h, --help        Print this help and exit
-v, --verbose     Print script debug info
-t, --tap         Tap device name [default: ${TAP_DEVICE}]
-c, --cloud-init  Path to a folder containing cloud init data (i.e. user-data, etc.)
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
  pkill -f "${CLOUD_INIT_SERVER}"
  rm -fr "${CLOUD_INIT_LOG}"
  docker compose -f dns/docker-compose.yml down
  rm -fr dns
}

die() {
  local msg=$1
  local code=${2-1} # default exit status 1
  echo >&2 -e "$msg"
  exit "$code"
}

parse_params() {
  while :; do
    case "${1-}" in
    -h | --help) usage ;;
    -v | --verbose) set -x ;;
    -t | --tap)
      TAP_DEVICE="${2-}"
      shift
      ;;
    -c | --cloud-init)
      CLOUD_INIT="${2-}"
      shift
      ;;
    -?*) die "Unknown option: $1" ;;
    *) break ;;
    esac
    shift
  done

  args=("$@")

  return 0
}

parse_params "$@"

if ip link show "$TAP_DEVICE" > /dev/null 2>&1; then
  BRIDGE_NAME=$(ip link show "$TAP_DEVICE" | grep -oP '(?<=master )\S+')
  if [ -z "$BRIDGE_NAME" ]; then
    echo "No bridge found for $TAP_DEVICE"
    exit 1
  fi
  IP_INFO=$(ip -o -f inet addr show "$BRIDGE_NAME" | awk '{print $4}')
  IFS='./' read -r a b c d mask <<< "${IP_INFO}"

  mkdir -p dns
  cat <<EOF > dns/dnsmasq.conf
port=0 # Disable DNS server
interface=${TAP_DEVICE}
bind-interfaces
listen-address=${a}.${b}.${c}.${d}
dhcp-range=${a}.${b}.${c}.$((d+1)),${a}.${b}.${c}.$((d+100)),255.255.255.0,12h
dhcp-option=3,${a}.${b}.${c}.${d}  # Gateway
dhcp-option=6,8.8.8.8,1.1.1.1  # DNS
log-queries
log-dhcp
EOF
  cat <<EOF > dns/docker-compose.yml
services:
  dns:
    restart: always
    image: strm/dnsmasq
    volumes:
      - ./dnsmasq.conf:/etc/dnsmasq.conf
    cap_add:
      - NET_ADMIN
    network_mode: host
EOF

  # Start DHCP server
  pushd dns
  docker compose up -d
  popd

  QEMU_CMD=(qemu-system-x86_64 -machine q35 -accel kvm -m 2048 -nographic) # -serial pty) # -display none)
  QEMU_CMD+=(-device virtio-net,netdev=net0,mac=$(printf '02:%02x:%02x:%02x:%02x:%02x\n' $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256)) $((RANDOM%256))))
  QEMU_CMD+=(-netdev tap,id=net0,ifname=${TAP_DEVICE},script=no,downscript=no)
  QEMU_CMD+=(-qmp unix:/tmp/${TAP_DEVICE},server,wait=off)

  if [ -d "${CLOUD_INIT}" ]; then
    # Start serving cloud-init files
    nohup python3 -m "${CLOUD_INIT_SERVER}" "${CLOUD_INIT_PORT}" --bind 0.0.0.0 --directory "${CLOUD_INIT}" > "${CLOUD_INIT_LOG}" 2>&1 &

    LAN_INTERFACE=$(ip route | grep default | awk '{print $5}')
    LAN_IP=$(ip addr show $LAN_INTERFACE | awk '/inet / {print $2}' | cut -d/ -f1)
    QEMU_CMD+=(-smbios type=1,serial=ds="nocloud;s=http://${LAN_IP}:${CLOUD_INIT_PORT}/")
  fi

  IMAGE_FILE="ubuntu-22.04-server-cloudimg-amd64.img"
  if [ ! -f "${IMAGE_FILE}" ]; then
    curl -LO https://cloud-images.ubuntu.com/releases/22.04/release/${IMAGE_FILE}
  fi
  cp ${IMAGE_FILE} ${IMAGE_FILE}-${TAP_DEVICE}

  QEMU_CMD+=(-hda $(pwd)/${IMAGE_FILE}-${TAP_DEVICE})
  QEMU_CMD+=(-cpu host)
  #QEMU_CMD+=(-daemonize)

  # Start the VM
  "${QEMU_CMD[@]}"
else
    echo "Device $TAP_DEVICE not found."
fi

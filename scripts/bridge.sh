#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
SUBNET="192.168.1.0/24"
BRIDGE_NAME="krjakbrjakbr0"
IPTABLES=iptables
UFW=ufw
FIREWALL_SUPPORTED=(${IPTABLES})
FIREWALL_SUPPORTED+=(${UFW})
FIREWALL=${FIREWALL_SUPPORTED[0]}

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-n BRIDG_NAME] [-s SUBNET] [--firewall FIREWALL]

Creates a brdige network and configures firewall rules to allow following communication:
  * host <-> vm
  * vm -> internet

Available options:

-h, --help      Print this help and exit
-v, --verbose   Print script debug info
-n, --name      Bridge name [default: ${BRIDGE_NAME}]
-s, --subnet    A subnet to be assigned to the bridge [default: ${SUBNET}]
--firewall      A firewall to use to enable netwrking for the VMs. Allowed values: ${FIREWALL_SUPPORTED[@]} [default: ${FIREWALL}]
EOF
  exit
}

cleanup() {
  trap - SIGINT SIGTERM ERR EXIT
  # script cleanup here
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
    -n | --name)
      BRIDGE_NAME="${2-}"
      shift
      ;;
    -s | --subnet)
      SUBNET="${2-}"
      shift
      ;;
    --firewall)
      FIREWALL="${2-}"
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

function add_rule() {
  action=$1
  rule=$2
  table=${3:-}
  command="sudo iptables"
  if [ ! -z "${table}" ]; then
    command="${command} -t ${table}"
  fi

  check_command="${command} -C ${rule}"

  # Check if rule exists
  if ${check_command} 2>/dev/null; then
    echo "Rule exists"
  else
    command="${command} ${action} ${rule}"
    ${command}
  fi
}

echo "Configuring the bridge [${BRIDGE_NAME}] with a custom subnet [${SUBNET}]"

# 1. Create the bridge interface (if it doesn't exist)
if ! ip link show ${BRIDGE_NAME} > /dev/null 2>&1; then
  sudo ip link add name ${BRIDGE_NAME} type bridge
  IFS='./' read -r a b c d mask <<< "${SUBNET}"
  sudo ip addr add "$a.$b.$c.1/${mask}" dev ${BRIDGE_NAME}
  sudo ip link set ${BRIDGE_NAME} up
fi

# 2. Configure IP forwarding (if not already enabled)
sudo sysctl -w net.ipv4.ip_forward=1

# 3. Configure iptables for NAT
LAN_INTERFACE=$(ip route | grep default | awk '{print $5}')
add_rule -A "POSTROUTING -o ${LAN_INTERFACE} -j MASQUERADE" nat
add_rule -A "POSTROUTING -j RETURN" nat

case "${FIREWALL}" in
  "${UFW}")
    sudo ufw allow in on ${BRIDGE_NAME} proto udp
    sudo ufw allow in on ${BRIDGE_NAME} proto tcp
    sudo ufw route allow in on ${BRIDGE_NAME} proto udp
    sudo ufw route allow in on ${BRIDGE_NAME} proto tcp
    sudo ufw reload
    ;;
  "${IPTABLES}")
    sudo iptables -I INPUT -i ${BRIDGE_NAME} -p udp -j ACCEPT
    sudo iptables -I INPUT -i ${BRIDGE_NAME} -p tcp -j ACCEPT
    sudo iptables -I FORWARD -i ${BRIDGE_NAME} -p udp -j ACCEPT
    sudo iptables -I FORWARD -i ${BRIDGE_NAME} -p tcp -j ACCEPT
    ;;
  *)
    die "Firewall ${FIREWALL} is not supported."
    ;;
esac

#!/usr/bin/env bash

set -Eeuo pipefail
trap cleanup SIGINT SIGTERM ERR EXIT

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd -P)
BRIDGE_NAME="krjakbrjakbr0"
TAP_DEVICE="krjakbrjaktap0"

usage() {
  cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [-h] [-v] [-n BRIDGE_NAME] [-t TAP_NAME]

Creates a TAP device and attaches it to the bridge network.

Available options:

-h, --help      Print this help and exit
-v, --verbose   Print script debug info
-n, --name      Bridge name [default: ${BRIDGE_NAME}]
-t, --tap       Tap device name [default: ${TAP_DEVICE}]
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
    -t | --tap)
      TAP_DEVICE="${2-}"
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

# 1. Create the tap interface
if ! ip link show ${TAP_DEVICE} > /dev/null 2>&1; then
  sudo ip tuntap add dev ${TAP_DEVICE} mode tap
  sudo ip link set ${TAP_DEVICE} up
fi

# 2. Add the tap interface to the bridge
sudo ip link set ${TAP_DEVICE} master ${BRIDGE_NAME}

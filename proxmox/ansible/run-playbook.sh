#!/bin/bash
set -euxo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  echo "Usage:"
  echo "  ./run-playbook.sh playbooks/playbook-name.yml [ansible options]"
  echo
  echo "Examples:"
  echo "  ./run-playbook.sh playbooks/baseline.yml --limit=lxc"
  exit 1
}

# Must pass in the playbook you want to run
if [[ $# -lt 1 ]]; then
  usage
fi

PLAYBOOK="$1"
shift

# Ensure playbook exists
if [[ ! -f "${SCRIPT_DIR}/${PLAYBOOK}" ]]; then
  echo "ERROR: Playbook not found: ${SCRIPT_DIR}/${PLAYBOOK}"
  exit 1
fi

echo "▶ Running Ansible playbook: ${PLAYBOOK}"
echo


# ansible-playbook "${PLAYBOOK}" "$@"
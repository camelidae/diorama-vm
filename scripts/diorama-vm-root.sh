#!/usr/bin/env bash
# shellcheck shell=bash
# Resolve diorama-vm repository root (directory containing guest/boot.sh).
if [[ -n "${DIORAMA_VM_ROOT:-}" && -f "${DIORAMA_VM_ROOT}/guest/boot.sh" ]]; then
  echo "${DIORAMA_VM_ROOT}"
  exit 0
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if git -C "${root}" rev-parse --show-toplevel &>/dev/null; then
  root="$(git -C "${root}" rev-parse --show-toplevel)"
fi
if [[ ! -f "${root}/guest/boot.sh" ]]; then
  echo "diorama-vm-root: cannot find repo root (missing guest/boot.sh); set DIORAMA_VM_ROOT" >&2
  exit 1
fi
echo "${root}"

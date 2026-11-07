#!/usr/bin/env bash
# shellcheck shell=bash
# Resolve dios repository root (directory containing guest/boot.sh).
if [[ -n "${DIOS_ROOT:-}" && -f "${DIOS_ROOT}/guest/boot.sh" ]]; then
  echo "${DIOS_ROOT}"
  exit 0
fi
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if git -C "${root}" rev-parse --show-toplevel &>/dev/null; then
  root="$(git -C "${root}" rev-parse --show-toplevel)"
fi
if [[ ! -f "${root}/guest/boot.sh" ]]; then
  echo "dios-root: cannot find repo root (missing guest/boot.sh); set DIOS_ROOT" >&2
  exit 1
fi
echo "${root}"

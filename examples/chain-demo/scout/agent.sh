#!/usr/bin/env bash
set -uo pipefail
mkdir -p out
printf '# findings\n\n- disk free: %s\n- load: %s\n- generated: %s\n' \
  "$(df -h / | awk 'NR==2 {print $4}')" \
  "$(uptime | sed 's/.*load aver[^:]*: //')" \
  "$(date -u +%FT%TZ)" > out/findings.md

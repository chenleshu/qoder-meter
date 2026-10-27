#!/bin/bash
# 给所有 .ps1 加 UTF-8 BOM —— PowerShell 5.1 需要 BOM 才能正确读中文字面量
cd "$(dirname "$0")/.." || exit 1
for f in src/*.ps1 probe/*.ps1 tools/*.ps1 *.ps1; do
  [ -f "$f" ] || continue
  if [ "$(head -c 3 "$f" | xxd -p)" != "efbbbf" ]; then
    printf '\xEF\xBB\xBF' > /tmp/.qm_bom
    { cat /tmp/.qm_bom "$f"; } > /tmp/.qm_ps1
    cp /tmp/.qm_ps1 "$f"
    echo "bom: $f"
  fi
done

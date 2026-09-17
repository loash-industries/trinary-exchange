#!/bin/zsh
# Full measurement campaign, strictly sequential (one address, one localnet).
set -uo pipefail
cd "$(dirname "$0")"
LOG=../results/run_all.log
echo "=== campaign start $(date) ===" >> $LOG

for v in A B C16 D32 D64 D64u; do
  echo "--- $v construction $(date) ---" >> $LOG
  python3 driver.py construction $v 300 >> $LOG 2>&1 || echo "!! $v construction FAILED" >> $LOG
  sui client faucet >/dev/null 2>&1; sleep 1
  echo "--- $v steady $(date) ---" >> $LOG
  python3 driver.py steady $v >> $LOG 2>&1 || echo "!! $v steady FAILED" >> $LOG
  sui client faucet >/dev/null 2>&1; sleep 1
done

echo "--- A ceiling $(date) ---" >> $LOG
python3 driver.py ceiling A >> $LOG 2>&1 || echo "!! A ceiling FAILED" >> $LOG

echo "=== campaign done $(date) ===" >> $LOG

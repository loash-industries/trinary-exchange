#!/bin/zsh
set -uo pipefail
cd "$(dirname "$0")"
BUILD=${1:-desc}
LOG=../results/ladder.log
echo "=== ladder campaign ($BUILD) start $(date) ===" >> $LOG
for v in C16u D64u A B; do
  echo "--- $v $(date) ---" >> $LOG
  python3 ladder.py $v $BUILD >> $LOG 2>&1 || echo "!! $v LADDER FAILED" >> $LOG
  sui client faucet >/dev/null 2>&1; sleep 1
done
echo "=== ladder campaign done $(date) ===" >> $LOG

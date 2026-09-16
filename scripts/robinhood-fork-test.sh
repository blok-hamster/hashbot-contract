#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Robinhood Chain fork test runner.
#
#  Robinhood's public gateway serves a SHORT sliding window of state (account/
#  code). The `eth_blockNumber` head is often AHEAD of the actual state window
#  (load-balanced gateways). Pinning a too-recent head fails with
#  "metadata is not found". This script:
#
#  1. Fetches head from eth_blockNumber.
#  2. Probes backwards to find a block whose state the gateway can serve.
#  3. Passes it to Forge via ROBINHOOD_BLOCK.
#
#  For guaranteed stability, point ROBINHOOD_RPC at an archive node.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

RPC="${ROBINHOOD_RPC:-https://rpc.mainnet.chain.robinhood.com}"
# Known long-lived contract on every Robinhood fork (Uniswap V3 factory).
PROBE_ADDR="0x1f7d7550B1b028f7571E69A784071F0205FD2EfA"

rpc_post() {
  curl -s -m 20 -X POST "$RPC" -H 'content-type: application/json' -d "$1"
}

HEX_HEAD="$(rpc_post \
  '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
  | sed 's/.*result":"\(0x[0-9a-fA-F]*\)".*/\1/')"

if [ -z "$HEX_HEAD" ] || [ "$HEX_HEAD" = "0x" ]; then
  echo "error: cannot reach $RPC" >&2
  exit 1
fi

HEAD=$((HEX_HEAD))
echo "RPC head: $HEAD"

# Walk backward in steps and find a state-servable block.
# For each candidate, probe eth_getCode and eth_getBalance — accept only
# if BOTH return non-error results (some blocks pass one probe but not the other).
BLOCK=""
for OFFSET in 100 200 500 1000 2000 3000 5000 10000 20000 50000; do
  CAND=$((HEAD - OFFSET))
  [ "$CAND" -lt 0 ] && break
  CAND_HEX=$(printf '0x%x' "$CAND")
  CODE_RESULT="$(rpc_post \
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"$PROBE_ADDR\",\"$CAND_HEX\"]}")"
  BAL_RESULT="$(rpc_post \
    "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_getBalance\",\"params\":[\"$PROBE_ADDR\",\"$CAND_HEX\"]}")"
  if echo "$CODE_RESULT" | grep -q '"result":"0x[0-9a-f]' && \
     echo "$BAL_RESULT"  | grep -q '"result":"0x[0-9a-f]'; then
    BLOCK="$CAND"
    echo "state-servable block found: $BLOCK ($OFFSET back from head)"
    break
  fi
done

if [ -z "$BLOCK" ]; then
  echo "error: no state-servable block found within 50k of head ($HEAD)" >&2
  echo "hint: point ROBINHOOD_RPC at an archive node for reliable fork tests." >&2
  exit 1
fi

# The public gateway rate-limits mid-run (429) and its state window slides, so a
# pinned block can go stale between probe and execution. Retry with backoff and
# re-probe on failures that smell like the RPC rather than the test itself.
ATTEMPT=0
MAX_ATTEMPTS="${FORK_TEST_ATTEMPTS:-6}"
while [ "$ATTEMPT" -lt "$MAX_ATTEMPTS" ]; do
  ATTEMPT=$((ATTEMPT + 1))
  echo "attempt $ATTEMPT/$MAX_ATTEMPTS (block $BLOCK)"
  if OUT="$(ROBINHOOD_RPC="$RPC" ROBINHOOD_BLOCK="$BLOCK" forge test --match-contract ForkTest "$@" 2>&1)"; then
    echo "$OUT"
    echo "SUCCESS on attempt $ATTEMPT (block $BLOCK)"
    exit 0
  fi
  STATUS=$?
  if [ $STATUS -eq 0 ]; then
    echo "$OUT"
    exit 0
  fi
  if echo "$OUT" | grep -q "429\|Too Many\|sharedbackend\|database error\|metadata is not found\|Unexpected error"; then
    echo "  RPC hiccup, re-probing for a fresh state-servable block..."
    sleep 3
    HEAD_NEW="$(rpc_post \
      '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
      | sed 's/.*result":"\(0x[0-9a-fA-F]*\)".*/\1/')"
    BLOCK=""
    for OFFSET in 100 200 500 1000 2000 5000 10000 20000 50000; do
      CAND=$((HEAD_NEW - OFFSET))
      [ "$CAND" -lt 0 ] && break
      CAND_HEX=$(printf '0x%x' "$CAND")
      CODE_RESULT="$(rpc_post \
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getCode\",\"params\":[\"$PROBE_ADDR\",\"$CAND_HEX\"]}")"
      BAL_RESULT="$(rpc_post \
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_getBalance\",\"params\":[\"$PROBE_ADDR\",\"$CAND_HEX\"]}")"
      if echo "$CODE_RESULT" | grep -q '"result":"0x[0-9a-f]' && \
         echo "$BAL_RESULT"  | grep -q '"result":"0x[0-9a-f]'; then
        BLOCK="$CAND"
        echo "  fresh state-servable block: $BLOCK"
        break
      fi
    done
    if [ -z "$BLOCK" ]; then
      echo "$OUT" >&2
      echo "error: no state-servable block found on retry; RPC may be degraded." >&2
      exit 1
    fi
    continue
  fi
  echo "$OUT" >&2
  exit $STATUS
done

echo "error: still failing after $MAX_ATTEMPTS attempts; last output above." >&2
exit 1

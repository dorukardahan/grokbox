#!/usr/bin/env bash
# Send a test through every configured channel without creating an incident. Exit: 0 ok, 1 failed, 3 unset.
source "$(dirname "$0")/lib.sh"
trap - ERR
if [[ -z "$(alert_channels)" ]]; then
  echo "no alert channel configured: set ALERT_NTFY_URL, ALERT_WEBHOOK_URL or ALERT_HOOK in config.env, then rerun ./test-alert.sh"
  exit 3
fi
rc=0
alert_deliver "TEST ALERT from $BACKUP_HOST: if you can read this, alerting works" test || rc=$?
exit "$rc"

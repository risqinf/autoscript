#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Polling loop for SSH All-Protocol Quota Enforcement
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
while true; do
  /usr/local/sbin/quota-ssh >/dev/null 2>&1 || true
  sleep 8
done

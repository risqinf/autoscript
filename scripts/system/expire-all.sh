#!/usr/bin/env bash
# ========================================================
# Project: Autoscript VPN by risqinf
# Description: Run every protocol's auto-expire pass in one shot.
#              Invoked by the autoexpire.timer systemd unit (no cron).
# License: Apache License 2.0 (see LICENSE file)
# Repository: https://github.com/risqinf/autoscript
# ========================================================
# Each xp-* command is DB-driven and idempotent (safe to run every minute).
xp-ssh
xp-vless
xp-vmess
xp-trojan
xp-noobz
exit 0

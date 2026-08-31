#!/bin/bash
# Passes when vendor/ is in sync with composer.lock. A dry-run install reports
# "Nothing to install, update or remove" when nothing is needed, so a match exits
# 0 (good). Missing or outdated packages list actions instead, exiting non-zero
# (needs attention, so composer install must run).
sail composer install --dry-run --no-scripts --no-interaction 2>&1 \
  | grep -q "Nothing to install, update or remove"

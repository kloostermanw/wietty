#!/bin/bash
# Passes when composer.lock is in sync with composer.json. validate --check-lock
# exits non-zero when the lock is out of date, meaning composer update must run to
# refresh it. --no-check-all and --no-check-publish keep unrelated schema warnings
# from tripping the check, so the exit code reflects only the lock's freshness.
sail composer validate --check-lock --no-check-all --no-check-publish --no-interaction

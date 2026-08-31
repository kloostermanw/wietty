#!/bin/bash
# Passes when no migrations are pending. The --pending option makes migrate:status
# exit with the given value (1) if any migration is still Pending, and 0 otherwise
# (all applied, or none to run). A missing migrations table also exits non-zero.
sail artisan migrate:status --pending=1

#!/bin/sh
set -eu

: "${FAKE_EWW_SNAPSHOTS:?}"
cat "$FAKE_EWW_SNAPSHOTS"

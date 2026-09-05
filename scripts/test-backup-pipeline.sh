#!/usr/bin/env bash
# Bounded synthetic regression; no database, backup files or credentials needed.
set -euo pipefail
producer() { head -c 1048576 /dev/zero; }
early_reader() { head -c 64 >/dev/null; }
checked_reader() {
  local result=0
  "$@" || result=$?
  cat >/dev/null
  return "$result"
}
if producer | early_reader; then
  echo 'Fixture did not reproduce early-consumer pipe failure' >&2
  exit 1
fi
producer | checked_reader early_reader
bad_reader() { head -c 64 >/dev/null; return 7; }
if producer | checked_reader bad_reader; then
  echo 'Reader failure was swallowed' >&2
  exit 1
fi
bad_producer() { producer; return 9; }
if bad_producer | checked_reader early_reader; then
  echo 'Producer/checksum failure was swallowed' >&2
  exit 1
fi
echo 'PASS: early reader drains safely; reader and producer failures propagate'
exit 0

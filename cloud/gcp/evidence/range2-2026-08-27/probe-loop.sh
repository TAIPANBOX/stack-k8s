#!/usr/bin/env bash
SP="$(dirname "$0")"
n="${1:-60}"; i=0
while [ "$i" -lt "$n" ]; do
  i=$((i+1))
  "$SP/probe-once.sh" "$(date -u +%H%M%S)-$i"
  sleep 1
done

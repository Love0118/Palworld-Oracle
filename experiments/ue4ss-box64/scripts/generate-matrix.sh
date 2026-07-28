#!/usr/bin/env bash
set -Eeuo pipefail

printf 'cycle,mode,scenario,replicate,warmup_minutes,measure_minutes,save,shutdown\n'
scenarios=(base_unloaded base_loaded_no_player base_loaded_player_nearby)
cycle=0
for replicate in {1..5}; do
  if (( replicate % 2 == 1 )); then
    modes=(baseline core)
  else
    modes=(core baseline)
  fi
  for scenario in "${scenarios[@]}"; do
    for mode in "${modes[@]}"; do
      (( cycle += 1 ))
      printf '%d,%s,%s,%d,10,20,REST_POST_/save,REST_POST_/shutdown\n' \
        "$cycle" "$mode" "$scenario" "$replicate"
    done
  done
done

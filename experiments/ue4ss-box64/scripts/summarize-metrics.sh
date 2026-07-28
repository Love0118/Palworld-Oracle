#!/usr/bin/env bash
set -Eeuo pipefail

[[ $# == 1 ]] || { printf 'usage: %s metrics.csv\n' "$0" >&2; exit 2; }
[[ -r "$1" ]] || { printf 'metrics file is not readable: %s\n' "$1" >&2; exit 1; }
awk -F, '
  NR == 1 {
    expected="cycle,mode,scenario,serverfps,serverframetime_ms,rss_mib,save_seconds,shutdown_seconds,exit_code,ue4ss_errors,box64_errors"
    if ($0 != expected) { print "unexpected CSV header" > "/dev/stderr"; exit 2 }
    next
  }
  $2 != "baseline" && $2 != "core" { print "invalid mode at line " NR > "/dev/stderr"; exit 2 }
  {
    key=$2 SUBSEP $3
    n[key]++
    fps[key]+=$4; frame[key]+=$5; rss[key]+=$6; save[key]+=$7; stop[key]+=$8
    bad[key]+=($9 != 0); ue[key]+=$10; box[key]+=$11
  }
  END {
    print "mode,scenario,n,mean_fps,mean_frametime_ms,mean_rss_mib,mean_save_seconds,mean_shutdown_seconds,bad_exits,ue4ss_errors,box64_errors"
    for (key in n) {
      split(key, part, SUBSEP)
      printf "%s,%s,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%d,%d,%d\n", \
        part[1],part[2],n[key],fps[key]/n[key],frame[key]/n[key],rss[key]/n[key],save[key]/n[key],stop[key]/n[key],bad[key],ue[key],box[key]
    }
  }
' "$1" | sort

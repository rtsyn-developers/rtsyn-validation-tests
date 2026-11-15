#!/usr/bin/env bash

rtsyn_period_tag() {
    local period_ns="$1"
    if ((period_ns % 1000000 == 0)); then
        printf '%sms' "$((period_ns / 1000000))"
    elif ((period_ns % 1000 == 0)); then
        printf '%sus' "$((period_ns / 1000))"
    else
        printf '%sns' "$period_ns"
    fi
}

rtsyn_validate_period() {
    local period_ns="$1" name="${2:-period}"
    if [[ ! "$period_ns" =~ ^[0-9]+$ ]] || ((period_ns != 100000)); then
        printf 'error: %s is fixed at 100000 ns (100 us / 10 kHz).\n' "$name" >&2
        return 1
    fi
}

#!/usr/bin/env sh
case "$1" in
  *Username*) printf '%s\n' "${GITHUB_USER:-x-access-token}" ;;
  *Password*) printf '%s\n' "${GITHUB_TOKEN:?GITHUB_TOKEN is required}" ;;
  *) printf '\n' ;;
esac

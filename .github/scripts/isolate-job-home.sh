#!/usr/bin/env bash
# Gives a job on the self-hosted Mac minis its own HOME.
#
# Usage: .github/scripts/isolate-job-home.sh
#
# The minis run two runners per machine under one user, and Bun, its install
# cache, and Wrangler all write under ~. Pointing HOME at RUNNER_TEMP (which
# the runner empties after each job) keeps concurrent jobs from sharing those
# files and leaves nothing from a deploy job behind. Later steps see the new
# HOME; actions/cache resolves `~` against it too.
set -euo pipefail

: "${GITHUB_ENV:?GITHUB_ENV is unset; run this from a GitHub Actions step}"
: "${RUNNER_TEMP:?RUNNER_TEMP is unset; run this from a GitHub Actions step}"

job_home="$RUNNER_TEMP/home"
mkdir -p "$job_home"
echo "HOME=$job_home" >> "$GITHUB_ENV"
echo "Job HOME is $job_home on $(hostname -s)"

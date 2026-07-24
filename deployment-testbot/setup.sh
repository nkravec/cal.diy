#!/usr/bin/env bash
# setup.sh — boot the cal.diy SUT stack for the Skyramp Testbot.
#
# The heavy build (yarn install + api-v2 + web builds, into the calcom-build
# volume) runs as a separate workflow step BEFORE the testbot action, via the
# one-shot `calcom-builder` service — see .github/workflows/skyramp-testbot.yml.
# This script only starts the runtime services; readiness is verified by the
# action's targetReadyCheckCommand (API 401 probe + web 200), and the eval user
# + API key are seeded by get-auth-token.sh (the action's authTokenCommand).
#
# Recipe ported from the eval-framework 08-caldiy scenario (proven boot).
set -euo pipefail

docker compose -f docker-compose.eval.yml up -d database redis calcom-api calcom

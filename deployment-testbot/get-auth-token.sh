#!/usr/bin/env bash
# get-auth-token.sh — seed an eval user + API key in cal.diy and output the key.
#
# Flow:
#   1. Compute bcrypt hash of the eval password (inside calcom-api container)
#   2. Compute SHA-256 hash of the raw API key (used as hashedKey in ApiKey table)
#   3. Upsert the eval user and UserPassword via psql in the database container
#   4. Upsert the ApiKey row via psql
#   5. Output "cal_<raw_key>" to stdout → becomes SKYRAMP_TEST_TOKEN
#
# The workspace.yml sets authType: bearer so the executor sends:
#   Authorization: Bearer cal_<raw_key>
#
# Idempotent: re-running is safe (uses INSERT ... ON CONFLICT DO NOTHING).
set -euo pipefail

DB_CONTAINER="${DB_CONTAINER:-database}"
API_CONTAINER="${API_CONTAINER:-calcom-api}"
DB_USER="${DB_USER:-unicorn_user}"
DB_NAME="${DB_NAME:-calendso}"
API_KEY_PREFIX="${API_KEY_PREFIX:-cal_}"

EVAL_EMAIL="eval@skyramp.dev"
EVAL_USERNAME="eval-skyramp"
EVAL_NAME="Skyramp Eval"
EVAL_PASSWORD="Eval1234!"
EVAL_TIMEZONE="America/New_York"
# Fixed raw key — deterministic so re-runs produce the same token
RAW_API_KEY="evalsk00000000000000000000000000"

echo "  [get-auth-token] Seeding eval user: ${EVAL_EMAIL}" >&2

# ── 1. bcrypt hash of the password ──────────────────────────────────────────
BCRYPT_HASH=$(docker exec "$API_CONTAINER" node -e "
const { hashSync } = require('/calcom/node_modules/bcryptjs/dist/bcrypt.js');
process.stdout.write(hashSync('${EVAL_PASSWORD}', 10));
")
echo "  [get-auth-token] Password hashed" >&2

# ── 2. SHA-256 hash of the raw API key ──────────────────────────────────────
HASHED_KEY=$(node -e "
const { createHash } = require('crypto');
process.stdout.write(createHash('sha256').update('${RAW_API_KEY}').digest('hex'));
")
echo "  [get-auth-token] API key hashed" >&2

# ── 3. Upsert user ───────────────────────────────────────────────────────────
docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -q -c \
  "INSERT INTO users (username, name, email, \"timeZone\", \"emailVerified\", \"completedOnboarding\", role, uuid)
   VALUES ('${EVAL_USERNAME}', '${EVAL_NAME}', '${EVAL_EMAIL}', '${EVAL_TIMEZONE}', NOW(), true, 'USER', gen_random_uuid())
   ON CONFLICT (email) DO NOTHING;"
echo "  [get-auth-token] User upserted" >&2

# ── 4. Upsert password ───────────────────────────────────────────────────────
docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -q -c \
  "INSERT INTO \"UserPassword\" (\"userId\", hash)
   SELECT id, '${BCRYPT_HASH}' FROM users WHERE email = '${EVAL_EMAIL}'
   ON CONFLICT (\"userId\") DO NOTHING;"
echo "  [get-auth-token] Password upserted" >&2

# ── 5. Upsert API key ────────────────────────────────────────────────────────
docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -q -c \
  "INSERT INTO \"ApiKey\" (id, \"userId\", \"hashedKey\", note)
   SELECT gen_random_uuid(), id, '${HASHED_KEY}', 'Skyramp eval key'
   FROM users WHERE email = '${EVAL_EMAIL}'
   ON CONFLICT (\"hashedKey\") DO NOTHING;"
echo "  [get-auth-token] API key upserted" >&2

# ── 6. Verify the key resolves ───────────────────────────────────────────────
VERIFY=$(docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -tAq -c \
  "SELECT u.email FROM \"ApiKey\" k JOIN users u ON k.\"userId\" = u.id WHERE k.\"hashedKey\" = '${HASHED_KEY}';")
if [[ "$VERIFY" != "$EVAL_EMAIL" ]]; then
  echo "  [get-auth-token] ERROR: key verification failed (got: '${VERIFY}')" >&2
  exit 1
fi
echo "  [get-auth-token] Verified: key resolves to ${VERIFY}" >&2

# ── 7. Seed bookable data: schedule + availability + one event type ──────────
# A booking-flow UI test needs the public booking page (/eval-skyramp/quick-chat)
# to show slots: the eval user must have a default schedule with availability and
# at least one event type. All-day/all-week availability avoids timezone- and
# weekday-dependent "no slots" flakiness. Idempotent (NOT EXISTS guards).
docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -q -c \
  "INSERT INTO \"Schedule\" (\"userId\", name, \"timeZone\")
   SELECT id, 'Skyramp Eval Hours', '${EVAL_TIMEZONE}' FROM users u WHERE u.email = '${EVAL_EMAIL}'
   AND NOT EXISTS (SELECT 1 FROM \"Schedule\" s WHERE s.\"userId\" = u.id AND s.name = 'Skyramp Eval Hours');"
docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -q -c \
  "INSERT INTO \"Availability\" (\"scheduleId\", days, \"startTime\", \"endTime\")
   SELECT s.id, ARRAY[0,1,2,3,4,5,6], '00:00:00'::time, '23:45:00'::time
   FROM \"Schedule\" s JOIN users u ON s.\"userId\" = u.id
   WHERE u.email = '${EVAL_EMAIL}' AND s.name = 'Skyramp Eval Hours'
   AND NOT EXISTS (SELECT 1 FROM \"Availability\" a WHERE a.\"scheduleId\" = s.id);"
docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -q -c \
  "UPDATE users SET \"defaultScheduleId\" = (SELECT s.id FROM \"Schedule\" s WHERE s.\"userId\" = users.id AND s.name = 'Skyramp Eval Hours')
   WHERE email = '${EVAL_EMAIL}' AND \"defaultScheduleId\" IS NULL;"
docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -q -c \
  "INSERT INTO \"EventType\" (title, slug, length, \"userId\", \"scheduleId\")
   SELECT 'Quick Chat', 'quick-chat', 30, u.id, u.\"defaultScheduleId\"
   FROM users u WHERE u.email = '${EVAL_EMAIL}'
   AND NOT EXISTS (SELECT 1 FROM \"EventType\" e WHERE e.\"userId\" = u.id AND e.slug = 'quick-chat');"
docker exec "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -q -c \
  "INSERT INTO \"_user_eventtype\" (\"A\", \"B\")
   SELECT e.id, u.id FROM \"EventType\" e JOIN users u ON e.\"userId\" = u.id
   WHERE u.email = '${EVAL_EMAIL}' AND e.slug = 'quick-chat'
   ON CONFLICT DO NOTHING;"
echo "  [get-auth-token] Bookable data seeded (schedule, availability, event type quick-chat)" >&2

# ── 8. Install dotenv for the Playwright executor ────────────────────────────
# cal.diy's playwright.config.ts imports dotenv. The Skyramp executor runs
# playwright from the CI runner's home dir where dotenv may not be installed.
npm install --prefix "$HOME" dotenv --silent 2>/dev/null || true

# ── 9. Output the bearer token ───────────────────────────────────────────────
echo "${API_KEY_PREFIX}${RAW_API_KEY}"

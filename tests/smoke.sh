#!/usr/bin/env bash
# SmartTunes smoke / integration tests, run by Jenkins on the test EC2 against a
# container started from the exact image digest that will be deployed.
#   tests/smoke.sh http://localhost:18080
# Env options:
#   EXPECTED_VERSION=<git-sha>  version healthz.php must report
#   UPLOAD_TEST=true            register, log in and upload a recording (writes to test DB/bucket)
#   FAIL_TESTS=false            true = add one failing test (proves a failing test blocks release)
# Writes a JUnit report to tests/results/smoke.xml for the Jenkins test report.
set -uo pipefail

BASE=${1:?usage: smoke.sh <base-url>}
EXPECTED_VERSION=${EXPECTED_VERSION:-}
UPLOAD_TEST=${UPLOAD_TEST:-true}
FAIL_TESTS=${FAIL_TESTS:-false}
HERE=$(cd "$(dirname "$0")" && pwd)
RESULTS_DIR="$HERE/results"
WORK=$(mktemp -d)
JAR="$WORK/cookies.txt"
mkdir -p "$RESULTS_DIR"

passed=0; failed=0; cases=""

# run_test NAME FUNCTION -> run one test, record the result for the console and JUnit.
run_test() {
    local name=$1 fn=$2 started=$SECONDS out
    if out=$($fn 2>&1); then
        passed=$((passed + 1)); echo "PASS  $name"
        cases+="<testcase classname=\"smoke\" name=\"$name\" time=\"$((SECONDS - started))\"/>"
    else
        failed=$((failed + 1)); echo "FAIL  $name -> $out"
        out=$(echo "$out" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g')
        cases+="<testcase classname=\"smoke\" name=\"$name\"><failure message=\"$out\"/></testcase>"
    fi
}

status_of() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

# ---------- tests ----------
t_health() {
    local body; body=$(curl -fsS "$BASE/healthz.php") || { echo "healthz not 200"; return 1; }
    echo "$body" | grep -q '"db":"ok"' || { echo "database not reachable: $body"; return 1; }
}

t_version() {
    local body; body=$(curl -fsS "$BASE/healthz.php")
    [ -z "$EXPECTED_VERSION" ] && { echo "$body" | grep -q '"version":"unknown"' && return 1; return 0; }
    echo "$body" | grep -q "\"version\":\"$EXPECTED_VERSION\"" || { echo "expected $EXPECTED_VERSION, got $body"; return 1; }
}

t_home_requires_login() {
    local loc; loc=$(curl -s -o /dev/null -w '%{redirect_url}' "$BASE/")
    echo "$loc" | grep -q 'login.php' || { echo "home did not redirect to login: '$loc'"; return 1; }
}

t_login_page() {
    curl -fsS "$BASE/login.php" | grep -q 'name="password"' || { echo "login form missing"; return 1; }
}

t_register_page() {
    [ "$(status_of "$BASE/register.php")" = "200" ] || { echo "register page not 200"; return 1; }
}

t_catalogue_json() {
    local body; body=$(curl -fsS "$BASE/get_songs.php?limit=5&q=") || { echo "songs endpoint failed"; return 1; }
    echo "$body" | grep -q '"song_id"' || { echo "no songs returned: ${body:0:200}"; return 1; }
}

t_static_assets() {
    [ "$(status_of "$BASE/css/style.css")" = "200" ] || { echo "css/style.css not served"; return 1; }
}

t_secrets_not_exposed() {
    local s1 s2
    s1=$(status_of "$BASE/app/config/.env"); s2=$(status_of "$BASE/app/config/database.php")
    [ "$s1" != "200" ] && [ "$s2" != "200" ] || { echo ".env=$s1 database.php=$s2"; return 1; }
}

t_karaoke_requires_login() {
    local loc; loc=$(curl -s -o /dev/null -w '%{redirect_url}' "$BASE/karaoke.php")
    echo "$loc" | grep -q 'login.php' || { echo "karaoke page open without login"; return 1; }
}

TEST_USER="ci_$(date +%s)_$RANDOM"
TEST_PASS="ci-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"

t_register_and_login() {
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' -c "$JAR" -b "$JAR" \
        --data-urlencode "username=$TEST_USER" --data-urlencode "password=$TEST_PASS" "$BASE/register.php")
    [ "$code" = "302" ] || { echo "register returned $code"; return 1; }
    code=$(curl -s -o /dev/null -w '%{http_code}' -c "$JAR" -b "$JAR" \
        --data-urlencode "username=$TEST_USER" --data-urlencode "password=$TEST_PASS" "$BASE/login.php")
    [ "$code" = "302" ] || { echo "login returned $code"; return 1; }
    [ "$(status_of -b "$JAR" "$BASE/karaoke.php")" = "200" ] || { echo "karaoke not reachable after login"; return 1; }
}

t_recording_upload_and_score() {
    local song body score
    song=$(curl -fsS "$BASE/get_songs.php?limit=1&q=" | grep -o '"song_id":[^,}]*' | head -n1 | grep -o '[0-9]\+')
    [ -n "$song" ] || { echo "no song id available"; return 1; }
    body=$(curl -s -b "$JAR" -F "audio=@$HERE/fixtures/sample.webm;type=audio/webm" \
        -F "song_id=$song" -F "audio_mix=voice_and_backing" "$BASE/upload_and_score.php")
    echo "$body" | grep -q '"success":true' || { echo "upload failed: ${body:0:300}"; return 1; }
    score=$(echo "$body" | grep -o '"score":[0-9]*' | grep -o '[0-9]*')
    [ "$score" -ge 60 ] && [ "$score" -le 100 ] || { echo "score out of range: $score"; return 1; }
}

t_intentional_failure() {
    echo "intentional failure (FAIL_TESTS=true) to demonstrate that failed tests block deployment"
    return 1
}

# ---------- run ----------
echo "Smoke tests against $BASE"
run_test "health_endpoint_and_database" t_health
run_test "build_version_reported" t_version
run_test "home_redirects_to_login" t_home_requires_login
run_test "login_page_renders" t_login_page
run_test "register_page_renders" t_register_page
run_test "song_catalogue_returns_json" t_catalogue_json
run_test "static_assets_served" t_static_assets
run_test "secrets_not_exposed" t_secrets_not_exposed
run_test "karaoke_requires_login" t_karaoke_requires_login
if [ "$UPLOAD_TEST" = "true" ]; then
    run_test "register_and_login" t_register_and_login
    run_test "recording_upload_and_score" t_recording_upload_and_score
fi
[ "$FAIL_TESTS" = "true" ] && run_test "intentional_failure" t_intentional_failure

total=$((passed + failed))
echo "<testsuite name=\"smoke\" tests=\"$total\" failures=\"$failed\">$cases</testsuite>" > "$RESULTS_DIR/smoke.xml"
rm -rf "$WORK"
echo "Result: $passed passed, $failed failed"
[ "$failed" -eq 0 ]

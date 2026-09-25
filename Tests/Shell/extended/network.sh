#!/bin/bash
#
# Tests/Shell/extended/network.sh - the allowlist network of a real box: allowed and refused
# hosts, the log, rules changed on a running box, the public rule, the rebinding defense, and no
# way around the proxy. Needs the internet (example.com, www.iana.org, localtest.me).

file_setup() {
    start_file_box "shtest-net-$$" --allow example.com
}

file_teardown() {
    stop_file_box
}

# http_code <url> [curl options...]: the HTTP status curl gets from inside the box ("000" when
# the connection itself failed).
http_code() {
    local _url="$1"
    shift
    "$AGENT_VM" exec --box "$BOX" -- /usr/bin/curl -sS -m 20 -o /dev/null -w '%{http_code}' "$@" "$_url" 2>/dev/null
}

test_allowed_and_refused_hosts() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    assert_eq "$(http_code https://example.com)" "200" "allowed host" || return 1
    assert_eq "$(http_code http://example.com)" "200" "allowed host, plain HTTP" || return 1
    assert_eq "$(http_code https://www.iana.org)" "000" "refused host" || return 1
    run_avm box netlog "$BOX" --denied --json
    assert_status 0 || return 1
    assert_contains "$OUT" "www.iana.org" "the log" || return 1
}

test_system_proxy_serves_urlsession_programs() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm exec --box "$BOX" -- /bin/sh -c '/usr/bin/nscurl https://example.com 2>&1 | /usr/bin/head -c 400'
    assert_status 0 || return 1
    assert_out_contains "Example Domain" || return 1
}

test_rules_change_on_a_running_box() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm box network "$BOX" --allow www.iana.org
    assert_status 0 || return 1
    assert_eq "$(http_code https://www.iana.org)" "200" "newly allowed host" || return 1
    run_avm box network "$BOX" --disallow www.iana.org
    assert_status 0 || return 1
    assert_eq "$(http_code https://www.iana.org)" "000" "disallowed again" || return 1
    run_avm box network "$BOX" --net open
    assert_status 1 || return 1
    assert_err_contains "is running" || return 1
}

test_the_public_rule_allows_public_names_only() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    run_avm box network "$BOX" --allow public
    assert_status 0 || return 1
    assert_eq "$(http_code https://www.iana.org)" "200" "a host allowed only by public" || return 1
    assert_eq "$(http_code https://example.com)" "200" "a host with its own rule" || return 1
    # An IP literal needs its own rule (403), and a public name resolving to this Mac is still
    # refused (502).
    local _code
    _code="$("$AGENT_VM" exec --box "$BOX" -- /usr/bin/curl -sS -m 20 -o /dev/null -w '%{http_code}' https://1.1.1.1 2>&1)"
    assert_contains "$_code" "403" "an IP literal" || return 1
    _code="$("$AGENT_VM" exec --box "$BOX" -- /usr/bin/curl -sS -m 20 -o /dev/null -w '%{http_code}' https://localtest.me 2>&1)"
    assert_contains "$_code" "502" "rebinding defense under public" || return 1
    # The log (one object per line, sorted keys) names the rule that let each through: public,
    # or the named rule that comes before it.
    local _log="${AGENT_VM_HOME:-$HOME/Library/Application Support/agent-vm}/Boxes/$BOX/network.jsonl"
    local _iana
    _iana="$(/usr/bin/grep '"host":"www.iana.org"' "$_log" | /usr/bin/tail -1)"
    assert_contains "$_iana" '"rule":"public"' "www.iana.org logged under public" || return 1
    local _named
    _named="$(/usr/bin/grep '"host":"example.com"' "$_log" | /usr/bin/tail -1)"
    assert_contains "$_named" '"rule":"example.com"' "example.com logged under its own rule" || return 1
    run_avm box network "$BOX" --disallow public
    assert_status 0 || return 1
    assert_eq "$(http_code https://www.iana.org)" "000" "public removed" || return 1
}

test_no_way_around_the_proxy() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    # Allowed by name, but it resolves to 127.0.0.1: refused (502).
    run_avm box network "$BOX" --allow localtest.me
    assert_status 0 || return 1
    local _code
    _code="$("$AGENT_VM" exec --box "$BOX" -- /usr/bin/curl -sS -m 20 -o /dev/null -w '%{http_code}' https://localtest.me 2>&1)"
    assert_contains "$_code" "502" "rebinding defense" || return 1
    run_avm box network "$BOX" --disallow localtest.me
    assert_status 0 || return 1
    # Without the proxy there is no route and no DNS.
    run_avm exec --box "$BOX" --env HTTPS_PROXY= --env https_proxy= -- /usr/bin/curl -sS -m 5 -o /dev/null https://1.1.1.1
    # 28 (timed out) or 7 (refused at once), depending on the guest's routing state: no connection.
    [ "$STATUS" -eq 28 ] || [ "$STATUS" -eq 7 ] || { fail "expected no connection (28 or 7), got $STATUS"; return 1; }
}

test_the_mac_is_unreachable_from_the_box() {
    require_box || return $(( $? == 1 ? 0 : 1 ))
    # A listener on every address of the Mac, reachable from the Mac itself, so a refused
    # connection from the box means no route rather than nothing listening.
    local _port=$(( 20000 + $$ % 20000 ))
    /usr/bin/nc -l -k "$_port" > /dev/null 2>&1 &
    local _listener=$!
    local _addresses="10.254.0.1 192.168.64.1"
    local _interface
    _interface="$(/sbin/route -n get default 2>/dev/null | /usr/bin/awk '/interface:/ {print $2}')"
    if [ -n "$_interface" ]; then
        local _lan
        _lan="$(/usr/sbin/ipconfig getifaddr "$_interface" 2>/dev/null)"
        [ -n "$_lan" ] && _addresses="$_addresses $_lan"
    fi
    /bin/sleep 1
    /usr/bin/nc -z -G 2 127.0.0.1 "$_port"
    local _local=$?
    if [ "$_local" -ne 0 ]; then
        kill "$_listener"
        fail "the test listener on port $_port does not answer on the Mac"
        return 1
    fi
    local _address
    for _address in $_addresses; do
        run_avm exec --box "$BOX" -- /bin/sh -c "/usr/bin/nc -z -G 3 $_address $_port; echo \$?"
        if [ "$OUT" != "1" ]; then
            kill "$_listener"
            fail "the box reached (or could not test) $_address:$_port: [$OUT]"
            return 1
        fi
    done
    kill "$_listener"
}

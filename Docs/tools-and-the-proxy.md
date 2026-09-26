# Tools and the box proxy

A box on the allowlist network (or `off`) has no route out and no DNS. The only way out is its proxy, at `127.0.0.1:3128` in the guest, which the guest daemon relays to the box's supervisor on the Mac, where the rules are checked. A tool therefore reaches the internet only if it uses that proxy. This page says which tools do on their own, which need a setting, and what cannot go through a proxy at all.

The box offers the proxy in three ways:

- **The system proxy** (the guest's network settings, web and secure web proxy), set at every start of a box on the allowlist network. URLSession programs, `softwareupdate` and Python's `urllib` read it.
- **Environment variables** for programs run with `exec` and `box shell`: `HTTP_PROXY`, `HTTPS_PROXY` and `NO_PROXY` in both spellings, and `NODE_USE_ENV_PROXY=1` for Node. Programs started some other way (an app on the box's screen, a LaunchAgent) do not get them.
- **An ssh setting** for every account, `/etc/ssh/ssh_config.d/agent-vm.conf`, written at every start of a box on the allowlist network and removed in an `open` one. It sends ssh through the proxy with macOS's `nc`, except for local names (`localhost`, `127.0.0.1`, `::1`, `*.local`). A `ProxyCommand` in your `~/.ssh/config` wins; `ProxyCommand none` there turns it off for a host.

The rules still decide every connection: a host needs a rule for the port it is reached on (a rule without a port allows 443 and 80), and ssh needs the host on port 22 (`github.com:22`, which `pack:github` includes).

## Works as is

Measured in boxes on macOS 27 guests:

- **curl** with the variables, as `exec` sets them.
- **URLSession** programs, with the system proxy alone (`nscurl`).
- **git** over HTTPS (`git clone`, `git ls-remote`).
- **git and ssh over SSH** (`git@github.com:` addresses), through the ssh setting, with `github.com:22` allowed.
- **npm** (`npm view`, `npm install`), **Homebrew** (its API and bottles) and **pip** (`pip install --user`).
- **Python's `urllib`**.
- **Node's `fetch`**, with `NODE_USE_ENV_PROXY=1`, which `exec` sets.

## Needs a setting

- **curl without the variables** ignores the system proxy. Pass `--proxy http://127.0.0.1:3128`, or set `HTTPS_PROXY`.
- **Node's `fetch` without `NODE_USE_ENV_PROXY=1`** ignores the variables and fails to resolve names (`ENOTFOUND`). Set `NODE_USE_ENV_PROXY=1`, or use a proxy agent.
- **Python's `aiohttp`** ignores the variables unless the session is made with `trust_env=True`, and otherwise fails with `ClientConnectorDNSError`. Some Python MCP servers use it.
- **Java** (not measured; there is no Java in the images): `-Djava.net.useSystemProxies=true`, or `-Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=3128` (and the `http.` pair). Gradle and Maven have their own proxy settings (`gradle.properties`, `~/.m2/settings.xml`).
- **Anything started outside `exec`** that reads only the variables: set them where it starts, as `exec` does.

## Cannot go through the proxy

- **Name lookups on their own**: `dig`, `nslookup` and `host` fail, since the box has no DNS. Tools that go through the proxy never need it: the proxy resolves names on the Mac.
- **ICMP**: `ping` and `traceroute` fail.
- **UDP**: DNS, QUIC and anything else over UDP.
- **Other TCP without proxy support**: database clients, mail (SMTP, IMAP), and raw TCP to other ports, unless the client can use an HTTP CONNECT proxy (as ssh does with `nc`) and the host and port are allowed. Such services are reached from the Mac instead; port forwards from the box are not supported yet.
- **A port without a rule** is refused by design (for example `github.com:8443` with only `github.com` allowed).
- **Addresses on this Mac or your local network** are refused whatever the rules say (see README, "How the allowlist works").

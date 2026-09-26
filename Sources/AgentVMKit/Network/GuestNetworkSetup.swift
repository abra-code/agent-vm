// Sources/AgentVMKit/Network/GuestNetworkSetup.swift
//
// The guest side of a box's network mode, applied by the supervisor through the guest daemon
// (as root) every time the box starts, since the same disk can be run in any mode:
// - allowlist/off: the fixed dead-end address, no DNS servers, and the system web and secure
//   web proxy at 127.0.0.1:3128 (the daemon's relay to the host proxy). URLSession tools,
//   softwareupdate and Python follow the system proxy (measured on macOS 27 guests).
//   ssh too, through /etc/ssh/ssh_config.d/agent-vm.conf (a ProxyCommand with macOS's nc).
// - open: DHCP from the NAT, no proxy, and the ssh file removed.
// Programs run through exec also get HTTP_PROXY/HTTPS_PROXY (curl, git and SwiftPM ignore the
// system proxy - measured) - see `proxyEnvironment`.

import Foundation

public enum GuestNetworkSetup {
    /// A /bin/sh command for the guest; exits non-zero with a message when a step fails.
    public static func command(for mode: BoxNetwork.Mode) -> String {
        // The network service of the only card, en0 (named "Ethernet" in practice).
        let findService = #"service=$(/usr/sbin/networksetup -listnetworkserviceorder | /usr/bin/awk '/^\([0-9*]+\) /{sub(/^\([0-9*]+\) /, ""); name=$0} /Device: en0\)/{print name; exit}'); [ -n "$service" ] || { echo "no network service for en0" >&2; exit 1; }"#
        let steps: [String]
        switch mode {
        case .allowlist, .off:
            steps = [
                #"/usr/sbin/networksetup -setmanual "$service" \#(DeadEndLink.guestAddress) \#(DeadEndLink.netmask) \#(DeadEndLink.routerAddress)"#,
                #"/usr/sbin/networksetup -setdnsservers "$service" Empty"#,
                #"/usr/sbin/networksetup -setwebproxy "$service" 127.0.0.1 \#(GuestRelay.port) off"#,
                #"/usr/sbin/networksetup -setsecurewebproxy "$service" 127.0.0.1 \#(GuestRelay.port) off"#,
                #"/usr/sbin/networksetup -setproxybypassdomains "$service" localhost 127.0.0.1 '*.local'"#,
                #"/bin/mkdir -p \#(sshConfigDirectory)"#,
                #"/usr/bin/printf '%s\n' \#(sshConfigLines.map { "'\($0)'" }.joined(separator: " ")) > \#(sshConfigPath)"#,
            ]
        case .open:
            steps = [
                #"/bin/rm -f \#(sshConfigPath)"#,
                #"/usr/sbin/networksetup -setdhcp "$service""#,
                #"/usr/sbin/networksetup -setdnsservers "$service" Empty"#,
                #"/usr/sbin/networksetup -setwebproxystate "$service" off"#,
                #"/usr/sbin/networksetup -setsecurewebproxystate "$service" off"#,
                // Switching back from the fixed address takes a DHCP round; programs started
                // right after would find no DNS (measured). Wait for the interfaces.
                #"/usr/sbin/ipconfig waitall"#,
            ]
        }
        return ([findService] + steps.map { "\($0) || exit 1" }).joined(separator: "; ")
    }

    /// ssh through the proxy, for every account: the system file macOS's ssh_config includes,
    /// written at each start of a proxied box and removed in an open one (the same disk runs in
    /// either mode). A ProxyCommand in ~/.ssh/config still wins; `ProxyCommand none` there turns
    /// it off for a host. The allowlist must allow the host on port 22 (pack:github does).
    static let sshConfigDirectory = "/etc/ssh/ssh_config.d"
    static let sshConfigPath = "\(sshConfigDirectory)/agent-vm.conf"
    /// macOS's nc speaks CONNECT; local names stay direct, as for the web proxy.
    static var sshConfigLines: [String] {
        return [
            "# Written by agent-vm at each start of a box whose network goes through its proxy (allowlist or off).",
            "Host * !localhost !127.0.0.1 !::1 !*.local",
            "    ProxyCommand /usr/bin/nc -X connect -x 127.0.0.1:\(GuestRelay.port) %h %p",
        ]
    }

    /// Environment for programs run by exec in a proxied box. Both spellings: tools differ.
    public static var proxyEnvironment: [String: String] {
        let proxy = "http://127.0.0.1:\(GuestRelay.port)"
        let bypass = "localhost,127.0.0.1,::1"
        return [
            "HTTP_PROXY": proxy, "http_proxy": proxy,
            "HTTPS_PROXY": proxy, "https_proxy": proxy,
            "NO_PROXY": bypass, "no_proxy": bypass,
            // Node's fetch ignores the variables above unless told otherwise.
            "NODE_USE_ENV_PROXY": "1",
        ]
    }
}

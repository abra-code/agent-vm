# Threat model: what a box protects, and what it does not

AgentVM runs an agent and its tools in a virtual machine (a "box", running macOS or Linux) so that a mistaken, prompt-injected or malicious agent cannot reach the rest of your Mac. This page says what that promise covers, what each part of it rests on, and where it ends. The README describes each feature; this page is the summary to read before you decide what to put in a box and what to allow it.

## The short version

- Everything that runs in a box is treated as hostile: the agent, its tools, code it downloads, root in the box, and the box's copy of AgentVM's own guest daemon.
- A box can read and change the folders you share with it, use the hosts you allow, and use the secrets you hand it. It can do nothing else on your Mac. A Linux box can share several folders at once, one per session; inside the box they are one trust zone, not kept apart from each other.
- Three things come back out of a box, and each is a way to reach you: the files in the shared folder, what the box prints on your terminal or shows in its window, and what it sends to the hosts you allowed. AgentVM reports, filters or logs each of them; it cannot make them safe.
- AgentVM does not defend against other programs that already run as you on your Mac, against root on your Mac, or against a flaw in Apple's Virtualization framework.

## Who is trusted

| Trusted | Why it has to be |
|---|---|
| You, and every program running as you on the Mac | They can already read the store, the disk images and your Keychain items (macOS asks first for those). |
| macOS on your Mac and Apple's Virtualization framework | The wall between the box and the Mac is theirs. |
| The `agent-vm` you installed, with the `packs.json` and `agents.json` beside it | It runs as you. |
| The restore image from Apple | macOS in the box is installed from it. |
| The distribution's cloud image and its package servers (Debian's, or Ubuntu's) | A Linux box's system is built from them (see Linux boxes). |
| The recipes you build images with, and the files and installers you send into a box | They run as root or as the box user while the image is built, with the open network. |

| Not trusted | What it controls |
|---|---|
| The agent and every program in a box | The box user's account: in a macOS box an administrator without the password, in a Linux box an account with no password and no sudo. |
| Root in a box | Everything in that box, including the guest daemon and every answer it gives. |
| Servers on the internet | What allowed hosts answer; what names resolve to. |
| The project folder after a session | Every file name, content, permission and link in it. |
| Other users of the Mac | Their own processes; they can try to reach your store, sockets and processes. |

## What a box cannot do

Each line names what the claim rests on.

- **Read or change files on your Mac outside the shared folder.** The box has its own disk. Only the folders you share are there, each at its own path (one at a time in a macOS box, up to 8 in a Linux box), and AgentVM refuses to share `/`, your home folder, `~/Library`, hidden folders of your home, and its own store, whatever name they are reached by. Your Keychain, SSH keys, browser data and other projects do not exist in the box.
- **Reach your Mac or your local network** (on the `allowlist` and `off` networks). A macOS box's network card leads nowhere: no route and no DNS. A Linux box has no network card at all. The only way out is a proxy on the Mac that the guest daemon relays to. The proxy checks the host name against your rules, looks the name up on the Mac, and connects only to public addresses. A name that resolves to the Mac, to a private or link-local address, to the Mac's own networks, or to an address that stands for one of those (NAT64, 6to4, Teredo) is refused.
- **Reach hosts you did not allow.** Each request is one host and one port, checked before anything is connected. A plain HTTP connection carries one request, so a second one for another host cannot ride on it.
- **Hide what it connected to.** Every attempt is logged on the Mac, in files the box cannot reach. Refused attempts cannot push allowed ones out of the log.
- **Start anything on your Mac.** The guest answers the Mac's requests and never the other way around: the guest daemon accepts connections only from the host, and the Mac never runs a command or opens a file because the guest said so.
- **Hang, crash or fill the process that runs it.** Whatever the box's supervisor asks of the guest has a time limit and a size limit, so `box stop` always ends and a guest cannot use up the supervisor's memory or the proxy's connections for good.
- **Act on your terminal through what it prints.** Text that came from a box (names, versions, errors, file names in a change report, recipe output) has control characters replaced before it is printed. In a terminal session (`exec --tty`, `box shell`, `avm`) the program's output goes through a filter that passes what draws in the window and drops what reaches past it: files, uploads, notifications, links to anything but web pages, and window control. The clipboard is never read for a box. It is written only in a session that allows it (`exec --tty --clipboard`, which `avm` passes unless told `--no-clipboard`), and only while you are using that session: a key or a mouse report of yours went into the box within the last 2 seconds (what the terminal types by itself, such as answers to a program's questions, does not count, nor does input the box kept waiting or that was typed before the session began), at most 4 times in 2 seconds, as plain text with control characters and hidden or reordering characters removed, 768 KB at most. Any other request is dropped, and a refused one is counted in the exec log.
- **Steer an undo out of the project, or block it.** Undo and the snapshot work through open folders and never follow a link, so a folder exchanged for a link while the undo runs is refused. Files the agent locked, folders it made read-only or unreadable, and access control lists it added are opened up first.
- **Become root in the box by itself.** In a macOS box the account is an administrator, but its password never enters the box as a file the box user can read or as a command argument, and there is no passwordless `sudo`. In a Linux box the account has no password, no sudo rule and no group but its own (unless you built the image with the sudo recipe; see Linux boxes).
- **Outlive a disposable box.** A disposable box is never started again once it stops and is deleted by the next `box gc` (which `box list`, `box start` and `doctor` run); a temporary `avm` box is deleted when its session ends. A kept box keeps whatever was planted in it until you recreate it from its image.
- **Change what is recorded about it** (since 0.7.19 also for its events). The three logs of a box (programs, connections, events) are written on the Mac by agent-vm's own processes. A box chooses some of the text in them (host names, command lines, file names in a report), which is cut to a fixed length and made printable when shown, and it can make them grow up to their limits; it cannot remove or alter a line. The names of the variables and secrets handed to a program are recorded, never their values.
- **Erase its record by being deleted** (since 0.7.14). A box's logs are written on the Mac by its supervisor, where nothing in the box can change them, and when the box is deleted they move to `Logs/` in the store, compressed, for 30 days (`agent-vm store logs`; the number of days is the store's to set, and with 0 nothing is kept, which is then what a deleted box leaves). So a disposable or temporary box, the kind trusted least, still leaves what it ran and what it contacted. What the logs hold is as before: the host names and commands a box chose appear in them, cut to a fixed length. They are as private as the store (the folder is yours alone), and they are removed after 30 days, so they are no archive.
- **Take more of the Mac than it was given.** A box has a fixed number of CPUs, a fixed memory size and a disk with a ceiling. macOS itself runs at most two macOS guests at once; Linux boxes are limited by their memory sizes only, and AgentVM warns at a start when the running boxes together, by the sizes they were given, leave the Mac less than 6 GB.

## What a box can still do

These are not flaws to be fixed later. They follow from what a box is for.

### Change the shared folder, and so run code on your Mac later

The folder is your real folder, live. An agent can write anything there, and some files run on your Mac the next time you use the project: git hooks and git configuration, agent configuration and instructions (`.mcp.json`, `CLAUDE.md`, `AGENTS.md`), build scripts, package manifests, editor tasks, `.envrc`, Xcode projects, new executables.

- The session report lists what changed and flags such files first. The flags are a list of known patterns and a review aid, not a boundary: a file that matters to a tool the list does not know is reported as changed, without a flag.
- Nothing is checked while the agent works. A program on your Mac that acts on the folder by itself (an editor that runs tasks or loads project settings, a file watcher that builds, direnv) acts on the agent's files before you saw any report. Close such programs, or keep them from trusting the folder, while an agent works in it.
- Files the agent writes carry no quarantine attribute, so Gatekeeper does not check a program it built.
- Undo puts back content, permissions and lock flags. It does not report or undo extended attributes and access control lists. Content that reached a file outside the project through a hard link you made yourself stays changed there.
- Writes to the share land on the Mac's disk and are limited only by its free space.
- A snapshot taken while something still changes the folder (an agent left running from an earlier session) is not a copy of one moment: it never holds anything from outside the project, but it may miss what was being moved. Stop what works in the folder before a session starts, as before an undo.
- Sharing a folder read only (`--read-only`) closes this path.

### Reach the other projects that share its box

A Linux box can share up to 8 folders at once, so that sessions on different projects use one box. The box does not keep them apart: every program in it runs as the same account, and every folder the box shares at that moment is open to all of them.

- An agent working on one project can read every other folder shared into its box, and change those shared for writing; anything it read can leave by the hosts its box allows, which are the box's rules, not one session's.
- A change it makes in another session's folder is reported by that session's report, as that session's, and that session's undo takes it back. Its own session's report does not show it.
- A program one session leaves running can work in a folder another session shares later, until that folder is unshared 5 seconds after its last program ends.
- AgentVM says so when a program starts in a box that already shares another folder (`box <name> also shares ...`), and `agent-vm status` lists every folder each box shares.
- A box of its own keeps a project apart, at the cost of its memory and processors. A macOS box shares one folder at a time.

### Send what it can read to the hosts you allowed

Every program in the box can read the shared folders and every secret you passed in (`--env`, `--secret`). It can send them to any host the rules allow.

- An allowed host that takes uploads (a code host, a package registry, a paste site, the agent's own provider) is a way out for data. Prefer keys that are limited to the task and that you can revoke.
- The proxy does not look inside HTTPS. A rule allows a connection to the address behind a name; what the box asks for inside the encrypted connection is its own. Where one service hosts many sites, a rule for one of them allows them all, for reading and for sending data out. Measured with the one rule `pages.github.com`: `curl https://octocat.github.io/` is refused, but `curl --connect-to octocat.github.io:443:pages.github.com:443 https://octocat.github.io/` and `curl -H "Host: octocat.github.io" https://pages.github.com/` both return the other site's page, and the network log shows two allowed connections to `pages.github.com`. So the log names the host the rule allowed, not the site the box talked to. Any site on such a service is somebody's own content; treat a rule for a host on a shared service (`*.github.io`, a content delivery network, a storage bucket's host) as a rule for the whole service.
- Several built-in packs allow such hosts because the tools need them: `github`, `homebrew` and `swiftpm` allow `github.com` and hosts under `githubusercontent.com` and `ghcr.io`, which serve whatever anyone published there, and `npm` and `pypi` allow registries anyone can publish to. With any of them a box can fetch code of its choosing, and with an account's key it can upload.
- The `public` rule allows every public host name. It keeps the Mac and the local network out of reach and logs every connection, but it stops no upload, and the names a box asks for are themselves a message to whoever runs the name server.
- `public` cannot tell your router's public address, or a company network that uses public addresses behind a VPN, from the internet.
- On the `open` network a box is a machine on your local network, behind the Mac's NAT: it reaches the internet, your local network and services on the Mac that listen there, and nothing is logged.

### Show and print what it likes inside its own window

- A full-screen program draws anything in your terminal window for as long as the session lasts, including text that looks like your Mac's shell prompt or a password question. What you type during a session goes to the box.
- The box's screen (`box view`, macOS boxes only) is drawn by the box. A dialog there that asks for your Mac's password is the box asking. A Linux box has no screen.
- Window titles and links to `http` and `https` pages pass the terminal filter. A link's text and its address are the program's choice.
- In an `avm` session, a program in the box can put text of its choice on your clipboard whenever you are typing or using the mouse in that session. agent-vm sees that you are there, not what you selected or whether you asked to copy: the text can differ from what you selected, and it can replace what you copied elsewhere a moment before. Nothing is written while you are not using the session, and the box never reads your clipboard. The text cannot carry escape sequences, end a bracketed paste, or hide characters, but what is left is still the box's words: it can hold several lines, and in a shell without bracketed paste (macOS's `/bin/bash`) each complete line runs as pasted; it can be a command that looks right, an address with a lookalike letter, or instructions meant for another agent you paste it into. Read what you paste from a box session. `box execlog` says how many times a session wrote the clipboard and how many requests were refused; `avm --no-clipboard` turns the writing off.

### Use the Mac's resources up to its limits

A box can keep its CPUs busy, fill its disk up to its ceiling (64 GB by default, taken from the Mac's free space as it is used) and fill the shared folder. It can make the proxy log grow to its size limit, after which old lines are dropped.

## Inside a box there is one trust zone

AgentVM does not try to protect programs in a box from each other. Two things are worth knowing:

- **Root in a macOS box.** The account password is what keeps the box user from root. It is the same in every image and box that descends from one macOS install, and macOS keeps it in each guest, lightly obscured, for automatic login (`/etc/kcpassword`, readable by root). So root in one box learns the password of its sibling boxes. A box that was shown in a window by an agent-vm older than 0.5.11 may have let its agent read it; rebuild such an image from a restore file if that matters.
- **A replaced guest daemon.** Root in a box can replace the guest daemon. The Mac side assumes this: every answer from the guest is checked for size, shape and time, and printed as text. What a replaced daemon gains is inside its own box only, plus the account password the next time the Mac sends it (a macOS update, turning the screen lock off).

## Secrets

- **Agent secrets** (`agent-vm secret set`) are Keychain items tied to the agent-vm that stored them. They are sent to the guest inside the exec request, never logged, never written to disk by AgentVM. Once in the box they are the box's.
- `--env NAME=VALUE` puts the value in agent-vm's argument list, which every local user can read with `ps` while the command runs. Use `--env NAME`, `--env-file` or `--secret`. The exec log never records a program's environment, but it records the program's command line as given, so keep secrets out of its arguments too.
- Recipe parameters (`--set`) are recorded in the image and written to the build log in clear. Do not pass secrets that way.
- **The account password** of a macOS image (a Linux image has none) is in the Keychain (images made since 0.6.0 by a build signed with an identity, not ad hoc) or in a private `Password` file. Either way it can be recovered from any disk image of that lineage by whoever can read the store.
- The supervisor of a box and the runner of a job outlive the command that started them, so they do not keep its environment (since 0.6.7): a key exported in your shell does not stay in a process that runs for days. The box never sees the Mac's environment either way.

## Other users of the Mac, and other programs running as you

- The store is a folder only you can open, checked on every write; one owned by someone else is refused. Control sockets are private and the peer's user is checked on every connection. Jobs are recognized by a lock, not by a process number. No way was found for another local user to read the store, reach a control socket or signal a supervisor or a job.
- On a volume mounted with ownership ignored (the default for external volumes), permissions keep nobody out. `agent-vm doctor` warns.
- A program running as you is outside this model: it can run `agent-vm exec --user root` in any box, read the disk images, edit the store, change the files beside `agent-vm`, and set the environment variables AgentVM reads. Run agents you do not trust in a box, not next to one.
- A `session` without a box (snapshot, report and undo around an agent that runs directly on your Mac) contains nothing. It gives you the report and the undo.

## Building images

- An image build runs with the open network (NAT), because macOS and the tools come from the internet, and recipe steps run as the box user or as root. Use recipes you have read.
- Until the guest daemon is in place, the build of a macOS image reaches the new guest over SSH with the account password, on the Mac's virtual network. (A Linux image's build has no such phase: its daemon is installed from a second disk at the first boot.) It never uses your SSH configuration, keys or `known_hosts`. Whether another virtual machine on that network at that moment could answer in the guest's place was not measured; do not build images while a box you do not trust runs on the `open` network.
- A restore image is trusted because it came from Apple over HTTPS, or is a file you supplied, and Virtualization can load it. AgentVM keeps no checksum of it.
- An agent entry of your own (`Agents/<id>.json`) is shown and asked about once before it is first used, and again when the file changes.

## Linux boxes

Everything above holds for a Linux box, with the differences each line names. What is smaller, what is new, and what each new part rests on:

**Smaller than for a macOS box**

- **No account password exists.** There is nothing to store, to type, or to leak between sibling boxes.
- **No SSH phase in the image build,** so no first contact that another machine on the virtual network could answer.
- **No network card** on the `allowlist` and `off` networks. "No route and no DNS" becomes "no card": there is nothing to configure wrongly, and root in the box cannot bring up what is not there.
- **No screen,** so no window in which a box can ask for your Mac's password.
- **No ssh server and no background updates.** The server is removed from the image (not only disabled: systemd would make an installed one listen on a second kind of socket by itself), and the image's build checks that nothing listens for the network and nothing but the guest daemon on the socket the Mac uses.

**New, and what it rests on**

| What | The risk | What answers it |
|---|---|---|
| Debian's cloud image | A tampered download | Its SHA-512 must be the one in Debian's list, fetched over HTTPS from `cloud.debian.org` and from no other host, before anything reads the file; a cached file is checked again at every use. Debian publishes no signature beside the list, so HTTPS to that host is what the image is trusted by. |
| Ubuntu's cloud image (since 0.7.11) | A tampered download | The same rule with Ubuntu's `SHA256SUMS` from `cloud-images.ubuntu.com`. Ubuntu signs its list; agent-vm does not check the signature (macOS has no tool for it), so here too HTTPS to that host is what the image is trusted by. |
| The reader of Ubuntu's disk format (qcow2) | A crafted file: a parser on your Mac, of a file from the network | It reads only a file that passed the checksum (or one you named). Every offset the file names is checked against the file's length before it is read; memory is taken by the cluster size (2 MiB at most) and a table of 32 MB at most, never by an unchecked number; a compressed cluster must inflate to exactly one cluster; the disk may not be larger than the image's, nor than 64 GB; a backing file, encryption, an external data file and unknown feature bits are refused. It names no file but the one it reads and the one it writes. |
| Ubuntu's packages over plain HTTP | A changed package on the way | apt checks the signed index and each package's checksum with the keys in the image, as it does over HTTPS; the proxy allows the two hosts by name. What plain HTTP gives away is which packages a box asks for. |
| Debian's packages; the Node archive of `Recipes/linux-node` | What the image is built from | apt checks its signed index with the keys in the image. The Node recipe checks nodejs.org's own checksum list. Both are "recipes you have read". |
| Unpacking the cloud image | A crafted archive | Only a checked file is read; one member, written to the disk file through a pipe, never unpacked into a folder; no more than the disk's size. |
| The disk that installs the guest daemon at first boot | A secret left in the guest | It holds none: the daemon, its unit, and the daemon's SHA-256. |
| What the build believes of the guest | The build takes the system's name, version and kernel from the guest it just made, on the open network | Each is taken only as a short printable word; nothing the guest says is run or used as a path on the Mac. |
| The console log | A guest that prints without end, or prints control characters | 2 MB at most on disk and 4 MB a minute; shown only with control characters replaced. |
| The shared folder | Every user in the box can do in it what you can on the Mac | Stated: inside a box there is one trust zone, and several folders shared into one Linux box are in it together. The folder is mounted so that a setuid file or a device file in it means nothing in the box. |
| Starting a program in the shared folder | The folder's files appear to belong to whoever asks, so root in the box must not be the one that looks | The daemon's helper checks the folder and the program after it has become the box user, and tells the daemon through a pipe limited to 1 KB, 10 seconds and plain text. |
| Root in the box loads kernel modules | The guest daemon accepts connections only from the Mac | A socket in the guest cannot take the Mac's address, with or without the kernel's loopback module (measured). |
| System updates | An upgrade that brings back what was sealed | `image update --system` compares what the build sealed before and after; something that held and no longer does fails the update. |
| The boot firmware's variables (`EFIVariableStore`) | A file the guest writes and Apple's firmware reads at the next boot | Outside the model, as every input to the Virtualization framework is; named because a macOS box has no such file. It is per box, and a box recreated from its image gets the image's. |

**Root in a Linux box**

- **By default the box user cannot become root:** a locked password, no sudo rule, no group but its own, and no `polkitd`. A flaw in the Linux kernel is outside this; `image update --system` is how its fixes arrive.
- **Why there is no passwordless sudo by default.** Root in a box can load kernel modules and talk to the virtual machine's devices in ways a user cannot, so more of Apple's device code is within its reach. A macOS box's user cannot become root either.
- **`Recipes/linux-sudo` is the choice to accept that** for an image. The recipe is then in the image's record, and in the record of every image built from it, and `agent-vm image list` shows it for the image built with it.
- **A sudo rule for `apt-get` alone would be a limit in name only:** apt can be made to run a program of the caller's choosing as root.

**Not measured**

- The agents' own behavior in a Linux box beyond their start: which hosts each asks for was not compared with a macOS box.

## Outside the model

- A flaw in the Virtualization framework, the hypervisor or macOS that lets a guest out.
- Hardware side channels between the guest and the host.
- Root on the Mac, and physical access to it.
- What an allowed service does with what the agent sends it.
- The agent's own judgment: a box limits what a wrong action can touch, not whether the action is wrong.

## How this was checked

- A review of the whole tool by four independent reviewers, one for each boundary: the guest-facing code and the guest daemon, the network proxy, file safety (snapshot, report, undo), and the local surface on the Mac. Its confirmed findings were fixed in versions 0.5.8 to 0.6.6.
- Unit tests that play the hostile side: a fake guest that sends malformed, oversized, slow and out-of-turn frames; proxy requests with smuggled lines, odd hosts and addresses in every notation; projects with planted links, FIFOs, locked and unreadable files, deep trees and names holding control characters; terminal output fed a byte at a time.
- Tests on real boxes for what only a real one shows: no way around the proxy, the Mac unreachable from the box, rules changed on a running box, read-only shares, signals, terminals and permission prompts.
- The same tests on real Linux boxes, and for what is theirs alone: no network card and no way around the proxy for root either, no ssh server and no listener but the guest daemon, descriptors a program inherits, `git` in the shared folder right after root looked at it, and an update that leaves the image as it was when canceled.

What was not measured is named above where it applies.

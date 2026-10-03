# Threat model: what a box protects, and what it does not

AgentVM runs an agent and its tools in a macOS virtual machine (a "box") so that a mistaken, prompt-injected or malicious agent cannot reach the rest of your Mac. This page says what that promise covers, what each part of it rests on, and where it ends. The README describes each feature; this page is the summary to read before you decide what to put in a box and what to allow it.

## The short version

- Everything that runs in a box is treated as hostile: the agent, its tools, code it downloads, root in the box, and the box's copy of AgentVM's own guest daemon.
- A box can read and change the one folder you share with it, use the hosts you allow, and use the secrets you hand it. It can do nothing else on your Mac.
- Three things come back out of a box, and each is a way to reach you: the files in the shared folder, what the box prints on your terminal or shows in its window, and what it sends to the hosts you allowed. AgentVM reports, filters or logs each of them; it cannot make them safe.
- AgentVM does not defend against other programs that already run as you on your Mac, against root on your Mac, or against a flaw in Apple's Virtualization framework.

## Who is trusted

| Trusted | Why it has to be |
|---|---|
| You, and every program running as you on the Mac | They can already read the store, the disk images and your Keychain items (macOS asks first for those). |
| macOS on your Mac and Apple's Virtualization framework | The wall between the box and the Mac is theirs. |
| The `agent-vm` you installed, with the `packs.json` and `agents.json` beside it | It runs as you. |
| The restore image from Apple | macOS in the box is installed from it. |
| The recipes you build images with, and the files and installers you send into a box | They run as root or as the box user while the image is built, with the open network. |

| Not trusted | What it controls |
|---|---|
| The agent and every program in a box | The box user's account, an administrator without the password. |
| Root in a box | Everything in that box, including the guest daemon and every answer it gives. |
| Servers on the internet | What allowed hosts answer; what names resolve to. |
| The project folder after a session | Every file name, content, permission and link in it. |
| Other users of the Mac | Their own processes; they can try to reach your store, sockets and processes. |

## What a box cannot do

Each line names what the claim rests on.

- **Read or change files on your Mac outside the shared folder.** The box has its own disk. One folder is shared, at its own path, and AgentVM refuses to share `/`, your home folder, `~/Library`, hidden folders of your home, and its own store, whatever name they are reached by. Your Keychain, SSH keys, browser data and other projects do not exist in the box.
- **Reach your Mac or your local network** (on the `allowlist` and `off` networks). The box's network card leads nowhere: no route and no DNS. The only way out is a proxy on the Mac that the guest daemon relays to. The proxy checks the host name against your rules, looks the name up on the Mac, and connects only to public addresses. A name that resolves to the Mac, to a private or link-local address, to the Mac's own networks, or to an address that stands for one of those (NAT64, 6to4, Teredo) is refused.
- **Reach hosts you did not allow.** Each request is one host and one port, checked before anything is connected. A plain HTTP connection carries one request, so a second one for another host cannot ride on it.
- **Hide what it connected to.** Every attempt is logged on the Mac, in files the box cannot reach. Refused attempts cannot push allowed ones out of the log.
- **Start anything on your Mac.** The guest answers the Mac's requests and never the other way around: the guest daemon accepts connections only from the host, and the Mac never runs a command or opens a file because the guest said so.
- **Hang, crash or fill the process that runs it.** Whatever the box's supervisor asks of the guest has a time limit and a size limit, so `box stop` always ends and a guest cannot use up the supervisor's memory or the proxy's connections for good.
- **Act on your terminal through what it prints.** Text that came from a box (names, versions, errors, file names in a change report, recipe output) has control characters replaced before it is printed. In a terminal session (`exec --tty`, `box shell`, `avm`) the program's output goes through a filter that passes what draws in the window and drops what reaches past it: the clipboard, files, uploads, notifications, links to anything but web pages, and window control.
- **Steer an undo out of the project, or block it.** Undo and the snapshot work through open folders and never follow a link, so a folder exchanged for a link while the undo runs is refused. Files the agent locked, folders it made read-only or unreadable, and access control lists it added are opened up first.
- **Become root in the box by itself.** The box account is an administrator, but its password never enters the box as a file the box user can read or as a command argument, and there is no passwordless `sudo`.
- **Outlive a disposable box.** A disposable box is never started again once it stops and is deleted by the next `box gc` (which `box list`, `box start` and `doctor` run); a temporary `avm` box is deleted when its session ends. A kept box keeps whatever was planted in it until you recreate it from its image.
- **Take more of the Mac than it was given.** A box has a fixed number of CPUs, a fixed memory size and a disk with a ceiling. macOS itself runs at most two macOS guests at once.

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

### Send what it can read to the hosts you allowed

Every program in the box can read the shared folder and every secret you passed in (`--env`, `--secret`). It can send them to any host the rules allow.

- An allowed host that takes uploads (a code host, a package registry, a paste site, the agent's own provider) is a way out for data. Prefer keys that are limited to the task and that you can revoke.
- The proxy does not look inside HTTPS. A rule allows a connection to the address behind a name; what the box asks for inside the encrypted connection is its own. Where one address serves many sites (a content delivery network), a box may reach another site at the same address through a rule for one of them. This was not measured.
- The `public` rule allows every public host name. It keeps the Mac and the local network out of reach and logs every connection, but it stops no upload, and the names a box asks for are themselves a message to whoever runs the name server.
- `public` cannot tell your router's public address, or a company network that uses public addresses behind a VPN, from the internet.
- On the `open` network a box is a machine on your local network, behind the Mac's NAT: it reaches the internet, your local network and services on the Mac that listen there, and nothing is logged.

### Show and print what it likes inside its own window

- A full-screen program draws anything in your terminal window for as long as the session lasts, including text that looks like your Mac's shell prompt or a password question. What you type during a session goes to the box.
- The box's screen (`box view`) is drawn by the box. A dialog there that asks for your Mac's password is the box asking.
- Window titles and links to `http` and `https` pages pass the terminal filter. A link's text and its address are the program's choice.

### Use the Mac's resources up to its limits

A box can keep its CPUs busy, fill its disk up to its ceiling (64 GB by default, taken from the Mac's free space as it is used) and fill the shared folder. It can make the proxy log grow to its size limit, after which old lines are dropped.

## Inside a box there is one trust zone

AgentVM does not try to protect programs in a box from each other. Two things are worth knowing:

- **Root.** The account password is what keeps the box user from root. It is the same in every image and box that descends from one macOS install, and macOS keeps it in each guest, lightly obscured, for automatic login (`/etc/kcpassword`, readable by root). So root in one box learns the password of its sibling boxes. A box that was shown in a window by an agent-vm older than 0.5.11 may have let its agent read it; rebuild such an image from a restore file if that matters.
- **A replaced guest daemon.** Root in a box can replace the guest daemon. The Mac side assumes this: every answer from the guest is checked for size, shape and time, and printed as text. What a replaced daemon gains is inside its own box only, plus the account password the next time the Mac sends it (a macOS update, turning the screen lock off).

## Secrets

- **Agent secrets** (`agent-vm secret set`) are Keychain items tied to the agent-vm that stored them. They are sent to the guest inside the exec request, never logged, never written to disk by AgentVM. Once in the box they are the box's.
- `--env NAME=VALUE` puts the value in agent-vm's argument list, which every local user can read with `ps` while the command runs. Use `--env NAME`, `--env-file` or `--secret`. The exec log never records a program's environment, but it records the program's command line as given, so keep secrets out of its arguments too.
- Recipe parameters (`--set`) are recorded in the image and written to the build log in clear. Do not pass secrets that way.
- **The account password** is in the Keychain (images made since 0.6.0 by a build signed with an identity, not ad hoc) or in a private `Password` file. Either way it can be recovered from any disk image of that lineage by whoever can read the store.
- The supervisor of a box and the runner of a job keep the environment of the shell that started them for as long as they live. A key exported in that shell stays in that process; the box does not see it.

## Other users of the Mac, and other programs running as you

- The store is a folder only you can open, checked on every write; one owned by someone else is refused. Control sockets are private and the peer's user is checked on every connection. Jobs are recognized by a lock, not by a process number. No way was found for another local user to read the store, reach a control socket or signal a supervisor or a job.
- On a volume mounted with ownership ignored (the default for external volumes), permissions keep nobody out. `agent-vm doctor` warns.
- A program running as you is outside this model: it can run `agent-vm exec --user root` in any box, read the disk images, edit the store, change the files beside `agent-vm`, and set the environment variables AgentVM reads. Run agents you do not trust in a box, not next to one.
- A `session` without a box (snapshot, report and undo around an agent that runs directly on your Mac) contains nothing. It gives you the report and the undo.

## Building images

- An image build runs with the open network (NAT), because macOS and the tools come from the internet, and recipe steps run as the box user or as root. Use recipes you have read.
- Until the guest daemon is in place, the build reaches the new guest over SSH with the account password, on the Mac's virtual network. It never uses your SSH configuration, keys or `known_hosts`. Whether another virtual machine on that network at that moment could answer in the guest's place was not measured; do not build images while a box you do not trust runs on the `open` network.
- A restore image is trusted because it came from Apple over HTTPS, or is a file you supplied, and Virtualization can load it. AgentVM keeps no checksum of it.
- An agent entry of your own (`Agents/<id>.json`) is shown and asked about once before it is first used, and again when the file changes.

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

What was not measured is named above where it applies.

# Processors and memory for a box

How many CPUs and how much memory to give a box. When unsure, keep the default: **4 CPUs and 8 GB**.

## 1. What will the box do?

| The box is for | Memory | CPUs |
|---|---|---|
| A command-line agent, shell, git, small tests | **8 GB** (4 at the least) | 4 |
| Swift packages and command-line builds | **6-8 GB** (4 at the least) | 4 |
| Web, Node or Python work with a language server and test workers | **12 GB** (8 at the least) | 4 |
| Xcode builds and tests on one iOS simulator | **16 GB** (12 at the least) | 6 |
| Large applications, several simulators, big Rust or C++ builds | **24 GB** (16 at the least) | 8 |
| Xcode's own window open in `box view`, on top of any of these | add 2-4 GB | - |

The Swift row is measured (section 5); the others are estimates to start from.

## 2. Does it fit on your Mac?

A running box takes its whole memory from the Mac. Leave the Mac about 8 GB.

| Your Mac | For boxes | What fits |
|---|---|---|
| 8 GB | 2 GB | Not enough for a box |
| 16 GB | 8 GB | One box of 8 GB, or two of 4-6 GB. No Xcode with a simulator |
| 24 GB | 16 GB | One of 16 GB, or 12 + 4, or two of 8 |
| 32 GB | 24 GB | 16 + 8, or two of 12 |
| 48 GB and up | 40 GB | Two of 16-20 |

At most two boxes run at once (a macOS limit). `agent-vm doctor` prints your Mac's CPU cores and memory.

## 3. Set it

```sh
agent-vm box create work --image dev --cpus 6 --memory-gb 12     # a new box
agent-vm box set work --cpus 4 --memory-gb 8                     # a stopped box; what it holds stays
avm new dev --memory-gb 12                                       # a new box from avm
agent-vm image create dev --ipsw latest --cpus 4 --memory-gb 8   # what an image's new boxes start with
```

`box set` takes effect at the next `box start` and loses nothing, so start with the default and change it if the box turns out too small or too large.

## 4. Signs of a wrong size

| You see | Meaning | Do |
|---|---|---|
| `box start` gives up after 180 seconds: the guest daemon did not answer | The box has less than 3 GB | `box set <box> --memory-gb 4` or more |
| Builds in the box are slow and its disk file grows | Too little memory: the box swaps onto its own disk | Give it more memory |
| `box start` says "the Mac and the boxes may get slow" | Running boxes leave the Mac less than 6 GB | Stop a box, or make one smaller |
| Your Mac's own applications are slow while a box runs | The same | The same |
| More CPUs made a build no faster, or slower | One worker starts per CPU, and each needs memory | Add memory with the CPUs, or go back |

Good to know:

- **The memory is taken from about a minute after the box starts until it stops,** even when the box is idle. Stop boxes you are not using.
- **Nothing is refused when boxes ask for more than the Mac has.** macOS compresses and swaps, and everything gets slow.
- **CPUs are shared, not taken.** An idle box costs the Mac almost no CPU.

## 5. What was measured

On a MacBook Air M5 (10 cores, 24 GB) with macOS 27.0.1, one box at a time, the Mac otherwise idle. The work: a clean release build of swift-syntax (295 source files), with the box's swap sampled every 5 seconds.

| Memory | CPUs | Starts | Build | Peak swap in the box | Taken from the Mac |
|---|---|---|---|---|---|
| 1 GB | 4 | no | - | - | - |
| 2 GB | 4 | no | - | - | - |
| 3 GB | 4 | yes | 161 s | 1.2 GB | 3.1 GB |
| 4 GB | 4 | yes | 141 s | 75 MB | 4.1 GB |
| 6 GB | 4 | yes | 128 s | none | 6.2 GB |
| 8 GB | 4 | yes | 126 s | none | 8.2 GB |
| 12 GB | 4 | yes | 127 s | none | 12 GB |
| 16 GB | 4 | yes | 130 s | none | 16 GB |
| 8 GB | 8 | yes | 124 s | none | 8.2 GB |
| 16 GB | 8 | yes | 127 s | none | 16 GB |

- **6 GB is where a Swift build stops caring.** From 6 to 16 GB the time is the same. At 4 GB it is 12% slower, at 3 GB 28% slower.
- **Twice the CPUs bought almost nothing here.** A release build of one large Swift module is mostly one process. A project with many independent targets, or a test run with a worker per CPU, would gain more; that is not measured.
- **Idle macOS in a box** uses about 1.3 GB that it cannot give up. The rest of what looks used is file cache.
- **A box starts in about 20 seconds** at every size.

Not measured yet: an agent session, a Node project with test workers, and Xcode with an iOS simulator.

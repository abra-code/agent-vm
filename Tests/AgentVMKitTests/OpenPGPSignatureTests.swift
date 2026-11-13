// Tests/AgentVMKitTests/OpenPGPSignatureTests.swift
//
// The distributions' real signed checksum lists (fetched 2026-11-13; each verified with gpg as well)
// against the keys agent-vm pins: they verify, and any change to them, a wrong key, or a list from
// outside the signed part is refused.

import Foundation
import Testing
@testable import AgentVMKit

@Suite struct OpenPGPSignatureTests {
    /// Fedora 45's Cloud aarch64 CHECKSUM, clear-signed by Fedora 45's key.
    static let fedoraList = """
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA256

# Fedora-Cloud-Base-AmazonEC2-45-1.4.aarch64.raw.xz: 567490936 bytes
SHA256 (Fedora-Cloud-Base-AmazonEC2-45-1.4.aarch64.raw.xz) = 37876d647caa2a1bb28e592a6ec576e021433fc70acc21f8e18454e4f3c88187
# Fedora-Cloud-Base-Azure-45-1.4.aarch64.vhdfixed.xz: 598521216 bytes
SHA256 (Fedora-Cloud-Base-Azure-45-1.4.aarch64.vhdfixed.xz) = db94728b1c4fc770e3cf2303dbbc2e00f5e9ba4d2adde44d7942dc0a5cea20fe
# Fedora-Cloud-Base-GCE-45-1.4.aarch64.tar.gz: 583456984 bytes
SHA256 (Fedora-Cloud-Base-GCE-45-1.4.aarch64.tar.gz) = 24fa97c7d23b7b160f4b1b1cc26aab588de5d924aee416ec48b93b8b2d092623
# Fedora-Cloud-Base-Generic-45-1.4.aarch64.qcow2: 596705280 bytes
SHA256 (Fedora-Cloud-Base-Generic-45-1.4.aarch64.qcow2) = 1632acc8bc14d45b6c9596a0acc71b070d3748d1abdcf1a519be5c983bb0286c
# Fedora-Cloud-Base-UEFI-UKI-45-1.4.aarch64.qcow2: 623050752 bytes
SHA256 (Fedora-Cloud-Base-UEFI-UKI-45-1.4.aarch64.qcow2) = f51f556104434e66df591d647d3e54254cc722378c5ac31c4b1c37b15075e4f1
# Fedora-Cloud-Base-Vagrant-libvirt-45-1.4.aarch64.vagrant.libvirt.box: 787600356 bytes
SHA256 (Fedora-Cloud-Base-Vagrant-libvirt-45-1.4.aarch64.vagrant.libvirt.box) = afedd0b6ed8579457deb2808942590c716d05c3780c12141a0b001887213d9ae
-----BEGIN PGP SIGNATURE-----

iQIzBAEBCAAdFiEET1CmEUzVxpdqfxF5ZVpLAvV3hh4FAmrllHUACgkQZVpLAvV3
hh6PkA//RQK9oGz6NhJ4watVk2p60rYbFJCTDyFXgexulhl9Lf+a90xWhKEkB4wL
M4MsYNiN3JE2bCpwORkSPs8KxMI6zX92VkgUVGI3aNp7R4SXyJu/3CBKk12cTNTI
50WjCe5z8WzLJn2cb/9z5Co+xhr1iwk71B9Pg96Vh9D7LIkZEpr91Squ5/H0NgjE
5sss2RpEBYbpz39Uc3lVK0T/WP4iiXIxO7GHM6/ZSgDVAFekI1gk4Ir/ELnPwUy4
8BmijgSiNMUEBWg2ZHMyvgywtr5MHPbK+dfUekioQqL7ZRN5ZjORfmnl6722JSdb
wbcnoEwkISScZmYWsX5W4FHOFwaFVQLkB3pBt7X2W/hYSXuKtqXv8Bjb4XUoiVve
Q00TqHz5S1/ydsQ5CkqFTDqapPj6hXO8RXhwDItQ0mr8aJCMX7nZNu0amGU+aI8j
Qtl04DioddFVvbtOnmc0vagZKWQ9OnYvLUAy+jBVPrVnrns0SDuNUFDYxv4GhW0M
Mw0BnU23ZkzRPvxqosqhjSQ27TJtcQ5wn5R/V4LIQ51GEuI5lpNXwofwamxmoM52
pcEwMWrIj3ViitkBb3jH3cRe08ySjQwQDrdNM9LUWcPHLd18PfYIFBIfTUN+SE7x
gcw7NVCGJglhC9innpQZU4A+PDriHs4sD5UXEwmRRIw1l6RcwRc=
=/m45
-----END PGP SIGNATURE-----
"""

    /// Ubuntu 26.04's cloud image SHA256SUMS (base64), and its detached SHA256SUMS.gpg (base64).
    static let ubuntuList = Data(base64Encoded: "MDE0MDg4ZTVhZWVhZjcyYTkwYThmNjdhZDkyYjc2NDYwMGY1ODNmN2NlMTI2ODU2M2M0Zjc5YzQ2NzRlODFiZiAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFtZDY0djMudGFyLmd6CjAyZDkwOGFjZDBlMzU4Y2U4MWRlNTJlOThmZTE5ZTg0ZmJmNmM2YTMxNjc4Mjk2ZWRkNTgwMDc1MzBkZjg4ZjkgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hbWQ2NHYzLXJvb3QudGFyLnh6CjA2NTg5MzkzODk0OWI4ZWRjZDM4YzUyYTE2NTExZmMyN2EyNDE1YTBkNzJjZjU1MWJlOTgzZTRlNjI5MTUzZjUgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hcm02NC1seGQudGFyLnh6CjA5Yjc3YTg3ZWZjMWQ0NTFmZjFlODY5ZTQ1NjBhNDI2NzE2NWU0OTI5NzM1YmQ1MTZkZTQ1NTE3ODI3Y2RiNmMgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hbWQ2NHYzLnZtZGsKMDllYWMxNjU0ZmY0ZWJmMDBhZjk0ZjhiNDJjNGU3N2M3YTgzNDBhYWRjMWI1NzAwZTYwNDhlOWM5NjI2N2MxMyAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLXJpc2N2NjQuZGFpbHkuMjAyNjA5MjcuMjAyNjEwMTYuaW1hZ2VfY2hhbmdlbG9nLmpzb24KMGE0M2ZkNWU0Y2NkY2MwMDIyMzg0YmE2NTAxN2U1MDk5MjcxYzAwY2E0NTk5MmMxZGZkM2U0MWVkNWFhOGZiMCAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFybWhmLnJlbGVhc2UuMjAyNjA5MjcuMjAyNjEwMTYuaW1hZ2VfY2hhbmdlbG9nLmpzb24KMTM2NmUwYjA2NGNiMjBjNjJjNmRmMmE2ZmE4ODk1Yjk1NmU1ZmMyMTQ1M2U4MzNjNjYwNjQ4NjFmYzZhMGY3YyAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFtZDY0LXJvb3QubWFuaWZlc3QKMTM2NmUwYjA2NGNiMjBjNjJjNmRmMmE2ZmE4ODk1Yjk1NmU1ZmMyMTQ1M2U4MzNjNjYwNjQ4NjFmYzZhMGY3YyAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFtZDY0LnNxdWFzaGZzLm1hbmlmZXN0CjEzNjZlMGIwNjRjYjIwYzYyYzZkZjJhNmZhODg5NWI5NTZlNWZjMjE0NTNlODMzYzY2MDY0ODYxZmM2YTBmN2MgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hbWQ2NHYzLXJvb3QubWFuaWZlc3QKMTM2NmUwYjA2NGNiMjBjNjJjNmRmMmE2ZmE4ODk1Yjk1NmU1ZmMyMTQ1M2U4MzNjNjYwNjQ4NjFmYzZhMGY3YyAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFtZDY0djMuc3F1YXNoZnMubWFuaWZlc3QKMTVkNjk3ZWJkYjE2Y2M5ZGJlNjgzZmM4NTNmYmU3ZDIzMDdjODllYWUzNTY4YWI1ZmY0MjZkMjg2NjhiMDE4YiAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLXJpc2N2NjQudGFyLmd6CjE4YjkyMzY4YWI2Y2QzM2ExNzdiYWRhYjUwNWIyZjQ4OWI5YmZiY2Y4Njg2NmIyMmM2ZDFhZmQxM2ZhNmFhM2IgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1zMzkweC5pbWcKMWRhNDU5YWUyYTU5ZTc2ZTlkZTQ2MGQ0YjA3YzIzN2UxMWQxNWM3YmQ3MmFiNDRjODhhNmJjYzM1ZjA1NGIyZCAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFtZDY0djMuaW1nCjFlNDI2NjIyNDc0MWMzNWQzNGYzNGRmNzNhYjZiNTEwYjg2Y2ZkNmY5OWVjMzlkN2RiZWRmM2Y4MzQwODkwZjQgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1wcGM2NGVsLnRhci5negoyNjRlMDFkMzBlNDcxYjIyODhiZjk5NTY5MjE1NTc5NmE0MzM5NWI0ZGE4OWE0MmIzNTM2NTFiZTdiY2M0MGRjICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctcHBjNjRlbC1seGQudGFyLnh6CjMxMDUyNmJlZDMwZDE3ZjM5ODBmNjUzMzVmNTJkZjE0Y2QyNjMzYTM0NmJjZWMyYWVlZDczZmRkNTExNjVjM2YgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hcm1oZi50YXIuZ3oKM2Y0NjgyN2FlZjljZjFiNTNmMzBiYTE1YmQwOTU2ZGY2NDc0MWE1M2I0ZTU4M2YxYzViNTcyNjc3N2Y4Mjg3OSAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLXMzOTB4LmRhaWx5LjIwMjYwOTI3LjIwMjYxMDE2LmltYWdlX2NoYW5nZWxvZy5qc29uCjQyYzY5YTA3MDAzM2ZjZjBiYjJkYzVmOWJlNGU4YWJhMDBjM2NkZWZhNzllM2JjYzlmZWEwZDNlZTUwNTFjZjEgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1zMzkweC5yZWxlYXNlLjIwMjYwOTI3LjIwMjYxMDE2LmltYWdlX2NoYW5nZWxvZy5qc29uCjQ2YTdjOGY3ZDc3MGQ3ZWY2NzYwMjQwM2Q1NTdmN2ZkYTJkNTRjZDIwM2YxMTA3NjkyMDk3OGNhNjQ0NmVkYmMgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hbWQ2NHYzLnNxdWFzaGZzCjQ4Mjc5MWMyNDgwYjM5NmNhOGY4NzliNGJiYTBmNDlhMTQxNDA4NmYxYTVkMzE4Y2NkZjRlMzNkN2QzNjQxMzQgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hcm02NC1yb290LnRhci54ego0YjQwMmY5YjdiNTNmZWRkZTliMjE0NWE4MTgyZmJkNzM4YzZiMzYxZjU4ODk3ZGU1YzkwMTI5Yjg3Njg2NjVmICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctcmlzY3Y2NC1seGQudGFyLnh6CjUzMDlhMWNmMWU2MWMwNWE0MjIyYjYzODFmMGJiNmMzOGZjMzJjYzk5NDFiZGI3MGUxOGQyZGY4NjVlZTYwYTEgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1yaXNjdjY0LmltZwo1NjQ1ZDAzMThhZDIxZjY0M2ViYjFhYzQ1Njc1MTQ2MjBlOTg5MzM4MGIwN2IwMjAxZmRhMTYzYmFhNWI3ZWI1ICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctYW1kNjQuaW1nCjVlZjAwYTE5MzFlNDVjOWFmNzM0ZjQyYmQ1MGE3NDA1NjhmZDU5NjQ2ZjczOWQ0MjIyMjRkMmI2ZWI4NjZhOTcgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hcm1oZi5tYW5pZmVzdAo1ZmFmN2QzMWIzZTQzNDU4ZjQ3NTZkMWUwMjVhODU3MjQ4ODYxN2IzZmIzZThlYjM4YmYxYTJlY2M3YzQwYzk5ICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctcHBjNjRlbC5tYW5pZmVzdAo1ZmRmYTZlYmFhYzU3N2VlYmMzNmJjN2ZhYTI5YmM2ZWY4YjkxNWViMzVlOTVmYTM0MDhmMjU3ZGFlNzE4YTA1ICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctcHBjNjRlbC1yb290Lm1hbmlmZXN0CjVmZGZhNmViYWFjNTc3ZWViYzM2YmM3ZmFhMjliYzZlZjhiOTE1ZWIzNWU5NWZhMzQwOGYyNTdkYWU3MThhMDUgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1wcGM2NGVsLnNxdWFzaGZzLm1hbmlmZXN0CjYwODYyZWNmYjJhM2MxODk4ZTIwYzZiOGQwMjkwYTBjMDcxODU0ZTc4MzY1ZTNiMjc1NGY2YzA3YWU2ZmM0NDMgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1wcGM2NGVsLnNxdWFzaGZzCjY4MDZkNzg3ZmNlOWYxYzM1ZjdhYTY5ZTcwNzMyMGUxNzkyMDUwMTQ4ZmViNmVmNTliOThmOTY5ODUyNzFlZDggKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1zMzkweC50YXIuZ3oKNmRhNTdlODRiOWVkZDZiZDZhNjZmYzZkMzExOWViYjcwMmRkMjE3NGJhMzMzZDNiNmNjOGZlZjhiMTE4N2FjZSAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFybWhmLXJvb3QubWFuaWZlc3QKNmRhNTdlODRiOWVkZDZiZDZhNjZmYzZkMzExOWViYjcwMmRkMjE3NGJhMzMzZDNiNmNjOGZlZjhiMTE4N2FjZSAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFybWhmLnNxdWFzaGZzLm1hbmlmZXN0CjcwZmE2OTUxOGMwNjk3NWUwYzA1MmE5MGZkMWIyMGYxNDU4ZGJlZTQwN2I3MmEzNzBjNjNkMWEwMTlkOGM4MjUgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1yaXNjdjY0Lm1hbmlmZXN0CjcxOTUxMDA2ZTEyZDNlN2Q1NDE2OTFjNjY4OWY0ZDA5ZTgyMDE5ZmE3ZDhmM2Y2M2UwM2Q0ODc5NjAwYTkzNmIgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1zMzkweC1yb290LnRhci54ego3MmE4YTQxMGUyN2YwYzkwNTYwMTBmZWFiMDRlZDg4ZjJkN2IzODdjYmZlMzgxYzFmZDRiOWY5MzM3ZDc3MjFkICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctczM5MHgtbHhkLnRhci54ego3MmM2YTE4ZDk5YzJmZGY2NWU0YmJhMjczOTg5MWVmOTlkNDU2OGRjZGIyMjMzYmZjNzYyNDcwZjQxMWM5NWUxICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctYXJtNjQudGFyLmd6Cjc0ZWIyYTcyZjgxZWY2MzUwNzBkNTQ1NzA5ZGE3YjI0ZmIzMWFlMjdmMjRiOGM2YjRiYzRkYTQ0N2Y3MzYxMDQgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hcm1oZi5zcXVhc2hmcwo3Njk0YjExY2I3N2RjMWI3YjBmNDI4NWQ2OGRjMTc2YThjYTk4ZGY2MWYwMzg5OWU4MTcwZDE4NTA5Y2ExMjRmICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctcHBjNjRlbC5pbWcKODBlOGMzMGU4MDRiOWEwNDNkNDU0YTMxZjE1MzQ2ZTYyMzMzNWYzNjIzM2ZhMTJjMGQ2MjNjMjljYTI1NTliNiAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLXBwYzY0ZWwuZGFpbHkuMjAyNjA5MjcuMjAyNjEwMTYuaW1hZ2VfY2hhbmdlbG9nLmpzb24KODJjMTI3NTU2MTNlNjQ2ODkyNmUwOWU0MmI3ZGNmMjI5NDU0M2QxNjZjYjgwOGFiM2NkNzI5N2NiYjc1OGVlZCAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFybWhmLWx4ZC50YXIueHoKODMwZTY4YjA4OTJkMTRlNWU4ODYwNDhhMjM3OWEyODdmNjUyYzg4ZWUzNDQwZTRhYWIwODIwZjA1Y2VjOGJkMiAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFybTY0Lm1hbmlmZXN0Cjg5OWVlZWFiYzc4ZTgzMDYyMjU2ZmNjMTA2NmZkZjk2OWZlOTRlNGM4MjhlOTkxNmM5NWNkNjgyNzc1NzM1MTUgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hbWQ2NC5zcXVhc2hmcwo4YmE4NmYxZDQzNmMxNmEzNDc5ZTlkNjQ4MGIwZjBmMGViYWZhYzAzMjNhYzY4YjM3MDQyMGJkNTZjOGQ5M2Y4ICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctYW1kNjR2My1seGQudGFyLnh6CjhlNWMzYjZjNjFlYWQzN2JlNzJhMmNjMjRkMzRhOGFmN2MzYWVlNTUyNzdmNWYyZTk4NmYwZmVhYTg4MDI5MTMgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hbWQ2NC50YXIuZ3oKOGViODc2YzJjY2M0YjZmZjg5ZTRhNjVkNTExODE1OTIzYjI4NWUwNDUwM2JhNDY1ODA5YmY1ODdmNzYzZGEyNCAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFybTY0LmltZwo5NGEzMzgzMmRjNGYwYzc3NzVlZWNlODcwOWVlODg2MWVhOTkzMzk3YTUwYWExNTkxYTU5YTY5MTlhOTc1ZDUzICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctYW1kNjQuZGFpbHkuMjAyNjA5MjcuMjAyNjEwMTYuaW1hZ2VfY2hhbmdlbG9nLmpzb24KOTRhMzM4MzJkYzRmMGM3Nzc1ZWVjZTg3MDllZTg4NjFlYTk5MzM5N2E1MGFhMTU5MWE1OWE2OTE5YTk3NWQ1MyAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFtZDY0djMuZGFpbHkuMjAyNjA5MjcuMjAyNjEwMTYuaW1hZ2VfY2hhbmdlbG9nLmpzb24KOWY0NzYzYzFmYjRmNTQxOTNhOGVlYzEzMzg0YWQzODhiNGJkNDE4OTJkMWU0YTFjNTMzZGM5MzRiZTdjMmExOCAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFybWhmLmltZwphMzdkMmU3YzI1ODljYzdiNmE3N2YxYzQyYmI3YTg1MDgxNGYzZjU5NmJlNDZjNGUzY2I4ZTJkZDJlMTcyMGNiICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctczM5MHgtcm9vdC5tYW5pZmVzdAphMzdkMmU3YzI1ODljYzdiNmE3N2YxYzQyYmI3YTg1MDgxNGYzZjU5NmJlNDZjNGUzY2I4ZTJkZDJlMTcyMGNiICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctczM5MHguc3F1YXNoZnMubWFuaWZlc3QKYTUzNWQxMDJiYjlhNGQyNWMxZjYxNDBlNWQ0MzZjZTE2YWU4YWNhYWViNTdkMTViM2JkYjNiNWZhNDU4M2YxYSAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFybTY0LmRhaWx5LjIwMjYwOTI3LjIwMjYxMDE2LmltYWdlX2NoYW5nZWxvZy5qc29uCmFhOTRhZDUzYjA2ZDYyMDZiYTkzZGE2NmRmODM4NjFiYzFmNzc5ZWI5MWRlYjA3MjM5NTVkMjE3YjU4MGU1OGYgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hcm02NC1yb290Lm1hbmlmZXN0CmFhOTRhZDUzYjA2ZDYyMDZiYTkzZGE2NmRmODM4NjFiYzFmNzc5ZWI5MWRlYjA3MjM5NTVkMjE3YjU4MGU1OGYgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hcm02NC5zcXVhc2hmcy5tYW5pZmVzdAphZDBmZTA1MjZiZjM0M2M1NjUxMmFkN2ZiMmRmMTQzMmFmOWY4ZWJjOGIwNmQ1ODdhNWUwZTRhNDNlZDJjYmFmICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctYW1kNjR2My5vdmEKYWQxZTM3YjllN2E2NDkxZTVmNTliM2M1OGZlNmVjNmQxMTcwZWViNjViYWYxNWY2ODAyNzg5YWFiOTNkNjIzMCAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFybTY0LnJlbGVhc2UuMjAyNjA5MjcuMjAyNjEwMTYuaW1hZ2VfY2hhbmdlbG9nLmpzb24KYjU3NTI1NTczMzg2ZGVjZDVmY2QzODFiOTVkZGJiYzFmMDI2Y2IwOWE3MjRiZDUwZDE5ZGRjNmVjNGNlYzc1MCAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLXJpc2N2NjQtcm9vdC50YXIueHoKYjU3YzI5YmEzMzhmMTFkZjg5NzI1ZDE1OWZkMWNiOTMyMWFmYjFkZTkwMTc0MDY4NjFlNzExMTg0OWJkMGQyYSAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLXMzOTB4Lm1hbmlmZXN0CmJhNmY4NGFhM2U4ZTRmYjQ4M2Q0Nzg4ZjM2NjVkMTE1YjJhYTE4MmVjZTI4N2EyMDIyNzljN2E3NzdkNjdkM2UgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hcm02NC5zcXVhc2hmcwpjOWE1YmUzMmRlMDhlYTg0MjliZTdjYTcxOTI0MzcyYjA1NmZmN2FiMjI4MjRjYjI4NTdjNGE5YTZhNjkwNGY4ICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctYW1kNjQtcm9vdC50YXIueHoKZDUyYWRiNGFlNWE3MzFkY2JlZDVlYmU2NjQ3NTdkMjQ4ZjZjMDk5NGRjNjIzMGM4ODg5MWYxNzYzYTgxODA4MyAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFtZDY0Lm1hbmlmZXN0CmQ1MmFkYjRhZTVhNzMxZGNiZWQ1ZWJlNjY0NzU3ZDI0OGY2YzA5OTRkYzYyMzBjODg4OTFmMTc2M2E4MTgwODMgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hbWQ2NHYzLm1hbmlmZXN0CmQ2MWI5NjZkNTIyMjY1NzgxYmVjOGI0OWJmNjViZTcyZWEyMWQwZGQ1YTdkNzYyMGNhMzdiOWE5N2VmZDUzMjIgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1zMzkweC5zcXVhc2hmcwpkYzJiZTI2NzNiZTM3YWYyMDY2YTcxNzFjNTlkZWNhMmE5ZmI0ZDc4MjQ3YjdhOTgyYjFhMGJkOTI1MTIzNWY5ICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctcHBjNjRlbC5yZWxlYXNlLjIwMjYwOTI3LjIwMjYxMDE2LmltYWdlX2NoYW5nZWxvZy5qc29uCmRlNTE4YjMyNGYzMjY4ZDk1YzcxMjdmMGE3Y2VjY2JhOTllM2E1MWRmYmZmZjZmNDc1OTQ1NGQ1OWRmZjhjYjUgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1wcGM2NGVsLXJvb3QudGFyLnh6CmRlN2E2NWY2MmZiNWM2MTg3NjdiOGUwYmRmYjUxNTBjYmRmZGY1MGI3NDEwM2E0NTM1Njk5MTY3YjU1MjMyMzYgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1yaXNjdjY0LnNxdWFzaGZzCmU1OTEwNjc1OWZiZGYxY2JjOTdhYTNkMzUxNDkzYjhkZTQ2MjgzNjRkY2FlYTRlOTIwMWY0NDYyZTUzNjY1ZDIgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hbWQ2NC1seGQudGFyLnh6CmViZDg0YzcyMWFlYmJjODA0ODUwZmUxNWEzZTBhMWZhMDk5YzgwZGVjZDBmOWUyM2EyOGEwY2I0MDI1M2U1YTkgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hbWQ2NC5yZWxlYXNlLjIwMjYwOTI3LjIwMjYxMDE2LmltYWdlX2NoYW5nZWxvZy5qc29uCmViZDg0YzcyMWFlYmJjODA0ODUwZmUxNWEzZTBhMWZhMDk5YzgwZGVjZDBmOWUyM2EyOGEwY2I0MDI1M2U1YTkgKnJlc29sdXRlLXNlcnZlci1jbG91ZGltZy1hbWQ2NHYzLnJlbGVhc2UuMjAyNjA5MjcuMjAyNjEwMTYuaW1hZ2VfY2hhbmdlbG9nLmpzb24KZWM5MjY3MjNiMDVkYTQ0NTg0OTdiOGIyYmEyMGZkMTdhNmM0NzE5Y2RmZGFmYmNjNmJmMTA3OTFjMDJjYmQ5YyAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLXJpc2N2NjQtcm9vdC5tYW5pZmVzdAplYzkyNjcyM2IwNWRhNDQ1ODQ5N2I4YjJiYTIwZmQxN2E2YzQ3MTljZGZkYWZiY2M2YmYxMDc5MWMwMmNiZDljICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctcmlzY3Y2NC5zcXVhc2hmcy5tYW5pZmVzdApmMTEzMTY3YmU1YjZhYTBkMGQ1OTU1MGU2OTYwOWY2MDkzYmExNTAzYWRhNGQzMjMyZjI0MDUwZDU5MDIxNzcxICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctYXJtaGYuZGFpbHkuMjAyNjA5MjcuMjAyNjEwMTYuaW1hZ2VfY2hhbmdlbG9nLmpzb24KZjIxMTViZDlmY2MyNTM2OWI3MGY3MzM1ZjhkZjk3YTk4MWFmNmYyYTQ2OTljYWQwYjYzYzY4NDZmODk4NTE5OCAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLXJpc2N2NjQucmVsZWFzZS4yMDI2MDkyNy4yMDI2MTAxNi5pbWFnZV9jaGFuZ2Vsb2cuanNvbgpmNGE5OGJkZjM3ZWI5OTM4ZmQyYTcwYzdmYWQxMWZjMDY3ZDA1MDdiNTBkMWU3ZTZjMmQ1OTViMmI3M2RkZTZkICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctYW1kNjQudm1kawpmNzg4Y2FkYmYzZDRlYzY2NGRhNDU1ZjFmNGU3OTRjYjE1YTRmZDc0MTEyMDBiMWEyMjM0YjRjYjJkMzRlMDE2ICpyZXNvbHV0ZS1zZXJ2ZXItY2xvdWRpbWctYXJtaGYtcm9vdC50YXIueHoKZmI1MmVlYjc5YzBlNzFiY2U2NzU3MjlhN2Q2N2Y1YTBjNjY5MWRlZWEwNGQyYjEzYTUyNGM3ZTM3NmQ3NGVjMSAqcmVzb2x1dGUtc2VydmVyLWNsb3VkaW1nLWFtZDY0Lm92YQo=")!
    static let ubuntuSignature = Data(base64Encoded: "LS0tLS1CRUdJTiBQR1AgU0lHTkFUVVJFLS0tLS0KCmlRSXpCQUFCQ2dBZEZpRUUwdXRFWW0vZHd3dFJQVnUzR2wxc1RIMjRmSUVGQW1yWGxJSUFDZ2tRR2wxc1RIMjQKZklFclNoQUFrcjRRUVk5MnErS3h2RkRmTzdxYlBkWlJ0TFV1TFFXUjZDNzJrV1NNZmNiZktjQnlTVFhkRFpPYwpMeDczNnp1ME5BSXd4bU94USszYWRtTXAzUFE1OEtURlJTVEVKOWlTN3RDUEYvK2lKWkwrenZkeTNoTk5tRmR3Ck1YTVpGRWUvNDVUQ3Q5WVp4N2pkRUFlbkQ0aHRQcS9OZWlTNjBqY2d5TGhsNHJQQ3h0M255cHkwd0ticExXQmMKYWU5d3NuSm9EZWU2OGFVT2hMbk9UWHdNUFVUVnpqVUlwNWUvODkzSGR5WkwxWWp6ZS96M0VQRkRYUnRtdDdLOApUMkdWYWdGR0dsdjNhbFpTbFQ4b2xVSk8yVVhrL1VXeDFBWG92eGpOTTlqL2oxdDY5b0dkNnRPRWpuVWtOcFBVCitOeDJhRy80azEwRGQxRVlRWml5Q3RpcVJ0SUV0SldrRHdVVHhxK2ZWTzkrQzRiaWZBay9pTEptdFMwazhkdmkKMVFFZDZySEZXVXZrVVl5ZUdDam5oK1owbnp5aUpqdjZvUHJGbjBQQ2U3Vk1FZmU1VmJXL1lMbVF0OW5oRmFvWApuZlZabXptbUVCSjlFVXo0MGFIVzN6R0tFUTFpMlJiR1B0b2g0TTFxT3MrU2t5WC9SOVhUSS82bzJraHlCdzdxCm1ZRDBvM0lMWVBOZk5ZQU9Kb2dVbUJoMUJYVzlic2J2dVErc1hudWc1cDB5U0VOcTF4SFpGWURmZU4yVlkxOCsKNkRaUXQxczk4OCs0QWJmQkJub1pQVldlSDJzYzltTE9GdHZxY2FXb2xuMmQ3WnN0RnBIZjNIUXBqSUNsYnRxNApZcHdsVllIYkVSMnRrVUxPV2tWdzZhMmFwUG01a2hKQU94dHJTcXRBMTM2aE5oOGNvUWc9Cj1lWXdMCi0tLS0tRU5EIFBHUCBTSUdOQVRVUkUtLS0tLQo=")!

    @Test func fedorasClearSignedListVerifiesAndOnlyTheSignedTextComesBack() throws {
        let text = try OpenPGP.verifyCleartext(Self.fedoraList, key: LinuxSigningKeys.fedora45, fingerprint: LinuxSigningKeys.fedora45Fingerprint)
        #expect(text.hasPrefix("# Fedora-Cloud-Base-AmazonEC2-45-1.4.aarch64.raw.xz: 567490936 bytes"))
        #expect(!text.contains("PGP"))
        let fedora = try LinuxBase.named("fedora-45")
        #expect(try LinuxBase.digest(for: fedora.file, inList: text, kind: .sha256) == "1632acc8bc14d45b6c9596a0acc71b070d3748d1abdcf1a519be5c983bb0286c")
    }

    @Test func aChangedFedoraListIsRefused() {
        // One digit of the Generic image's digest
        let changed = Self.fedoraList.replacingOccurrences(of: "= 1632acc8", with: "= 1632acc9")
        #expect(changed != Self.fedoraList)
        #expect(throws: OpenPGP.Problem("the data is not what was signed")) {
            _ = try OpenPGP.verifyCleartext(changed, key: LinuxSigningKeys.fedora45, fingerprint: LinuxSigningKeys.fedora45Fingerprint)
        }
        // A line added before the signed part is not read, and one added inside is refused
        let added = Self.fedoraList.replacingOccurrences(of: "# Fedora-Cloud-Base-Generic", with: "SHA256 (x) = 00\n# Fedora-Cloud-Base-Generic")
        #expect(throws: OpenPGP.Problem("the data is not what was signed")) {
            _ = try OpenPGP.verifyCleartext(added, key: LinuxSigningKeys.fedora45, fingerprint: LinuxSigningKeys.fedora45Fingerprint)
        }
        // Text outside the signed message is never returned
        let wrapped = "SHA256 (evil.qcow2) = " + String(repeating: "0", count: 64) + "\n" + Self.fedoraList + "\nSHA256 (evil2.qcow2) = 00\n"
        let text = try? OpenPGP.verifyCleartext(wrapped, key: LinuxSigningKeys.fedora45, fingerprint: LinuxSigningKeys.fedora45Fingerprint)
        #expect(text != nil && !(text ?? "").contains("evil"))
    }

    @Test func aSignatureByAnotherKeyIsRefused() {
        // Fedora's list against Ubuntu's key: the key block's primary key is not the pinned one
        #expect(throws: OpenPGP.Problem("signed by 4F50A6114CD5C6976A7F1179655A4B02F577861E, not by D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81")) {
            _ = try OpenPGP.verifyCleartext(Self.fedoraList, key: LinuxSigningKeys.ubuntuCloudImage, fingerprint: LinuxSigningKeys.ubuntuCloudImageFingerprint)
        }
        // A pinned fingerprint that is not the key block's
        #expect(throws: OpenPGP.Problem("the key block's primary key is not D2EB44626FDDC30B513D5BB71A5D6C4C7DB87C81")) {
            _ = try OpenPGP.verifyCleartext(Self.fedoraList, key: LinuxSigningKeys.fedora45, fingerprint: LinuxSigningKeys.ubuntuCloudImageFingerprint)
        }
    }

    @Test func ubuntusDetachedSignatureVerifies() throws {
        try OpenPGP.verifyDetached(data: Self.ubuntuList, signature: Self.ubuntuSignature, key: LinuxSigningKeys.ubuntuCloudImage,
                                   fingerprint: LinuxSigningKeys.ubuntuCloudImageFingerprint)
        var changed = Self.ubuntuList
        changed[100] ^= 0x01
        #expect(throws: OpenPGP.Problem.self) {
            try OpenPGP.verifyDetached(data: changed, signature: Self.ubuntuSignature, key: LinuxSigningKeys.ubuntuCloudImage,
                                       fingerprint: LinuxSigningKeys.ubuntuCloudImageFingerprint)
        }
        var badSignature = Self.ubuntuSignature
        badSignature[badSignature.count - 10] ^= 0x01
        #expect(throws: OpenPGP.Problem.self) {
            try OpenPGP.verifyDetached(data: Self.ubuntuList, signature: badSignature, key: LinuxSigningKeys.ubuntuCloudImage,
                                       fingerprint: LinuxSigningKeys.ubuntuCloudImageFingerprint)
        }
    }

    @Test func thePinnedKeysAreTheirFingerprints() throws {
        #expect(try OpenPGP.publicKeys(armored: LinuxSigningKeys.fedora45).first?.fingerprint == OpenPGP.hexBytes(LinuxSigningKeys.fedora45Fingerprint))
        #expect(try OpenPGP.publicKeys(armored: LinuxSigningKeys.ubuntuCloudImage).first?.fingerprint == OpenPGP.hexBytes(LinuxSigningKeys.ubuntuCloudImageFingerprint))
        // Each base that signs names its key; Debian signs nothing
        #expect(try LinuxBase.named("debian").signature == nil)
        #expect(try LinuxBase.named("ubuntu").signature == .detached(file: "SHA256SUMS.gpg", key: LinuxSigningKeys.ubuntuCloudImage, fingerprint: LinuxSigningKeys.ubuntuCloudImageFingerprint))
        #expect(try LinuxBase.named("fedora").signature == .cleartext(key: LinuxSigningKeys.fedora45, fingerprint: LinuxSigningKeys.fedora45Fingerprint))
    }

    @Test func armorChecksItsCRC() {
        let broken = LinuxSigningKeys.fedora45.replacingOccurrences(of: "mQINBGiIvJgBEAD3", with: "mQINBGiIvJgBEAD4")
        #expect(throws: OpenPGP.Problem("the PGP public key block's checksum does not match")) {
            _ = try OpenPGP.publicKeys(armored: broken)
        }
    }

    @Test func aClearSignedListWithCRLFLineEndingsVerifies() throws {
        // RFC 9580 7.2: line endings are canonicalized, so the same message with CR LF verifies,
        // and the same text comes back
        let plain = try OpenPGP.verifyCleartext(Self.fedoraList, key: LinuxSigningKeys.fedora45, fingerprint: LinuxSigningKeys.fedora45Fingerprint)
        let crlf = Self.fedoraList.replacingOccurrences(of: "\n", with: "\r\n")
        #expect(try OpenPGP.verifyCleartext(crlf, key: LinuxSigningKeys.fedora45, fingerprint: LinuxSigningKeys.fedora45Fingerprint) == plain)
        // An armored detached signature with CR LF line endings too
        let armored = String(decoding: Self.ubuntuSignature, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n")
        try OpenPGP.verifyDetached(data: Self.ubuntuList, signature: Data(armored.utf8), key: LinuxSigningKeys.ubuntuCloudImage,
                                   fingerprint: LinuxSigningKeys.ubuntuCloudImageFingerprint)
    }

    @Test func trailingWhitespaceIsNotSignedAndNeverReturned() throws {
        // Trailing spaces and tabs are not part of what was signed (RFC 9580 7.2): anyone on the
        // way may add them, so the signature still holds, and they must not reach the list's reader
        let padded = Self.fedoraList.replacingOccurrences(of: "1632acc8bc14d45b6c9596a0acc71b070d3748d1abdcf1a519be5c983bb0286c\n",
                                                          with: "1632acc8bc14d45b6c9596a0acc71b070d3748d1abdcf1a519be5c983bb0286c \t \n")
        #expect(padded != Self.fedoraList)
        let text = try OpenPGP.verifyCleartext(padded, key: LinuxSigningKeys.fedora45, fingerprint: LinuxSigningKeys.fedora45Fingerprint)
        #expect(text == (try OpenPGP.verifyCleartext(Self.fedoraList, key: LinuxSigningKeys.fedora45, fingerprint: LinuxSigningKeys.fedora45Fingerprint)))
        let fedora = try LinuxBase.named("fedora-45")
        #expect(try LinuxBase.digest(for: fedora.file, inList: text, kind: .sha256) == "1632acc8bc14d45b6c9596a0acc71b070d3748d1abdcf1a519be5c983bb0286c")
    }
}

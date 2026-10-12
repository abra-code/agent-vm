# Packaging agent-vm

`agent-vm.pkgbld` is the installer package's project, for PackageBuilder.app. It builds a signed `agent-vm_<version>.pkg` that installs for the user who runs it, into their home folder, with no administrator password:

```
~/.local/share/agent-vm/versions/<version>/   agent-vm, agent-vm-guest, packs.json, agents.json, Recipes/, LICENSE
~/.local/bin/agent-vm -> ../share/agent-vm/versions/<version>/agent-vm
~/.local/bin/avm      -> ../share/agent-vm/versions/<version>/agent-vm
```

agent-vm follows the link to find the files beside its real executable, and knows it is `avm` by the name it was started as.

The package has two parts, both ticked by default and both shown under Customize:

- **agent-vm and avm** installs the version folder, and its `postinstall` points the two links in `~/.local/bin` at it. A new version goes into a folder of its own and the links move, so box supervisors and image jobs started by the previous version keep running from files nothing touches. Earlier version folders are then removed, unless a program is still running from one (a later install removes it), so versions do not pile up at about 60 MB each. Nothing is removed while an `agent-vm` or `avm` started through the links is running, since the list of running programs does not say which version that is.
- **The component's identifier ends with the version** (`com.abracode.pkg.agent-vm.<version>`). Installer deletes what the last receipt of an identifier lists when a package with the same identifier is installed again, so with one identifier for every version each install emptied the folder of the version before it, under whatever still ran from it. Packages before 0.7.43 had the one identifier, `com.abracode.pkg.agent-vm`; their last receipt stays and does no harm.
- **Add ~/.local/bin to your shell's PATH** runs a script PackageBuilder provides. It adds a marked block to the login shell's startup file (`~/.zprofile` for zsh, the first of `~/.bash_profile`, `~/.bash_login` or `~/.profile` for bash, a file in `~/.config/fish/conf.d` for fish) and changes nothing when one of the shell's files already mentions `.local/bin`. The block sits between `# >>> agent-vm installer >>>` and `# <<< agent-vm installer <<<`. What it did is in `/var/log/install.log`.

## Building a release

1. Bump the version in the sources, then build and sign with the Developer ID:

   ```sh
   Scripts/build.sh --require-linux-guest --identity "Developer ID Application: Tomasz Kukielka (T9NM2ZLDTY)"
   ```

   The signed files land in `.build/signed/release`, the project's artifacts folder. `--require-linux-guest` fails the build when `linux/agent-vm-guest` (the guest daemon for Linux boxes) cannot be built: the package carries it, and a release without it could not create Linux images. It is an ELF program, not signed, and the package installs it in a `linux` folder beside the others (it has the macOS daemon's name) without the signature checks the two Mach-O programs get.

2. Set the package version and the component's identifier, which ends with the version, and build. The version check fails the build when the binaries report a different version, which is what catches a stale artifacts folder; the fast shell tests (`Tests/Shell/run.sh fast --filter package_project`) fail when the document's version or identifier is not the tool's:

   ```sh
   PB=<path to>/PackageBuilder.app/Contents/Resources/Agents/pkgbuilder
   "$PB" set Packaging/agent-vm.pkgbld /PROJECT/VERSION 0.3.13
   "$PB" set Packaging/agent-vm.pkgbld /COMPONENTS/0/IDENTIFIER com.abracode.pkg.agent-vm.0.3.13
   "$PB" build Packaging/agent-vm.pkgbld
   ```

   Or open the document in PackageBuilder and press Build Package (after the two values are set: PackageBuilder does not put the version into an identifier by itself). The signed package lands in `.build/package`.

   Check that it carries the Linux guest daemon (the listing under "Checking a package without installing it" must show `linux/agent-vm-guest` and the `Recipes/linux-*` folders), and after installing, that `agent-vm doctor` has the line `linux guest daemon: next to agent-vm`.

3. Notarize it with Notarize.app, and staple the ticket.

4. Attach the stapled package to the GitHub release.

## Checking a package without installing it

```sh
installer -dominfo -pkg .build/package/agent-vm_0.3.13.pkg   # prints CurrentUserHomeDirectory
"$PB" inspect .build/package/agent-vm_0.3.13.pkg             # "Installs for: user", the payload, the signature
```

To try an install by hand: `installer -pkg <pkg> -target CurrentUserHomeDirectory` as yourself, no `sudo`. To undo it:

```sh
rm -rf ~/.local/share/agent-vm/versions/<version>
rm ~/.local/bin/agent-vm ~/.local/bin/avm       # or point them back at another version
pkgutil --volume "$HOME" --forget com.abracode.pkg.agent-vm.<version>
# and remove the "agent-vm installer" block from ~/.zprofile if the PATH part added one
```

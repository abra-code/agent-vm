# Packaging agent-vm

`agent-vm.pkgbld` is the installer package's project, for PackageBuilder.app. It builds a signed `agent-vm_<version>.pkg` that installs for the user who runs it, into their home folder, with no administrator password:

```
~/.local/share/agent-vm/versions/<version>/   agent-vm, agent-vm-guest, packs.json, agents.json, Recipes/, LICENSE
~/.local/bin/agent-vm -> ../share/agent-vm/versions/<version>/agent-vm
~/.local/bin/avm      -> ../share/agent-vm/versions/<version>/agent-vm
```

agent-vm follows the link to find the files beside its real executable, and knows it is `avm` by the name it was started as.

The package has two parts, both ticked by default and both shown under Customize:

- **agent-vm and avm** installs the version folder, and its `postinstall` points the two links in `~/.local/bin` at it. A new version goes into a folder of its own and the links move, so box supervisors started by the previous version keep running from files nothing touches. Earlier version folders are not removed.
- **Add ~/.local/bin to your shell's PATH** runs a script PackageBuilder provides. It adds a marked block to the login shell's startup file (`~/.zprofile` for zsh, the first of `~/.bash_profile`, `~/.bash_login` or `~/.profile` for bash, a file in `~/.config/fish/conf.d` for fish) and changes nothing when one of the shell's files already mentions `.local/bin`. The block sits between `# >>> agent-vm installer >>>` and `# <<< agent-vm installer <<<`. What it did is in `/var/log/install.log`.

## Building a release

1. Bump the version in the sources, then build and sign with the Developer ID:

   ```sh
   Scripts/build.sh --identity "Developer ID Application: Tomasz Kukielka (T9NM2ZLDTY)"
   ```

   The signed files land in `.build/signed/release`, the project's artifacts folder.

2. Set the package version and build it. The version check fails the build when the binaries report a different version, which is what catches a stale artifacts folder:

   ```sh
   PB=<path to>/PackageBuilder.app/Contents/Resources/Agents/pkgbuilder
   "$PB" set Packaging/agent-vm.pkgbld /PROJECT/VERSION 0.3.13
   "$PB" build Packaging/agent-vm.pkgbld
   ```

   Or open the document in PackageBuilder and press Build Package. The signed package lands in `.build/package`.

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
pkgutil --volume "$HOME" --forget com.abracode.pkg.agent-vm
# and remove the "agent-vm installer" block from ~/.zprofile if the PATH part added one
```

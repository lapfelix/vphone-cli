# Research Guests boot (developer workflow)

[Documentation](../README.md) · [Research findings](../../Research/Host/research_guests_only.md)

This workflow boots an **already restored and CFW-installed** research VM with
Apple's signed `vrevm`, normal SIP, and Research Guests enabled. It uses a
guest debugger to supply the success result for the existing, selected
AVPBooter digest patch. It does not run the usual `vphone-cli vm launch`.
After boot, `vphone-cli vm research-view` opens a separate viewer over the
guest's authenticated host-only TCP API. `VPhone.bundle` is a bundle of tools,
not a Mac app to open in Finder.

The verified host was macOS 27.0.1 (26A434) with CSR flags `0x1000`: Research
Guests enabled and the SIP debug exception disabled. The script supports only
the installed Apple research AP ROM whose SHA-256 is
`301bc973b56e86a9906bb6002d008015a57c9e07b5f191260717b97a62589072`.
It checks this hash before starting a VM; another host ROM needs its own
research and validation.

## Starting state

You need:

- An Apple Silicon Mac with `csrutil allow-research-guests enable` already
  applied in Recovery, and Apple's `vrevm` license accepted with
  `sudo /System/Library/SecurityResearch/usr/bin/vrevm license`.
- Xcode and LLDB on the build machine. This developer script uses LLDB for
  the guest debugger; the distributed `VPhone.bundle` does not depend on it.
- A built `VPhone.bundle` containing `vphone-cli`. The script defaults to
  `.build/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli`
  in this checkout. `VPHONE_CLI` can name another built CLI.
- A stopped vphone machine with its patched boot images and a patch plan
  enabling `avpbooter-boot-dgst_bypass`. `vphone-cli cfw install` must have
  completed on its disk and cached that installed Preboot ticket as
  `<VPHONE_LIBRARY_ROOT>/<VPHONE_MACHINE>/ResearchBootTicket.der`. The
  extracted restore tree is needed to prepare images afresh; if it has been
  removed, the machine must already have all nine personalized IMG4s under
  `ResearchBoot/` for `--reuse-prepared`.
- A stopped, already restored VRE VM at
  `<VREVM_DATADIR>/<VREVM_NAME>.vm/`, with `config.plist` and its CFW-installed
  `Disk.img`. Its research platform is `vresearch101` (`platformType = 3`),
  it uses Apple's **implicit default AP ROM** and `hostOnly` networking, and
  its ECID, disk, NVRAM and SEP storage belong to the same restored guest. The
  ticket above must come from that disk's installed Preboot volume. Do not use
  a fresh DFU ticket in its place: its SHA-384 can select a different Preboot
  directory during boot. Snapshot `Disk.img`, `SEPStorage` and
  `AuxiliaryStorage` together; a disk-only rollback on an older scratch VM
  was followed by a SEP panic.
- A `cfw install` made with the current bundle on that guest disk. It also
  provisions `ResearchAPIToken` in the vphone machine folder and
  `/usr/lib/vphone/research-api-token` in the guest for the TCP viewer.

This procedure starts after the restore and CFW installation. It does not
create the VRE VM, perform a restore, or copy a disk between machines.

## Run

From the repository checkout, build the complete bundle if needed:

```sh
xcodebuild -workspace VPhone.xcworkspace -scheme VPhone \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/XcodeBundle build
```

Then give the script the vphone library and machine, followed by Apple's VRE
data directory and VM name. Pass absolute paths for the directories:

```sh
scripts/ResearchGuestsBoot.zsh \
  /absolute/path/to/vphone-library vphone-machine \
  /absolute/path/to/vrevm-datadir vrevm-name
```

If the CLI bundle is elsewhere, set its executable path for this invocation:

```sh
VPHONE_CLI=/absolute/path/to/VPhone.bundle/Contents/MacOS/vphone-cli \
  scripts/ResearchGuestsBoot.zsh \
  /absolute/path/to/vphone-library vphone-machine \
  /absolute/path/to/vrevm-datadir vrevm-name
```

The standard invocation prepares IMG4s from the retained restore tree. In
the tested normal CFW install, that tree was removed. Repeat a boot with the
same installed ticket and saved `ResearchBoot/` images by adding a fifth
argument:

```sh
scripts/ResearchGuestsBoot.zsh \
  /absolute/path/to/vphone-library vphone-machine \
  /absolute/path/to/vrevm-datadir vrevm-name --reuse-prepared
```

`--reuse-prepared` validates all nine saved IMG4 containers, their expected
component tags and their embedded ticket against `ResearchBootTicket.der`
before starting the VM. It cannot reconstruct missing images. If the
installed ticket or firmware changes, prepare new images from the matching
restore tree instead of reusing the old ones.

The script first runs `vphone-cli vm research-upload --prepare-only`, passing
`--reuse-prepared` when selected. That checks the patch plan, installed
ticket, VRE configuration and either the restore sources or nine saved
IMG4s before starting the VM. In standard mode it writes the personalized
IMG4s under the vphone machine's `ResearchBoot/` directory. It then starts `vrevm`
in DFU, connects LLDB to the **AP** guest debugger, and arms a conditional
hardware breakpoint at `0x102b88` on the verified ROM. On a failing digest
return, LLDB sets guest `x0` to zero. `vm research-upload` sends the prepared
boot chain over the VM's ECID-scoped virtual USB connection. The script waits
for `Early boot complete` in the VRE serial log and leaves the VM running.

Success prints `iOS early boot completed` and the serial log path. Press
Control-C to stop the VM; the script then prints its temporary controller
log directory. On failure, inspect the reported VRE, LLDB and serial logs.
An unsupported ROM hash, missing installed ticket, wrong VRE configuration,
or absent firmware component stops the script before upload.

## View the booted guest

Leave the boot script running. In another Terminal, use the same built CLI,
vphone library and machine. `research-view` finds the guest's host-only IPv4
address from the VRE config's MAC address and the Mac's DHCP lease:

```sh
.build/XcodeBundle/Build/Products/Debug/VPhone.bundle/Contents/MacOS/vphone-cli \
  vm research-view --library-root /absolute/path/to/vphone-library \
  vphone-machine \
  --vrevm-config /absolute/path/to/vrevm-datadir/vrevm-name.vm/config.plist
```

The viewer requires a current host-only DHCP lease and a bridge with exactly
one `vmenet` member whose live source MAC matches the VM config before sending
its token. It handles macOS lease and bridge entries that omit leading zeroes
in MAC octets. If the preflight fails, check that the VRE VM is running, its
config uses `hostOnly` networking, and no other VM shares that bridge.
The command reads `ResearchAPIToken` from the vphone machine folder. Its host
copy is owned by the invoking user and has mode `0600`; the guest copy has
mode `0400`. `vphoned` uses VSOCK when available and falls back to TCP port
1339 on this VRE host. TCP requests need the bearer token, including health
requests; an HTTP request without it receives `401`.

The bearer blocks unauthenticated network and browser clients. The bridge
check is a startup preflight; it does not authenticate the network endpoint
after a host administrator changes the bridge or its routing. Use this path
only when local host and network administration are trusted. The bearer also
does not isolate Mac accounts from one another: the guest copy is inside the
project's mode-`0777` host `Disk.img`, and another local account with access
to that image may be able to read it despite the guest file's `0400` mode.

The viewer fetches screenshots and sends mouse input through guest RPCs. In
the clean end-to-end repeat, the CFW-installed daemon registered Research HID;
`input.swipe` unlocked, and `input.tap` opened Settings. In the viewer, a
bottom-edge drag returned Settings to a settled Home screen; a click reopened
Settings, and a drag scrolled it. An earlier `setup.skip` RPC succeeded on a
disposable guest, but it is not a normal step in this guide. Close the viewer
window to end `research-view`; stop the VM with Control-C in the boot-script
Terminal.

## Validation boundary

The full bundle build and bundle admission passed. All nine IMG4s prepared
from the restore tree matched the successful scratch images byte for byte.
On a new disposable VM (`ECID 7A0B7D1B6A52B60A`), a clean patched restore,
CFW install and fifth-argument `--reuse-prepared` boot reached
`Early boot complete` with normal SIP. The viewer connected through the
current DHCP/bridge MAC guard; its 50 ms screenshot polling was live-tested.
The screen, tap, scroll and Home-edge actions above worked in that run.
The guest's `device.displays` reported the AppleParavirtGPU and Metal plugin.
A scratch one-thread Metal compute probe completed on the Apple Paravirtual
GPU with the expected output `0x12345678` under normal SIP. The viewer still
transports repeated screenshots rather than attaching to Apple's VM view.

This remains a developer boot path. Ordinary `vrevm` disk boot of the restored
VM still fell to DFU with an empty serial log after CFW reinstall with the
virtual-touchscreen daemon. Apple's launcher does not expose its VM view to
the vphone app or create VSOCK, so
the regular vphone window, its full controls, and Launchpad integration are
not available through this workflow. See the
[research record](../../Research/Host/research_guests_only.md) for the restore,
ticket and boot-chain evidence.

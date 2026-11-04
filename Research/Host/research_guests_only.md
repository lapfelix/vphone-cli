# Research Guests without the SIP debug exception

Investigation: 2026-11-02–03. Target policy: normal SIP and AMFI, with only
`csrutil allow-research-guests enable` changed in Recovery.

## Finding and validation boundary

**The direct OpenAVB-via-`vrevm` proposal failed its runtime test.** Apple's
unmodified, signed `/System/Library/SecurityResearch/usr/bin/vrevm` can run
PV=3 guests with this host policy, and a custom SEP ROM works. However, the
VM service rejects any explicit AP ROM override, including a byte-identical
copy of Apple's own ROM. The published CLI's `--rom` option does not mean
the installed executable has permission to use it.

After the user enabled Research Guests in Recovery and rebooted, the installed
macOS 27.0.1 (26A434) host reported CSR flags **0x1000**: Research Guests set,
debug exception clear. The user also completed Apple's first-run VRE license
acceptance. The probes below did not change host policy, AMFI or trust settings.

A revised research route is Apple's default AP ROM plus OpenSEP, using the
guest debugger to reproduce the existing AVPBooter validation bypass through
hardware breakpoints and register updates. Both debugger primitives were
verified inside a disposable guest under the target host policy. On November 3,
the full `VPhone` Xcode scheme built successfully, an Apple TSS ticket was
issued for the disposable guest, and the signed stock iBSS reached recovery.
The ROM digest-result interception was then exercised with an image it
rejected: changing that guest return register let the alternate stock image
reach recovery.
Apple's stock cloudOS 26.4 subsequently completed a full restore and reached
normal-mode USB when booted through `vrevm`. The vphone firmware preparation
and patch pipeline also ran. Initial rebuilt iBSS images failed before
recovery, even after the ROM digest result was changed in the guest debugger.
A scratch LZFSE encoder configured to reproduce Apple's stock iBSS output
then let a serial-label-only patched iBSS enter recovery through that same
guest-side digest interception. A later uninterrupted restore with the full
229-patch firmware completed successfully using tuned iBSS compression and
an automatic guest ROM digest-result override. The restored VM still fell
back to DFU when started for ordinary disk boot. After CFW installation on a
disk clone and use of its installed ticket, a manual USB boot reached iOS
launchd, data and user mounts, and keybag initialization; Xcode identified a
connected virtual iPhone. A checked-in developer script subsequently repeated
the USB boot through `bootx` and observed `Early boot complete` with SIP
enabled. An authenticated host-only TCP fallback let `vm research-view`
display the live Welcome screen. A click woke the display, but the initial
guest reported no digitizer and viewer gestures did not visibly respond. A
temporary signed virtual-touchscreen probe subsequently unlocked the Home
screen. After CFW reinstall, the daemon's virtual touchscreen registered;
a timed direct swipe unlocked to Home, and the viewer opened and scrolled
Settings. The installed viewer's bottom-edge Home gesture inside Settings
initially failed, although a later scratch sender-matched gesture returned
Home. A clean restore and CFW install on a new disposable VM then confirmed
the installed daemon and viewer: a bottom-edge viewer drag returned Settings
to settled Home, and tap and scroll worked. Normal SIP remained enabled.
**Patched restore, manual USB boot and a basic viewer are demonstrated;
ordinary disk boot and regular vphone/Launchpad integration are not.**

## Post-Recovery runtime results

The initial ROM and DFU probes used isolated scratch machines under
`/tmp/vphone-vrevm-proof`, with 2 CPUs, 4 GiB RAM, a 1 GiB sparse blank disk,
and no network. Later restore probes used separate 64 GiB scratch machines.
`vrevm` version was 274.1.3.

| AP ROM | SEP ROM | Result |
| --- | --- | --- |
| Apple's implicit default | Apple's implicit default | Starts; matching ECID appears as USB DFU, CPID FE01 / BDID 90 |
| OpenAVB override | OpenSEP override | Configuration validates; start fails with VZErrorDomain 1 |
| OpenAVB override | Apple's implicit default | Same immediate start failure |
| Apple's implicit default | OpenSEP override | Starts and enumerates as USB DFU |
| Unmodified Apple AP ROM supplied explicitly | Apple's implicit default | Same immediate start failure |

The last row distinguishes an override-policy rejection from a fault in OpenAVB.
The successful default-ROM DFU identity contained `SRTG:[mBoot-20457.1.29]`.

Service disassembly corroborates the tests. The AP boot-loader factory's
alternate-ROM descriptor path calls a gate requiring
`com.apple.private.virtualization`; the installed `vrevm` instead holds
`com.apple.private.virtualization.security-research`. The SEP ROM factory
accepts either entitlement. The strict gate's diagnostic is
`Restricted devices require the com.apple.private.virtualization entitlement.`
This check happens in the service after client-side configuration validation.

For this service binary, the strict gate is at static address `0x1003357dc`,
the research-or-private gate at `0x10033581c`, and the AP alternate-ROM
handler at `0x100343ae0`. These are evidence locations, not runtime offsets
to embed in a patcher. The service SHA-256 is
`f9c5430289a84e8e44189d361b5bb246822d48f99c59b4c3b52721600d044961`.

### Guest debugger evidence

The default-ROM guest exposed AP and SEP GDB ports without a host debug
exception. Connecting LLDB to the AP guest port established:

- ROM reads work; the running DFU loop was inside the default AP ROM.
- Writing back one **unchanged** byte at ROM base `0x100000` is refused.
  A debugger therefore cannot simply write the existing patch into this ROM.
- A hardware breakpoint in the observed DFU loop was installed and actually
  hit after `continue` (`stop reason = breakpoint 1.1`). This was not merely
  an accepted breakpoint declaration.
- With the guest halted, x0 was saved, changed to `0x1234`, read back, restored
  to its saved value, and read back again before detaching. No guest instruction
  ran while the temporary register value was installed.

These establish the primitives for intercepting the existing DGST-validation
return and supplying its success result. The November 3 test below also
established that the breakpoint can be armed while the guest waits in DFU and
hit during a real firmware upload. A reboot still needs re-arming.

The existing `AVPBooterPatcher` reveal procedure was reproduced with the
project's unchanged `ARM64Disassembler` and `ARM64Instruction` sources, using
a scratch Capstone naming adapter for the build machine's installed library.
The first DGST marker was at file offset `0x260c`, the selected result setter
at `0x2b68` (`mov x0, x20`), and the return at `0x2b88` (`retab`). Live guest
disassembly confirmed the same sequence at ROM base `0x100000`. The 36 bytes
from the result setter through the return were read from the guest and
compared byte-for-byte with the installed ROM; they matched.

For a future debugger implementation, interception must be **after** the
result setter, for example at the decoded return. Setting x0 before the
`mov x0, x20` would immediately be overwritten. The observed epilogue between
setter and return only restores saved registers and the stack; it does not
write x0. Derive these addresses from each host ROM and check the live bytes,
rather than copying these evidence offsets into executable logic.

No ROM instruction was changed during these tests. A shipping implementation
must use the existing patch declaration/preset and record the runtime action;
it must not introduce an unconditional, untracked patch path. Use a native
guest-debugger client rather than making LLDB a shipped runtime dependency.

### Inspected binary hashes (SHA-256)

| Binary | SHA-256 |
| --- | --- |
| Installed `vrevm` | `d237499fbefad390c65c77f27f7975dfa5a143e0b1ddb028dd99883d2f9c0956` |
| Installed Apple AP ROM | `301bc973b56e86a9906bb6002d008015a57c9e07b5f191260717b97a62589072` |
| Repository OpenAVB | `bbcabe73fd39fb92b96fbb4c661c1a15b0f9e5d9411468f7954c4f433911cb9c` |
| Repository OpenSEP | `92690b9c7e900ec0054271dbbc0444ee2d8567c8d41d3a2e491ba011e2b08b12` |

The original machine library was not used or modified.

### Signed boot-chain test, November 3

The `VPhone` scheme built successfully in Xcode 27.2 RC after resolving its
pinned packages. The bundle was produced under Xcode's DerivedData, without a
source change. The native `vphone-cli restore --get-shsh` path used the
cloudOS 26.4 beta (`23E5207q`) `BuildManifest.plist` and the disposable VM's
ECID `3D6FD3A2BEF0D45B` to request a ticket. Apple returned a 5,668-byte
`ApImg4Ticket` with a matching DFU nonce. For this ticket-only test, other
firmware paths in the scratch restore directory were zero-byte placeholders;
they must never be used for an actual restore.

The stock `iBSS.vresearch101.RELEASE.im4p` was wrapped with that ticket in an
IMG4 container and uploaded through the vendored `libirecovery` to the
ECID-scoped virtual USB device. USB changed from DFU `05ac:1227` to recovery
`05ac:1281`. The serial log identified `iBoot-13822.100.791.502.1`, board
`vresearch101ap`, and `Entering recovery mode, starting command prompt`.
The AP debugger then observed execution in the loaded iBSS at
`0x700a7dbc`, rather than the ROM's DFU loop near `0x1111ac`. This proves
that the stock signed first stage runs under the requested host policy.

A similarly ticketed stock iBEC was sent through recovery USB, followed by
`go`. The send and command returned success and a second iBoot header appeared
in the serial log. The device remained in `05ac:1281`, as expected for a
recovery-stage image. The log does not by itself establish that later restore
images or the vphone-patched boot chain run. No guest breakpoint altered the
stock image's return value in these tests.

### Digest-result interception with a real image

With the VM restarted in DFU, a hardware breakpoint was armed at the
live-verified ROM return `0x102b88` before sending firmware. A correctly
ticketed stock release iBSS hit that breakpoint during upload and proceeded
to recovery without a register change. This proves the attach timing for
DFU-initiated restores.

For a rejection control, Apple's valid `RESEARCH_RELEASE` iBSS was wrapped
with a ticket obtained for the `RELEASE` identity. The result was a valid
container whose image digest did not match that ticket. Without any guest
modification it remained in DFU. On a repeated upload, the same return site
reported `x0 = 1` on its failing invocation. For the decisive run, LLDB's
conditional hardware breakpoint (`$x0 != 0`) skipped successful invocations,
stopped with `x0 = 1`, and wrote `x0 = 0` while that guest thread was halted.
After continuing, virtual USB changed from DFU `05ac:1227` to recovery
`05ac:1281`. The serial log identified the loaded image's
`BUILD_STYLE: RESEARCH_RELEASE` and `UUID: BCDC7AA8-9767-369F-AFC8-5296A210472F`,
then reported `Entering recovery mode`. This demonstrates the mechanism for
the existing AVPBooter DGST patch using only Apple's signed launcher and
guest debugger under the target SIP state.

This was a manual proof, not a working vphone backend. It used LLDB as a build
tool, a disposable VM with a 1 GiB blank disk, and Apple's unmodified research
boot images. The later developer script pins the known ROM hash, re-arms its
breakpoint on each run and checks the patch preset, but still uses LLDB. A
supported runtime would need a native debugger client and live ROM-byte
verification. The following restore, boot and viewer tests extend this proof.
These initial manual tests modified no host executable or repository boot
patch.

### Full stock cloudOS restore and boot

The cloudOS 26.4 beta (`23E5207q`) IPSW was downloaded to
`/tmp/vphone-vrevm-proof/cloudOS_26.4_23E5207q.ipsw`. A separate scratch
machine, `cloudos-stock-proof`, was created with a 64 GiB disk, host-only
network, Apple's implicit AP ROM, and the repository OpenSEP. Its ECID was
`7A0B7D1B6A52B60A`. Apple's signed `vrevm create --restore` completed with
`Restore Completed` and exit status 0. A subsequent `vrevm run` booted from
the restored disk and enumerated as normal-mode USB (`05ac:12ac`) with the
matching serial `0000FE01-7A0B7D1B6A52B60A`. The host-only `bridge100`
became active at `192.168.128.1`; `devicectl list devices` reported a
`ComputeModule14,2` with the same ECID. This establishes a full stock
restore and disk boot under the requested host policy. It does not establish
vphone firmware, guest control, or screen access. The machine was stopped
after the test.

The stopped stock VM's disk was attached read-only, and
`System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle` was
copied from its system volume to a scratch path. The disk was then ejected.
This local 26.4 GPU bundle was supplied explicitly to `fw prepare`, avoiding
that command's temporary recovery VM, whose direct `vphone-vm` launch is
blocked by AMFI under this host policy. This is a preparation workaround,
not a change to the shipped bundle or a successful vphone guest boot.

### Initial vphone firmware restore attempt and isolation

A disposable vphone machine, `vphone-full`, was created under
`/tmp/vphone-test-library` with the Apple AP ROM selection and OpenSEP. A
separate `vrevm` restore target, `vphone-restore-proof`, used Apple's implicit
AP ROM, OpenSEP, a 64 GiB disk, host-only network, and ECID
`3C9B1E56B276AC0C`. `fw prepare` for iPhone 26.4.2 (`23E261`) and the local
cloudOS IPSW succeeded when given the extracted stock GPU bundle. `fw patch`
then applied the existing preset's 229 patches, including the AVPBooter digest
bypass and iBSS image-validation changes. No patch source or manifest was
changed for this experiment.

The native `vphone-cli restore` requested a TSS ticket for the scratch target
and uploaded the patched iBSS. The live ROM digest return again reported
`x0 = 1`. Changing it to `x0 = 0` while halted and continuing did not bring
up recovery: the guest remained in DFU and restore reported that the device
did not reconnect, possibly due to an invalid iBSS. The debugger trace showed
that the digest-check caller returned success after the register change; the
later rejection point has not yet been located.

To isolate the cause, the scratch machine's preset was retested with the
iBSS image-validation, nonce, and serial-label patches blocked. The resulting
iBSS was byte-for-byte identical to Apple's original and reached recovery.
Restore then sent the still-patched iBEC, which was refused with a serial
`Memory image not valid` message. A build with only the iBSS image-validation
patch enabled failed before recovery. A build with only the cosmetic serial
label patch enabled failed there as well, despite the digest-return override.
The tested failure therefore applies to these rebuilt iBSS outputs generally;
it is not isolated to the image-validation patch. The original and rebuilt
iBSS containers parsed as IM4P and extracted to equal-length code payloads.

### iBSS LZFSE encoding and recovery proof

Further comparison found a compression difference that the IM4P parser and
equal-length decompressed payloads did not reveal. Apple's stock iBSS LZFSE
stream has 19 `bvx2` blocks and frequent blocks with 3,742 matches. The
project's macOS Compression output has 7 `bvx2` blocks and frequent blocks
with 9,992 matches. A no-op rewrap of the iBSS and an attempt using 32 KiB
input chunks both failed ROM decompression. Apple's open-source `lzfse`
rebuilt with `LZFSE_MATCHES_PER_BLOCK=3750` instead reproduced the complete
stock iBSS IM4P **byte for byte**. This is strong evidence that the ROM's
loader depends on the stock stream's block shape, beyond accepting a valid
IM4P and an independently decompressible LZFSE payload.

For a live test, a serial-label-only iBSS patch was encoded with that tuned
scratch build. A fresh nonce ticket was obtained for the disposable VM. With
the guest debugger changing the ROM digest return from `x0 = 1` to `x0 = 0`
on the patched upload, the ROM reported decompression of
`740704/740704` bytes and USB moved from DFU to recovery (`05ac:1281`).
This proves that a genuinely modified iBSS can pass the default Apple AP ROM
under the requested host policy when its compressed stream is compatible and
the digest result is intercepted. This first live test changed only the
cosmetic serial label. The tuned encoder and test image were scratch
artifacts; production Swift encoder integration is separate from this proof.

### Full patched restore and normal-boot result

The full 229-patch iBSS was next encoded with the tuned 3,750-match LZFSE
build. The guest ROM debugger automatically changed the DGST-validation
result at the live-verified return `0x102b88`. In manual stage tests, the
patched iBSS and patched iBEC both booted. Restarting `vphone-cli restore`
from iBEC recovery resent iBEC and caused a panic; that restart was not a
valid continuation test. A fresh, single uninterrupted `vphone-cli restore`
then completed with exit status 0. It recorded iOS 26.4.2, cloudOS 26.4,
and 93 boot-chain patches for the disposable machine. This demonstrates the
patched restore path under the requested host policy, with the tuned encoder
and guest debugger as scratch tooling.

Normal boot remains blocked. Running the restored `vphone-restore-proof` VM
through `vrevm` without `--dfu` fell into DFU with an empty serial log. As a
control for the reboot procedure, the stock cloudOS VM was started with
`--dfu`, given a signed stock iBSS, and rebooted from recovery; it returned
to normal-mode USB (`idProduct 4780`, or `05ac:12ac`). The vphone result
therefore cannot be attributed to that reboot method alone.

### Manual boot-chain diagnosis and CFW boot

The patched LLB was recompressed with the same tuned LZFSE encoder and
restored byte-identical into `AuxiliaryStorage`, but an ordinary `vrevm` boot
still fell to DFU without serial output. The guest debugger also refused a
write to ROM code memory. The automatic boot failure remains unresolved.

A direct USB boot used the patched iBSS and iBEC, the correct IMG4 restore
retags, and uploads of SPTM, TXM, trust cache, device tree, SEP, and kernel
cache. It reached XNU. The release `RestoreKernelCache` then panicked while
mounting the APFS root snapshot. Retagging the installed patched research
kernel as `rkrn` passed the mount, but init was killed. Substituting the
patched research TXM alone did not resolve that failure. Loading the
installed `StaticTrustCache` as firmware tag `trst` allowed launchd to run;
the next panic reported a missing `libSystem.B.dylib`, expected before CFW
installation. These were scratch boot probes, not a normal VM boot.

`vphone-cli cfw install` then completed on an APFS clone of the restored VRE
`Disk.img`. It installed the cryptex and `vphoned`, and the clone was placed
into the VRE VM. An initial direct USB boot with a fresh DFU ticket loaded
iOS and launchd, but `seputil` looked for
`/private/preboot/AFD633.../usr/standalone/firmware/sep-firmware.img4` and
failed. The actual Preboot directory began `166B88...` and contained that SEP
firmware. The SHA-384 of the fresh `ApImg4Ticket` began `AFD633...`; the
installed Preboot `System/Library/Caches/apticket.der` hash began
`166B88...`, matching the directory name. This tied the failure to the
ticket used for manual boot rather than an absent SEP firmware file.

All boot images were then rewrapped with the installed Preboot ticket. The
patched iBSS was accepted with the guest hardware debugger's ROM digest
override, and the patched iBEC loaded. The direct USB boot uploaded restore
SPTM, patched research TXM, restore and static trust caches, restore device
tree and SEP, and the patched research kernel cache retagged for recovery
boot. The guest reached launchd's `Early boot complete`, mounted data and user
volumes, and initialized the keybag. No panic was observed. Xcode
`devicectl` listed `0000FE01-3C9B1E56B276AC0C` as a connected virtual
`iPhone99,11`.

The first successful boot was a manual scratch path. An ordinary
`vrevm run --noask` after CFW reinstall with the virtual-touchscreen daemon
still presented ECID `3C9B1E56B276AC0C` as DFU in Xcode `devicectl`; its
serial log remained empty. That disposable run was stopped. Apple's launcher
supplies no app-owned VM view or VSOCK device. These results alone did not
establish a viewer or a working user-facing vphone backend; the separate
viewer test below extends them.

The older scratch VM later panicked in SEP after a disk-only rollback. Keep
`Disk.img`, `SEPStorage` and `AuxiliaryStorage` together when snapshotting or
reverting a VRE VM; a disk-only rollback does not restore the matching SEP
and auxiliary state.

### Checked-in developer boot path

[`scripts/ResearchGuestsBoot.zsh`](../../scripts/ResearchGuestsBoot.zsh) now
drives an already restored, CFW-installed VRE VM. Its four arguments are the
vphone library root and machine name, then the `vrevm` data directory and VM
name. The script calls `vphone-cli vm research-upload --prepare-only` to check
the selected `avpbooter-boot-dgst_bypass` patch, the installed Preboot ticket
cached by `cfw install` as `ResearchBootTicket.der`, the default-AP-ROM VRE
configuration, and the nine firmware inputs. For later boots after the
restore tree has been removed, as happened in the normal CFW install test,
an optional fifth `--reuse-prepared` argument validates the nine saved
`ResearchBoot` IMG4s against that installed ticket instead of reading the
restore sources. The script pins the installed Apple AP ROM SHA-256 to
`301bc973b56e86a9906bb6002d008015a57c9e07b5f191260717b97a62589072`.
It then starts Apple's signed `vrevm` in DFU, arms LLDB's conditional guest
hardware breakpoint at `0x102b88`, runs the ECID-scoped `research-upload`,
and waits for `Early boot complete` in the serial log. This is a developer
script with an LLDB build-machine dependency, not a runtime dependency of
`VPhone.bundle`.

The full bundle build succeeded. All nine IMG4s prepared by the checked-in
command matched the successful scratch images byte for byte. The first live
script attempt mistakenly selected the SEP debugger port and was stopped;
the port parser was fixed to select the AP debugger. The subsequent attempt
on the disposable VRE VM with ECID `3C9B1E56B276AC0C` reached `bootx`, and
its serial log contained `Early boot complete` with SIP enabled. This
validates the scripted manual boot route; it does not prove ordinary disk
boot, a vphone-owned view, or VSOCK control. See the
[developer boot guide](../../Documents/Guides/research-guests-boot.md) for
the exact starting state and invocation.

The later full build and bundle admission passed with `--reuse-prepared`.
The script's preflight validated all nine saved IMG4s against the installed
ticket, and a live repeat again reached `Early boot complete` under normal
SIP. This confirms the saved-image boot route after the restore tree was
removed; it does not change the ordinary-disk-boot result.

### Authenticated host-only viewer

The current `cfw install` provisions a 64-character random API token in the
vphone machine folder as `ResearchAPIToken` (owner-only mode `0600`) and in
the guest as `/usr/lib/vphone/research-api-token` (mode `0400`). When VSOCK is
absent in Apple's VRE host, `vphoned` uses authenticated TCP port 1339 on its
`hostOnly` network. Its HTTP gate returns `401` without a bearer token,
including for health requests. The separate `vphone-cli vm research-view`
reads the host token and discovers the guest's address from the VRE config's
MAC and the Mac's current DHCP lease. Before sending the bearer, it also
requires an unauthenticated `401` health response and a host-only bridge
with exactly one `vmenet` member whose live source MAC matches the VM config.
The MAC parser tolerates macOS lease and bridge entries that omit leading
zeroes from octets. The viewer does not accept an arbitrary IPv4 override.
The bridge check is a startup preflight, so the local host and network
administrator must be trusted not to change the bridge or routing afterward.
The bearer rejects unauthenticated network and browser clients; it is not
isolation between local Mac accounts. The guest token sits inside the host
`Disk.img`, which follows this project's mode-`0777` artifact policy, so an
account able to read the image may be able to recover the guest's mode-`0400`
token.

In the initial live viewer run with normal SIP and Research Guests enabled,
the viewer displayed the Welcome screen from repeated guest screenshots.
A click woke the display, but this did not establish touch delivery. The
guest's `device.input_devices` RPC listed five HID services and no digitizer.
The guest accepted `input.touch`, `input.tap` and `input.swipe` RPCs, yet those
calls and viewer gestures produced no visible response on Setup or the lock
screen. The `setup.skip` RPC succeeded in a disposable test and exposed the
lock screen; it is not part of the default boot workflow.

A temporary signed iOS probe created a virtual touchscreen with
`IOHIDUserDevice`. Its first registration appeared to BackBoard as
`externalAccessory`, with `builtIn = NO` and `authenticated = NO`; BackBoard
ignored its events. Adding literal `Built-In = true` and
`Authenticated = true` properties made BackBoard classify it as built-in and
authenticated. A bottom swipe then unlocked to the Home screen, visibly
proving touch input from that probe. The same properties were added to the
`vphoned` implementation, which built and was CFW-installed into the
disposable VRE disk. The subsequent boot reported
`researchTouchMode=1 registered=1 lastStatus=0`. A direct timed research-HID
swipe unlocked the lock screen to Home. In the authenticated viewer, a click
opened Settings and a drag scrolled it. This verifies tap and drag delivery
through the installed daemon and viewer. The bottom-edge Home gesture inside
Settings scrolled in early tests. A fast, sender-matched scratch edge gesture
returned Home; the clean integrated repeat below then confirmed the viewer
gesture. The early failures do not isolate whether timing, sender identity
or edge metadata mattered.

A new disposable VRE VM with ECID `7A0B7D1B6A52B60A` received a clean
patched restore and CFW installation, then booted with the fifth
`--reuse-prepared` script argument under normal SIP. The boot reached
`Early boot complete`. Its installed daemon registered Research HID;
`input.swipe` unlocked, and `input.tap` opened Settings. `research-view`
connected through the current DHCP/bridge MAC guard. In the live viewer, a
CUA-driven bottom-edge drag returned Settings to a settled Home screen. A
click reopened Settings, and a drag scrolled it. This confirms the integrated
edge gesture, tap and scroll on that clean VM. It does not establish ordinary
disk boot or the regular vphone window.
`VPhone.bundle` itself has no app launcher and cannot be opened as a Mac app;
the CLI command opens this separate viewer. Ordinary disk boot, Launchpad
lifecycle, and the regular vphone window remain unproven.

### Guest GPU and viewer refresh

The live guest's `device.displays` report identified AppleParavirtGPU and its
Metal plugin. A scratch Metal compute probe on the disposable VRE guest ran a
one-thread kernel on the Apple Paravirtual GPU. Its command buffer completed,
the output buffer held the expected `0x12345678`, and the probe exited 0 under
normal SIP. This confirms guest Metal compute execution for that probe.
`research-view` still obtains frames through `screen.screenshot` over
authenticated TCP; it does not attach to Apple's VM view or consume the
Metal surface directly. The viewer's
screenshot polling pause was reduced from 500 ms to 50 ms and was live-tested
in the clean viewer run above. The transport remains repeated screenshots.

## Why the existing host cannot simply be switched over

The current path has two independent requirements:

1. Research Guests permits the research VM platform.
2. AMFI must admit the private-entitled `vphone-vm` executable.

`VPhoneLaunchpadShared/VPhoneLaunchpadHostPolicy.swift` checks CSR bit 2
(`CSR_ALLOW_TASK_FOR_PID`) separately from bit 12 (`CSR_ALLOW_RESEARCH_GUESTS`).
The former enables `VPhoneEscalator/AMFIDTask.c` to acquire the protected
`amfid` task port. `Commands.c` then changes the AMFI requirements manager's
`_isRunningInternalBuild` heap byte and reloads the code-requirements preference.
Removing Launchpad's check would leave the protected task-port denial intact.
Writing that preference without changing the manager does not enable it.

Local scratch probes, run outside the execution sandbox on this host:

| Probe | Result |
| --- | --- |
| Ad hoc executable with only public `com.apple.security.virtualization` | Runs; `VZVirtualMachine.isSupported == true`, PV=3 `VZMacHardwareModel.isSupported == false` |
| Identical executable adding only `com.apple.private.virtualization.security-research` | Killed at exec, status 137, before program output |

The probes used the project's PV=3/ISA=2 descriptor and did not start a VM.
Both results were reproduced after enabling Research Guests, outside the
execution sandbox. The public-only probe also read CSR flags `0x1000` in the
same process. The research-only private-entitlement probe was killed before
printing its first line. A smaller entitlement set therefore does not solve
the custom-host admission problem on this host.

Read-only inspection of Apple's AMFI framework in our own process classified
`com.apple.private.virtualization.security-research` as restricted, alongside
the broader private virtualization and BiometricKit entitlements. The
classification method uses static matching tables. Inspection of the
`AMFIPathValidator_macos` and `AMFIRequirementsManager` instance methods found
the internal-build CSR check in the manager initializer and no Research
Guests exception. This strengthens the separate-admission explanation, but
does not alone rule out a kernel-side exception before userspace validation;
the post-Recovery admission retest above supplies the runtime result.

Installed Virtualization VM-service disassembly also shows entitlement checks
against the XPC client's actual signature. A client-side `isSupported` override
would not supply those entitlements to the service.

Ordinary Developer ID signing does not itself grant private entitlements.
`com.apple.vm.networking` is a requestable entitlement, but no public provisioning
route was found for the private virtualization entitlements. Apple's
[debugger entitlement documentation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.debugger)
explicitly excludes obtaining protected SIP task ports. The previously studied
[KextRW route](kextrw_host_integration.md) requires additional Recovery policy
changes and therefore does not satisfy this target.

## Apple host evidence

Inspected Apple source revision
[`785eeabb6dc076cd94b620436296bc45987d9020`](https://github.com/apple/security-pcc/tree/785eeabb6dc076cd94b620436296bc45987d9020/srd_tools/vre/vrevm)
(2026-10-23), alongside the installed executable. The source is evidence of
intended behavior; it is not proof that the installed binary is built from
that exact revision.

- Apple's [VRE setup guide](https://security.apple.com/documentation/private-cloud-compute/vresetup)
  specifies enabling Research Guests.
- [`PCCVREUtils.allowedToRunVRE`](https://github.com/apple/security-pcc/blob/785eeabb6dc076cd94b620436296bc45987d9020/srd_tools/vre/Shared/PCC/PCCVREUtils.swift#L102)
  checks `CSR_ALLOW_RESEARCH_GUESTS`, not `CSR_ALLOW_TASK_FOR_PID`.
- [`Main.swift`](https://github.com/apple/security-pcc/blob/785eeabb6dc076cd94b620436296bc45987d9020/srd_tools/vre/vrevm/Main.swift#L28)
  performs that check before license handling and argument parsing. This
  explains why even `--help` stops while Research Guests is disabled.
- [`CLI+CreateCmd.swift`](https://github.com/apple/security-pcc/blob/785eeabb6dc076cd94b620436296bc45987d9020/srd_tools/vre/vrevm/CLI/CLI%2BCreateCmd.swift#L97)
  exposes `--rom` and `--vseprom`; `modify` exposes the same options.
- [`VM+Config.swift`](https://github.com/apple/security-pcc/blob/785eeabb6dc076cd94b620436296bc45987d9020/srd_tools/vre/vrevm/VM/VM%2BConfig.swift#L149)
  applies the AP ROM override and the SEP ROM override (line 243). It forces
  production fusing on retail hosts (line 209), independently of those overrides.
- The installed executable's arm64e signature contains
  `com.apple.private.virtualization.security-research`,
  `com.apple.security.virtualization`, `com.apple.vm.networking`, and
  `com.apple.private.security.bootpolicy.readonly`. It does not need to attach
  to `amfid`.

Rebuilding or modifying `vrevm` would discard the crucial Apple signature and
reintroduce the admission problem. Invoke the system binary in place.

## Reproducing the rejected AP-ROM override test

Use an unused scratch directory. Apple's license flow must complete before
running VM commands. The following test was performed: `create` succeeded,
but `run` failed immediately with `VZErrorDomain Code=1` and no guest output.
It is retained to reproduce the restriction, not as a working launch recipe.

```sh
rtk proxy /System/Library/SecurityResearch/usr/bin/vrevm create \
  --datadir /tmp/vphone-vrevm-proof --name openavb-proof \
  --ncpu 2 --nram 4 --storage 1 --network none \
  --rom "$PWD/VPhoneExecutable/VPhoneVirtualization/Resources/OpenAVB/OpenAVB.bin" \
  --vseprom "$PWD/VPhoneExecutable/VPhoneVirtualization/Resources/OpenSEP/OpenSEP.bin"

rtk proxy /System/Library/SecurityResearch/usr/bin/vrevm run \
  --datadir /tmp/vphone-vrevm-proof --name openavb-proof --dfu
```

The 1 GiB sparse disk is only for ROM/DFU testing, not for an iOS restore.
Omitting `--rom` lets the same test reach DFU, with either the default SEP ROM
or `--vseprom` pointing at OpenSEP. Verify USB enumeration and its matching ECID
while the process runs; a successful `create` alone proves little.

Only after validating a patched-firmware boot path, boot a **separate copy**
of an existing stopped guest. Preserve
the complete mutable set (disk, NVRAM, SEP storage) and its machine identifier.
Do not point two hosts at shared writable guest files, and do not use a freshly
generated ECID with an existing guest's storage.

## Translating a vphone machine

Apple's bundle layout is `<datadir>/<name>.vm/`. Its configuration is related to
ours but is not interchangeable:

| vphone machine | Apple host |
| --- | --- |
| `platformType = "vresearch101"` | Integer `platformType = 3` |
| `machineIdentifier` data | Preserve exactly |
| `cpuCount`, `memorySize` in bytes | Same units |
| Manifest-selected disk filename | `Disk.img` |
| Manifest-selected NVRAM filename | `AuxiliaryStorage` |
| Manifest-selected SEP storage filename | `SEPStorage` |
| ROM keys `avpBooter`, `avpSEPBooter` | `avpbooter`, `avpsepbooter` |
| Network key `macAddress` | `macAddr` |
| Configurable display | Apple source fixes 1290 × 2796 at 460 ppi |

Apple requires the legacy `networkConfig` dictionary and accepts
`networkConfigs`; use the same primary interface in both for compatibility.
Its network mode strings include `none`, `nat`, and `hostOnly`. Omit VirtMesh
fields and `darwin-init.json` for the initial iOS clone test. The latter is PCC
configuration that the launcher otherwise writes into guest NVRAM.

After solving the AP boot-chain gate, a translated clone can be launched with:

```sh
rtk proxy /System/Library/SecurityResearch/usr/bin/vrevm run \
  --datadir /absolute/path/to/clone-library --name iphone-proof
```

The source supports foreground lifetime, serial output, DFU, guest and SEP
debug stubs, and `VREVM_EXIT_ON_PID` for controller lifetime monitoring. Its
guest debugger does not imply disabling host SIP debugging restrictions.

## Integration after the boot proof

The Apple host supplies a GPU, and the guest Metal probe above completed on
its paravirtual device, but the host does not expose a GUI window or its
`VZVirtualMachine` object to our process. Its published configuration does not
create VSOCK, USB touch/keyboard, synthetic battery, sound, or our extra
video/scaler/neural accelerator devices.

The remaining progression is:

1. Make ordinary disk boot of the CFW clone reach the connected state seen in
   the USB proof, or integrate the DFU start and upload into a supported
   lifecycle. Confirm stable USB and host-only network identity.
2. Extend and verify the separate viewer beyond the tested tap, scroll and
   Home-edge actions. It uses screenshots over TCP; the current recorder and
   native `VZVirtualMachineView` cannot attach to another process's VM.
3. Add Launchpad preflight and lifecycle handling for this backend. Keep the
   existing debug-bit requirement on the existing AMFI-helper path. Its
   launcher currently only permits the receipt-pinned bundle CLI, so use
   that CLI/controller boundary without widening the helper to arbitrary
   commands.

The full build, bundle admission, and clean saved-IMG4 boot repeat passed.
The authenticated TCP viewer displayed the guest and delivered tap, scroll
and Home-edge actions. A supported VM backend still needs ordinary boot or
an integrated recovery-start flow, broader control verification, and
Launchpad lifecycle.
The public firmware mode remains JB. This is not yet a supported backend.

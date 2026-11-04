# Boot LZFSE encoder

The C implementation in this directory is from [Apple's open-source LZFSE](https://github.com/lzfse/lzfse), commit `e634ca58b4821d9f3d560cdc6df5dec02ffc93fd`. Its license is in `LICENSE`.

The only upstream change is `LZFSE_MATCHES_PER_BLOCK` in `lzfse_internal.h`: 10,000 to 3,750. This reproduces Apple's iBSS compression exactly. The macOS Compression encoder uses 10,000 and emits blocks that AVPBooter rejects. `VPhoneBootLZFSE.c` is the local wrapper used by `IM4PHandler` when writing iBSS.

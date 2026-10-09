`dfu_bootloader.elf` is ra8-firmware's DFU bootloader built at `dev` a8fcd8a49
(MinSizeRel, Arm GNU 13.3.rel1) with a throwaway root public key in place of the
provisioned one, then stripped of debug sections. It is the RA8EMU-776 fixture:
the real bootloader has to pick between staged slots the way
`src/session/boot_slots.zig` says it will.

`signed_a.bin` and `signed_b.bin` are the same 32-byte payload, each followed by
a 116-byte ROT1 trailer signed with the throwaway key: sequence 1 for Slot A and
sequence 2 for Slot B. The payload writes `0x9710C0DE` to `0x22010000` and
spins, so a run that reaches it proves the bootloader verified, copied and
started the slot. The test writes each body at its slot base and builds the
32-byte slot header (magic, sequence, length 32, CRC32 of the payload, entry
`0x22020000`) in the slot's last page.

The private key is not committed; it was generated for this fixture and only
ever signs these two images. The public key's SHA-256 is
`980a0103...166a` (full value on the ticket).

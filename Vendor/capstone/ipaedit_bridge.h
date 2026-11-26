// Small C wrapper around Capstone so Swift only sees plain types.
#ifndef IPAEDIT_BRIDGE_H
#define IPAEDIT_BRIDGE_H

#include <stdint.h>
#include <stddef.h>

typedef struct {
    uint64_t address;
    uint32_t size;
    uint32_t word;          // raw little-endian instruction word (0 if size != 4)
    char mnemonic[32];
    char operands[160];
} IPAInsn;

/// Opens an ARM64 disassembler. Returns NULL on failure.
void *ipa_disasm_open(void);
void ipa_disasm_close(void *handle);

/// Disassembles up to `max` instructions from `code`. Undecodable words are
/// emitted as `.word` so the listing never stops early. Returns the count.
size_t ipa_disasm(void *handle, const uint8_t *code, size_t length, uint64_t address,
                  IPAInsn *out, size_t max);

/// Capstone version as major * 100 + minor.
int ipa_disasm_version(void);

#endif

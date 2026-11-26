#include "ipaedit_bridge.h"
#include <capstone/capstone.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

void *ipa_disasm_open(void) {
    csh *h = malloc(sizeof(csh));
    if (!h) return NULL;
    if (cs_open(CS_ARCH_ARM64, CS_MODE_LITTLE_ENDIAN, h) != CS_ERR_OK) {
        free(h);
        return NULL;
    }
    cs_option(*h, CS_OPT_DETAIL, CS_OPT_OFF);
    return h;
}

void ipa_disasm_close(void *handle) {
    if (!handle) return;
    csh *h = (csh *)handle;
    cs_close(h);
    free(h);
}

static void copy_str(char *dst, size_t cap, const char *src) {
    if (!src) { dst[0] = 0; return; }
    strncpy(dst, src, cap - 1);
    dst[cap - 1] = 0;
}

size_t ipa_disasm(void *handle, const uint8_t *code, size_t length, uint64_t address,
                  IPAInsn *out, size_t max) {
    if (!handle || !code || !out) return 0;
    csh h = *(csh *)handle;
    cs_insn *insn = cs_malloc(h);
    if (!insn) return 0;

    size_t n = 0;
    while (n < max && length >= 4) {
        const uint8_t *p = code;
        size_t len = length;
        uint64_t addr = address;
        uint32_t word = (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
        IPAInsn *o = &out[n];
        o->address = address;
        o->word = word;
        if (cs_disasm_iter(h, &p, &len, &addr, insn)) {
            o->size = insn->size;
            copy_str(o->mnemonic, sizeof o->mnemonic, insn->mnemonic);
            copy_str(o->operands, sizeof o->operands, insn->op_str);
        } else {
            o->size = 4;
            copy_str(o->mnemonic, sizeof o->mnemonic, ".word");
            snprintf(o->operands, sizeof o->operands, "0x%08x", word);
        }
        code += o->size;
        length -= o->size;
        address += o->size;
        n++;
    }
    cs_free(insn, 1);
    return n;
}

int ipa_disasm_version(void) {
    int major = 0, minor = 0;
    cs_version(&major, &minor);
    return major * 100 + minor;
}

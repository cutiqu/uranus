// Differential-test harness: runs ONE instruction per case on Musashi (68000).
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include "m68k.h"

static uint32_t seed;
static uint8_t code[12];
static struct { uint32_t addr; uint8_t val; } ov[256];
static int nov;
typedef struct { uint32_t addr, size, val; } W;
static W wl[64];
static int nw, odd;

static uint8_t hbyte(uint32_t a) {
    uint32_t h = (a * 0x9E3779B1u) ^ seed;
    h ^= h >> 15; h *= 0x85EBCA6Bu; h ^= h >> 13;
    return (uint8_t)(h >> 11);
}
static uint8_t rb(uint32_t a) {
    a &= 0xFFFFFF;
    for (int i = nov - 1; i >= 0; i--) if (ov[i].addr == a) return ov[i].val;
    if (a >= 0x1000 && a < 0x100C) return code[a - 0x1000];
    if (a < 0x400) { uint32_t v = 0x00080000u + (a >> 2) * 0x10u; return (uint8_t)(v >> (8 * (3 - (a & 3)))); }
    return hbyte(a);
}
static void wb(uint32_t a, uint8_t v) { a &= 0xFFFFFF; if (nov < 256) { ov[nov].addr = a; ov[nov].val = v; nov++; } }

unsigned int m68k_read_memory_8(unsigned int a) { return rb(a); }
unsigned int m68k_read_memory_16(unsigned int a) { if (a & 1) odd = 1; a &= ~1u; return rb(a) << 8 | rb(a + 1); }
unsigned int m68k_read_memory_32(unsigned int a) { if (a & 1) odd = 1; a &= ~1u; return (unsigned)rb(a) << 24 | rb(a + 1) << 16 | rb(a + 2) << 8 | rb(a + 3); }
unsigned int m68k_read_disassembler_16(unsigned int a) { return m68k_read_memory_16(a); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return m68k_read_memory_32(a); }
void m68k_write_memory_8(unsigned int a, unsigned int v) { if (nw < 64) wl[nw++] = (W){a & 0xFFFFFF, 1, v & 0xFF}; wb(a, v); }
void m68k_write_memory_16(unsigned int a, unsigned int v) { if (a & 1) odd = 1; a &= ~1u; if (nw < 64) wl[nw++] = (W){a & 0xFFFFFF, 2, v & 0xFFFF}; wb(a, v >> 8); wb(a + 1, v); }
void m68k_write_memory_32(unsigned int a, unsigned int v) { if (a & 1) odd = 1; a &= ~1u; if (nw < 64) wl[nw++] = (W){a & 0xFFFFFF, 4, v}; wb(a, v >> 24); wb(a + 1, v >> 16); wb(a + 2, v >> 8); wb(a + 3, v); }

int main(void) {
    m68k_init();
    m68k_set_cpu_type(M68K_CPU_TYPE_68000);
    char line[1024];
    while (fgets(line, sizeof line, stdin)) {
        unsigned v[32]; int n = 0; char *p = line, *e;
        while (n < 32) { unsigned long x = strtoul(p, &e, 16); if (e == p) break; v[n++] = (unsigned)x; p = e; }
        if (n < 25) continue;
        seed = v[0]; nov = nw = odd = 0;
        // order: seed d0-7 a0-6 usp ssp pc sr op w1 w2 w3 w4  (a7 = usp or ssp by S)
        m68k_pulse_reset();
        m68k_execute(1); /* eat the queued reset cycles */
        for (int i = 0; i < 8; i++) m68k_set_reg(M68K_REG_D0 + i, v[1 + i]);
        for (int i = 0; i < 7; i++) m68k_set_reg(M68K_REG_A0 + i, v[9 + i]);
        uint32_t usp = v[16], ssp = v[17], sr = v[19];
        m68k_set_reg(M68K_REG_SR, sr);
        // Musashi: set both stack pointers explicitly
        m68k_set_reg(M68K_REG_USP, usp);
        m68k_set_reg(M68K_REG_ISP, ssp);
        if (sr & 0x2000) m68k_set_reg(M68K_REG_A7, ssp); else m68k_set_reg(M68K_REG_A7, usp);
        m68k_set_reg(M68K_REG_PC, v[18]);
        for (int i = 0; i < 5; i++) { code[2*i] = v[20+i] >> 8; code[2*i+1] = v[20+i]; }
        int cyc = m68k_execute(1);
        printf("%x:", seed);
        for (int i = 0; i < 8; i++) printf(" %08x", m68k_get_reg(NULL, M68K_REG_D0 + i));
        for (int i = 0; i < 8; i++) printf(" %08x", m68k_get_reg(NULL, M68K_REG_A0 + i));
        printf(" %08x %08x %08x %04x", m68k_get_reg(NULL, M68K_REG_USP), m68k_get_reg(NULL, M68K_REG_ISP), m68k_get_reg(NULL, M68K_REG_PC), m68k_get_reg(NULL, M68K_REG_SR));
        printf(" |");
        for (int i = 0; i < nw; i++) printf(" %x/%x=%x", wl[i].addr, wl[i].size, wl[i].val);
        printf(" | odd=%d cyc=%d\n", odd, cyc);
    }
    return 0;
}

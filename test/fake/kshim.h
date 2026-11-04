// SPDX-License-Identifier: GPL-2.0
/* Minimal user-space stand-ins for the kernel APIs used by wgobfs.c. */
#ifndef KSHIM_H
#define KSHIM_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>
#include <errno.h>
#include <zlib.h>
typedef uint8_t u8; typedef uint16_t u16; typedef uint32_t u32; typedef uint64_t u64;
struct rcu_head { void *p; };
#define __rcu
#define likely(x) (x)
#define unlikely(x) (x)
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x, v) ((x) = (v))
#define smp_wmb() do {} while (0)
#define min_t(t, a, b) ((t)(a) < (t)(b) ? (t)(a) : (t)(b))
#define ALIGN(x, a) (((x) + (a) - 1) & ~((a) - 1))
#define U16_MAX 0xFFFF
#define LL_MAX_HEADER 32
#define NET_SKB_PAD 32
#define GFP_ATOMIC 0
static inline u16 get_unaligned_le16(const void *p) { const u8 *b = p; return b[0] | b[1] << 8; }
static inline u32 get_unaligned_le32(const void *p) { const u8 *b = p; return b[0] | b[1] << 8 | b[2] << 16 | (u32)b[3] << 24; }
static inline u16 get_unaligned_be16(const void *p) { const u8 *b = p; return b[0] << 8 | b[1]; }
static inline u32 get_unaligned_be32(const void *p) { const u8 *b = p; return (u32)b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]; }
static inline void put_unaligned_le16(u16 v, void *p) { u8 *b = p; b[0] = v; b[1] = v >> 8; }
static inline void put_unaligned_be16(u16 v, void *p) { u8 *b = p; b[0] = v >> 8; b[1] = v; }
static inline void put_unaligned_be32(u32 v, void *p) { u8 *b = p; b[0] = v >> 24; b[1] = v >> 16; b[2] = v >> 8; b[3] = v; }
static inline u32 prandom_u32_max(u32 r) { return r ? (u32)(((uint64_t)(u32)random() * r) >> 31) % r : 0; }
static inline void get_random_bytes(void *p, int n) { u8 *b = p; while (n--) *b++ = random(); }
static inline u32 crc32_le(u32 crc, const u8 *p, size_t n) { return ~(u32)crc32(0, p, n); }
struct sk_buff { u8 *head, *data; unsigned int len, size; };
static inline unsigned int skb_headroom(const struct sk_buff *s) { return s->data - s->head; }
static inline unsigned int skb_tailroom(const struct sk_buff *s) { return s->size - skb_headroom(s) - s->len; }
static inline int skb_linearize(struct sk_buff *s) { (void)s; return 0; }
static inline int skb_cloned(const struct sk_buff *s) { (void)s; return 0; }
static inline int pskb_expand_head(struct sk_buff *s, int nhead, int ntail, int gfp) {
	unsigned int hr = skb_headroom(s), nsize = s->size + nhead + ntail;
	u8 *n = malloc(nsize); (void)gfp;
	memcpy(n + hr + nhead, s->data, s->len); free(s->head);
	s->head = n; s->data = n + hr + nhead; s->size = nsize; return 0; }
static inline u8 *skb_put(struct sk_buff *s, unsigned int n) { u8 *t = s->data + s->len; s->len += n; return t; }
static inline u8 *skb_push(struct sk_buff *s, unsigned int n) { s->data -= n; s->len += n; return s->data; }
static inline u8 *__skb_pull(struct sk_buff *s, unsigned int n) { s->data += n; s->len -= n; return s->data; }
static inline int pskb_trim(struct sk_buff *s, unsigned int n) { if (n < s->len) s->len = n; return 0; }
#endif

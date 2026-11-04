// SPDX-License-Identifier: GPL-2.0
/*
 * wgobfs-tool: small helpers the router lacks, one static binary.
 * Called by name (symlinks) or with the command as the first argument:
 *
 *   genlid [NAME]             generic netlink family id of NAME (wireguard)
 *   kmload FILE.ko [p=v ...]  load a kernel module, parameters passed as is
 *                             (busybox insmod may drop them)
 *   texthash FILE [SECTION]   sha256 of an ELF section (.text by default),
 *                             any class and byte order
 */
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <linux/netlink.h>
#include <linux/genetlink.h>

/* ---- genlid ------------------------------------------------------------ */

static int cmd_genlid(int argc, char **argv)
{
	struct { struct nlmsghdr n; struct genlmsghdr g; char buf[256]; } req;
	char resp[8192];
	const char *name = argc > 1 ? argv[1] : "wireguard";
	int fd, len, nl = (int)strlen(name) + 1, off, end;
	struct nlattr *a;
	struct nlmsghdr *n;

	if (nl > 200) {
		fprintf(stderr, "name too long\n");
		return 2;
	}
	memset(&req, 0, sizeof(req));
	req.n.nlmsg_type = GENL_ID_CTRL;
	req.n.nlmsg_flags = NLM_F_REQUEST;
	req.n.nlmsg_seq = 1;
	req.g.cmd = CTRL_CMD_GETFAMILY;
	req.g.version = 1;
	a = (struct nlattr *)req.buf;
	a->nla_type = CTRL_ATTR_FAMILY_NAME;
	a->nla_len = NLA_HDRLEN + nl;
	memcpy((char *)a + NLA_HDRLEN, name, nl);
	req.n.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN) + NLA_ALIGN(a->nla_len);

	fd = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
	if (fd < 0 || send(fd, &req, req.n.nlmsg_len, 0) < 0) {
		perror("netlink");
		return 2;
	}
	len = recv(fd, resp, sizeof(resp), 0);
	close(fd);
	if (len < (int)NLMSG_LENGTH(GENL_HDRLEN)) {
		perror("recv");
		return 2;
	}
	n = (struct nlmsghdr *)resp;
	if (n->nlmsg_type == NLMSG_ERROR) {
		fprintf(stderr, "%s: not registered\n", name);
		return 1;
	}
	off = NLMSG_LENGTH(GENL_HDRLEN);
	end = (int)n->nlmsg_len < len ? (int)n->nlmsg_len : len;
	while (off + NLA_HDRLEN <= end) {
		a = (struct nlattr *)(resp + off);
		if (a->nla_len < NLA_HDRLEN)
			break;
		if ((a->nla_type & NLA_TYPE_MASK) == CTRL_ATTR_FAMILY_ID) {
			uint16_t id;

			memcpy(&id, (char *)a + NLA_HDRLEN, 2);
			printf("%u\n", id);
			return 0;
		}
		off += NLA_ALIGN(a->nla_len);
	}
	fprintf(stderr, "no id in reply\n");
	return 1;
}

/* ---- file helper ------------------------------------------------------- */

static unsigned char *slurp(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	unsigned char *buf;
	long n;

	if (!f) {
		perror(path);
		return NULL;
	}
	if (fseek(f, 0, SEEK_END) || (n = ftell(f)) < 0 || fseek(f, 0, SEEK_SET)) {
		perror(path);
		fclose(f);
		return NULL;
	}
	buf = malloc(n ? n : 1);
	if (!buf || fread(buf, 1, n, f) != (size_t)n) {
		perror(path);
		fclose(f);
		free(buf);
		return NULL;
	}
	fclose(f);
	*len = n;
	return buf;
}

/* ---- kmload ------------------------------------------------------------ */

static int cmd_kmload(int argc, char **argv)
{
	char opts[1024] = "";
	unsigned char *img;
	size_t len, used = 0;
	int i;

	if (argc < 2) {
		fprintf(stderr, "usage: kmload module.ko [param=value ...]\n");
		return 2;
	}
	img = slurp(argv[1], &len);
	if (!img)
		return 1;
	for (i = 2; i < argc; i++) {
		size_t l = strlen(argv[i]);

		if (used + l + 2 > sizeof(opts)) {
			fprintf(stderr, "parameters too long\n");
			return 1;
		}
		if (used)
			opts[used++] = ' ';
		memcpy(opts + used, argv[i], l + 1);
		used += l;
	}
	if (syscall(SYS_init_module, img, (unsigned long)len, opts)) {
		perror("init_module");
		return 1;
	}
	return 0;
}

/* ---- sha256 ------------------------------------------------------------ */

static const uint32_t K[64] = {
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(uint32_t h[8], const unsigned char *p)
{
	uint32_t w[64], a, b, c, d, e, f, g, hh, t1, t2;
	int i;

	for (i = 0; i < 16; i++)
		w[i] = (uint32_t)p[4 * i] << 24 | p[4 * i + 1] << 16 | p[4 * i + 2] << 8 | p[4 * i + 3];
	for (i = 16; i < 64; i++)
		w[i] = (ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10)) + w[i - 7] +
		       (ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3)) + w[i - 16];
	a = h[0]; b = h[1]; c = h[2]; d = h[3]; e = h[4]; f = h[5]; g = h[6]; hh = h[7];
	for (i = 0; i < 64; i++) {
		t1 = hh + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
		t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
		hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
	}
	h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
}

static void sha256_hex(const unsigned char *data, uint64_t len, char out[65])
{
	uint32_t h[8] = { 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
			  0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 };
	unsigned char tail[128];
	uint64_t i, bits = len * 8;
	size_t rest, tl;
	int j;

	for (i = 0; i + 64 <= len; i += 64)
		sha256_block(h, data + i);
	rest = len - i;
	memset(tail, 0, sizeof(tail));
	memcpy(tail, data + i, rest);
	tail[rest] = 0x80;
	tl = rest + 1 + 8 <= 64 ? 64 : 128;
	for (j = 0; j < 8; j++)
		tail[tl - 1 - j] = (unsigned char)(bits >> (8 * j));
	sha256_block(h, tail);
	if (tl == 128)
		sha256_block(h, tail + 64);
	for (j = 0; j < 8; j++)
		sprintf(out + 8 * j, "%08x", h[j]);
}

/* ---- texthash ---------------------------------------------------------- */

static int big;

static uint64_t rd(const unsigned char *p, int n)
{
	uint64_t v = 0;
	int i;

	for (i = 0; i < n; i++)
		v = v << 8 | p[big ? i : n - 1 - i];
	return v;
}

static int cmd_texthash(int argc, char **argv)
{
	const char *want = argc > 2 ? argv[2] : ".text";
	unsigned char *f;
	size_t len;
	int is64, i;
	uint64_t shoff, shentsize, shnum, shstrndx, stroff, strsz;
	char hex[65];

	if (argc < 2) {
		fprintf(stderr, "usage: texthash FILE [SECTION]\n");
		return 2;
	}
	f = slurp(argv[1], &len);
	if (!f)
		return 1;
	if (len < 52 || memcmp(f, "\177ELF", 4) || (f[4] != 1 && f[4] != 2) || (f[5] != 1 && f[5] != 2)) {
		fprintf(stderr, "%s: not an ELF file\n", argv[1]);
		return 1;
	}
	is64 = f[4] == 2;
	big = f[5] == 2;
	if (is64 && len < 64)
		goto bad;
	shoff = is64 ? rd(f + 0x28, 8) : rd(f + 0x20, 4);
	shentsize = rd(f + (is64 ? 0x3a : 0x2e), 2);
	shnum = rd(f + (is64 ? 0x3c : 0x30), 2);
	shstrndx = rd(f + (is64 ? 0x3e : 0x32), 2);
	if (shentsize < (uint64_t)(is64 ? 64 : 40) || shstrndx >= shnum ||
	    shoff > len || shnum * shentsize > len - shoff)
		goto bad;
#define SH(i) (f + shoff + (uint64_t)(i) * shentsize)
#define OFF(s) (is64 ? rd((s) + 0x18, 8) : rd((s) + 0x10, 4))
#define SIZE(s) (is64 ? rd((s) + 0x20, 8) : rd((s) + 0x14, 4))
	stroff = OFF(SH(shstrndx));
	strsz = SIZE(SH(shstrndx));
	if (stroff > len || strsz > len - stroff)
		goto bad;
	for (i = 0; i < (int)shnum; i++) {
		const unsigned char *s = SH(i);
		uint64_t name = rd(s, 4), off = OFF(s), size = SIZE(s);

		if (name >= strsz || strnlen((const char *)f + stroff + name, strsz - name) == strsz - name)
			continue;
		if (strcmp((const char *)f + stroff + name, want))
			continue;
		if (off > len || size > len - off)
			goto bad;
		sha256_hex(f + off, size, hex);
		printf("%s\n", hex);
		return 0;
	}
	fprintf(stderr, "%s: no section %s\n", argv[1], want);
	return 1;
bad:
	fprintf(stderr, "%s: malformed ELF\n", argv[1]);
	return 1;
}

int main(int argc, char **argv)
{
	const char *me = strrchr(argv[0], '/');

	me = me ? me + 1 : argv[0];
	if (!strcmp(me, "genlid"))
		return cmd_genlid(argc, argv);
	if (!strcmp(me, "kmload"))
		return cmd_kmload(argc, argv);
	if (!strcmp(me, "texthash"))
		return cmd_texthash(argc, argv);
	if (argc > 1) {
		if (!strcmp(argv[1], "genlid"))
			return cmd_genlid(argc - 1, argv + 1);
		if (!strcmp(argv[1], "kmload"))
			return cmd_kmload(argc - 1, argv + 1);
		if (!strcmp(argv[1], "texthash"))
			return cmd_texthash(argc - 1, argv + 1);
	}
	fprintf(stderr, "usage: %s genlid|kmload|texthash ...\n", me);
	return 2;
}

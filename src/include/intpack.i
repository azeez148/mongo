/*-
 * See the file LICENSE for redistribution information.
 *
 * Copyright (c) 2008-2011 WiredTiger, Inc.
 *	All rights reserved.
 */

/*
 * Variable-length integer encoding.
 * We need up to 64 bits, signed and unsigned.  Further, we want the packed
 * representation to have the same lexicographic ordering as the integer
 * values.  This avoids the need for special-purpose comparison code.
 *
 * Try hard to keep small values small (up to ~2 bytes): that gives the biggest
 * benefit for common cases storing small values.  After that, just encode the
 * length in the first byte: we could squeeze in a couple of extra bits, but
 * the marginal benefit is small, and we want this code to be relatively
 * easy to implement in client code or scripting APIs.
 *
 * First byte | Next |                        |
 * byte       | bytes| Min Value              | Max Value
 * ------------+------+------------------------+--------------------------------
 * [00 00xxxx] | free | N/A                    | N/A
 * [00 01llll] | llll | -2^64                  | -2^13 - 2^6
 * [00 1xxxxx] | 1    | -2^13 - 2^6            | -2^6 - 1
 * [01 xxxxxx] | 0    | -2^6                   | -1
 * [10 xxxxxx] | 0    | 0                      | 2^6 - 1
 * [11 0xxxxx] | 1    | 2^6                    | 2^13 + 2^6 - 1
 * [11 10llll] | llll | 2^13 + 2^6             | 2^64 - 1
 * [11 11xxxx] | free | N/A                    | N/A
 */

#define	NEG_MULTI_MARKER (uint8_t)0x10
#define	NEG_2BYTE_MARKER (uint8_t)0x20
#define	NEG_1BYTE_MARKER (uint8_t)0x40
#define	POS_1BYTE_MARKER (uint8_t)0x80
#define	POS_2BYTE_MARKER (uint8_t)0xc0
#define	POS_MULTI_MARKER (uint8_t)0xe0

#define	NEG_1BYTE_MIN ((-1) << 6)
#define	NEG_2BYTE_MIN (((-1) << 13) + NEG_1BYTE_MIN)
#define	POS_1BYTE_MAX ((1 << 6) - 1)
#define	POS_2BYTE_MAX ((1 << 13) + POS_1BYTE_MAX)

#define	GET_BITS(x, start, end) (((x) & ((1 << (start)) - 1)) >> (end))

#define	WT_SIZE_CHECK(l, maxl) WT_RET(((size_t)(l) > (maxl)) ? ENOMEM : 0)

/*
 * __wt_vpack_posint --
 *      Packs a positive variable-length integer in the specified location.
 */
static inline int
__wt_vpack_posint(
    WT_SESSION_IMPL *session, uint8_t **pp, size_t maxlen, uint64_t x)
{
	uint8_t *p;
	int len, shift;

	WT_UNUSED(session);

	for (shift = 56, len = 8; len != 0; shift -= 8, --len)
		if (x >> shift != 0)
			break;

	WT_SIZE_CHECK(len + 1, maxlen);
	p = *pp;

	/* There are four bits we can use in the first byte. */
	*p++ |= (len & 0xf);

	for (; len != 0; shift -= 8, --len)
		*p++ = (x >> shift);

	*pp = p;
	return (0);
}

/*
 * __wt_vpack_negint --
 *      Packs a negative variable-length integer in the specified location.
 */
static inline int
__wt_vpack_negint(
    WT_SESSION_IMPL *session, uint8_t **pp, size_t maxlen, uint64_t x)
{
	uint8_t *p;
	int len, shift;

	WT_UNUSED(session);

	for (shift = 56, len = 8; len != 0; shift -= 8, --len)
		if (((x >> shift) & 0xff) != 0xff)
			break;

	WT_SIZE_CHECK(len + 1, maxlen);
	p = *pp;

	/*
	 * There are four bits we can use in the first byte.
	 * We store (8 - len) to maintain ordering: this is the number of
	 * 0xff bytes in the prefix.
	 */
	*p++ |= ((8 - len) & 0xf);

	for (; len != 0; shift -= 8, --len)
		*p++ = (x >> shift);

	*pp = p;
	return (0);
}

/*
 * __wt_vunpack_posint --
 *      Reads a variable-length positive integer from the specified location.
 */
static inline int
__wt_vunpack_posint(
    WT_SESSION_IMPL *session, const uint8_t **pp, size_t maxlen, uint64_t *retp)
{
	uint64_t x;
	const uint8_t *p;
	uint8_t len;

	WT_UNUSED(session);

	/* There are four length bits in the first byte. */
	p = *pp;
	len = (*p++ & 0xf);

	WT_SIZE_CHECK(len + 1, maxlen);

	for (x = 0; len != 0; --len, ++p)
		x = (x << 8) | *p;

	*retp = x;
	*pp = p;
	return (0);
}

/*
 * __wt_vunpack_negint --
 *      Reads a variable-length negative integer from the specified location.
 */
static inline int
__wt_vunpack_negint(
    WT_SESSION_IMPL *session, const uint8_t **pp, size_t maxlen, uint64_t *retp)
{
	uint64_t x;
	const uint8_t *p;
	uint8_t len;

	WT_UNUSED(session);

	/* There are four length bits in the first byte. */
	p = *pp;
	len = 8 - (*p++ & 0xf);

	WT_SIZE_CHECK(len + 1, maxlen);

	for (x = UINT64_MAX; len != 0; --len, ++p)
		x = (x << 8) | *p;

	*retp = x;
	*pp = p;
	return (0);
}

/*
 * __wt_vpack_uint
 *      Variable-sized packing for unsigned integers
 */
static inline int
__wt_vpack_uint(
    WT_SESSION_IMPL *session, uint8_t **pp, size_t maxlen, uint64_t x)
{
	uint8_t *p;

	WT_SIZE_CHECK(1, maxlen);
	p = *pp;
	if (x <= POS_1BYTE_MAX)
		*p++ = POS_1BYTE_MARKER | GET_BITS(x, 6, 0);
	else if (x <= POS_2BYTE_MAX) {
		WT_SIZE_CHECK(2, maxlen);
		x -= POS_1BYTE_MAX + 1;
		*p++ = POS_2BYTE_MARKER | GET_BITS(x, 13, 8);
		*p++ = GET_BITS(x, 8, 0);
	} else {
		x -= POS_2BYTE_MAX + 1;
		*p = POS_MULTI_MARKER;
		return (__wt_vpack_posint(session, pp, maxlen, x));
	}

	*pp = p;
	return (0);
}

/*
 * __wt_vpack_int
 *      Variable-sized packing for signed integers
 */
static inline int
__wt_vpack_int(WT_SESSION_IMPL *session, uint8_t **pp, size_t maxlen, int64_t x)
{
	uint8_t *p;

	WT_SIZE_CHECK(1, maxlen);
	p = *pp;
	if (x < NEG_2BYTE_MIN) {
		*p = NEG_MULTI_MARKER;
		return (__wt_vpack_negint(session, pp, maxlen, (uint64_t)x));
	} else if (x < NEG_1BYTE_MIN) {
		WT_SIZE_CHECK(2, maxlen);
		x -= NEG_2BYTE_MIN;
		*p++ = NEG_2BYTE_MARKER | GET_BITS(x, 13, 8);
		*p++ = GET_BITS(x, 8, 0);
	} else if (x < 0) {
		x -= NEG_1BYTE_MIN;
		*p++ = NEG_1BYTE_MARKER | GET_BITS(x, 6, 0);
	} else
		/* For non-negative values, use the unsigned code above. */
		return (__wt_vpack_uint(session, pp, maxlen, (uint64_t)x));

	*pp = p;
	return (0);
}

/*
 * __wt_vunpack_uint
 *      Variable-sized unpacking for unsigned integers
 */
static inline int
__wt_vunpack_uint(
    WT_SESSION_IMPL *session, const uint8_t **pp, size_t maxlen, uint64_t *xp)
{
	const uint8_t *p;

	WT_SIZE_CHECK(1, maxlen);
	p = *pp;
	switch (*p & 0xf0) {
	case POS_1BYTE_MARKER:
	case POS_1BYTE_MARKER | 0x10:
	case POS_1BYTE_MARKER | 0x20:
	case POS_1BYTE_MARKER | 0x30:
		*xp = GET_BITS(*p, 6, 0);
		p += 1;
		break;
	case POS_2BYTE_MARKER:
	case POS_2BYTE_MARKER | 0x10:
		WT_SIZE_CHECK(2, maxlen);
		*xp = POS_1BYTE_MAX + 1 + ((GET_BITS(*p, 5, 0) << 8) | p[1]);
		p += 2;
		break;
	case POS_MULTI_MARKER:
		WT_RET(__wt_vunpack_posint(session, pp, maxlen, xp));
		*xp += POS_2BYTE_MAX + 1;
		return (0);
	default:
		WT_ASSERT(session, *p != *p);
		return (EINVAL);
	}

	*pp = p;
	return (0);
}

/*
 * __wt_vunpack_int
 *      Variable-sized packing for signed integers
 */
static inline int
__wt_vunpack_int(
    WT_SESSION_IMPL *session, const uint8_t **pp, size_t maxlen, int64_t *xp)
{
	const uint8_t *p;

	WT_SIZE_CHECK(1, maxlen);
	p = *pp;
	switch (*p & 0xf0) {
	case NEG_MULTI_MARKER:
		WT_RET(__wt_vunpack_negint(session,
		    pp, maxlen, (uint64_t *)xp));
		return (0);
	case NEG_2BYTE_MARKER:
	case NEG_2BYTE_MARKER | 0x10:
		WT_SIZE_CHECK(2, maxlen);
		*xp = NEG_2BYTE_MIN + ((GET_BITS(*p, 5, 0) << 8) | p[1]);
		p += 2;
		break;
	case NEG_1BYTE_MARKER:
	case NEG_1BYTE_MARKER | 0x10:
	case NEG_1BYTE_MARKER | 0x20:
	case NEG_1BYTE_MARKER | 0x30:
		*xp = NEG_1BYTE_MIN + GET_BITS(*p, 6, 0);
		p += 1;
		break;
	default:
		/* Identical to the unsigned case. */
		return (__wt_vunpack_uint(session,
		    pp, maxlen, (uint64_t *)xp));
	}

	*pp = p;
	return (0);
}

/*
 * __wt_vsize_posint --
 *      Return the packed size of a positive variable-length integer.
 */
static inline size_t
__wt_vsize_posint(uint64_t x)
{
	size_t size;
	int len, shift;

	for (shift = 56, len = 8; len != 0; shift -= 8, --len)
		if (x >> shift != 0)
			break;

	for (size = 1; len != 0; shift -= 8, --len)
		++size;
	return (size);
}

/*
 * __wt_vsize_negint --
 *      Return the packed size of a negative variable-length integer.
 */
static inline size_t
__wt_vsize_negint(uint64_t x)
{
	size_t size;
	int len, shift;

	for (shift = 56, len = 8; len != 0; shift -= 8, --len)
		if (((x >> shift) & 0xff) != 0xff)
			break;

	for (size = 1; len != 0; shift -= 8, --len)
		++size;
	return (size);
}

/*
 * __wt_vsize_uint
 *      Return the packed size of an unsigned integer.
 */
static inline size_t
__wt_vsize_uint(uint64_t x)
{
	if (x <= POS_1BYTE_MAX)
		return (1);
	else if (x <= POS_2BYTE_MAX) {
		return (2);
	} else {
		x -= POS_2BYTE_MAX + 1;
		return (__wt_vsize_posint(x));
	}
}

/*
 * __wt_vsize_int
 *      Return the packed size of a signed integer.
 */
static inline size_t
__wt_vsize_int(int64_t x)
{
	if (x < NEG_2BYTE_MIN) {
		return (__wt_vsize_negint((uint64_t)x));
	} else if (x < NEG_1BYTE_MIN) {
		return (2);
	} else if (x < 0) {
		return (1);
	} else
		/* For non-negative values, use the unsigned code above. */
		return (__wt_vsize_uint((uint64_t)x));
}

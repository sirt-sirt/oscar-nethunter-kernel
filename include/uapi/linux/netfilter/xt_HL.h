/* SPDX-License-Identifier: GPL-2.0 WITH Linux-syscall-note */
#ifndef _XT_HL_TARGET_H
#define _XT_HL_TARGET_H

#include <linux/types.h>

#define XT_HL_MAXMODE	3

/* target info */
struct xt_HL_info {
	__u8 mode;
	__u8 hop_limit;
};

#endif /* _XT_HL_TARGET_H */

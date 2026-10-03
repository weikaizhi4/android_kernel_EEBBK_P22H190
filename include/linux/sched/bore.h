/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Burst-Oriented Response Enhancer (BORE) CPU Scheduler
 * Copyright (C) 2021-2024 Masahito Suzuki <firelzrd@gmail.com>
 *
 * Backported to this 4.14 tree: the tunables are unsigned int (this tree has
 * no proc_dou8vec handlers) and the sysctl table lives in kernel/sysctl.c.
 */
#ifndef _LINUX_SCHED_BORE_H
#define _LINUX_SCHED_BORE_H

#include <linux/sched.h>
#include <linux/sched/cputime.h>

#define SCHED_BORE_VERSION "5.9.6"

#ifdef CONFIG_SCHED_BORE
extern unsigned int __read_mostly sched_bore;
extern unsigned int __read_mostly sched_burst_exclude_kthreads;
extern unsigned int __read_mostly sched_burst_smoothness_long;
extern unsigned int __read_mostly sched_burst_smoothness_short;
extern unsigned int __read_mostly sched_burst_fork_atavistic;
extern unsigned int __read_mostly sched_burst_parity_threshold;
extern unsigned int __read_mostly sched_burst_penalty_offset;
extern unsigned int __read_mostly sched_burst_penalty_scale;
extern unsigned int __read_mostly sched_burst_cache_stop_count;
extern unsigned int __read_mostly sched_burst_cache_lifetime;
extern unsigned int __read_mostly sched_deadline_boost_mask;

extern void update_burst_score(struct sched_entity *se);
extern void update_burst_penalty(struct sched_entity *se);

extern void restart_burst(struct sched_entity *se);
extern void restart_burst_rescale_deadline(struct sched_entity *se);

extern int sched_bore_update_handler(struct ctl_table *table, int write,
	void __user *buffer, size_t *lenp, loff_t *ppos);

extern void sched_clone_bore(
	struct task_struct *p, struct task_struct *parent, u64 clone_flags, u64 now);

extern void reset_task_bore(struct task_struct *p);
extern void sched_bore_init(void);

extern void reweight_entity(
	struct cfs_rq *cfs_rq, struct sched_entity *se, unsigned long weight);
#endif /* CONFIG_SCHED_BORE */
#endif /* _LINUX_SCHED_BORE_H */

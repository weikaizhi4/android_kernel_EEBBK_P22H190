/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Compatibility shims that let the mainline (v6.14) zram driver build
 * against the 4.14 block/bio/mm APIs.
 *
 * The driver body is kept as close to mainline as possible; everything
 * that does not exist in 4.14 is emulated here with the closest 4.14
 * equivalent instead of being open coded in the driver.
 */
#ifndef _ZRAM_COMPAT_H_
#define _ZRAM_COMPAT_H_

#include <linux/bio.h>
#include <linux/blkdev.h>
#include <linux/genhd.h>
#include <linux/highmem.h>
#include <linux/jiffies.h>
#include <linux/string.h>

/*
 * kmap_local_page()/kunmap_local() were added in v5.11. On 4.14 the
 * atomic variants are the direct equivalent (both return an address
 * that is consumed by the matching unmap helper).
 */
#define kmap_local_page(page)	kmap_atomic(page)
#define kunmap_local(addr)	kunmap_atomic(addr)

/* bio_advance_iter_single() was added in v4.20 */
#define bio_advance_iter_single(bio, iter, bytes)	\
	bio_advance_iter((bio), (iter), (bytes))

/*
 * bio_start_io_acct()/bio_end_io_acct() were introduced in v5.7 to let a
 * bio based driver account I/O. 4.14 has the generic_*_io_acct() helpers
 * that need an explicit start time.
 */
static inline unsigned long zram_bio_start_io_acct(struct bio *bio)
{
	struct gendisk *disk = bio->bi_disk;
	unsigned long start_time = jiffies;

	generic_start_io_acct(disk->queue, bio_data_dir(bio),
			      bio_sectors(bio), &disk->part0);
	return start_time;
}

static inline void zram_bio_end_io_acct(struct bio *bio,
					unsigned long start_time)
{
	struct gendisk *disk = bio->bi_disk;

	generic_end_io_acct(disk->queue, bio_data_dir(bio), &disk->part0,
			    start_time);
}

/*
 * memcpy_to_bvec()/memcpy_from_bvec() were added in v5.18.
 */
static inline void memcpy_to_bvec(struct bio_vec *bvec, const void *src)
{
	void *dst = kmap_atomic(bvec->bv_page);

	memcpy(dst + bvec->bv_offset, src, bvec->bv_len);
	kunmap_atomic(dst);
}

static inline void memcpy_from_bvec(void *dst, struct bio_vec *bvec)
{
	void *src = kmap_atomic(bvec->bv_page);

	memcpy(dst, src + bvec->bv_offset, bvec->bv_len);
	kunmap_atomic(src);
}

#define bio_start_io_acct(bio)		zram_bio_start_io_acct(bio)
#define bio_end_io_acct(bio, start_time)			\
	zram_bio_end_io_acct((bio), (start_time))

#endif /* _ZRAM_COMPAT_H_ */

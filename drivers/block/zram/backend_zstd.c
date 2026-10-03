// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * zstd compression backend.
 *
 * The mainline backend is written against the post-v5.13 zstd API
 * (zstd_{c,d}ctx / zstd_cdict / custom allocators). 4.14 ships the older
 * one-shot zstd API, so the context handling is adapted here. Dictionary
 * and streaming (cctx/dctx by reference) support is not available on 4.14
 * and is therefore not implemented.
 */

#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/vmalloc.h>
#include <linux/zstd.h>

#include "backend_zstd.h"

/* Same default as mainline zstd_default_clevel() */
#define ZSTD_DEF_CLEVEL		3

struct zstd_ctx {
	ZSTD_CCtx *cctx;
	ZSTD_DCtx *dctx;
	void *cctx_mem;
	void *dctx_mem;
};

static void zstd_release_params(struct zcomp_params *params)
{
}

static int zstd_setup_params(struct zcomp_params *params)
{
	if (params->level == ZCOMP_PARAM_NO_LEVEL)
		params->level = ZSTD_DEF_CLEVEL;

	return 0;
}

static void zstd_destroy(struct zcomp_ctx *ctx)
{
	struct zstd_ctx *zctx = ctx->context;

	if (!zctx)
		return;

	vfree(zctx->cctx_mem);
	vfree(zctx->dctx_mem);
	kfree(zctx);
	ctx->context = NULL;
}

static int zstd_create(struct zcomp_params *params, struct zcomp_ctx *ctx)
{
	struct zstd_ctx *zctx;
	ZSTD_parameters prm;
	size_t sz;

	zctx = kzalloc(sizeof(*zctx), GFP_KERNEL);
	if (!zctx)
		return -ENOMEM;

	ctx->context = zctx;

	prm = ZSTD_getParams(params->level, PAGE_SIZE, 0);

	sz = ZSTD_CCtxWorkspaceBound(prm.cParams);
	zctx->cctx_mem = vzalloc(sz);
	if (!zctx->cctx_mem)
		goto error;

	zctx->cctx = ZSTD_initCCtx(zctx->cctx_mem, sz);
	if (!zctx->cctx)
		goto error;

	sz = ZSTD_DCtxWorkspaceBound();
	zctx->dctx_mem = vzalloc(sz);
	if (!zctx->dctx_mem)
		goto error;

	zctx->dctx = ZSTD_initDCtx(zctx->dctx_mem, sz);
	if (!zctx->dctx)
		goto error;

	return 0;

error:
	zstd_destroy(ctx);
	return -ENOMEM;
}

static int zstd_compress(struct zcomp_params *params, struct zcomp_ctx *ctx,
			 struct zcomp_req *req)
{
	struct zstd_ctx *zctx = ctx->context;
	ZSTD_parameters prm;
	size_t ret;

	prm = ZSTD_getParams(params->level, req->src_len, 0);
	ret = ZSTD_compressCCtx(zctx->cctx, req->dst, req->dst_len,
				req->src, req->src_len, prm);
	if (ZSTD_isError(ret))
		return -EINVAL;

	req->dst_len = ret;
	return 0;
}

static int zstd_decompress(struct zcomp_params *params, struct zcomp_ctx *ctx,
			   struct zcomp_req *req)
{
	struct zstd_ctx *zctx = ctx->context;
	size_t ret;

	ret = ZSTD_decompressDCtx(zctx->dctx, req->dst, req->dst_len,
				  req->src, req->src_len);
	if (ZSTD_isError(ret))
		return -EINVAL;

	return 0;
}

const struct zcomp_ops backend_zstd = {
	.compress	= zstd_compress,
	.decompress	= zstd_decompress,
	.create_ctx	= zstd_create,
	.destroy_ctx	= zstd_destroy,
	.setup_params	= zstd_setup_params,
	.release_params	= zstd_release_params,
	.name		= "zstd",
};

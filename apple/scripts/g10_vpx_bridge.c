#include "g10_vpx_bridge.h"
#include <vpx/vpx_decoder.h>
#include <vpx/vp8dx.h>
#include <stdlib.h>
#include <math.h>

struct G10Decoder {
    vpx_codec_ctx_t color, alpha;
    vpx_codec_iface_t *codec;
    unsigned width, height;
};

const char *g10_version(void) { return vpx_codec_version_str(); }

G10Decoder *g10_create(int vp9, unsigned width, unsigned height) {
    if (!width || !height || width > 4096 || height > 4096) return NULL;
    G10Decoder *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    vpx_codec_dec_cfg_t config = {.threads=1, .w=width, .h=height};
    vpx_codec_iface_t *codec = vp9 ? vpx_codec_vp9_dx() : vpx_codec_vp8_dx();
    if (vpx_codec_dec_init(&d->color, codec, &config, 0) != VPX_CODEC_OK) { free(d); return NULL; }
    if (vpx_codec_dec_init(&d->alpha, codec, &config, 0) != VPX_CODEC_OK) {
        vpx_codec_destroy(&d->color); free(d); return NULL;
    }
    d->width=width; d->height=height;
    d->codec=codec;
    return d;
}

void g10_destroy(G10Decoder *d) {
    if (!d) return;
    vpx_codec_destroy(&d->color); vpx_codec_destroy(&d->alpha); free(d);
}

static uint8_t byte(double value) { return (uint8_t)fmin(255, fmax(0, round(value))); }

int g10_decode(G10Decoder *d, const uint8_t *color, size_t color_size,
               const uint8_t *alpha, size_t alpha_size, uint8_t *rgba, size_t capacity) {
    if (!d || !rgba || color_size > 16777216 || alpha_size > 16777216 ||
        capacity < (size_t)d->width*d->height*4) return -1;
    vpx_codec_stream_info_t info={.sz=sizeof(info)};
    if (vpx_codec_peek_stream_info(d->codec, color, (unsigned)color_size, &info) == VPX_CODEC_OK &&
        info.w && info.h && (info.w != d->width || info.h != d->height)) return -3;
    info.sz=sizeof(info); info.w=info.h=0;
    if (alpha_size && vpx_codec_peek_stream_info(d->codec, alpha, (unsigned)alpha_size, &info) == VPX_CODEC_OK &&
        info.w && info.h && (info.w != d->width || info.h != d->height)) return -5;
    if (vpx_codec_decode(&d->color, color, (unsigned)color_size, NULL, 0) != VPX_CODEC_OK) return -2;
    vpx_codec_iter_t iter=NULL;
    vpx_image_t *image=vpx_codec_get_frame(&d->color, &iter);
    if (!image) return 0;
    if (image->d_w != d->width || image->d_h != d->height || image->fmt != VPX_IMG_FMT_I420) return -3;
    vpx_image_t *mask=NULL;
    if (alpha_size) {
        if (vpx_codec_decode(&d->alpha, alpha, (unsigned)alpha_size, NULL, 0) != VPX_CODEC_OK) return -4;
        iter=NULL; mask=vpx_codec_get_frame(&d->alpha, &iter);
        if (!mask || mask->d_w != d->width || mask->d_h != d->height || mask->fmt != VPX_IMG_FMT_I420) return -5;
    }
    // Prototype supports 8-bit I420 BT.601/BT.709 only. Reject HDR/high-bit-depth.
    if (image->cs != VPX_CS_UNKNOWN && image->cs != VPX_CS_BT_601 &&
        image->cs != VPX_CS_SMPTE_170 && image->cs != VPX_CS_BT_709) return -6;
    for (unsigned y=0; y<d->height; ++y) for (unsigned x=0; x<d->width; ++x) {
        double luma=image->planes[0][y*image->stride[0]+x];
        double u=image->planes[1][(y/2)*image->stride[1]+x/2]-128;
        double v=image->planes[2][(y/2)*image->stride[2]+x/2]-128;
        int full=image->range == VPX_CR_FULL_RANGE;
        luma=full ? luma : (luma-16)*255.0/219;
        double chroma=full ? 1 : 255.0/224;
        u*=chroma; v*=chroma;
        int bt709=image->cs == VPX_CS_BT_709;
        uint8_t a=mask ? mask->planes[0][y*mask->stride[0]+x] : 255;
        size_t i=((size_t)y*d->width+x)*4;
        rgba[i+0]=(uint8_t)((unsigned)byte(luma+(bt709?1.5748:1.402)*v)*a/255);
        rgba[i+1]=(uint8_t)((unsigned)byte(luma-(bt709?0.1873:0.344136)*u-(bt709?0.4681:0.714136)*v)*a/255);
        rgba[i+2]=(uint8_t)((unsigned)byte(luma+(bt709?1.8556:1.772)*u)*a/255);
        rgba[i+3]=a;
    }
    return 1;
}

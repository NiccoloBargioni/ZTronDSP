#include "ztd_internal.h"
#include "ztd_vdsp.h"

/* Partitioned convolution (WP-214, WP-215): a long FIR as a uniformly partitioned
   frequency-domain delay line (Wefers 2015, ch. 5; Gardner 1995 for the direct head).

   The filter is cut into P partitions of B taps. With N = 2B, partition i is zero-padded to N
   and transformed once, when the kernel is created: its spectrum H_i. The input is cut into
   partitions of B frames on a grid counted from the kernel's first frame. When partition t is
   complete, the window made of partitions t - 1 and t is transformed: X_t, kept in a delay line
   of the last P such spectra. Then

       Y_t = sum over i of H_i * X_(t - i)

   and the last B frames of its inverse transform are the B outputs of partition t (overlap-save:
   the first B frames are the wrapped part of the circular convolution and are dropped).

   The kernel adds no latency, for any block size. A block that brings a whole partition on the
   grid takes the path above: two transforms and P spectral products for B frames. Frames that
   arrive as part of a partition cannot wait for the rest of it, so they are computed as

       y[n] = (first B taps, convolved directly with the input)  +  tail[n]

   where the tail, the contribution of partitions 1 … P - 1 of the filter, depends only on input
   partitions that are already complete: it is one inverse transform of
   sum over i >= 1 of H_i * X_(t - i), computed the first time a partition needs it.

   vDSP's real transform (vDSP_DFT_zrop) packs a spectrum of N real values as B real and B
   imaginary values, with the two purely real bins sharing index 0: real[0] is bin 0 and
   imaginary[0] is bin B. Forward it returns twice the transform; inverse it is not scaled. The
   kernel spectra are therefore stored scaled by 1 / (4N), an exact power of two, so that the
   inverse of a product is the convolution itself. */

typedef struct ztd_partitioned {
    uint32_t channels;
    uint32_t count;      /* taps */
    uint32_t partition;  /* B */
    uint32_t partitions; /* P */
    uint32_t head_count; /* taps of the direct head: min(count, B) */
    uint32_t fill;       /* frames of the current input partition already in: 0 ..< B */
    uint32_t newest;     /* slot of the delay line that holds the latest complete window */
    bool tail_ready;     /* `tail` holds the tail of the current partition */
    vDSP_DFT_Setup forward, inverse;
    float *head;         /* the first head_count taps, reversed for vDSP_conv */
    float *spectra;      /* P spectra: B real then B imaginary each, scaled by 1 / (4N) */
    float **window;      /* per channel: the previous partition, then the current one (2B) */
    float **line;        /* per channel: the delay line, P slots of 2B */
    float **tail;        /* per channel: B frames */
    float *even, *odd;   /* B each: a window split for the forward transform */
    float *sum_real, *sum_imaginary; /* B each: the accumulated product */
    float *time_even, *time_odd;     /* B each: the inverse transform */
} ztd_partitioned_t;

/* Transforms channel `channel`'s window into slot `slot` of its delay line. */
static void ztd_partitioned_transform(ztd_partitioned_t *p, uint32_t channel, uint32_t slot) ZTD_NONBLOCKING {
    const uint32_t size = p->partition;
    const float *restrict window = p->window[channel];
    float *restrict even = p->even, *restrict odd = p->odd;
    for (uint32_t index = 0; index < size; index++) {
        even[index] = window[2 * index];
        odd[index] = window[2 * index + 1];
    }
    float *spectrum = p->line[channel] + (size_t)slot * 2 * size;
    vDSP_DFT_Execute(p->forward, even, odd, spectrum, spectrum + size);
    ztd_flush_state(spectrum, 2 * size);
}

/* sum over i in first ..< P of H_i * X_(latest - i), inverse-transformed; the last B frames go
   to `out`. `latest` is the slot of the newest window that takes part. */
static void ztd_partitioned_convolve(ztd_partitioned_t *p, uint32_t channel, uint32_t first, uint32_t latest,
                                     float *out) ZTD_NONBLOCKING {
    const uint32_t size = p->partition;
    float *restrict sum_real = p->sum_real, *restrict sum_imaginary = p->sum_imaginary;
    memset(sum_real, 0, (size_t)size * sizeof(float));
    memset(sum_imaginary, 0, (size_t)size * sizeof(float));
    for (uint32_t index = first; index < p->partitions; index++) {
        const uint32_t slot = (latest + p->partitions - (index - first)) % p->partitions;
        const float *restrict h_real = p->spectra + (size_t)index * 2 * size;
        const float *restrict h_imaginary = h_real + size;
        const float *restrict x_real = p->line[channel] + (size_t)slot * 2 * size;
        const float *restrict x_imaginary = x_real + size;
        /* Index 0 holds two real bins, not one complex one. */
        sum_real[0] += h_real[0] * x_real[0];
        sum_imaginary[0] += h_imaginary[0] * x_imaginary[0];
        for (uint32_t bin = 1; bin < 4; bin++) {
            sum_real[bin] += h_real[bin] * x_real[bin] - h_imaginary[bin] * x_imaginary[bin];
            sum_imaginary[bin] += h_real[bin] * x_imaginary[bin] + h_imaginary[bin] * x_real[bin];
        }
        /* The rest, four bins at a time (see ztd_float4): this is where the kernel spends its
           time. The partition is a power of two from 8 up, so nothing is left over. */
        for (uint32_t bin = 4; bin < size; bin += 4) {
            const ztd_float4 hr = ztd_load4(h_real + bin), hi = ztd_load4(h_imaginary + bin);
            const ztd_float4 xr = ztd_load4(x_real + bin), xi = ztd_load4(x_imaginary + bin);
            ztd_store4(sum_real + bin, ztd_load4(sum_real + bin) + (hr * xr - hi * xi));
            ztd_store4(sum_imaginary + bin, ztd_load4(sum_imaginary + bin) + (hr * xi + hi * xr));
        }
    }
    float *restrict time_even = p->time_even, *restrict time_odd = p->time_odd;
    vDSP_DFT_Execute(p->inverse, sum_real, sum_imaginary, time_even, time_odd);
    /* Frame 2j of the result is time_even[j], frame 2j + 1 is time_odd[j]; frames B ..< 2B. */
    const uint32_t half = size / 2;
    float *restrict result = out;
    for (uint32_t index = 0; index < half; index++) {
        result[2 * index] = time_even[half + index];
        result[2 * index + 1] = time_odd[half + index];
    }
}

static uint32_t ztd_partitioned_process(void *state, const float *const *in, float *const *out,
                                        uint32_t channels, uint32_t frames) ZTD_NONBLOCKING {
    ztd_partitioned_t *p = (ztd_partitioned_t *)state;
    const uint32_t count = ztd_min_u32(channels, p->channels);
    const uint32_t size = p->partition;
    uint32_t done = 0;
    while (done < frames) {
        const uint32_t chunk = ztd_min_u32(frames - done, size - p->fill);
        const uint32_t next = (p->newest + 1) % p->partitions;
        if (chunk == size) {
            /* A whole partition on the grid: the frequency-domain path. */
            for (uint32_t channel = 0; channel < count; channel++) {
                float *window = p->window[channel];
                memcpy(window + size, in[channel] + done, (size_t)size * sizeof(float));
                ztd_flush_state(window + size, size);
                ztd_partitioned_transform(p, channel, next);
                ztd_partitioned_convolve(p, channel, 0, next, out[channel] + done);
                memcpy(window, window + size, (size_t)size * sizeof(float));
            }
            p->newest = next;
            p->tail_ready = false;
        } else {
            /* Part of a partition: the head directly, the tail from the delay line. */
            if (!p->tail_ready) {
                for (uint32_t channel = 0; channel < count; channel++) {
                    if (p->partitions > 1) {
                        ztd_partitioned_convolve(p, channel, 1, p->newest, p->tail[channel]);
                        ztd_flush_state(p->tail[channel], size);
                    } else {
                        memset(p->tail[channel], 0, (size_t)size * sizeof(float));
                    }
                }
                p->tail_ready = true;
            }
            for (uint32_t channel = 0; channel < count; channel++) {
                float *slot = p->window[channel] + size + p->fill;
                memcpy(slot, in[channel] + done, (size_t)chunk * sizeof(float));
                ztd_flush_state(slot, chunk);
                float *restrict destination = out[channel] + done;
                vDSP_conv(slot - (p->head_count - 1), 1, p->head, 1, destination, 1, chunk, p->head_count);
                const float *restrict tail = p->tail[channel] + p->fill;
                for (uint32_t frame = 0; frame < chunk; frame++) destination[frame] += tail[frame];
            }
            p->fill += chunk;
            if (p->fill == size) {
                /* The partition is complete: its window joins the delay line. */
                for (uint32_t channel = 0; channel < count; channel++) {
                    float *window = p->window[channel];
                    ztd_partitioned_transform(p, channel, next);
                    memcpy(window, window + size, (size_t)size * sizeof(float));
                }
                p->newest = next;
                p->fill = 0;
                p->tail_ready = false;
            }
        }
        done += chunk;
    }
    return frames;
}

static void ztd_partitioned_reset(void *state) ZTD_NONBLOCKING {
    ztd_partitioned_t *p = (ztd_partitioned_t *)state;
    const size_t size = p->partition;
    for (uint32_t channel = 0; channel < p->channels; channel++) {
        memset(p->window[channel], 0, 2 * size * sizeof(float));
        memset(p->line[channel], 0, (size_t)p->partitions * 2 * size * sizeof(float));
        memset(p->tail[channel], 0, size * sizeof(float));
    }
    p->fill = 0;
    p->newest = p->partitions - 1;
    p->tail_ready = false;
}

static void ztd_partitioned_free_lanes(float **lanes, uint32_t channels) {
    if (!lanes) return;
    for (uint32_t channel = 0; channel < channels; channel++) free(lanes[channel]);
    free(lanes);
}

static void ztd_partitioned_destroy(void *state) {
    ztd_partitioned_t *p = (ztd_partitioned_t *)state;
    if (!p) return;
    if (p->forward) vDSP_DFT_DestroySetup(p->forward);
    if (p->inverse) vDSP_DFT_DestroySetup(p->inverse);
    ztd_partitioned_free_lanes(p->window, p->channels);
    ztd_partitioned_free_lanes(p->line, p->channels);
    ztd_partitioned_free_lanes(p->tail, p->channels);
    free(p->head);
    free(p->spectra);
    free(p->even);
    free(p->odd);
    free(p->sum_real);
    free(p->sum_imaginary);
    free(p->time_even);
    free(p->time_odd);
    free(p);
}

static float **ztd_partitioned_lanes(uint32_t channels, size_t frames) {
    float **lanes = (float **)ztd_allocate(channels, sizeof(float *));
    if (!lanes) return NULL;
    for (uint32_t channel = 0; channel < channels; channel++) {
        lanes[channel] = (float *)ztd_allocate(frames, sizeof(float));
        if (!lanes[channel]) {
            ztd_partitioned_free_lanes(lanes, channels);
            return NULL;
        }
    }
    return lanes;
}

ztd_kernel_t ztd_partitioned_create(uint32_t channels, const float *taps, uint32_t count, uint32_t partition,
                                    uint32_t latency_frames) {
    /* The transform length 2 * partition must be one vDSP documents: a power of two from 16 up
       (E-09). The length is admitted by arithmetic; a setup is created only for an admitted one. */
    const bool admitted = partition >= 8 && partition <= ((uint32_t)1 << 20) && (partition & (partition - 1)) == 0;
    if (channels == 0 || channels > ZTD_LIMIT || !admitted || !ztd_taps_are_valid(taps, count)) {
        return ztd_kernel_null();
    }
    ztd_partitioned_t *p = (ztd_partitioned_t *)ztd_allocate(1, sizeof(ztd_partitioned_t));
    if (!p) return ztd_kernel_null();
    const size_t size = partition;
    p->channels = channels;
    p->count = count;
    p->partition = partition;
    p->partitions = (count + partition - 1) / partition;
    p->head_count = count < partition ? count : partition;
    p->newest = p->partitions - 1;
    p->forward = ztd_may_allocate() ? vDSP_DFT_zrop_CreateSetup(NULL, 2 * size, vDSP_DFT_FORWARD) : NULL;
    p->inverse = p->forward && ztd_may_allocate() ? vDSP_DFT_zrop_CreateSetup(p->forward, 2 * size, vDSP_DFT_INVERSE) : NULL;
    p->head = (float *)ztd_allocate(p->head_count, sizeof(float));
    p->spectra = (float *)ztd_allocate((size_t)p->partitions * 2 * size, sizeof(float));
    p->window = ztd_partitioned_lanes(channels, 2 * size);
    p->line = ztd_partitioned_lanes(channels, (size_t)p->partitions * 2 * size);
    p->tail = ztd_partitioned_lanes(channels, size);
    p->even = (float *)ztd_allocate(size, sizeof(float));
    p->odd = (float *)ztd_allocate(size, sizeof(float));
    p->sum_real = (float *)ztd_allocate(size, sizeof(float));
    p->sum_imaginary = (float *)ztd_allocate(size, sizeof(float));
    p->time_even = (float *)ztd_allocate(size, sizeof(float));
    p->time_odd = (float *)ztd_allocate(size, sizeof(float));
    if (!p->forward || !p->inverse || !p->head || !p->spectra || !p->window || !p->line || !p->tail || !p->even ||
        !p->odd || !p->sum_real || !p->sum_imaginary || !p->time_even || !p->time_odd) {
        ztd_partitioned_destroy(p);
        return ztd_kernel_null();
    }

    for (uint32_t tap = 0; tap < p->head_count; tap++) p->head[p->head_count - 1 - tap] = taps[tap];

    /* The kernel spectra: partition i, zero-padded to 2B, transformed, scaled by 1 / (4N). */
    const float scale = 1.0f / (4.0f * (float)(2 * size));
    for (uint32_t index = 0; index < p->partitions; index++) {
        memset(p->even, 0, size * sizeof(float));
        memset(p->odd, 0, size * sizeof(float));
        for (uint32_t tap = 0; tap < partition; tap++) {
            const uint64_t source = (uint64_t)index * partition + tap;
            if (source >= count) break;
            /* Sample `tap` of the padded partition: even samples in one array, odd in the other. */
            if (tap % 2 == 0) p->even[tap / 2] = taps[source];
            else p->odd[tap / 2] = taps[source];
        }
        float *spectrum = p->spectra + (size_t)index * 2 * size;
        vDSP_DFT_Execute(p->forward, p->even, p->odd, spectrum, spectrum + size);
        for (size_t bin = 0; bin < 2 * size; bin++) spectrum[bin] *= scale;
    }
    memset(p->even, 0, size * sizeof(float));
    memset(p->odd, 0, size * sizeof(float));

    ztd_kernel_t kernel = {
        .process = ztd_partitioned_process,
        .command = NULL,
        .reset = ztd_partitioned_reset,
        .destroy = ztd_partitioned_destroy,
        .state = p,
        .latency_frames = latency_frames,
        .settling_frames = count - 1,
    };
    return kernel;
}

uint32_t ztd_partitioned_spectrum(const ztd_kernel_t *kernel, uint32_t index, float *real, float *imaginary) {
    /* Only a kernel made by ztd_partitioned_create has such spectra. */
    if (!kernel || kernel->process != ztd_partitioned_process || !kernel->state) return 0;
    const ztd_partitioned_t *p = (const ztd_partitioned_t *)kernel->state;
    if (index >= p->partitions || !real || !imaginary) return p->partitions;
    const size_t size = p->partition;
    const float *stored = p->spectra + (size_t)index * 2 * size;
    /* Stored: twice the transform (vDSP's convention) times 1 / (4N), which is the transform over
       2N. Undoing it is a multiplication by a power of two, which is exact. */
    const float scale = 2.0f * (float)(2 * size);
    real[0] = stored[0] * scale;
    imaginary[0] = 0.0f;
    for (size_t bin = 1; bin < size; bin++) {
        real[bin] = stored[bin] * scale;
        imaginary[bin] = stored[size + bin] * scale;
    }
    real[size] = stored[size] * scale; /* bin B, purely real, travels in imaginary[0] */
    imaginary[size] = 0.0f;
    return p->partitions;
}

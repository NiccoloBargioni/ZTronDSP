#include "ztd_internal.h"

/* The input history shared by the direct FIR, the decimator and the interpolator. See
   ztd_internal.h for what a cell is and why the kernels work in cells. */

bool ztd_history_create(ztd_history_t *history, uint32_t channels, uint32_t past, uint32_t cell) {
    memset(history, 0, sizeof *history);
    history->channels = channels;
    history->past = past;
    history->cell = cell;
    /* Enough cells that the move back to the front happens at most once per `past` frames, and
       no more often than every 1 024 frames. */
    history->cells = (past > 1023 ? past : 1023) / cell + 1;
    history->buffer = (float **)ztd_allocate(channels, sizeof(float *));
    if (!history->buffer) return false;
    const size_t frames = (size_t)past + (size_t)history->cells * cell;
    for (uint32_t channel = 0; channel < channels; channel++) {
        history->buffer[channel] = (float *)ztd_allocate(frames, sizeof(float));
        if (!history->buffer[channel]) return false;
    }
    return true;
}

void ztd_history_destroy(ztd_history_t *history) {
    if (!history->buffer) return;
    for (uint32_t channel = 0; channel < history->channels; channel++) free(history->buffer[channel]);
    free(history->buffer);
    history->buffer = NULL;
}

void ztd_history_reset(ztd_history_t *history) ZTD_NONBLOCKING {
    const size_t frames = (size_t)history->past + (size_t)history->cells * history->cell;
    for (uint32_t channel = 0; channel < history->channels; channel++) {
        memset(history->buffer[channel], 0, frames * sizeof(float));
    }
    history->index = 0;
    history->fill = 0;
}

const float *ztd_history_accept(ztd_history_t *history, uint32_t channel, const float *in,
                                uint32_t frames) ZTD_NONBLOCKING {
    float *window = history->buffer[channel] + (size_t)history->index * history->cell;
    float *slot = window + history->past + history->fill;
    memcpy(slot, in, (size_t)frames * sizeof(float));
    ztd_flush_state(slot, frames);
    const uint32_t rest = history->cell - history->fill - frames;
    if (rest > 0) memset(slot + frames, 0, (size_t)rest * sizeof(float));
    return window;
}

void ztd_history_advance(ztd_history_t *history, uint32_t frames) ZTD_NONBLOCKING {
    history->fill += frames;
    if (history->fill < history->cell) return;
    history->fill = 0;
    history->index += 1;
    if (history->index < history->cells) return;
    /* The buffer is full: its last `past` frames are the history of the next cell. */
    const size_t used = (size_t)history->cells * history->cell;
    for (uint32_t channel = 0; channel < history->channels; channel++) {
        memmove(history->buffer[channel], history->buffer[channel] + used, (size_t)history->past * sizeof(float));
    }
    history->index = 0;
}

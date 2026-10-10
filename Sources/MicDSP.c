#include "MicDSP.h"
#include <math.h>
float mic_process(float *samples, size_t count, float gain_db, int boost, int mute) {
    if (!samples) return 0;
    if (!isfinite(gain_db)) gain_db = 0;
    gain_db = fminf(12, fmaxf(-24, gain_db));
    float multiplier = mute ? 0 : powf(10, (gain_db + (boost ? 12 : 0)) / 20);
    float peak = 0;
    for (size_t i = 0; i < count; ++i) {
        float value = isfinite(samples[i]) ? samples[i] * multiplier : 0;
        // Pass quiet signals unchanged; gently limit the last 18% of headroom.
        if (fabsf(value) > 0.8f) value = copysignf(0.8f + 0.18f * tanhf((fabsf(value) - 0.8f) / 0.18f), value);
        samples[i] = value;
        peak = fmaxf(peak, fabsf(value));
    }
    return peak;
}

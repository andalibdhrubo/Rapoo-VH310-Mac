#include "../Sources/MicDSP.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
int main(void) {
    float flat[] = {0, .2f, -.2f};
    assert(fabsf(mic_process(flat, 3, 0, 0, 0) - .2f) < 1e-6);
    assert(flat[1] == .2f && flat[2] == -.2f);
    float boost[] = {.1f, -.1f}; mic_process(boost, 2, 0, 1, 0);
    assert(fabsf(boost[0] - .398107f) < 1e-5 && boost[0] == -boost[1]);
    float quiet[] = {.2f}; mic_process(quiet, 1, -6, 0, 0);
    assert(fabsf(quiet[0] - .100237f) < 1e-5);
    float loud[] = {1, -1, NAN, INFINITY};
    float peak = mic_process(loud, 4, 12, 1, 0);
    assert(peak <= .98f && peak >= .8f && loud[0] == -loud[1]);
    assert(loud[2] == 0 && loud[3] == 0);
    assert(mic_process(loud, 4, 12, 1, 1) == 0);
    for (int i = 0; i < 4; ++i) assert(loud[i] == 0);
    puts("PASS: mic unity, +12 dB boost, attenuation, limiter symmetry/bounds, invalid samples, mute.");
}

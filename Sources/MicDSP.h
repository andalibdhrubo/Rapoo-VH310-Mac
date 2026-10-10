#ifndef MIC_DSP_H
#define MIC_DSP_H
#include <stddef.h>
float mic_process(float *samples, size_t count, float gain_db, int boost, int mute);
#endif

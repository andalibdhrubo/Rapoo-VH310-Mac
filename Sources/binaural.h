#include "Surround.h"
#include "MicDSP.h"
#ifndef RAPOO_BINAURAL_H
#define RAPOO_BINAURAL_H
#include <stddef.h>
typedef struct Binaural Binaural;
Binaural *binaural_create(double sample_rate);
void binaural_destroy(Binaural *processor);
void binaural_process(Binaural *processor, float *left, float *right, size_t frames, int enabled);
#endif

#ifndef RAPOO_SURROUND_H
#define RAPOO_SURROUND_H
#include <stddef.h>
/* WAVE 7.1 channel order: FL FR C LFE BL BR SL SR. */
typedef struct Surround Surround;
Surround *surround_create(double sample_rate);
void surround_destroy(Surround *p);
void surround_reset(Surround *p);
/* Strength applies only to the ambience derived from stereo. Rotation
   changes all seven directional speakers; LFE is always nondirectional. */
void surround_settings(Surround *p, float strength, float rotation_degrees);
void surround_stereo(Surround *p, float *left, float *right, size_t frames, int enabled);
void surround_interleaved(Surround *p, const float *wave_7_1, float *left, float *right, size_t frames);
void surround_test(Surround *p, int channel, float *left, float *right, size_t frames);
#endif

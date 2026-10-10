#include "binaural.h"
#include "hrtf_coefficients.h"
#include <math.h>
#include <stdlib.h>
struct Binaural {
    const float *near_ir, *far_ir;
    size_t taps, position;
    float *history_l, *history_r;
    float wet, smoothing;
};
#define BANK(rate) case rate: p->near_ir=near_##rate; p->far_ir=far_##rate; p->taps=sizeof(near_##rate)/sizeof(float); break
Binaural *binaural_create(double sample_rate) {
    if (!isfinite(sample_rate) || sample_rate<1 || sample_rate>96000.01 || fabs(sample_rate-round(sample_rate))>0.01) return NULL;
    Binaural *p=calloc(1,sizeof(*p)); if(!p)return NULL;
    switch((int)round(sample_rate)) { BANK(44100);BANK(48000);BANK(88200);BANK(96000);default:free(p);return NULL; }
    p->history_l=calloc(p->taps,sizeof(float));p->history_r=calloc(p->taps,sizeof(float));
    if(!p->history_l||!p->history_r){binaural_destroy(p);return NULL;}
    p->smoothing=1.0f/(float)(0.02*sample_rate);return p;
}
void binaural_destroy(Binaural *p) {if(p){free(p->history_l);free(p->history_r);free(p);}}
// Preserve ordinary levels; apply a smooth saturation only above 0.9.
static float protect(float x) {float a=fabsf(x);return a<=0.9f?x:copysignf(0.9f+0.1f*tanhf((a-0.9f)*10.0f),x);}
void binaural_process(Binaural *p,float *left,float *right,size_t frames,int enabled){
    if(!p||!left||!right)return;
    const float target=enabled?1.0f:0.0f;
    for(size_t frame=0;frame<frames;frame++){
        float l=isfinite(left[frame])?left[frame]:0,r=isfinite(right[frame])?right[frame]:0;
        p->history_l[p->position]=l;p->history_r[p->position]=r;
        float out_l=0,out_r=0;
        p->wet += fmaxf(-p->smoothing,fminf(p->smoothing,target-p->wet));
        if(p->wet>0){
            size_t pos=p->position;
            for(size_t t=0;t<p->taps;t++){
                float hl=p->history_l[pos],hr=p->history_r[pos];
                out_l+=hl*p->near_ir[t]+hr*p->far_ir[t];
                out_r+=hl*p->far_ir[t]+hr*p->near_ir[t];
                pos=pos?pos-1:p->taps-1;
            }
            out_l=protect(out_l*0.5f);out_r=protect(out_r*0.5f);
            left[frame]=l*(1-p->wet)+out_l*p->wet;
            right[frame]=r*(1-p->wet)+out_r*p->wet;
        }
        p->position=(p->position+1)%p->taps;
    }
}

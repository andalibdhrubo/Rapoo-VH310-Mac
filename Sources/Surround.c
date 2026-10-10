#include "Surround.h"
#include "surround_coefficients.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>
struct Surround {
    const float *bank;
    size_t taps, position, delay_position, delay_frames;
    float *history, *delay;
    const float *ir[8][2], *old_ir[8][2];
    float morph, morph_step, wet, wet_step, strength, bass_a, bass1, bass2, side_low;
    float limiter_gain, limiter_release;
    double rate;
};
#define BANK(R) case R: p->bank=&surround_ir_##R[0][0][0];p->taps=sizeof(surround_ir_##R[0][0])/sizeof(float);break
static float finite_sample(float x) {return isfinite(x)?x:0;}
static float protect(float x) {return fabsf(x)<=.9f?x:copysignf(.9f+.1f*tanhf((fabsf(x)-.9f)*10),x);}
void surround_settings(Surround *p,float strength,float rotation) {
    if(!p||!isfinite(strength)||!isfinite(rotation))return;
    p->strength=fmaxf(0,fminf(1,strength));
    const float positions[8]={-30,30,0,0,-150,150,-90,90};
    int changed=0;
    for(int ch=0;ch<8;ch++) {
        if(ch==3)continue;
        float angle=remainderf(positions[ch]+rotation,360);
        int index=(int)lroundf(fabsf(angle)/5); if(index>36)index=36;
        for(int ear=0;ear<2;ear++) {
            int source_ear=angle<0?1-ear:ear;
            const float *next=p->bank+(index*2+source_ear)*p->taps;
            if(next!=p->ir[ch][ear]){p->old_ir[ch][ear]=p->ir[ch][ear]?p->ir[ch][ear]:next;p->ir[ch][ear]=next;changed=1;}
        }
    }
    if(changed)p->morph=0;
}
Surround *surround_create(double rate) {
    if(!isfinite(rate)||rate<1||rate>96000.01||fabs(rate-round(rate))>.01)return NULL;
    Surround *p=calloc(1,sizeof(*p));if(!p)return NULL;
    switch((int)round(rate)){BANK(44100);BANK(48000);BANK(88200);BANK(96000);default:free(p);return NULL;}
    p->limiter_gain=1;p->limiter_release=1-expf(-1/(float)(.08*rate));
    p->rate=rate;p->delay_frames=(size_t)lround(rate*.012);p->history=calloc(8*p->taps,sizeof(float));p->delay=calloc(p->delay_frames,sizeof(float));
    if(!p->history||!p->delay){surround_destroy(p);return NULL;}
    p->bass_a=1-expf(-2*3.14159265358979323846f*120/(float)rate);
    p->wet_step=1/(float)(.02*rate);p->morph_step=1/(float)(.03*rate);
    surround_settings(p,.6f,0);p->morph=1;return p;
}
void surround_destroy(Surround *p){if(p){free(p->history);free(p->delay);free(p);}}
void surround_reset(Surround *p){if(p){memset(p->history,0,8*p->taps*sizeof(float));memset(p->delay,0,p->delay_frames*sizeof(float));p->position=p->delay_position=0;p->bass1=p->bass2=p->side_low=p->wet=0;p->morph=1;p->limiter_gain=1;}}
static void render(Surround *p,const float channels[8],float *left,float *right) {
    float sum[2]={0,0};
    p->morph=fminf(1,p->morph+p->morph_step);
    for(int ch=0;ch<8;ch++) {
        if(ch==3)continue;
        float *history=p->history+ch*p->taps;history[p->position]=finite_sample(channels[ch]);
        for(int ear=0;ear<2;ear++) {
            float current=0,previous=0;size_t pos=p->position;
            for(size_t t=0;t<p->taps;t++) {
                current+=history[pos]*p->ir[ch][ear][t];
                if(p->morph<1)previous+=history[pos]*p->old_ir[ch][ear][t];
                pos=pos?pos-1:p->taps-1;
            }
            sum[ear]+=p->morph<1?previous+(current-previous)*p->morph:current;
        }
    }
    p->bass1+=p->bass_a*(finite_sample(channels[3])-p->bass1);
    p->bass2+=p->bass_a*(p->bass1-p->bass2);
    // Fixed common headroom across channels. LFE is lowpassed and equally
    // distributed, with no cinema +10 dB boost or false directional cue.
    *left=protect(.32f*sum[0]+.25f*p->bass2);
    *right=protect(.32f*sum[1]+.25f*p->bass2);
    p->position=(p->position+1)%p->taps;
}
void surround_interleaved(Surround *p,const float *input,float *left,float *right,size_t frames) {
    if(!p||!input||!left||!right)return;
    for(size_t i=0;i<frames;i++)render(p,input+8*i,left+i,right+i);
}
void surround_stereo(Surround *p,float *left,float *right,size_t frames,int enabled) {
    if(!p||!left||!right)return;
    float target=enabled?1:0;
    for(size_t i=0;i<frames;i++) {
        float l=finite_sample(left[i]),r=finite_sample(right[i]);
        float mid=.5f*(l+r),side=.5f*(l-r);
        // Only uncorrelated/difference content feeds the synthetic surrounds.
        // Identical mono inputs stay in front instead of creating rear voices.
        p->side_low+=p->bass_a*(side-p->side_low);
        float ambience=side-p->side_low,delayed=p->delay[p->delay_position];
        p->delay[p->delay_position]=ambience;p->delay_position=(p->delay_position+1)%p->delay_frames;
        float channels[8]={.75f*l,.75f*r,.5f*mid,.35f*mid,.35f*delayed*p->strength,-.35f*delayed*p->strength,.5f*ambience*p->strength,-.5f*ambience*p->strength};
        p->wet+=fmaxf(-p->wet_step,fminf(p->wet_step,target-p->wet));
        if(p->wet>0){float out_l,out_r;render(p,channels,&out_l,&out_r);// Preserve the direct signal for body and intelligibility, while
            // retaining the measured spatial render. +4 dB makeup gain.
            float enhanced_l=1.584893f*(.8f*l+.65f*out_l);
            float enhanced_r=1.584893f*(.8f*r+.65f*out_r);
            float peak=fmaxf(fabsf(enhanced_l),fabsf(enhanced_r));
            float wanted=peak>.97f?.97f/peak:1;
            // Linked instant attack / 80 ms release preserves stereo balance.
            if(wanted<p->limiter_gain)p->limiter_gain=wanted;
            else p->limiter_gain+=p->limiter_release*(wanted-p->limiter_gain);
            left[i]=l+(enhanced_l*p->limiter_gain-l)*p->wet;
            right[i]=r+(enhanced_r*p->limiter_gain-r)*p->wet;}
        else {left[i]=l;right[i]=r;}
    }
}
void surround_test(Surround *p,int channel,float *left,float *right,size_t frames) {
    if(!p||!left||!right||channel<0||channel>7)return;
    surround_reset(p);
    unsigned noise=12345;
    for(size_t i=0;i<frames;i++){
        double time=(double)i/p->rate;float channels[8]={0};
        float envelope=time<.02?time/.02:time<.7?1:time<.75?(.75-time)/.05:0;
        noise=1664525u*noise+1013904223u;
        float signal=channel==3?(float)sin(2*3.14159265358979323846*65*time):((float)(noise>>8)/16777215-.5f);
        channels[channel]=signal*.4f*envelope;render(p,channels,left+i,right+i);
    }
}

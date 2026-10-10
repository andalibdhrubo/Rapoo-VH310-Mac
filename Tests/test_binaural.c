#include "../Sources/binaural.h"
#include "../Sources/hrtf_coefficients.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
int main(void){
    Binaural *p=binaural_create(44100);assert(p);
    float warm_l[1200]={0},warm_r[1200]={0};binaural_process(p,warm_l,warm_r,1200,1);
    float l[256]={1},r[256]={0};binaural_process(p,l,r,256,1);
    for(int i=0;i<128;i++){assert(fabsf(l[i]-.5f*near_44100[i])<1e-6f);assert(fabsf(r[i]-.5f*far_44100[i])<1e-6f);}
    float ml[256]={0},mr[256]={1};binaural_process(p,ml,mr,256,1);
    for(int i=0;i<256;i++){assert(fabsf(ml[i]-r[i])<1e-6f);assert(fabsf(mr[i]-l[i])<1e-6f);}
    memset(warm_l,0,sizeof(warm_l));memset(warm_r,0,sizeof(warm_r));binaural_process(p,warm_l,warm_r,1200,0);
    for(int i=0;i<256;i++){l[i]=.2f;r[i]=-.3f;}binaural_process(p,l,r,256,0);
    for(int i=0;i<256;i++){assert(l[i]==.2f);assert(r[i]==-.3f);}binaural_destroy(p);
    const int rates[]={44100,48000,88200,96000};for(int i=0;i<4;i++){p=binaural_create(rates[i]);assert(p);binaural_destroy(p);}assert(!binaural_create(32000));
    puts("PASS: measured impulse, stereo mirror, exact bypass, supported rates.");return 0;
}

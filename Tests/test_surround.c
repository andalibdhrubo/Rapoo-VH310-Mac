#include "../Sources/Surround.h"
#include "../Sources/surround_coefficients.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
int main(void) {
    Surround *p=surround_create(44100);assert(p);
    float input[256*8]={0},left[256],right[256];
    const int angle[8]={-30,30,0,0,-150,150,-90,90};
    for(int ch=0;ch<8;ch++) {
        surround_reset(p);memset(input,0,sizeof(input));input[ch]=1;
        surround_interleaved(p,input,left,right,256);
        if(ch==3){for(int i=0;i<256;i++)assert(left[i]==right[i]);assert(left[0]>0);continue;}
        int a=abs(angle[ch])/5,ear=angle[ch]<0?1:0;
        for(int i=0;i<128;i++) {
            assert(fabsf(left[i]-.32f*surround_ir_44100[a][ear][i])<1e-6f);
            assert(fabsf(right[i]-.32f*surround_ir_44100[a][1-ear][i])<1e-6f);
        }
        for(int i=128;i<256;i++)assert(left[i]==0 && right[i]==0);
    }
    surround_reset(p);
    for(int i=0;i<256*8;i++)input[i]=.2f*sinf((float)i*.019f);
    surround_interleaved(p,input,left,right,256);
    float split_l[256],split_r[256];surround_reset(p);
    surround_interleaved(p,input,split_l,split_r,7);
    surround_interleaved(p,input+7*8,split_l+7,split_r+7,249);
    assert(memcmp(left,split_l,sizeof(left))==0 && memcmp(right,split_r,sizeof(right))==0);
    surround_reset(p);surround_settings(p,.6f,180);
    memset(input,0,sizeof(input));surround_interleaved(p,input,left,right,256);
    // Finish the 30 ms direction crossfade before checking the rear center.
    for(int j=0;j<6;j++)surround_interleaved(p,input,left,right,256);
    input[2]=1;surround_interleaved(p,input,left,right,256);
    for(int i=0;i<128;i++)assert(fabsf(left[i]-.32f*surround_ir_44100[36][0][i])<1e-6f);
    surround_destroy(p);
    const int rates[]={44100,48000,88200,96000};
    for(int r=0;r<4;r++) {
        p=surround_create(rates[r]);assert(p);
        float l[256],rr[256],saved[256];
        for(int i=0;i<256;i++)saved[i]=l[i]=rr[i]=.1f*sinf((float)i*.04f);
        surround_stereo(p,l,rr,256,0);assert(memcmp(l,saved,sizeof(l))==0 && memcmp(rr,saved,sizeof(rr))==0);
        surround_stereo(p,l,rr,256,1);
        for(int i=0;i<256;i++)assert(isfinite(l[i]) && isfinite(rr[i]) && fabsf(l[i])<=1 && fabsf(rr[i])<=1);
        for(int ch=0;ch<8;ch++){surround_test(p,ch,l,rr,256);for(int i=0;i<256;i++)assert(isfinite(l[i])&&isfinite(rr[i]));}
        surround_destroy(p);
    }
    assert(surround_create(32000)==NULL);
    puts("PASS: seven measured channel responses, LFE, split buffers, 180-degree rotation, exact bypass and four rates.");
}

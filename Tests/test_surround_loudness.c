#include "../Sources/Surround.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>
int main(void) {
 const int rates[]={44100,48000,88200,96000};
 for(int k=0;k<4;k++) {
  Surround *p=surround_create(rates[k]);
  float l[256],r[256]; double before=0,after=0;
  for(int block=0;block<100;block++) {
   for(int i=0;i<256;i++)l[i]=r[i]=.1f*sinf(6.2831853f*440*(block*256+i)/rates[k]);
   if(block>40)for(int i=0;i<256;i++)before+=l[i]*l[i];
   surround_stereo(p,l,r,256,1);
   if(block>40)for(int i=0;i<256;i++){after+=l[i]*l[i];assert(fabsf(l[i]-r[i])<1e-5);}
  }
  double db=10*log10(after/before); printf("%d Hz mono 440 Hz loudness change: %.2f dB\n",rates[k],db); assert(db>2 && db<7);
  for(int block=0;block<40;block++) {
   for(int i=0;i<256;i++){l[i]=sinf((block*256+i)*.13f);r[i]=cosf((block*256+i)*.19f);}
   surround_stereo(p,l,r,256,1);
   for(int i=0;i<256;i++)assert(isfinite(l[i])&&isfinite(r[i])&&fabsf(l[i])<=.971f&&fabsf(r[i])<=.971f);
  }
  surround_destroy(p);
 }
 puts("PASS: makeup gain, centered mono and stereo peak protection at all supported rates.");
}

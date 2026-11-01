/* Bounded, disposable test pressure. No files/data/network; stdin EOF or watchdog releases all RAM.
 * High oom_score_adj makes this helper expendable. Never locks pages or disables swap. */
#define _POSIX_C_SOURCE 200809L
#define _DEFAULT_SOURCE
#include <sys/mman.h>
#include <sys/select.h>
#include <time.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <signal.h>

static long available_kib(void) {
    FILE *f=fopen("/proc/meminfo","r"); if(!f)return -1;
    char line[256];long n=-1;
    while(fgets(line,sizeof(line),f))if(sscanf(line,"MemAvailable: %ld kB",&n)==1)break;
    fclose(f);return n;
}
static double seconds(void){struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
int main(int argc,char **argv){
    long target=argc>1?strtol(argv[1],NULL,10):393216;
    if(target<327680 || target>1048576)return 2;
    FILE *adj=fopen("/proc/self/oom_score_adj","w");
    if(!adj)return 3;
    if(fputs("900\n",adj)<0 || fclose(adj)!=0)return 3;
    adj=fopen("/proc/self/oom_score_adj","r");int priority=-1000;
    if(!adj)return 3;int scan_count=fscanf(adj,"%d",&priority);fclose(adj);
    if(scan_count!=1 || priority!=900)return 3;
    setvbuf(stdout,NULL,_IOLBF,0);
    alarm(45); /* Default SIGALRM terminates the helper even while its loop is delayed. */
    printf("{\"event\":\"started\",\"watchdogSeconds\":45,\"oomScoreAdj\":900,\"allocationCapMiB\":4096,\"targetKiB\":%ld}\n",target);
    const size_t chunk=16U*1024*1024;const int limit=256; /* <=4GiB, independent 45s watchdog */
    uint8_t *blocks[256]={0};int count=0;uint32_t rng=0x8135abc7U;
    const double start=seconds();double last=0;const char *reason="watchdog";
    while(seconds()-start<45.0){
        fd_set rfds;FD_ZERO(&rfds);FD_SET(STDIN_FILENO,&rfds);struct timeval tv={0,0};
        if(select(STDIN_FILENO+1,&rfds,NULL,NULL,&tv)>0){char command[32];ssize_t n=read(STDIN_FILENO,command,sizeof(command));(void)n;reason="stdin_release_or_eof";break;}
        long free_kib=available_kib();if(free_kib<0){reason="snapshot_unavailable";break;}
        if(free_kib<262144){reason="safety_floor";break;}
        if(free_kib>target && count<limit){
            uint8_t *p=mmap(NULL,chunk,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
            if(p==MAP_FAILED){reason="allocation_failed";break;}
            blocks[count++]=p;
            for(size_t j=0;j<chunk/sizeof(uint32_t);j++){
                rng^=rng<<13;rng^=rng>>17;rng^=rng<<5;((uint32_t*)p)[j]=rng;
            }
        }else{
            /* Retouch one byte per page, with low-frequency sleep; ordinary swappable pages. */
            for(int i=0;i<count;i++)for(size_t j=0;j<chunk;j+=4096)blocks[i][j]^=1;
            struct timespec pause={0,200000000};nanosleep(&pause,NULL);
        }
        if(seconds()-last>=0.25){
            last=seconds();long current=available_kib();
            printf("{\"event\":\"pressure_sample\",\"elapsedSeconds\":%.3f,\"availableKiB\":%ld,\"allocatedMiB\":%d,\"targetReached\":%s,\"oomScoreAdj\":900}\n",last-start,current,count*16,current<=target?"true":"false");
        }
    }
    for(int i=0;i<count;i++)munmap(blocks[i],chunk);
    printf("{\"event\":\"released\",\"reason\":\"%s\",\"allocatedMiB\":%d,\"availableKiB\":%ld}\n",reason,count*16,available_kib());
    return 0;
}

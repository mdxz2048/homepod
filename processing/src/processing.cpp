#include "flow/processing.h"
#include <array>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <limits>
#include <new>

static_assert(sizeof(float)==4,"processing ABI requires 32-bit float");

struct Ramp {
    double current=1, initial=1, target=1;
    uint32_t done=0, length=0;
    void start(double value, uint32_t frames) noexcept {
        initial=current; target=value; done=0; length=frames;
    }
    double advance() noexcept {
        if(done<length) {
            ++done;
            current = done==length ? target : initial+(target-initial)*double(done)/length;
        }
        return current;
    }
};
struct Command { int32_t index; float target; uint64_t frame; uint32_t ramp; };
struct flow_processing {
    uint32_t count=0, max_frames=0, command_count=0;
    uint64_t next_frame=0;
    std::array<std::array<float,4>,8> matrix{};
    std::array<Ramp,9> gain{}; // index0 master, remaining devices
    std::array<Command,64> commands{};
    const char* error="";
};
namespace {
bool unit(float x) noexcept { return std::isfinite(x)&&x>=0&&x<=1; }
int32_t fail(flow_processing* p,int32_t status,const char* message) noexcept {
    if(p) p->error=message;
    return status;
}
bool overlaps(const float* input,uint64_t count,const float* output,uint64_t out_count) noexcept {
    const auto a=reinterpret_cast<uintptr_t>(input), b=reinterpret_cast<uintptr_t>(output);
    const auto max=std::numeric_limits<uintptr_t>::max();
    if(count>max/sizeof(float)||out_count>max/sizeof(float)) return true;
    const auto as=uintptr_t(count*sizeof(float)), bs=uintptr_t(out_count*sizeof(float));
    if(a>max-as||b>max-bs) return true;
    return a<b+bs&&b<a+as;
}
}
extern "C" {
uint32_t FLOW_DSP_CALL flow_processing_version(void) { return 1; }
flow_processing* FLOW_DSP_CALL flow_processing_create(uint32_t mode,
    const flow_processing_device* devices,uint32_t count,float lx,float ly,uint32_t max_frames,float master) {
    if(mode>1||!devices||count<1||count>8||!unit(lx)||!unit(ly)||!unit(master)||max_frames<1||max_frames>65536) return nullptr;
    for(uint32_t i=0;i<count;++i)
        if(!unit(devices[i].x)||!unit(devices[i].y)||!unit(devices[i].gain)) return nullptr;
    auto p=new(std::nothrow) flow_processing;
    if(!p) return nullptr;
    p->count=count; p->max_frames=max_frames;
    p->gain[0].current=p->gain[0].initial=p->gain[0].target=master;
    std::array<float,8> rear{}, pan{};
    uint32_t coverage=0; bool has_front=false;
    for(uint32_t i=0;i<count;++i) {
        const float dx=devices[i].x-lx, dy=devices[i].y-ly;
        rear[i]=std::clamp(dy/std::max(1-ly,0.05f),0.0f,1.0f);
        const float distance=std::hypot(dx,dy);
        pan[i]=distance>0.000001f ? std::clamp(dx/distance,-1.0f,1.0f):0;
        if(rear[i]<=0.1f) has_front=true;
        if(rear[i]<rear[coverage]) coverage=i;
        p->gain[i+1].current=p->gain[i+1].initial=p->gain[i+1].target=devices[i].gain;
    }
    if(!has_front) rear[coverage]=0; // retain a full-content bus when all speakers are behind
    for(uint32_t i=0;i<count;++i) {
        float r=mode==1 ? rear[i]:0;
        const float ql=0.125f-0.35f*pan[i], qr=0.125f+0.35f*pan[i];
        auto& m=p->matrix[i];
        m={1-r+r*ql,r*qr,r*ql,1-r+r*qr};
        for(uint32_t row=0;row<2;++row) {
            const float norm=std::abs(m[row*2])+std::abs(m[row*2+1]);
            if(norm>1) { m[row*2]/=norm; m[row*2+1]/=norm; }
        }
    }
    return p;
}
int32_t FLOW_DSP_CALL flow_processing_set_gain(flow_processing* p,int32_t index,float target,
    uint64_t frame,uint32_t ramp) {
    if(!p||index< -1||index>=int32_t(p->count)||!unit(target)||ramp<882||ramp>441000)
        return fail(p,FLOW_DSP_INVALID_ARGUMENT,"invalid gain, output, or ramp");
    if(frame<p->next_frame) return fail(p,FLOW_DSP_DISCONTINUITY,"gain frame already processed");
    for(uint32_t i=0;i<p->command_count;++i)
        if(p->commands[i].index==index&&p->commands[i].frame==frame) {
            p->commands[i]={index,target,frame,ramp}; p->error=""; return FLOW_DSP_OK;
        }
    if(p->command_count==p->commands.size()) return fail(p,FLOW_DSP_QUEUE_FULL,"gain queue full");
    uint32_t i=p->command_count++;
    while(i>0&&p->commands[i-1].frame>frame) { p->commands[i]=p->commands[i-1]; --i; }
    p->commands[i]={index,target,frame,ramp}; p->error="";
    return FLOW_DSP_OK;
}
int32_t FLOW_DSP_CALL flow_processing_process(flow_processing* p,uint64_t first,const float* input,
    uint64_t samples,float* output,uint64_t capacity) {
    if(!p||!input||!output||samples==0||samples%2||samples/2>p->max_frames)
        return fail(p,FLOW_DSP_INVALID_ARGUMENT,"invalid input buffer or frame count");
    const uint64_t frames=samples/2, needed=samples*p->count;
    if(capacity<needed||overlaps(input,samples,output,needed))
        return fail(p,FLOW_DSP_INVALID_ARGUMENT,"insufficient or overlapping output buffer");
    if(first!=p->next_frame||first>std::numeric_limits<uint64_t>::max()-frames)
        return fail(p,FLOW_DSP_DISCONTINUITY,"noncontinuous or overflowing media frame");
    for(uint64_t i=0;i<samples;++i)
        if(!std::isfinite(input[i])||input[i]<-1||input[i]>1)
            return fail(p,FLOW_DSP_INVALID_ARGUMENT,"input must be finite float32 in [-1,1]");
    uint32_t applied=0;
    for(uint64_t f=0;f<frames;++f) {
        while(applied<p->command_count&&p->commands[applied].frame==first+f) {
            const auto& c=p->commands[applied++]; p->gain[c.index+1].start(c.target,c.ramp);
        }
        const double master=p->gain[0].advance();
        const double l=input[f*2],r=input[f*2+1];
        for(uint32_t d=0;d<p->count;++d) {
            const auto& m=p->matrix[d];
            const double gain=master*p->gain[d+1].advance();
            output[f*p->count*2+d*2]=float((l*m[0]+r*m[1])*gain);
            output[f*p->count*2+d*2+1]=float((l*m[2]+r*m[3])*gain);
        }
    }
    for(uint32_t i=applied;i<p->command_count;++i) p->commands[i-applied]=p->commands[i];
    p->command_count-=applied; p->next_frame+=frames; p->error="";
    return FLOW_DSP_OK;
}
int32_t FLOW_DSP_CALL flow_processing_matrix(const flow_processing* p,float* out,uint32_t capacity) {
    if(!p||!out||capacity<p->count*4) return FLOW_DSP_INVALID_ARGUMENT;
    for(uint32_t d=0;d<p->count;++d) for(uint32_t i=0;i<4;++i) out[d*4+i]=p->matrix[d][i];
    return FLOW_DSP_OK;
}
const char* FLOW_DSP_CALL flow_processing_last_error(const flow_processing* p) { return p?p->error:"null processor"; }
void FLOW_DSP_CALL flow_processing_destroy(flow_processing* p) { delete p; }
}

#include "flow/processing.h"
#include <array>
#include <vector>
#include <cmath>
#include <iostream>
#include <stdexcept>
#include <limits>
#include <algorithm>

namespace {
void check(bool ok,const char* why) { if(!ok) throw std::runtime_error(why); }
void near(float a,float b,const char* why) { check(std::abs(a-b)<0.000002f,why); }
const flow_processing_device devices[]={{.5f,.1f,1},{.1f,1,1},{.9f,1,1}};
struct Owner {
    flow_processing* p;
    Owner(uint32_t mode=0,uint32_t count=3,float gain=1):
        p(flow_processing_create(mode,devices,count,.5f,.7f,4096,gain)) { check(p,"create"); }
    ~Owner() { flow_processing_destroy(p); }
};
std::vector<float> render(Owner& p,const std::vector<float>& in,uint64_t first,uint32_t count=3) {
    std::vector<float> out(in.size()*count);
    check(flow_processing_process(p.p,first,in.data(),in.size(),out.data(),out.size())==0,"render");
    return out;
}
void sync_and_matrices() {
    Owner sync;
    const std::vector<float> input={1,-1,.3f,.8f,0,0};
    auto out=render(sync,input,0);
    for(size_t f=0;f<3;++f) for(size_t d=0;d<3;++d) {
        near(out[f*6+d*2],input[f*2],"sync L"); near(out[f*6+d*2+1],input[f*2+1],"sync R");
    }
    Owner cinema(1);
    std::array<float,12> m;
    check(flow_processing_matrix(cinema.p,m.data(),m.size())==0,"matrix inspect");
    near(m[0],1,"front full L"); near(m[3],1,"front full R");
    check(std::abs(m[4]-m[8])>.1f,"rear directional difference");
    for(size_t row=0;row<6;++row) check(std::abs(m[row*2])+std::abs(m[row*2+1])<=1.000001f,"row bound");
    auto mono=render(cinema,{1,1,0,0,-1,1},0);
    check(mono[2]>.20f&&mono[4]>.20f,"mono content retained in rears");
    for(size_t d=0;d<3;++d) {
        near(mono[d*2],m[d*4]+m[d*4+1],"mono public matrix");
        near(mono[12+d*2],-m[d*4]+m[d*4+1],"antiphase public matrix");
    }
}
void split_invariance_and_scheduled_gain() {
    Owner one(1),split(1);
    for(auto p:{one.p,split.p}) {
        check(flow_processing_set_gain(p,-1,0,17,882)==0,"master schedule");
        check(flow_processing_set_gain(p,1,.3f,500,1000)==0,"relative schedule");
        check(flow_processing_set_gain(p,-1,.8f,1000,882)==0,"master ramp interruption");
    }
    std::vector<float> input(4000);
    for(size_t i=0;i<input.size();++i) input[i]=float(std::sin(double(i)*.07));
    const auto expected=render(one,input,0);
    std::vector<float> result;
    size_t offset=0;
    for(size_t frames:{1u,16u,499u,3u,481u,1u,999u}) {
        const std::vector<float> chunk(input.begin()+offset*2,input.begin()+(offset+frames)*2);
        const auto block=render(split,chunk,offset);
        result.insert(result.end(),block.begin(),block.end()); offset+=frames;
    }
    check(result==expected,"arbitrary block split bit identity");
    Owner ramp(0,1,0);
    check(flow_processing_set_gain(ramp.p,-1,1,0,882)==0,"unmute");
    auto smooth=render(ramp,std::vector<float>(1800,1),0,1);
    near(smooth[0],1.0f/882,"first step"); near(smooth[1762],1,"20ms reaches target");
    check(smooth[0]<.002f,"no initial full volume transient");
}
void invalid_atomic_and_queue() {
    Owner p;
    float in[]={.5f,.5f,std::numeric_limits<float>::quiet_NaN(),0};
    float out[12]; std::fill(std::begin(out),std::end(out),.123f);
    check(flow_processing_set_gain(p.p,-1,0,0,882)==0,"schedule for atomic check");
    check(flow_processing_process(p.p,0,in,4,out,12)==FLOW_DSP_INVALID_ARGUMENT,"NaN reject");
    for(float v:out) near(v,.123f,"invalid did not partially write");
    in[2]=0;
    check(flow_processing_process(p.p,0,in,4,out,11)==FLOW_DSP_INVALID_ARGUMENT,"capacity reject");
    check(flow_processing_process(p.p,1,in,4,out,12)==FLOW_DSP_DISCONTINUITY,"frame reject");
    check(flow_processing_process(p.p,0,in,4,in,12)==FLOW_DSP_INVALID_ARGUMENT,"overlap reject");
    check(flow_processing_process(p.p,0,in,4,out,12)==0,"retry at same frame succeeds");
    near(out[0],.5f*(1-1.0f/882),"invalid calls did not advance gain");
    check(flow_processing_set_gain(p.p,-1,.5f,1,882)==FLOW_DSP_DISCONTINUITY,"past gain reject");
    check(flow_processing_set_gain(p.p,-1,.5f,2,881)==FLOW_DSP_INVALID_ARGUMENT,"short ramp reject");
    for(uint32_t i=0;i<64;++i) check(flow_processing_set_gain(p.p,0,.5f,100+i,882)==0,"bounded queue fill");
    check(flow_processing_set_gain(p.p,0,.8f,100,882)==0,"replace when full");
    check(flow_processing_set_gain(p.p,0,.5f,200,882)==FLOW_DSP_QUEUE_FULL,"queue overflow explicit");
}
void layouts_peak_and_counts() {
    for(uint32_t count=1;count<=8;++count) {
        std::array<flow_processing_device,8> back;
        for(uint32_t i=0;i<count;++i) back[i]={float(i)/8,1,1};
        auto p=flow_processing_create(1,back.data(),count,.5f,.7f,4096,1);
        check(p,"1..8 outputs");
        std::array<float,32> matrix{};
        check(flow_processing_matrix(p,matrix.data(),count*4)==0,"all-back inspect");
        bool full=false;
        for(uint32_t d=0;d<count;++d) if(matrix[d*4]==1&&matrix[d*4+3]==1) full=true;
        check(full,"all-back retains full-content output");
        std::vector<float> in(8192),out(in.size()*count);
        uint32_t state=123;
        for(auto& v:in) { state=1664525*state+1013904223; v=float(double(state)/4294967295.0*2-1); }
        check(flow_processing_process(p,0,in.data(),in.size(),out.data(),out.size())==0,"random process");
        for(float v:out) check(std::isfinite(v)&&std::abs(v)<=1,"peak safe random");
        flow_processing_destroy(p);
    }
    const flow_processing_device overlap[]={{.5f,.7f,1},{.5f,.7f,1}};
    auto p=flow_processing_create(1,overlap,2,.5f,.7f,4,1);
    check(p,"coincident layout defined"); flow_processing_destroy(p);
    check(!flow_processing_create(0,devices,0,.5f,.7f,1,1),"zero outputs reject");
    check(!flow_processing_create(0,devices,3,.5f,.7f,0,1),"zero max frames reject");
    check(!flow_processing_create(0,devices,3,.5f,.7f,1,2),"initial gain reject");
    check(flow_processing_process(nullptr,0,nullptr,0,nullptr,0)==FLOW_DSP_INVALID_ARGUMENT,"null safe");
    flow_processing_destroy(nullptr);
}
}
int main() {
    try {
        check(flow_processing_version()==1,"ABI");
        sync_and_matrices(); split_invariance_and_scheduled_gain();
        invalid_atomic_and_queue(); layouts_peak_and_counts();
        std::cout<<"processing: 4 behavior groups PASS (no network/audio)\n"; return 0;
    } catch(const std::exception& e) { std::cerr<<e.what()<<"\n"; return 1; }
}

#include "sherpa-onnx/c-api/c-api.h"
#include <AudioToolbox/AudioToolbox.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <limits>
#include <string>
#include <vector>

static std::string quoted(const std::string &s) {
    std::string out="\"";
    for (unsigned char c:s) {
        if(c=='"'||c=='\\') {out+='\\';out+=c;}
        else if(c=='\n')out+="\\n";else if(c=='\r')out+="\\r";else if(c=='\t')out+="\\t";
        else if(c>=32)out+=c;
    }
    return out+'"';
}
static void event(const char *type,const std::string &text,double start,double end) {
    std::cout<<"{\"type\":"<<quoted(type)<<",\"text\":"<<quoted(text)<<",\"start\":"<<start<<",\"end\":"<<end<<"}"<<std::endl;
}
static const SherpaOnnxVoiceActivityDetector *makeVAD(const std::string &path) {
    SherpaOnnxVadModelConfig config{};
    config.silero_vad.model=path.c_str();config.silero_vad.threshold=.5f;
    config.silero_vad.min_silence_duration=.6f;config.silero_vad.min_speech_duration=.25f;
    config.silero_vad.window_size=512;config.silero_vad.max_speech_duration=24.f;
    config.sample_rate=16000;config.num_threads=1;config.provider="cpu";
    return SherpaOnnxCreateVoiceActivityDetector(&config, 60);
}
// afconvert对AAC录音可能写出合法WAVE_FORMAT_EXTENSIBLE（fmt=40）。
// 交给系统解码器读取PCM，避免sherpa的简化WAV读取器只接受fmt=16。
static std::vector<float> readNormalizedWave(const char *path) {
    struct AudioFile {
        ExtAudioFileRef value=nullptr;
        ~AudioFile(){if(value)ExtAudioFileDispose(value);}
    } file;
    CFURLRef url=CFURLCreateFromFileSystemRepresentation(nullptr,
        reinterpret_cast<const UInt8 *>(path),std::char_traits<char>::length(path),false);
    if(!url)throw std::runtime_error("无法定位标准化录音文件");
    OSStatus status=ExtAudioFileOpenURL(url,&file.value);CFRelease(url);
    if(status!=noErr)throw std::runtime_error("无法打开标准化录音，解码代码："+std::to_string(status));
    AudioStreamBasicDescription source{};UInt32 size=sizeof(source);
    status=ExtAudioFileGetProperty(file.value,kExtAudioFileProperty_FileDataFormat,&size,&source);
    if(status!=noErr||source.mFormatID!=kAudioFormatLinearPCM||source.mSampleRate!=16000||
        source.mChannelsPerFrame!=1||source.mBitsPerChannel!=16)
        throw std::runtime_error("标准化录音应为16kHz单声道16位PCM");
    AudioStreamBasicDescription client{};
    client.mSampleRate=16000;client.mFormatID=kAudioFormatLinearPCM;
    client.mFormatFlags=kAudioFormatFlagsNativeFloatPacked;client.mBytesPerPacket=4;
    client.mFramesPerPacket=1;client.mBytesPerFrame=4;client.mChannelsPerFrame=1;client.mBitsPerChannel=32;
    status=ExtAudioFileSetProperty(file.value,kExtAudioFileProperty_ClientDataFormat,sizeof(client),&client);
    if(status!=noErr)throw std::runtime_error("无法配置录音解码格式，代码："+std::to_string(status));
    std::vector<float> samples;float block[4096];
    while(true) {
        UInt32 frames=4096;
        AudioBufferList buffers{};buffers.mNumberBuffers=1;
        buffers.mBuffers[0]={1,sizeof(block),block};
        status=ExtAudioFileRead(file.value,&frames,&buffers);
        if(status!=noErr)throw std::runtime_error("读取标准化录音失败，代码："+std::to_string(status));
        if(frames==0)break;
        if(samples.size()+frames>static_cast<size_t>(std::numeric_limits<int32_t>::max()))
            throw std::runtime_error("录音超过单次处理时长上限");
        samples.insert(samples.end(),block,block+frames);
    }
    return samples;
}
static int segment(const std::string &models,const char *file,const char *output) {
    const auto samples=readNormalizedWave(file);
    const int sampleCount=static_cast<int>(samples.size());
    auto *vad=makeVAD(models+"/silero_vad.onnx");
    if(!vad)throw std::runtime_error("Silero VAD加载失败");
    std::filesystem::create_directories(output);
    std::ofstream manifest(std::string(output)+"/segments.json");manifest<<"[";int index=0;
    auto drain=[&] {
        while(!SherpaOnnxVoiceActivityDetectorEmpty(vad)) {
            auto *s=SherpaOnnxVoiceActivityDetectorFront(vad);
            const int begin=std::max(0,s->start-1600),end=std::min(sampleCount,s->start+s->n+1600);
            for(int position=begin;position<end;position+=25*16000) {
                const int stop=std::min(end,position+25*16000);
                std::string path=std::filesystem::absolute(std::string(output)+"/"+std::to_string(index)+".wav").string();
                if(!SherpaOnnxWriteWave(samples.data()+position,stop-position,16000,path.c_str()))throw std::runtime_error("写入语音片段失败");
                if(index++)manifest<<",";
                manifest<<"{\"audio\":"<<quoted(path)<<",\"start\":"<<position/16000.0<<",\"end\":"<<stop/16000.0<<"}";
            }
            SherpaOnnxDestroySpeechSegment(s);SherpaOnnxVoiceActivityDetectorPop(vad);
        }
    };
    for(int i=0;i<sampleCount;i+=512) {
        auto n=std::min(512,sampleCount-i);
        SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad,samples.data()+i,n);drain();
    }
    SherpaOnnxVoiceActivityDetectorFlush(vad);drain();manifest<<"]";manifest.close();
    SherpaOnnxDestroyVoiceActivityDetector(vad);return 0;
}
int main(int argc,char **argv) {
    try {
        if(argc==5 && std::string(argv[1])=="segment")return segment(argv[2],argv[3],argv[4]);
        if(argc!=3)throw std::runtime_error("usage: paraformer-live modelDirectory language OR segment modelDirectory wav outputDirectory");
        const std::string models=argv[1];
        SherpaOnnxOnlineRecognizerConfig config{};
        std::string encoder=models+"/encoder.int8.onnx",decoder=models+"/decoder.int8.onnx",tokens=models+"/tokens.txt";
        config.feat_config.sample_rate=16000;config.feat_config.feature_dim=80;
        config.model_config.paraformer.encoder=encoder.c_str();config.model_config.paraformer.decoder=decoder.c_str();
        config.model_config.tokens=tokens.c_str();config.model_config.num_threads=2;
        config.model_config.provider="cpu";config.model_config.model_type="paraformer";
        config.decoding_method="greedy_search";config.enable_endpoint=0;
        auto *recognizer=SherpaOnnxCreateOnlineRecognizer(&config);
        auto *vad=makeVAD(models+"/silero_vad.onnx");
        if(!recognizer||!vad)throw std::runtime_error("Paraformer或Silero模型加载失败");
        const SherpaOnnxOnlineStream *stream=nullptr;
        std::vector<float> prefix,buffer;uint64_t total=0;double begin=0;std::string last;
        auto decode=[&](bool final) {
            if(!stream)return;
            if(final) {
                std::vector<float> tail(8000,0);SherpaOnnxOnlineStreamAcceptWaveform(stream,16000,tail.data(),int(tail.size()));
                SherpaOnnxOnlineStreamInputFinished(stream);
            }
            while(SherpaOnnxIsOnlineStreamReady(recognizer,stream))SherpaOnnxDecodeOnlineStream(recognizer,stream);
            auto *result=SherpaOnnxGetOnlineStreamResult(recognizer,stream);
            std::string text=result&&result->text?result->text:"";
            if(result)SherpaOnnxDestroyOnlineRecognizerResult(result);
            if(final||text!=last) {if(!text.empty())event(final?"commit":"partial",text,begin,total/16000.0);last=text;}
            if(final){SherpaOnnxDestroyOnlineStream(stream);stream=nullptr;last.clear();prefix.clear();}
        };
        auto frame=[&](const float *p,int n) {
            total+=n;SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad,p,n);
            bool detected=SherpaOnnxVoiceActivityDetectorDetected(vad);
            if(!stream&&detected) {
                stream=SherpaOnnxCreateOnlineStream(recognizer);if(!stream)throw std::runtime_error("创建流失败");
                begin=std::max(0.0,(total-n-prefix.size())/16000.0);
                if(!prefix.empty())SherpaOnnxOnlineStreamAcceptWaveform(stream,16000,prefix.data(),int(prefix.size()));
            }
            if(stream){SherpaOnnxOnlineStreamAcceptWaveform(stream,16000,p,n);decode(false);}
            if(!SherpaOnnxVoiceActivityDetectorEmpty(vad)) {
                decode(true);
                while(!SherpaOnnxVoiceActivityDetectorEmpty(vad))SherpaOnnxVoiceActivityDetectorPop(vad);
            }
            if(!stream){prefix.insert(prefix.end(),p,p+n);if(prefix.size()>8000)prefix.erase(prefix.begin(),prefix.end()-8000);}
        };
        event("ready","Paraformer流式识别与Silero VAD已就绪",0,0);
        while(true) {
            uint32_t count=0;size_t read=fread(&count,1,4,stdin);if(read==0)break;
            if(read!=4||count>64000||count==0)throw std::runtime_error("音频帧头无效");
            std::vector<float> samples(count);if(fread(samples.data(),sizeof(float),count,stdin)!=count)throw std::runtime_error("音频帧不完整");
            for(float value:samples)if(!std::isfinite(value))throw std::runtime_error("音频样本无效");
            buffer.insert(buffer.end(),samples.begin(),samples.end());size_t used=0;
            while(buffer.size()-used>=512){frame(buffer.data()+used,512);used+=512;}
            buffer.erase(buffer.begin(),buffer.begin()+used);
        }
        if(!buffer.empty())frame(buffer.data(),int(buffer.size()));
        SherpaOnnxVoiceActivityDetectorFlush(vad);decode(true);
        SherpaOnnxDestroyVoiceActivityDetector(vad);SherpaOnnxDestroyOnlineRecognizer(recognizer);
        event("done","",0,total/16000.0);return 0;
    } catch(const std::exception &e){event("error",e.what(),0,0);return 1;}
}

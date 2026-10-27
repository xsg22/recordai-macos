#include "whisper.h"
#include <algorithm>
#include <atomic>
#include <cmath>
#include <condition_variable>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

// 连续16 kHz Float32输入；模型只加载一次。Whisper使用滑动窗口，partial会被下一次识别修订。
namespace {
constexpr size_t sample_rate = 16000;
constexpr size_t step = sample_rate;
constexpr size_t window = sample_rate * 12;
constexpr size_t maximum_pending = sample_rate * 15;
std::mutex output_mutex;
std::string escaped(const std::string &text) {
    std::string result;
    for (unsigned char c : text) {
        if (c == '"' || c == '\\') { result += '\\'; result += c; }
        else if (c == '\n') result += "\\n";
        else if (c == '\r') result += "\\r";
        else if (c == '\t') result += "\\t";
        else if (c >= 0x20) result += c;
    }
    return result;
}
void event(const char *type, const std::string &text = "", double start = 0, double end = 0) {
    std::lock_guard<std::mutex> lock(output_mutex);
    std::cout << "{\"type\":\"" << type << "\",\"text\":\"" << escaped(text)
              << "\",\"start\":" << start << ",\"end\":" << end << "}" << std::endl;
}
bool silent(const std::vector<float> &samples, size_t begin) {
    double energy = 0;
    for (size_t i = begin; i < samples.size(); ++i) energy += samples[i] * samples[i];
    return std::sqrt(energy / std::max<size_t>(1, samples.size() - begin)) < 0.006;
}
}

int main(int argc, char **argv) {
    if (argc != 3) { event("error", "实时转录引擎参数不完整"); return 2; }
    const std::string language = argv[2];
    if (language != "auto" && whisper_lang_id(language.c_str()) < 0) {
        event("error", "不支持的实时转录语言"); return 2;
    }
    auto options = whisper_context_default_params();
    options.use_gpu = true;
    options.flash_attn = true;
    auto *context = whisper_init_from_file_with_params(argv[1], options);
    if (!context) { event("error", "无法加载本地实时转录模型"); return 3; }
    event("ready");
    std::mutex mutex;
    std::condition_variable changed;
    std::vector<float> pending;
    bool ended = false;
    std::atomic<bool> failed{false};
    std::thread input([&] {
        while (true) {
            uint32_t count = 0;
            const size_t header = fread(&count, 1, sizeof(count), stdin);
            if (header == 0) break;
            if (header != sizeof(count) || count > sample_rate * 4) { failed = true; break; }
            if (count == 0) break;
            std::vector<float> values(count);
            if (fread(values.data(), sizeof(float), count, stdin) != count) { failed = true; break; }
            if (std::any_of(values.begin(), values.end(), [](float value) { return !std::isfinite(value); })) { failed = true; break; }
            {
                std::lock_guard<std::mutex> lock(mutex);
                if (pending.size() + count > maximum_pending) { failed = true; break; }
                pending.insert(pending.end(), values.begin(), values.end());
            }
            changed.notify_one();
        }
        { std::lock_guard<std::mutex> lock(mutex); ended = true; }
        changed.notify_one();
    });
    size_t decoded_count = 0;
    size_t consumed = 0;
    bool inference_failed = false;
    while (true) {
        std::vector<float> snapshot;
        bool commit = false;
        {
            std::unique_lock<std::mutex> lock(mutex);
            changed.wait(lock, [&] { return ended || pending.size() >= decoded_count + step; });
            if (failed || (ended && pending.empty())) break;
            const size_t count = std::min(pending.size(), window);
            snapshot.assign(pending.begin(), pending.begin() + count);
            commit = (ended && count == pending.size()) || count == window;
        }
        if (snapshot.size() >= step && silent(snapshot, snapshot.size() - sample_rate * 4 / 5)) commit = true;
        const size_t actual_count = snapshot.size();
        std::string text;
        if (!silent(snapshot, 0)) {
            // 尾段不足一秒也补零解码，时间戳仍以真实输入长度为准。
            if (snapshot.size() < sample_rate) snapshot.resize(sample_rate, 0);
            auto params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
            params.n_threads = std::max(2u, std::min(8u, std::thread::hardware_concurrency() / 2));
            params.translate = false;
            params.language = std::string(argv[2]) == "auto" ? nullptr : argv[2];
            params.no_context = true;
            params.single_segment = true;
            params.print_realtime = false;
            params.print_progress = false;
            params.print_timestamps = false;
            params.print_special = false;
            params.suppress_blank = true;
            params.suppress_nst = true;
            params.no_speech_thold = 0.6f;
            if (whisper_full(context, params, snapshot.data(), static_cast<int>(snapshot.size())) != 0) {
                event("error", "本地实时识别失败，完整录音仍会保留"); inference_failed = true; break;
            }
            for (int i = 0; i < whisper_full_n_segments(context); ++i) {
                // 能量阈值只能跳过纯静音；模型判断无语音的背景噪声段同样不应显示成会议内容。
                if (whisper_full_get_segment_no_speech_prob(context, i) < params.no_speech_thold) {
                    text += whisper_full_get_segment_text(context, i);
                }
            }
        }
        event(commit ? "commit" : "partial", text, double(consumed) / sample_rate, double(consumed + actual_count) / sample_rate);
        {
            std::lock_guard<std::mutex> lock(mutex);
            if (commit) {
                pending.erase(pending.begin(), pending.begin() + actual_count);
                consumed += actual_count;
                decoded_count = 0;
            } else decoded_count = actual_count;
        }
    }
    // 推理故障时进程直接退出；不能等待仍持续发送的录音输入线程。
    if (inference_failed) { fflush(stdout); std::_Exit(4); }
    input.join();
    whisper_free(context);
    if (failed) { event("error", "实时音频积压或格式异常，停止预览；完整录音仍可转录"); return 5; }
    event("done");
    return 0;
}

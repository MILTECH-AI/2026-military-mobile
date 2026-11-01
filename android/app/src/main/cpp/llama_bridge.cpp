#include <jni.h>
#include <llama.h>
#include <algorithm>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
struct Session {
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    ~Session() { if (context) llama_free(context); if (model) llama_model_free(model); }
};
std::once_flag initialized;
void fail(JNIEnv * env, const char * message) { env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), message); }
std::string utf8(JNIEnv * env, jstring value) {
    auto cls = env->FindClass("java/lang/String");
    auto bytes = (jbyteArray) env->CallObjectMethod(value, env->GetMethodID(cls, "getBytes", "(Ljava/lang/String;)[B"), env->NewStringUTF("UTF-8"));
    std::string out(env->GetArrayLength(bytes), '\0');
    env->GetByteArrayRegion(bytes, 0, out.size(), reinterpret_cast<jbyte *>(out.data()));
    env->DeleteLocalRef(bytes);
    return out;
}
jstring javaString(JNIEnv * env, const std::string & value) {
    auto bytes = env->NewByteArray(value.size());
    env->SetByteArrayRegion(bytes, 0, value.size(), reinterpret_cast<const jbyte *>(value.data()));
    auto cls = env->FindClass("java/lang/String");
    auto out = (jstring) env->NewObject(cls, env->GetMethodID(cls, "<init>", "([BLjava/lang/String;)V"), bytes, env->NewStringUTF("UTF-8"));
    env->DeleteLocalRef(bytes);
    return out;
}
}

extern "C" JNIEXPORT jlong JNICALL
Java_com_superkid_military_military_1maintenance_LlamaNative_open(JNIEnv * env, jobject, jstring path, jint threads) {
    try {
        std::call_once(initialized, [] { llama_backend_init(); });
        auto owner = std::make_unique<Session>();
        auto modelParams = llama_model_default_params();
        modelParams.n_gpu_layers = 0;
        modelParams.load_mode = LLAMA_LOAD_MODE_MMAP;
        owner->model = llama_model_load_from_file(utf8(env, path).c_str(), modelParams);
        if (!owner->model) throw std::runtime_error("model_load_failed");
        auto params = llama_context_default_params();
        params.n_ctx = 1536;
        params.n_batch = 128;
        params.n_ubatch = 64;
        params.n_threads = params.n_threads_batch = std::max(1, int(threads));
        params.no_perf = true;
        owner->context = llama_init_from_model(owner->model, params);
        if (!owner->context) throw std::runtime_error("context_allocation_failed");
        return reinterpret_cast<jlong>(owner.release());
    } catch (...) { fail(env, "llama_load_failed"); return 0; }
}

extern "C" JNIEXPORT jstring JNICALL
Java_com_superkid_military_military_1maintenance_LlamaNative_generate(JNIEnv * env, jobject, jlong handle, jstring prompt, jstring grammar, jint limit) {
    try {
        auto s = reinterpret_cast<Session *>(handle);
        if (!s || !s->context || limit < 64 || limit > 128) throw std::runtime_error("invalid_request");
        const auto text = utf8(env, prompt);
        if (text.size() > 16000) throw std::runtime_error("prompt_too_large");
        const auto vocab = llama_model_get_vocab(s->model);
        const int required = -llama_tokenize(vocab, text.data(), text.size(), nullptr, 0, true, true);
        if (required <= 0 || required + limit > 1536) throw std::runtime_error("context_limit");
        std::vector<llama_token> tokens(required);
        if (llama_tokenize(vocab, text.data(), text.size(), tokens.data(), tokens.size(), true, true) != required) throw std::runtime_error("tokenize_failed");
        llama_memory_clear(llama_get_memory(s->context), true);
        for (int at = 0; at < required; at += 128) {
            auto batch = llama_batch_get_one(tokens.data() + at, std::min(128, required-at));
            if (llama_decode(s->context, batch)) throw std::runtime_error("prompt_decode_failed");
        }
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(llama_sampler_chain_init(llama_sampler_chain_default_params()), llama_sampler_free);
        auto grammarText = utf8(env, grammar);
        if (grammarText.empty() || grammarText.size() > 12000) throw std::runtime_error("invalid_grammar");
        auto grammarSampler = llama_sampler_init_grammar(vocab, grammarText.c_str(), "root");
        if (!grammarSampler) throw std::runtime_error("grammar_failed");
        llama_sampler_chain_add(sampler.get(), grammarSampler);
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_greedy());
        std::vector<llama_token> generated;
        bool ended = false;
        for (int n = 0; n < limit; n++) {
            auto token = llama_sampler_sample(sampler.get(), s->context, -1);
            if (llama_vocab_is_eog(vocab, token)) { ended = true; break; }
            generated.push_back(token);
            auto batch = llama_batch_get_one(&token, 1);
            if (llama_decode(s->context, batch)) throw std::runtime_error("generate_decode_failed");
        }
        std::vector<char> output(32768);
        int length = llama_detokenize(vocab, generated.data(), generated.size(), output.data(), output.size(), true, false);
        if (length < 0) throw std::runtime_error("output_limit");
        // Prefix metadata on a separate line; Kotlin serializes content as JSON safely.
        return javaString(env, std::to_string(required) + "," + std::to_string(generated.size()) + "," + (ended ? "1\n" : "0\n") + std::string(output.data(), length));
    } catch (...) { fail(env, "llama_generation_failed"); return nullptr; }
}

extern "C" JNIEXPORT void JNICALL
Java_com_superkid_military_military_1maintenance_LlamaNative_close(JNIEnv *, jobject, jlong handle) {
    delete reinterpret_cast<Session *>(handle);
}

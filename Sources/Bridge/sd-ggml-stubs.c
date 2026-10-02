// sd-ggml-stubs.c
//
// stable-diffusion.cpp 用的 ggml（leejet fork）比 llama.cpp 的 ggml 多三个扩展符号，
// 而本工程统一只链 llama.cpp 那份 ggml（两份 ggml 会撞符号），所以这里补空桩。
//
// 运行时安全性（SD1.5 + Q4_0 + 默认参数，钉死）：
//  · ggml_sage_attn            —— CUDA-only，且要显式开 sage_attn 才会走；iOS 上永远关
//  · ggml_mul_mat_i8_tensorwise —— 只给 INT8 tensorwise 量化的模型用
//  · ggml_quantize_i8_convrot   —— 同上（INT8 convrot 路径）
// 三条路都到不了，返回 NULL 的桩永远不会被调到；只是让链接器闭嘴。

typedef struct ggml_context_ ggml_context;
typedef struct ggml_tensor_  ggml_tensor;

void *ggml_sage_attn(void *ctx, void *q, void *k, void *v,
                     float scale, int mode) {
    (void)ctx; (void)q; (void)k; (void)v; (void)scale; (void)mode;
    return (void *)0;
}

void *ggml_mul_mat_i8_tensorwise(void *ctx, void *weight, void *input,
                                 void *weight_scale, void *bias,
                                 int convrot_group_size) {
    (void)ctx; (void)weight; (void)input; (void)weight_scale; (void)bias;
    (void)convrot_group_size;
    return (void *)0;
}

void *ggml_quantize_i8_convrot(void *ctx, void *a, int group_size) {
    (void)ctx; (void)a; (void)group_size;
    return (void *)0;
}

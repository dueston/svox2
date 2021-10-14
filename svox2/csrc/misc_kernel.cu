// Copyright 2021 Alex Yu
#include <torch/extension.h>
#include <cstdint>
#include <cstdio>
#include "cuda_util.cuh"
#include "render_util.cuh"
#include "data_spec_packed.cuh"

namespace {
namespace device {

__device__ __constant__ const float EMPTY_CELL_DATA[] = {
    0.f, 0.f, 0.f, 0.f, 0.f,
    0.f, 0.f, 0.f, 0.f, 0.f,
    0.f, 0.f, 0.f, 0.f, 0.f,
    0.f, 0.f, 0.f, 0.f, 0.f,
    0.f, 0.f, 0.f, 0.f, 0.f,
    0.f, 0.f, 0.f,
};

// Can also implement using convs.....
__global__ void dilate_kernel(
        const torch::PackedTensorAccessor32<bool, 3, torch::RestrictPtrTraits> grid,
        // Output
        torch::PackedTensorAccessor32<bool, 3, torch::RestrictPtrTraits> out_grid) {
    CUDA_GET_THREAD_ID(tid, grid.size(0) * grid.size(1) * grid.size(2));

    const int z = tid % grid.size(2);
    const int xy = tid / grid.size(2);
    const int y = xy % grid.size(1);
    const int x = xy / grid.size(1);

    int xl = max(x - 1, 0), xr = min(x + 1, (int) grid.size(0) - 1);
    int yl = max(y - 1, 0), yr = min(y + 1, (int) grid.size(1) - 1);
    int zl = max(z - 1, 0), zr = min(z + 1, (int) grid.size(2) - 1);

    out_grid[x][y][z] =
        grid[xl][yl][zl] | grid[xl][yl][z] | grid[xl][yl][zr] |
        grid[xl][y][zl] | grid[xl][y][z] | grid[xl][y][zr] |
        grid[xl][yr][zl] | grid[xl][yr][z] | grid[xl][yr][zr] |

        grid[x][yl][zl] | grid[x][yl][z] | grid[x][yl][zr] |
        grid[x][y][zl] | grid[x][y][z] | grid[x][y][zr] |
        grid[x][yr][zl] | grid[x][yr][z] | grid[x][yr][zr] |

        grid[xr][yl][zl] | grid[xr][yl][z] | grid[xr][yl][zr] |
        grid[xr][y][zl] | grid[xr][y][z] | grid[xr][y][zr] |
        grid[xr][yr][zl] | grid[xr][yr][z] | grid[xr][yr][zr];
}

__global__ void tv_kernel(
        torch::PackedTensorAccessor32<int32_t, 3, torch::RestrictPtrTraits> links,
        torch::PackedTensorAccessor64<float, 2, torch::RestrictPtrTraits> data,
        int start_dim, int end_dim,
        int Q,
        // Output
        float* __restrict__ out) {
    CUDA_GET_THREAD_ID(tid, Q);
    __shared__ float result;
    if (threadIdx.x == 0)
        result = 0.f;
    __syncthreads();

    const int z = tid % (links.size(2) - 1);
    const int xy = tid / (links.size(2) - 1);
    const int y = xy % (links.size(1) - 1);
    const int x = xy / (links.size(1) - 1);

    const float* __restrict__ ptr000 = (links[x][y][z] >= 0 ?
                          &data[links[x][y][z]][0] : EMPTY_CELL_DATA);
    const float* __restrict__ ptr100 = (links[x + 1][y][z] >= 0 ?
                          &data[links[x + 1][y][z]][0] : EMPTY_CELL_DATA);
    const float* __restrict__ ptr010 = (links[x][y + 1][z] >= 0 ?
                          &data[links[x][y + 1][z]][0] : EMPTY_CELL_DATA);
    const float* __restrict__ ptr001 = (links[x][y][z + 1] >= 0 ?
                          &data[links[x][y][z + 1]][0] : EMPTY_CELL_DATA);
    float tresult = 0.f;
    for (int i = start_dim; i < end_dim; ++i) {
        const float dx = ptr100[i] - ptr000[i];
        const float dy = ptr010[i] - ptr000[i];
        const float dz = ptr001[i] - ptr000[i];
        tresult += sqrtf(1e-5f + dx * dx + dy * dy + dz * dz);
    }
    atomicAdd(&result, tresult);
    __syncthreads();

    if (threadIdx.x == 0) {
        atomicAdd(out, result / Q);
    }
}

__global__ void tv_grad_kernel(
        const torch::PackedTensorAccessor32<int32_t, 3, torch::RestrictPtrTraits> links,
        const torch::PackedTensorAccessor64<float, 2, torch::RestrictPtrTraits> data,
        int start_dim, int end_dim,
        float scale,
        int Q,
        // Output
        float* __restrict__ grad_data) {
    CUDA_GET_THREAD_ID(tid, Q);
    __shared__ float dummy[28];
    const int z = tid % (links.size(2) - 1);
    const int xy = tid / (links.size(2) - 1);
    const int y = xy % (links.size(1) - 1);
    const int x = xy / (links.size(1) - 1);

    const float* dptr = data.data(), *ptr000 = EMPTY_CELL_DATA,
                                     *ptr100 = EMPTY_CELL_DATA,
                                     *ptr010 = EMPTY_CELL_DATA,
                                     *ptr001 = EMPTY_CELL_DATA;
    const size_t ddim = data.size(1);
    float* gptr000 = dummy,
         * gptr100 = dummy,
         * gptr010 = dummy,
         * gptr001 = dummy;
    bool any_nonempty = false;

    if (links[x][y][z] >= 0) {
        const size_t lnk = links[x][y][z] * ddim;
        ptr000 = dptr + lnk;
        gptr000 = grad_data + lnk;
        any_nonempty = true;
    }
    if (links[x + 1][y][z] >= 0) {
        const size_t lnk = links[x + 1][y][z] * ddim;
        ptr100 = dptr + lnk;
        gptr100 = grad_data + lnk;
        any_nonempty = true;
    }
    if (links[x][y + 1][z] >= 0) {
        const size_t lnk = links[x][y + 1][z] * ddim;
        ptr010 = dptr + lnk;
        gptr010 = grad_data + lnk;
        any_nonempty = true;
    }
    if (links[x][y][z + 1] >= 0) {
        const size_t lnk = links[x][y][z + 1] * ddim;
        ptr001 = dptr + lnk;
        gptr001 = grad_data + lnk;
        any_nonempty = true;
    }
    if (!any_nonempty) return;

    for (int i = start_dim; i < end_dim; ++i) {
        const float val = ptr000[i];
        const float dx = ptr100[i] - val;
        const float dy = ptr010[i] - val;
        const float dz = ptr001[i] - val;
        const float idelta = scale * rsqrtf(1e-5f + dx * dx + dy * dy + dz * dz);
        atomicAdd(gptr000 + i, -(dx + dy + dz) * idelta);
        atomicAdd(gptr100 + i, dx * idelta);
        atomicAdd(gptr010 + i, dy * idelta);
        atomicAdd(gptr001 + i, dz * idelta);
    }
}

__global__ void tv_aniso_grad_kernel(
        torch::PackedTensorAccessor32<int32_t, 3, torch::RestrictPtrTraits> links,
        torch::PackedTensorAccessor64<float, 2, torch::RestrictPtrTraits> data,
        int start_dim, int end_dim,
        float scale,
        int Q,
        // Output
        float* __restrict__ grad_data) {
    CUDA_GET_THREAD_ID(tid, Q);
    const int z = tid % links.size(2);
    const int xy = tid / links.size(2);
    const int y = xy % links.size(1);
    const int x = xy / links.size(1);

    if (links[x][y][z] < 0) return;
    const size_t ddim = data.size(1);
    const size_t lnk = links[x][y][z] * ddim;

    const float* __restrict__ ptr000 = data.data() + lnk;
    float* __restrict__ gptr000 = grad_data + lnk;
    const float* __restrict__ ptrx[6] = {
            ((x < links.size(0) - 1 && links[x + 1][y][z] >= 0 ?
                          &data[links[x + 1][y][z]][0] : EMPTY_CELL_DATA)),
            ((y < links.size(1) - 1 && links[x][y + 1][z] >= 0 ?
                          &data[links[x][y + 1][z]][0] : EMPTY_CELL_DATA)),
            ((z < links.size(2) - 1 && links[x][y][z + 1] >= 0 ?
                          &data[links[x][y][z + 1]][0] : EMPTY_CELL_DATA)),
            ((x > 0 && links[x - 1][y][z] >= 0 ?
                          &data[links[x - 1][y][z]][0] : EMPTY_CELL_DATA)),
            ((y > 0 && links[x][y - 1][z] >= 0 ?
                          &data[links[x][y - 1][z]][0] : EMPTY_CELL_DATA)),
            ((z > 0 && links[x][y][z - 1] >= 0 ?
                          &data[links[x][y][z - 1]][0] : EMPTY_CELL_DATA))
        };
    for (int i = start_dim; i < end_dim; ++i) {
        float cnt = 0.f;
        const float val = ptr000[i];
#pragma unroll 6
        for (int j = 0; j < 6; ++j) {
            cnt += (val > ptrx[j][i]) ? 1.f : (val < ptrx[j][i]) ? -1.f : 0.f;
        }
        gptr000[i] += cnt * scale;
    }
}

__device__ __inline__ void grid_trace_ray(
    const torch::PackedTensorAccessor32<float, 3, torch::RestrictPtrTraits>
        data,
        SingleRaySpec ray,
        const float* __restrict__ offset,
        const float* __restrict__ scaling,
        float step_size,
    torch::PackedTensorAccessor32<float, 3, torch::RestrictPtrTraits>
        grid_weight) {

    // Warning: modifies ray.origin
    transform_coord(ray.origin, scaling, offset);
    // Warning: modifies ray.dir
    const float world_step = _get_delta_scale(scaling, ray.dir) * step_size;

    float t, tmax;
    float invdir[3];

#pragma unroll 3
    for (int i = 0; i < 3; ++i) {
        invdir[i] = 1.0 / ray.dir[i];
        if (ray.dir[i] == 0.f)
            invdir[i] = 1e9f;
    }

    {
        float t1, t2;
        t = 0.0f;
        tmax = 1e9f;
#pragma unroll 3
        for (int i = 0; i < 3; ++i) {
            t1 = (- ray.origin[i]) * invdir[i];
            t2 = (data.size(i) - 1.f  - ray.origin[i]) * invdir[i];
            t = max(t, min(t1, t2));
            tmax = min(tmax, max(t1, t2));
        }
    }

    if (t > tmax) {
        // Ray doesn't hit box
        return;
    }
    float pos[3];
    int32_t l[3];

    float log_light_intensity = 0.f;
    const int stride0 = data.size(1) * data.size(2);
    const int stride1 = data.size(2);
    while (t <= tmax) {
#pragma unroll 3
        for (int j = 0; j < 3; ++j) {
            pos[j] = ray.origin[j] + t * ray.dir[j];
            pos[j] = min(max(pos[j], 0.f), data.size(j) - 1.f);
            l[j] = (int32_t) pos[j];
            l[j] = min(l[j], data.size(j) - 2);
            pos[j] -= l[j];
        }

        float log_att;
        const int idx = l[0] * stride0 + l[1] * stride1 + l[2];

        float sigma;
        {
            // Trilerp
            const float* __restrict__ sigma000 = data.data() + idx;
            const float* __restrict__ sigma100 = sigma000 + stride0;
            const float ix0y0 = lerp(sigma000[0], sigma000[1], pos[2]);
            const float ix0y1 = lerp(sigma000[stride1], sigma000[stride1 + 1], pos[2]);
            const float ix1y0 = lerp(sigma100[0], sigma100[1], pos[2]);
            const float ix1y1 = lerp(sigma100[stride1], sigma100[stride1 + 1], pos[2]);
            const float ix0 = lerp(ix0y0, ix0y1, pos[1]);
            const float ix1 = lerp(ix1y0, ix1y1, pos[1]);
            sigma = lerp(ix0, ix1, pos[0]);
        }

        if (sigma > 1e-4f) {
            log_att = -world_step * sigma;
            const float weight = expf(log_light_intensity) * (1.f - expf(log_att));
            log_light_intensity += log_att;
            float* __restrict__ max_wt_ptr_000 = grid_weight.data() + idx;
            atomicMax(max_wt_ptr_000, weight);
            atomicMax(max_wt_ptr_000 + 1, weight);
            atomicMax(max_wt_ptr_000 + stride1, weight);
            atomicMax(max_wt_ptr_000 + stride1 + 1, weight);
            float* __restrict__ max_wt_ptr_100 = max_wt_ptr_000 + stride0;
            atomicMax(max_wt_ptr_100, weight);
            atomicMax(max_wt_ptr_100 + 1, weight);
            atomicMax(max_wt_ptr_100 + stride1, weight);
            atomicMax(max_wt_ptr_100 + stride1 + 1, weight);
        }
        t += step_size;
    }
}


__global__ void grid_weight_render_kernel(
    const torch::PackedTensorAccessor32<float, 3, torch::RestrictPtrTraits>
        data,
    PackedCameraSpec cam,
    float step_size,
    const float* __restrict__ offset,
    const float* __restrict__ scaling,
    torch::PackedTensorAccessor32<float, 3, torch::RestrictPtrTraits>
        grid_weight) {
    CUDA_GET_THREAD_ID(tid, cam.width * cam.height);
    int iy = tid / cam.width, ix = tid % cam.width;
    float dir[3], origin[3];
    cam2world_ray(ix, iy, dir, origin, cam);
    grid_trace_ray(
        data,
        SingleRaySpec(origin, dir),
        offset,
        scaling,
        step_size,
        grid_weight);
}


}  // namespace device
}  // namespace

torch::Tensor dilate(torch::Tensor grid) {
    DEVICE_GUARD(grid);
    CHECK_INPUT(grid);
    TORCH_CHECK(!grid.is_floating_point());
    TORCH_CHECK(grid.ndimension() == 3);

    int Q = grid.size(0) * grid.size(1) * grid.size(2);

    const int cuda_n_threads = 768;
    const int blocks = CUDA_N_BLOCKS_NEEDED(Q, cuda_n_threads);
    torch::Tensor result = torch::empty_like(grid);
    device::dilate_kernel<<<blocks, cuda_n_threads>>>(
            grid.packed_accessor32<bool, 3, torch::RestrictPtrTraits>(),
            // Output
            result.packed_accessor32<bool, 3, torch::RestrictPtrTraits>());
    return result;
}

torch::Tensor tv(torch::Tensor links, torch::Tensor data,
                 int start_dim, int end_dim) {
    DEVICE_GUARD(data);
    CHECK_INPUT(data);
    CHECK_INPUT(links);
    TORCH_CHECK(data.is_floating_point());
    TORCH_CHECK(!links.is_floating_point());
    TORCH_CHECK(data.ndimension() == 2);
    TORCH_CHECK(links.ndimension() == 3);

    int Q = (links.size(0) - 1) * (links.size(1) - 1) * (links.size(2) - 1);

    const int cuda_n_threads = 1024;
    const int blocks = CUDA_N_BLOCKS_NEEDED(Q, cuda_n_threads);
    torch::Tensor result = torch::zeros({}, data.options());
    device::tv_kernel<<<blocks, cuda_n_threads>>>(
            links.packed_accessor32<int32_t, 3, torch::RestrictPtrTraits>(),
            data.packed_accessor64<float, 2, torch::RestrictPtrTraits>(),
            start_dim,
            end_dim,
            Q,
            // Output
            result.data<float>());
    CUDA_CHECK_ERRORS;
    return result;
}

void tv_grad(torch::Tensor links, torch::Tensor data,
             int start_dim, int end_dim,
             float scale,
             torch::Tensor grad_data) {
    DEVICE_GUARD(data);
    CHECK_INPUT(data);
    CHECK_INPUT(links);
    CHECK_INPUT(grad_data);
    TORCH_CHECK(data.is_floating_point());
    TORCH_CHECK(grad_data.is_floating_point());
    TORCH_CHECK(!links.is_floating_point());
    TORCH_CHECK(data.ndimension() == 2);
    TORCH_CHECK(links.ndimension() == 3);
    TORCH_CHECK(grad_data.ndimension() == 2);

    int Q = (links.size(0) - 1) * (links.size(1) - 1) * (links.size(2) - 1);

    const int cuda_n_threads = 1024;
    const int blocks = CUDA_N_BLOCKS_NEEDED(Q, cuda_n_threads);
    device::tv_grad_kernel<<<blocks, cuda_n_threads>>>(
            links.packed_accessor32<int32_t, 3, torch::RestrictPtrTraits>(),
            data.packed_accessor64<float, 2, torch::RestrictPtrTraits>(),
            start_dim,
            end_dim,
            scale / Q,
            Q,
            // Output
            grad_data.data<float>());
    CUDA_CHECK_ERRORS;
}

void tv_aniso_grad(torch::Tensor links, torch::Tensor data,
             int start_dim, int end_dim,
             float scale,
             torch::Tensor grad_data) {
    DEVICE_GUARD(data);
    CHECK_INPUT(data);
    CHECK_INPUT(links);
    CHECK_INPUT(grad_data);
    TORCH_CHECK(data.is_floating_point());
    TORCH_CHECK(grad_data.is_floating_point());
    TORCH_CHECK(!links.is_floating_point());
    TORCH_CHECK(data.ndimension() == 2);
    TORCH_CHECK(links.ndimension() == 3);
    TORCH_CHECK(grad_data.ndimension() == 2);

    int Q = links.size(0) * links.size(1) * links.size(2);

    const int cuda_n_threads = 1024;
    const int blocks = CUDA_N_BLOCKS_NEEDED(Q, cuda_n_threads);
    device::tv_aniso_grad_kernel<<<blocks, cuda_n_threads>>>(
            links.packed_accessor32<int32_t, 3, torch::RestrictPtrTraits>(),
            data.packed_accessor64<float, 2, torch::RestrictPtrTraits>(),
            start_dim,
            end_dim,
            scale / Q,
            Q,
            // Output
            grad_data.data<float>());
    CUDA_CHECK_ERRORS;
}

void grid_weight_render(
    torch::Tensor data, CameraSpec& cam, float step_size,
    torch::Tensor offset, torch::Tensor scaling,
    torch::Tensor grid_weight_out) {
    DEVICE_GUARD(data);
    CHECK_INPUT(data);
    CHECK_INPUT(offset);
    CHECK_INPUT(scaling);
    CHECK_INPUT(grid_weight_out);
    cam.check();
    const size_t Q = size_t(cam.width) * cam.height;

    const int cuda_n_threads = 512;
    const int blocks = CUDA_N_BLOCKS_NEEDED(Q, cuda_n_threads);

    device::grid_weight_render_kernel<<<blocks, cuda_n_threads>>>(
        data.packed_accessor32<float, 3, torch::RestrictPtrTraits>(),
        cam,
        step_size,
        offset.data<float>(),
        scaling.data<float>(),
        grid_weight_out.packed_accessor32<float, 3, torch::RestrictPtrTraits>());
    CUDA_CHECK_ERRORS;
}


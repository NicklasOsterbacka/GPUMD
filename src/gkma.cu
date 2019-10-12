/*
    Copyright 2017 Zheyong Fan, Ville Vierimaa, Mikko Ervasti, and Ari Harju
    This file is part of GPUMD.
    GPUMD is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.
    GPUMD is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.
    You should have received a copy of the GNU General Public License
    along with GPUMD.  If not, see <http://www.gnu.org/licenses/>.
*/

/*----------------------------------------------------------------------------80
Green-Kubo Modal Analysis (GKMA)
- Currently only supports output of modal heat flux
 -> Green-Kubo integrals must be post-processed

GPUMD Contributing author: Alexander Gabourie (Stanford University)

Some code here and supporting code in 'potential.cu' is based on the LAMMPS
implementation provided by the Henry group at MIT. This code can be found:
https://drive.google.com/open?id=1IHJ7x-bLZISX3I090dW_Y_y-Mqkn07zg
------------------------------------------------------------------------------*/

#include "gkma.cuh"
#include "atom.cuh"
#include <fstream>
#include <string>
#include <iostream>
#include <sstream>

#define BLOCK_SIZE 128
#define ACCUM_BLOCK 1024
#define BIN_BLOCK 128
#define BLOCK_SIZE_FORCE 64
#define BLOCK_SIZE_GK 16


static __global__ void gpu_reset_data
(
        int num_elements, real* data
)
{
    int n = blockIdx.x * blockDim.x + threadIdx.x;
    if (n < num_elements)
    {
        data[n] = ZERO;
    }
}

static __global__ void gpu_average_jm
(
        int num_elements, int samples_per_output, real* jm
)
{
    int n = blockIdx.x * blockDim.x + threadIdx.x;
    if (n < num_elements)
    {
        jm[n]/=(float)samples_per_output;
    }
}

static __global__ void gpu_gkma_reduce
(
        int N, int num_modes,
        const real* __restrict__ data_n,
        real* data
)
{
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    int number_of_patches = (N - 1) / ACCUM_BLOCK + 1;

    __shared__ real s_data_x[ACCUM_BLOCK];
    __shared__ real s_data_y[ACCUM_BLOCK];
    __shared__ real s_data_z[ACCUM_BLOCK];
    s_data_x[tid] = ZERO;
    s_data_y[tid] = ZERO;
    s_data_z[tid] = ZERO;

    for (int patch = 0; patch < number_of_patches; ++patch)
    {
        int n = tid + patch * ACCUM_BLOCK;
        if (n < N)
        {
            s_data_x[tid] += data_n[n + bid*N ];
            s_data_y[tid] += data_n[n + (bid + num_modes)*N];
            s_data_z[tid] += data_n[n + (bid + 2*num_modes)*N];
        }
    }

    __syncthreads();
    #pragma unroll
    for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
    {
        if (tid < offset)
        {
            s_data_x[tid] += s_data_x[tid + offset];
            s_data_y[tid] += s_data_y[tid + offset];
            s_data_z[tid] += s_data_z[tid + offset];
        }
        __syncthreads();
    }
    if (tid == 0)
    {
        data[bid] = s_data_x[0];
        data[bid + num_modes] = s_data_y[0];
        data[bid + 2*num_modes] = s_data_z[0];
    }

}

static __global__ void gpu_calc_xdotn
(
        int N, int N1, int N2, int num_modes,
        const real* __restrict__ g_vx,
        const real* __restrict__ g_vy,
        const real* __restrict__ g_vz,
        const real* __restrict__ g_mass,
        const real* __restrict__ g_eig,
        real* g_xdotn
)
{
    int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1;
    if (n1 >= N1 && n1 < N2)
    {

        real vx1, vy1, vz1;
        vx1 = LDG(g_vx, n1);
        vy1 = LDG(g_vy, n1);
        vz1 = LDG(g_vz, n1);

        real sqrtmass = sqrt(LDG(g_mass, n1));
        for (int i = 0; i < num_modes; i++)
        {
            g_xdotn[n1 + i*N] = sqrtmass*g_eig[n1 + i*3*N]*vx1;
            g_xdotn[n1 + (i + num_modes)*N] =
                    sqrtmass*g_eig[n1 + (1 + i*3)*N]*vy1;
            g_xdotn[n1 + (i + 2*num_modes)*N] =
                    sqrtmass*g_eig[n1 + (2 + i*3)*N]*vz1;
        }
    }
}


static __device__ void gpu_bin_reduce
(
       int num_modes, int bin_size, int shift, int num_bins,
       int tid, int bid, int number_of_patches,
       const real* __restrict__ g_jm,
       real* bin_out
)
{
    __shared__ real s_data_x[BIN_BLOCK];
    __shared__ real s_data_y[BIN_BLOCK];
    __shared__ real s_data_z[BIN_BLOCK];
    s_data_x[tid] = ZERO;
    s_data_y[tid] = ZERO;
    s_data_z[tid] = ZERO;

    for (int patch = 0; patch < number_of_patches; ++patch)
    {
        int n = tid + patch * BIN_BLOCK;
        if (n < bin_size)
        {
            s_data_x[tid] += g_jm[n + shift];
            s_data_y[tid] += g_jm[n + shift + num_modes];
            s_data_z[tid] += g_jm[n + shift + 2*num_modes];
        }
    }

    __syncthreads();
    #pragma unroll
    for (int offset = blockDim.x >> 1; offset > 0; offset >>= 1)
    {
        if (tid < offset)
        {
            s_data_x[tid] += s_data_x[tid + offset];
            s_data_y[tid] += s_data_y[tid + offset];
            s_data_z[tid] += s_data_z[tid + offset];
        }
        __syncthreads();
    }
    if (tid == 0)
    {
        bin_out[bid] = s_data_x[0];
        bin_out[bid + num_bins] = s_data_y[0];
        bin_out[bid + 2*num_bins] = s_data_z[0];
    }
}

static __global__ void gpu_bin_modes
(
       int num_modes, int bin_size, int num_bins,
       const real* __restrict__ g_jm,
       real* bin_out
)
{
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    int number_of_patches = (bin_size - 1) / BIN_BLOCK + 1;
    int shift = bid*bin_size;

    gpu_bin_reduce
    (
           num_modes, bin_size, shift, num_bins,
           tid, bid, number_of_patches, g_jm, bin_out
    );

}

static __global__ void gpu_bin_frequencies
(
       int num_modes,
       const int* __restrict__ bin_count,
       const int* __restrict__ bin_sum,
       int num_bins,
       const real* __restrict__ g_jm,
       real* bin_out
)
{
    int tid = threadIdx.x;
    int bid = blockIdx.x;
    int bin_size = bin_count[bid];
    int shift = bin_sum[bid];
    int number_of_patches = (bin_size - 1) / BIN_BLOCK + 1;

    gpu_bin_reduce
    (
           num_modes, bin_size, shift, num_bins,
           tid, bid, number_of_patches, g_jm, bin_out
    );

}

static __global__ void gpu_find_gkma_jmn
(
    int N, int N1, int N2,
    int triclinic, int pbc_x, int pbc_y, int pbc_z,
    int *g_neighbor_number, int *g_neighbor_list,
    const real* __restrict__ g_f12x,
    const real* __restrict__ g_f12y,
    const real* __restrict__ g_f12z,
    const real* __restrict__ g_x,
    const real* __restrict__ g_y,
    const real* __restrict__ g_z,
    const real* __restrict__ g_vx,
    const real* __restrict__ g_vy,
    const real* __restrict__ g_vz,
    const real* __restrict__ g_box,
    real *g_fx, real *g_fy, real *g_fz,
    const real* __restrict__ g_mass,
    const real* __restrict__ g_eig,
    const real* __restrict__ g_xdot,
    real* g_jmn,
    int num_modes
)
{
    int n1 = blockIdx.x * blockDim.x + threadIdx.x + N1;
    int nm = blockIdx.y * blockDim.y + threadIdx.y;

    if (n1 >= N1 && n1 < N2 && nm < num_modes)
    {
        int neighbor_number = g_neighbor_number[n1];
        real x1 = LDG(g_x, n1); real y1 = LDG(g_y, n1); real z1 = LDG(g_z, n1);
        real vx_gk, vy_gk, vz_gk, j_common;
        real rsqrtmass = rsqrt(LDG(g_mass, n1));

        vx_gk=rsqrtmass*g_eig[n1 + nm*3*N]*g_xdot[nm];
        vy_gk=rsqrtmass*g_eig[n1 + (1 + nm*3)*N]*g_xdot[nm + num_modes];
        vz_gk=rsqrtmass*g_eig[n1 + (2 + nm*3)*N]*g_xdot[nm + 2*num_modes];

        for (int i1 = 0; i1 < neighbor_number; ++i1)
        {
            int index = i1 * N + n1;
            int n2 = g_neighbor_list[index];
            int neighbor_number_2 = g_neighbor_number[n2];

            real x12  = LDG(g_x, n2) - x1;
            real y12  = LDG(g_y, n2) - y1;
            real z12  = LDG(g_z, n2) - z1;
            dev_apply_mic(triclinic, pbc_x, pbc_y, pbc_z, g_box, x12, y12, z12);

            int offset = 0;
            for (int k = 0; k < neighbor_number_2; ++k)
            {
                if (n1 == g_neighbor_list[n2 + N * k])
                { offset = k; break; }
            }
            index = offset * N + n2;
            real f21x = LDG(g_f12x, index);
            real f21y = LDG(g_f12y, index);
            real f21z = LDG(g_f12z, index);

            j_common = (f21x*vx_gk + f21y*vy_gk + f21z*vz_gk);

            g_jmn[n1 + nm*N] += j_common*x12; // x-all
            g_jmn[n1 + (nm+num_modes)*N] += j_common*y12; // y-all
            g_jmn[n1 + (nm+2*num_modes)*N] += j_common*z12; // z-all
        }
    }
}

void GKMA::compute_gkma_heat
(
        Atom *atom, int* NN, int* NL,
        real* f12x, real* f12y, real* f12z, int grid_size, int N1, int N2
)
{
    dim3 grid, block;
    int gk_grid_size = (num_modes - 1)/BLOCK_SIZE_GK + 1;
    block.x = BLOCK_SIZE_FORCE; grid.x = grid_size;
    block.y = BLOCK_SIZE_GK;    grid.y = gk_grid_size;
    block.z = 1;                grid.z = 1;
    gpu_calc_xdotn<<<grid_size, BLOCK_SIZE_FORCE>>>
    (
        atom->N, N1, N2, num_modes,
        atom->vx, atom->vy, atom->vz,
        atom->mass, eig, xdotn
    );
    CUDA_CHECK_KERNEL

    gpu_gkma_reduce<<<num_modes, ACCUM_BLOCK>>>
    (
        atom->N, num_modes, xdotn, xdot
    );
    CUDA_CHECK_KERNEL


    gpu_find_gkma_jmn<<<grid, block>>>
    (
        atom->N, N1, N2, atom->box.triclinic,
        atom->box.pbc_x, atom->box.pbc_y, atom->box.pbc_z, NN, NL,
        f12x, f12y, f12z, atom->x, atom->y, atom->z, atom->vx,
        atom->vy, atom->vz, atom->box.h, atom->fx, atom->fy, atom->fz,
        atom->mass, eig, xdot, jmn, num_modes
    );
    CUDA_CHECK_KERNEL
}


void GKMA::preprocess(char *input_dir, Atom *atom)
{
    if (!compute) return;
    num_modes = last_mode-first_mode+1;
    samples_per_output = output_interval/sample_interval;

    strcpy(gkma_file_position, input_dir);
    strcat(gkma_file_position, "/heatmode.out");

    int N = atom->N;
    MY_MALLOC(cpu_eig, real, N * num_modes * 3);
    CHECK(cudaMalloc(&eig, sizeof(real) * N * num_modes * 3));

    // initialize eigenvector data structures
    strcpy(eig_file_position, input_dir);
    strcat(eig_file_position, "/eigenvector.out");
    std::ifstream eigfile;
    eigfile.open(eig_file_position);
    if (!eigfile)
    {
        print_error("Cannot open eigenvector.out file.\n");
    }

    // GPU phonon code output format
    std::string val;
    double doubleval;

    // Setup binning
    if (f_flag)
    {
        real *cpu_f;
        MY_MALLOC(cpu_f, real, num_modes);
        getline(eigfile, val);
        std::stringstream ss(val);
        for (int i=0; i<first_mode-1; i++) { ss >> cpu_f[0]; }
        real temp;
        for (int i=0; i<num_modes; i++)
        {
            ss >> temp;
            cpu_f[i] = copysign(sqrt(abs(temp))/(2.0*PI), temp);
        }
        real fmax, fmin; // freq are in ascending order in file
        int shift;
        fmax = (floor(abs(cpu_f[num_modes-1])/f_bin_size)+1)*f_bin_size;
        fmin = floor(abs(cpu_f[0])/f_bin_size)*f_bin_size;
        shift = floor(abs(fmin)/f_bin_size);
        num_bins = floor((fmax-fmin)/f_bin_size);

        int *cpu_bin_count;
        ZEROS(cpu_bin_count, int, num_bins);

        for (int i = 0; i< num_modes; i++)
        {
            cpu_bin_count[int(abs(cpu_f[i]/f_bin_size))-shift]++;
        }
        int *cpu_bin_sum;
        ZEROS(cpu_bin_sum, int, num_bins);
        for (int i = 1; i < num_bins; i++)
        {
            cpu_bin_sum[i] = cpu_bin_sum[i-1] + cpu_bin_count[i-1];
        }

        CHECK(cudaMalloc(&bin_count, sizeof(int) * num_bins));
        CHECK(cudaMemcpy(bin_count, cpu_bin_count, sizeof(int) * num_bins,
                cudaMemcpyHostToDevice));

        CHECK(cudaMalloc(&bin_sum, sizeof(int) * num_bins));
        CHECK(cudaMemcpy(bin_sum, cpu_bin_sum, sizeof(int) * num_bins,
                cudaMemcpyHostToDevice));

        MY_FREE(cpu_f);
        MY_FREE(cpu_bin_count);
        MY_FREE(cpu_bin_sum);
    }
    else
    {
        num_bins = num_modes/bin_size;
        getline(eigfile,val);
    }

    // skips modes up to first_mode
    for (int i=1; i<first_mode; i++) { getline(eigfile,val); }
    for (int j=0; j<num_modes; j++) //modes
    {
        for (int i=0; i<3*N; i++) // xyz of eigvec
        {
            eigfile >> doubleval;
            cpu_eig[i + 3*N*j] = doubleval;
        }
    }
    eigfile.close();

    CHECK(cudaMemcpy(eig, cpu_eig, sizeof(real) * N * num_modes * 3,
                            cudaMemcpyHostToDevice));
    MY_FREE(cpu_eig);

    // Allocate modal variables
    MY_MALLOC(cpu_jm, real, num_modes * 3) //cpu
    MY_MALLOC(cpu_bin_out, real, num_bins*3);
    CHECK(cudaMalloc(&xdot, sizeof(real) * num_modes * 3));
    CHECK(cudaMalloc(&jm, sizeof(real) * num_modes * 3));
    CHECK(cudaMalloc(&xdotn, sizeof(real) * num_modes * 3 * N));
    CHECK(cudaMalloc(&jmn, sizeof(real) * num_modes * 3 * N));
    CHECK(cudaMalloc(&bin_out, sizeof(real) * num_bins * 3))

    int num_elements = num_modes*3;
    gpu_reset_data<<<(num_elements-1)/BLOCK_SIZE+1, BLOCK_SIZE>>>
    (
            num_elements, jm
    );
    CUDA_CHECK_KERNEL

    gpu_reset_data<<<(num_elements*N-1)/BLOCK_SIZE+1, BLOCK_SIZE>>>
    (
            num_elements*N, jmn
    );
    CUDA_CHECK_KERNEL

    gpu_reset_data<<<(num_bins * 3 - 1)/BLOCK_SIZE+1, BLOCK_SIZE>>>
    (
            num_bins*3, bin_out
    );

}


void GKMA::process(int step, Atom *atom)
{
    if (!compute) return;
    if (!((step+1) % output_interval == 0)) return;

    int N = atom->N;
    gpu_gkma_reduce<<<num_modes, ACCUM_BLOCK>>>
    (
            N, num_modes, jmn, jm
    );
    CUDA_CHECK_KERNEL


    int num_elements = num_modes*3;
    gpu_average_jm<<<(num_elements-1)/BLOCK_SIZE+1, BLOCK_SIZE>>>
    (
            num_elements, samples_per_output, jm
    );
    CUDA_CHECK_KERNEL

    if (f_flag)
    {
        gpu_bin_frequencies<<<num_bins, BIN_BLOCK>>>
        (
               num_modes, bin_count, bin_sum, num_bins,
               jm, bin_out
        );
        CUDA_CHECK_KERNEL
    }
    else
    {
        gpu_bin_modes<<<num_bins, BIN_BLOCK>>>
        (
               num_modes, bin_size, num_bins,
               jm, bin_out
        );
        CUDA_CHECK_KERNEL
    }


    CHECK(cudaMemcpy(cpu_bin_out, bin_out, sizeof(real) * num_bins * 3,
            cudaMemcpyDeviceToHost));

    FILE *fid = fopen(gkma_file_position, "a");
    for (int i = 0; i < num_bins; i++)
    {
        fprintf(fid, "%25.15e %25.15e %25.15e\n",
         cpu_bin_out[i], cpu_bin_out[i+num_bins], cpu_bin_out[i+2*num_bins]);
    }
    fflush(fid);
    fclose(fid);

    gpu_reset_data<<<(num_elements*N-1)/BLOCK_SIZE+1, BLOCK_SIZE>>>
    (
            num_elements*N, jmn
    );
    CUDA_CHECK_KERNEL

}

void GKMA::postprocess()
{
    if (!compute) return;
    CHECK(cudaFree(eig));
    CHECK(cudaFree(xdot));
    CHECK(cudaFree(xdotn));
    CHECK(cudaFree(jm));
    CHECK(cudaFree(jmn));
    CHECK(cudaFree(bin_out));
    MY_FREE(cpu_jm);
    MY_FREE(cpu_bin_out);
    if (f_flag)
    {
        CHECK(cudaFree(bin_count));
        CHECK(cudaFree(bin_sum));
    }
}



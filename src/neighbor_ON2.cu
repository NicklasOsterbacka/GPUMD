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
Construct the neighbor list using the O(N^2) method.
------------------------------------------------------------------------------*/




#include "atom.cuh"
#include "error.cuh"
#include "ldg.cuh"

#define BLOCK_SIZE 128




// a simple O(N^2) version of neighbor list construction
static __global__ void gpu_find_neighbor_ON2
(
    int pbc_x, int pbc_y, int pbc_z,
    int N, real cutoff_square, 
    real *box,
    int *NN, int *NL, real *x, real *y, real *z
)
{
    //<<<(N - 1) / BLOCK_SIZE + 1, BLOCK_SIZE>>>
    int n1 = blockIdx.x * blockDim.x + threadIdx.x;
    int count = 0;
    if (n1 < N)
    {  
        real x1 = x[n1];   
        real y1 = y[n1];
        real z1 = z[n1];  
        for (int n2 = 0; n2 < N; ++n2)
        { 
            if (n2 == n1) { continue; }
            real x12  = x[n2] - x1;  
            real y12  = y[n2] - y1;
            real z12  = z[n2] - z1;

            dev_apply_mic
            (pbc_x, pbc_y, pbc_z, x12, y12, z12, box[0], box[1], box[2]);

            real distance_square = x12 * x12 + y12 * y12 + z12 * z12;
            if (distance_square < cutoff_square)
            {        
                NL[count * N + n1] = n2;
                ++count;
            }
        }
        NN[n1] = count;
    }
}




// a driver function
void Atom::find_neighbor_ON2(void)
{
    int grid_size = (N - 1) / BLOCK_SIZE + 1; 
    real rc = neighbor.rc;
    real rc2 = rc * rc; 
    real *box = box_length;

    // Find neighbours
    gpu_find_neighbor_ON2<<<grid_size, BLOCK_SIZE>>>
    (pbc_x, pbc_y, pbc_z, N, rc2, box, NN, NL, x, y, z);
    CUDA_CHECK_KERNEL
}




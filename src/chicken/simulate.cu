// simulate.cu
// Include file for chicken, high-level simulation functions.
//
// PJ 2022-09-09

#ifndef SIMULATE_INCLUDED
#define SIMULATE_INCLUDED

#include <cmath>
#include <cstdio>
#include <stdlib.h>
#include <vector>
#include <iostream>
#include <string>
#include <filesystem>
#include <limits>

#include "number.cu"
#include "vector3.cu"
#include "gas.cu"
#include "flow.cu"
#include "vertex.cu"
#include "face.cu"
#include "flux.cu"
#include "cell.cu"
#include "block.cu"
#include "config.cu"

using namespace std;

struct SimState {
    number dt;
    int step;
    int max_step;
    number t_final;
    number dt_plot;
};

vector<Block*> fluidBlocks;

void do_something(); // left over from the CUDA workshop experiment [TODO] remove

__host__
void initialize_simulation(int tindx_start)
{
    char nameBuf[256];
    filesystem::path pth{Config::job};
    if (!filesystem::exists(pth) || !filesystem::is_directory(pth)) {
        throw runtime_error("Job directory is not present in current directory.");
    }
    read_config_file(Config::job + "/config.json");
    // Read initial grids and flow data
    for (int k=0; k < Config::nkb; ++k) {
        for (int j=0; j < Config::njb; ++j) {
            for (int i=0; i < Config::nib; ++i) {
                if (Config::blk_ids[i][j][k] >= 0) {
                    // Only defined blocks in the array will have a non-zero id.
                    Block* blk_ptr = new Block{};
                    int blk_id = Config::blk_ids[i][j][k];
                    blk_ptr->configure(Config::nics[i], Config::njcs[j], Config::nkcs[k]);
                    sprintf(nameBuf, "/grid/grid-%04d-%04d-%04d.gz", i, j, k);
                    string fileName = Config::job + string(nameBuf);
                    blk_ptr->readGrid(fileName);
                    sprintf(nameBuf, "/flow/t%04d/flow-%04d-%04d-%04d.zip", tindx_start, i, j, k);
                    fileName = Config::job + string(nameBuf);
                    blk_ptr->readFlow(fileName);
                    blk_ptr->computeGeometry();
                    blk_ptr->encodeConserved(0);
                    cout << "Sample cell data: " << blk_ptr->cells[blk_ptr->activeCellIndex(0,0,0)].toString() << endl;
                    cout << "Sample iFace data: " << blk_ptr->iFaces[blk_ptr->iFaceIndex(0,0,0)].toString() << endl;
                    cout << "Sample jFace data: " << blk_ptr->jFaces[blk_ptr->jFaceIndex(0,0,0)].toString() << endl;
                    cout << "Sample kFace data: " << blk_ptr->kFaces[blk_ptr->kFaceIndex(0,0,0)].toString() << endl;
                    fluidBlocks.push_back(blk_ptr);
                    if (blk_id+1 != fluidBlocks.size()) {
                        throw runtime_error("Inconsistent blk_id and position in fluidBlocks array.");
                    }
                }
            }
        }
    }
    if (fluidBlocks.size() != Config::nFluidBlocks) {
        throw runtime_error("Inconsistent number of blocks: "+
                            to_string(fluidBlocks.size())+" "+to_string(Config::nFluidBlocks));
    }
    do_something(); // Left over from GPU bootcamp exercise. [TODO] remove it
    return;
} // initialize_simulation()

__host__
void write_flow_data(int tindx)
{
    char nameBuf[256];
    sprintf(nameBuf, "%s/flow/t%04d", Config::job.c_str(), tindx);
    string flowDir = string(nameBuf);
    if (!filesystem::exists(flowDir)) { filesystem::create_directories(flowDir); }
    for (int k=0; k < Config::nkb; ++k) {
        for (int j=0; j < Config::njb; ++j) {
            for (int i=0; i < Config::nib; ++i) {
                if (Config::blk_ids[i][j][k] >= 0) {
                    // Only defined blocks in the array will have a non-zero id.
                    int blk_id = Config::blk_ids[i][j][k];
                    Block* blk_ptr = fluidBlocks[blk_id];
                    sprintf(nameBuf, "%s/flow-%04d-%04d-%04d.zip", flowDir.c_str(), i, j, k);
                    string fileName = string(nameBuf);
                    blk_ptr->writeFlow(fileName);
                }
            }
        }
    }
    return;
} // end write_flow_data()

// Repetitive boundary condition code is hidden here.
#include "bcs.cu"

__host__
void apply_boundary_conditions()
// Since the boundary-condition code needs a view of all blocks and
// most of the coperations are switching between code to copy specific data,
// we expect the CPU to apply the boundary conditions more effectively than the GPU.
// Measurements might tell us otherwise.
{
    for (int iblk=0; iblk < Config::nFluidBlocks; iblk++) {
        auto* blk_config = &(Config::blk_configs[iblk]);
        auto* blk_ptr = fluidBlocks[iblk];
        for (int ibc=0; ibc < 6; ibc++) {
            switch (blk_config->bcCodes[ibc]) {
            case BCCode::wall_with_slip: bc_wall_with_slip(blk_ptr, ibc); break;
            case BCCode::wall_no_slip: bc_wall_no_slip(blk_ptr, ibc); break;
            case BCCode::exchange: bc_exchange(iblk, ibc); break;
            case BCCode::inflow: bc_inflow(blk_ptr, ibc, Config::flow_states[blk_config->bc_fs[ibc]]); break;
            case BCCode::outflow: bc_outflow(blk_ptr, ibc); break;
            default:
                throw runtime_error("Invalid bcCode: "+to_string(blk_config->bcCodes[ibc]));
            }
        } // end for ibc
    } // end for iblk
} // end apply_boundary_conditions()

__host__
void gasdynamic_update(number dt)
{
    apply_boundary_conditions();
    // update_stage_1 for all blocks
    //
} // end gasdynamic_update()

__host__
void march_in_time()
{
    // Occasionally determine allowable time step.
    number dt = 1.0e-6; // [TODO] get from config
    for (auto* blk_ptr : fluidBlocks) {
        dt = fmin(dt, blk_ptr->estimate_allowed_dt(0.5));
    }
    gasdynamic_update(dt);
    // Call gasdynamic_update an number of times.
    for (auto* blk_ptr : fluidBlocks) {
        int bad_cell = blk_ptr->decodeConserved(0);
    }
    return;
}

__host__
void finalize_simulation()
{
    // Exercise the writing of flow data, even we have done no calculations.
    write_flow_data(1);
    return;
}

//---------------------------------------------------------------------------
//
// Bits left over from the CUDA workshop experiment.
// Initial hack adapts the vector addition example from the CUDA workshop
// to look a bit closer to our Puffin CFD code.
//
void host_process(vector<FlowState>& fss)
{
    for (auto& fs : fss) {
        auto& gas = fs.gas;
        auto& vel = fs.vel;
        number v2 = vel.x*vel.x + vel.y*vel.y + vel.z*vel.z;
        number v = sqrt(v2);
        number M = v/gas.a;
        number g = GasModel::g;
        number t1 = 1.0f + 0.5f*(g-1.0)*M*M;
        // Compute stagnation condition.
        number p_total = gas.p * pow(t1, (g/(g-1.0)));
        number T_total = gas.T * t1;
        gas.p = p_total;
        gas.T = T_total;
        gas.update_from_pT();
        vel = {0.0, 0.0, 0.0};
    }
    cout << "inside host_process: fss[0]= " << fss[0].toString() << endl;
}

__global__ void device_process(FlowState* fss, int N)
{
    int idx = blockIdx.x*blockDim.x + threadIdx.x;
    //
    if (idx < N) {
        auto& fs = fss[idx];
        auto gas = fs.gas;
        auto vel = fs.vel;
        number v2 = vel.x*vel.x + vel.y*vel.y + vel.z*vel.z;
        number v = sqrt(v2);
        number M = v/gas.a;
        number g = GasModel::g;
        number t1 = 1.0f + 0.5f*(g-1.0f)*M*M;
        // Compute stagnation condition.
        number p_total = gas.p * pow(t1, (g/(g-1.0f)));
        number T_total = gas.T * t1;
        gas.p = p_total;
        gas.T = T_total;
        gas.update_from_pT();
        vel = {0.0f, 0.0f, 0.0f};
        fs.gas = gas;
        fs.vel = vel;
    }
}

void print_sample(vector<FlowState> fss)
{
    for (int idx=0; idx < 3; idx++) {
        auto& fs = fss[idx];
        cout << "fs= " << fs.toString() << endl;
    }
    cout << "..." << endl;
    int N = fss.size();
    for (int idx=N-3; idx < N; idx++) {
        auto& fs = fss[idx];
        cout << "fs=" << fs.toString() << endl;
    }
}

void do_something()
{
    // Host data is in a standard C++ vector.
    vector<FlowState> fss_h;
    const int N = 32*512;
    for (int idx=0; idx < N; idx++) {
        auto gas = GasState{0.0, 0.0, 100.0e3, 300.0, 0.0};
        gas.update_from_pT();
        auto vel = Vector3{1000.0, 99.0, 0.0};
        fss_h.push_back(FlowState{gas, vel});
    }
    #ifdef CUDA
    if (!filesystem::exists(filesystem::status("/proc/driver/nvidia"))) {
        throw runtime_error("Cannot find NVIDIA driver in /proc/driver.");
    }
    int nDevices;
    cudaGetDeviceCount(&nDevices);
    cout << "Found " << nDevices << " CUDA devices." << endl;
    if (nDevices > 0) {
        cout << "We have a CUDA device, so use it." << endl;
        // Pointer to device arrays.
        FlowState* fss_d;
        int sze = N * sizeof(FlowState);
        cudaMalloc(&fss_d, sze);
        cudaMemcpy(fss_d, fss_h.data(), sze, cudaMemcpyHostToDevice);
        //
        const int threads_per_block = 128;
        const int nblocks = N/threads_per_block;
        device_process<<<nblocks,threads_per_block>>>(fss_d, N);
        cout << cudaGetErrorString(cudaGetLastError()) << endl;
        //
        cudaMemcpy(fss_h.data(), fss_d, sze, cudaMemcpyDeviceToHost);
        cudaFree(fss_d);
    } else {
        cout << "Fall back to CPU-only processing." << endl;
        host_process(fss_h);
    }
    #else
    host_process(fss_h);
    #endif
    print_sample(fss_h);
    fss_h.resize(0);
    return;
}

#endif

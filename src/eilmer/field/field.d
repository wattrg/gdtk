/**
 * field.d
 * Machinery for solving electromagnetic fields through the fluid domain
 *
 * Author: Nick Gibbons
 * Version: 2021-01-20: Prototyping
 */

module field;

import std.conv;
import std.algorithm;
import std.format;
import std.stdio;
import std.math;
import nm.complex;
import nm.number;

import fvcell;
import fvinterface;
import fluidblock;
import geom;
import globalconfig;
import fieldbc;
import fieldgmres;
import fieldconductivity;
import fieldexchange;
import fieldderivatives;

class ElectricField {
    this(const FluidBlock[] localFluidBlocks, const string field_conductivity_model) {
        writeln("Initialising Electric Field Solver...");
        N = 0;
        foreach(block; localFluidBlocks){
            block_offsets ~= N;
            N += to!int(block.cells.length);
        }
        A.length = N*nbands;
        Ai.length = N*nbands;
        b.length = N;
        max_iter = N; // eventually you need to do something about this.
        phi.length = N;
        phi0.length = N;
        auto gmodel = GlobalConfig.gmodel_master;
        conductivity = create_conductivity_model(field_conductivity_model, gmodel);

        // I don't want random bits of the field module hanging off the boundary conditions.
        // Doing it this way is bad encapsulation, but it makes sure that other people only break my code
        // rather than the other way around.
        field_bcs.length = localFluidBlocks.length;
        foreach(i, block; localFluidBlocks){
            field_bcs[i].length = block.bc.length;
            foreach(j, bc; block.bc){
                field_bcs[i][j] = create_field_bc(bc.field_bc, bc, block_offsets, field_conductivity_model, N);
            }
        }

        version(mpi_parallel){
            exchanger = new Exchanger(GlobalConfig.mpi_rank_for_local_task, GlobalConfig.mpi_size, MPISharedField.instances);
            gmres = new GMResFieldSolver(exchanger);
        } else {
            gmres = new GMResFieldSolver();
        }

        writeln("    Done.");
        return;
    }

    void solve_efield(FluidBlock[] localFluidBlocks) {
        A[] = 0.0;
        b[] = 0.0;
        Ai[] = -1;

        FVCell other;
        foreach(blkid, block; localFluidBlocks){
            auto gmodel = block.myConfig.gmodel;
            foreach(cell; block.cells){

                // Set up the sparse matrix indexes. This actually only needs to be done once, technically
                int k = cell.id + block_offsets[blkid];
                Ai[nbands*k + 2] = k;

                // We need the distances to the unknown phi locations, which may be faces or cells
                double[4] dx, dy, phi; // TODO: phi is just for testing purposes
                foreach(io, face; cell.iface){
                    Vector3 pos;
                    if (face.is_on_boundary) {
                        pos = face.pos;
                    } else {
                        other = face.left_cell;
                        if (other==cell) other = face.right_cell;
                        pos = other.pos[0];
                        // FIXME: This will fail in multi-block mode, we need the boundary conditions brought into play here
                        int iio = (io>1) ? to!int(io+1) : to!int(io); // -> [0,1,3,4] since 2 is the entry for "cell"
                        Ai[k*nbands + iio] = other.id + block_offsets[blkid];
                    }
                    dx[io] = pos.x.re - cell.pos[0].x.re;
                    dy[io] = pos.y.re - cell.pos[0].y.re;
                    phi[io] = exp(pos.x.re)*sin(pos.y.re);
                }
                double phii = exp(cell.pos[0].x.re)*sin(cell.pos[0].y.re);

                // TODO: Use Face enums?
                //double dxN = fmax(dx[0], 1e-12); double dyN = dy[0];
                double dxN = dx[0]; double dyN = dy[0];
                double dxE = dx[1]; double dyE = dy[1];
                double dxS = dx[2]; double dyS = dy[2];
                double dxW = dx[3]; double dyW = dy[3];

                double D = denominator(dxN, dxS, dxE, dxW, dyN, dyS, dyE, dyW);

                double[4] fdx, fdy, fdxx, fdxy;
                fdx[0] = mixin(Nx);
                fdx[1] = mixin(Ex);
                fdx[2] = mixin(Sx);
                fdx[3] = mixin(Wx);
                double _Ix    = mixin(Ix);

                fdy[0] = mixin(Ny);
                fdy[1] = mixin(Ey);
                fdy[2] = mixin(Sy);
                fdy[3] = mixin(Wy);
                double _Iy    = mixin(Iy);

                fdxx[0] = mixin(Nxx);
                fdxx[1] = mixin(Exx);
                fdxx[2] = mixin(Sxx);
                fdxx[3] = mixin(Wxx);
                double _Ixx    = mixin(Ixx);

                fdxy[0] = mixin(Nxy);
                fdxy[1] = mixin(Exy);
                fdxy[2] = mixin(Sxy);
                fdxy[3] = mixin(Wxy);
                double _Ixy    = mixin(Ixy);

                foreach(io, face; cell.iface){
                    face.fs.gas.sigma = conductivity(face.fs.gas, face.pos, gmodel); // TODO: Redundant work.
                    double sign = cell.outsign[io];
                    double S = face.length.re;
                    double sigmaF = face.fs.gas.sigma.re;
                    double dxF = face.pos.x.re - cell.pos[0].x.re;
                    double dyF = face.pos.y.re - cell.pos[0].y.re;
                    double nx = sign*face.n.x;
                    double ny = sign*face.n.y;
                    double dphidx_face_target = exp(face.pos.x)*sin(face.pos.y);
                    double dphidy_face_target = exp(face.pos.x)*cos(face.pos.y);

                    double dphidx_face = (_Ix + _Ixx*dxF + _Ixy*dyF)*phii;
                    double dphidy_face = (_Iy + _Ixy*dxF - _Ixx*dyF)*phii;

                    // cell k's contribution to the flux:
                    A[k*nbands + 2] +=  S/D*sigmaF*(nx*(_Ix + _Ixx*dxF + _Ixy*dyF) + ny*(_Iy + _Ixy*dxF - _Ixx*dyF));
                    // What about when iface is a boundary? At this stage it doesn't matter

                    // Each jface makes a contribution to the flux through "face"
                    foreach(jo, jface; cell.iface){
                        if (jface.is_on_boundary) {
                            auto field_bc = cast(FixedField_Test) field_bcs[blkid][jface.bc_id];
                            assert(field_bc !is null, "Oops, this should be a FixedField_Test object.");
                            // Note that we could set dphi_f manually
                            double phif = field_bc.test_field(jface.pos.x.re, jface.pos.y.re);
                            b[k] -= S/D*sigmaF*(nx*(fdx[jo] + fdxx[jo]*dxF + fdxy[jo]*dyF)
                                            + ny*(fdy[jo] + fdxy[jo]*dxF - fdxx[jo]*dyF))*phif;

                            dphidx_face += (fdx[jo] + fdxx[jo]*dxF + fdxy[jo]*dyF)*phif;
                            dphidy_face += (fdy[jo] + fdxy[jo]*dxF - fdxx[jo]*dyF)*phif;
                        } else {
                            dphidx_face += (fdx[jo] + fdxx[jo]*dxF + fdxy[jo]*dyF)*phi[jo];
                            dphidy_face += (fdy[jo] + fdxy[jo]*dxF - fdxx[jo]*dyF)*phi[jo];

                            int jjo = (jo>1) ? to!int(jo+1) : to!int(jo); // -> [0,1,3,4] since 2 is the entry for "cell"
                            A[k*nbands + jjo] += S/D*sigmaF*(nx*(fdx[jo] + fdxx[jo]*dxF + fdxy[jo]*dyF)
                                                         + ny*(fdy[jo] + fdxy[jo]*dxF - fdxx[jo]*dyF));
                        }
                    }
                    dphidx_face /= D;
                    dphidy_face /= D;
                    //writefln("cell %d face %d phidx %e (%e) phidy %e (%e) - edge? %s", k, io, dphidx_face, dphidx_face_target, dphidy_face, dphidy_face_target, face.is_on_boundary);
                }
                double refB = 0.0;
                refB += A[k*nbands + 2]*phii;
                bool edge = false;
                foreach(io, face; cell.iface){
                    int iio = (io>1) ? to!int(io+1) : to!int(io); // -> [0,1,3,4] since 2 is the entry for "cell"
                    refB+= A[k*nbands + iio]*phi[io];
                    if (face.is_on_boundary) edge=true;
                }
                writefln("k %d refB: %e (%e) edge? %s", k, b[k], refB, edge);
            }
        }

        // The Jacobi Preconditioner, a very simple scheme. Good for diagonally dominant matrices
        if (precondition){
            foreach(blkid, block; localFluidBlocks){
                foreach(cell; block.cells){
                    int k = cell.id + block_offsets[blkid];
                    //writefln(" A[i,:]=[%e,%e,%e,%e,%e] b=[%e]", A[k*nbands+0], A[k*nbands+1], A[k*nbands+2], A[k*nbands+3], A[k*nbands+4], b[k]);
                    double Akk = A[k*nbands + 2];
                    b[k] /= Akk;
                    foreach(iio; 0 .. nbands) A[k*nbands + iio] /= Akk;
                }
            }
        }

        phi0[] = 0.0;
        gmres.solve(N, nbands, A, Ai, b, phi0, phi, max_iter);

        // Unpack the solution into the "electric_potential" members stored in the cells
        size_t i = 0;
        foreach(block; localFluidBlocks){
            foreach(cell; block.cells){
                cell.electric_potential = phi[i];
                i += 1;
            }
        }

    }
    void compute_boundary_current(FluidBlock[] localFluidBlocks) {
    /*
        Loop over the boundaries of the domain and compute the total electrical current flowing in and out.
        We put the contributions of each face into different buckets depending on their sign, negative means
        current flow in and positive out.

        Notes:
         - TODO: MPI

        @author: Nick Gibbons
    */
        double Iin = 0.0;
        double Iout = 0.0;

        writeln("Called field.compute_boundary_current() ...");
        foreach(blkid, block; localFluidBlocks){
            auto gmodel = block.myConfig.gmodel;
            foreach(cell; block.cells){
                foreach(io, face; cell.iface){
                    if (face.is_on_boundary) {
                        face.fs.gas.sigma = conductivity(face.fs.gas, face.pos, gmodel);
                        double sign = cell.outsign[io];
                        auto field_bc = field_bcs[blkid][face.bc_id];
                        double I = field_bc.compute_current(sign, face, cell);
                        if (I<0.0) {
                            Iin -= I;
                        } else if (I>0.0) {
                            Iout += I;
                        }
                    }
                }
            }
        }
        writefln("    Current in:  %f (A/m)", Iin);
        writefln("    Current out: %f (A/m)", Iout);
	}
private:
    immutable int nbands = 5; // 5 for a 2D structured grid
    immutable bool precondition = true;

    GMResFieldSolver gmres;
    ConductivityModel conductivity;
    FieldBC[][] field_bcs;
    int[] block_offsets; // FIXME: Badness with the block id's not matching their order in local fluid blocks
    version(mpi_parallel){
        Exchanger exchanger;
    }

    double[] A;
    int[] Ai;
    double[] b;
    double[] phi,phi0;
    int max_iter;
    int N;
}

/** adjoint_solver.d
 * Code to construct, and solve the adjoint equations.
 *
 * Author: Kyle D.
 * Date: 2017-09-18
 *
 *
 * History:
 *   2017-09-18 : started -- 2D, 1st order, single-block, structured grid, Euler solver.
**/

import core.stdc.stdlib : exit;
import std.stdio;
import std.file;
import std.format;
import std.conv;
import std.parallelism;
import std.algorithm;
import std.getopt;
import std.string;
import std.array;
import std.math;
import std.datetime;

import nm.smla;
import nm.bbla;
import nm.rsla;

import fluxcalc;
import grid;
import sgrid;
import usgrid;
import block;
import sblock;
import ublock;
import fvcell;
import fvinterface;
import fvvertex;
import sblock;
import globaldata;
import globalconfig;
import simcore;
import fvcore;
import fileutil;
import user_defined_source_terms;
import conservedquantities;
import postprocess;
import loads;

import gzip;
import fvcore;
import fileutil;
import geom;
import sgrid;
import grid;
import gas;
import globalconfig;
import flowsolution;
import solidsolution;

// EPSILON parameter for numerical differentiation of flux jacobian
// Value used based on Vanden and Orkwis (1996), AIAA J. 34:6 pp. 1125-1129
immutable double EPSILON = 1.0e-2;
immutable double ESSENTIALLY_ZERO = 1.0e-15;

void main(string[] args) {

    writeln("Eilmer compressible-flow simulation code -- adjoint solver.");
    
    // -----------------------------------------------------
    // 1. Read in flow solution
    // -----------------------------------------------------

    string msg = "Usage:                              Comment:\n";
    msg       ~= "e4adjoint  [--job=<string>]     name of job\n";
    
    if ( args.length < 2 ) {
	writeln("Too few arguments.");
	write(msg);
	exit(1);
    }
    string jobName = "";
    try {
	getopt(args,
	       "job", &jobName,
	       );
    } catch (Exception e) {
	writeln("Problem parsing command-line options.");
	writeln("Arguments not processed:");
	args = args[1 .. $]; // Dispose of program in first arg
	foreach (arg; args) writeln("   arg: ", arg);
	write(msg);
	exit(1);
    }

    GlobalConfig.base_file_name = jobName;
    auto times_dict = readTimesFile(jobName);
    auto tindx_list = times_dict.keys;
    auto last_tindx = tindx_list[$-1];

    int maxCPUs = 1;
    int maxWallClock = 5*24*3600; // 5 days default
    init_simulation(last_tindx, maxCPUs, maxWallClock);
        
    writeln("simulation initialised");
    
    // -----------------------------------------------------
    // 2. store the stencil of effected cells for each cell
    // -----------------------------------------------------

    // NB: currently only for 1st order interpolation
    // TODO: high order interpolation
    
    FVCell[][] cellStencil;
    foreach (blk; gasBlocks) {
	foreach(i, cell; blk.cells) {
	    FVCell[] cell_refs;
	    cell_refs ~= cell; // add the parent cell as the first reference
	    foreach(f; cell.iface) {
		if (f.left_cell.id != cell.id &&
		    f.left_cell.id < ghost_cell_start_id) { cell_refs ~= f.left_cell; }
		if (f.right_cell.id != cell.id &&
		    f.right_cell.id < ghost_cell_start_id) { cell_refs ~= f.right_cell; }
	    }
	    cellStencil ~= cell_refs;
	}
    }

    // -----------------------------------------------------
    // 3. Compute and store perturbed flux
    // -----------------------------------------------------
    FVCell cellPp; FVCell cellPm; FVCell cellR; FVCell cellL;
    double h; double diff;
    FVInterface ifacePp;
    FVInterface ifacePm;

    double[][] Jac;
    size_t nc = 4; // number of primitive variables
    size_t ncells = gasBlocks[0].cells.length;
    size_t nvertices = gasBlocks[0].vertices.length;
    size_t ndim = gasBlocks[0].myConfig.dimensions;
    // currently stores the entire Jacobian -- this is quite wasteful
    // TODO: sparse matrix storage
    foreach (i; 0..nc*ncells) {
	double[] row;
	foreach (j; 0..nc*ncells) {
	    row ~= 0.0;
	}
	Jac ~= row;
    }
    foreach (blk; gasBlocks) {
	foreach(ci, cell; blk.cells) {
	    // 0th perturbation: rho
	    mixin(computeFluxFlowVariableDerivativesAroundCell("gas.rho", "0", true));
	    // 1st perturbation: u
	    mixin(computeFluxFlowVariableDerivativesAroundCell("vel.refx", "1", false));
	    // 2nd perturbation: v
	    mixin(computeFluxFlowVariableDerivativesAroundCell("vel.refy", "2", false));
	    // 3rd perturbation: P
	    mixin(computeFluxFlowVariableDerivativesAroundCell("gas.p", "3", true));
	    
	    
	    // -----------------------------------------------------
	    // loop through influenced cells and fill out Jacobian 
	    // -----------------------------------------------------
	    // at this point we can use the cell counter ci to access
	    // the correct stencil
	    foreach(c; cellStencil[ci]) {
		size_t I, J; // indices in Jacobian matrix
		double integral;
		double volInv = 1.0 / c.volume[0];
		for ( size_t ic = 0; ic < nc; ++ic ) {
		    I = c.id*nc + ic; // row index
		    for ( size_t jc = 0; jc < nc; ++jc ) {
			integral = 0.0;
			J = cell.id*nc + jc; // column index
			foreach(fi, iface; c.iface) {
			    integral -= c.outsign[fi] * iface.dFdU[ic][jc] * iface.area[0]; // gtl=0
			}
			Jac[I][J] = volInv * integral;
		    }
		}
	    }
	    // clear the flux Jacobian entries
	    foreach (iface; cell.iface) {
		foreach (i; 0..iface.dFdU.length) {
		    foreach (j; 0..iface.dFdU[i].length) {
			iface.dFdU[i][j] = 0.0;
		    }
		}
	    }
	} // end foreach cell
    } // end foreach block
    
    //--------------------------------------------------------
    // Transpose Jac
    //--------------------------------------------------------
    double[][] JacT;
    foreach (i; 0..nc*ncells) {
	double[] row;
	foreach (j; 0..nc*ncells) {
	    row ~= Jac[j][i];
	}
	JacT ~= row;
    }
    // -----------------------------------------------------
    //  Form cost function sensitvity
    // -----------------------------------------------------
    // Analytically form dJdV by hand differentiation
    // cost function is defined as: J(Q) = 0.5*integral[0->l] (p-p*)^2
    double[] dJdV;
    double[] p_target;

    // target pressure distribution saved in file target.dat
    auto file = File("target.dat", "r");
    foreach(i; 0 .. ncells) {
	auto lineContent = file.readln().strip();
	auto tokens = lineContent.split();
	p_target ~= to!double(tokens[8]);
    }
    writeln("target pressure imported");
    foreach (blk; gasBlocks) {
	foreach(i, cell; blk.cells) {
	    dJdV ~= 0.0;
	    dJdV ~= 0.0;
	    dJdV ~= 0.0;
	    dJdV ~= 0.5*(2.0*cell.fs.gas.p - 2.0*p_target[i]);
	}
    }

    // -----------------------------------------------------
    // Solve adjoint equations
    // -----------------------------------------------------

    // form augmented matrix aug = [A|B] = [Jac|dJdQ]
    size_t ncols = nc*ncells+1;
    size_t nrows = nc*ncells;
    Matrix aug;
    aug = new Matrix(nrows, ncols);
    foreach (i; 0 .. JacT.length) {
	foreach (j; 0 .. (Jac[i].length+1) ) {
	    if (j < JacT[i].length) aug[i,j] =  JacT[i][j];
	    else aug[i,j] = -dJdV[i];
	}
    }

    // solve for adjoint variables
    gaussJordanElimination(aug);

    double[] psi;
    foreach (i; 0 .. nrows) {
	psi ~= aug[i,ncols-1];
    }

    writeln(psi);
    
    foreach(i; 0 .. 100) {
	FVCell cell = gasBlocks[0].cells[i];
	auto writer = format("%f %f %f %f %f \n", cell.pos[0].x, psi[i*nc], psi[i*nc+1], psi[i*nc+2], psi[i*nc+3]);
	append("e4_adjoint_vars.dat", writer);
    }
    
    // -----------------------------------------------------
    // form dR/dX 
    // -----------------------------------------------------
    FVCell[][] vtxStencil;
    foreach (blk; gasBlocks) {
	foreach(i, vtx; blk.vertices) {
	    FVCell[] cell_refs;
	    foreach (cid; blk.cellIndexListPerVertex[vtx.id]) {
		cell_refs ~= blk.cells[cid];
	    }
	    vtxStencil ~= cell_refs;
	}
    }

    FVVertex verticePp; FVVertex verticePm;
    // currently stores the entire Jacobian -- this is quite wasteful
    // TODO: sparse matrix storage
    Matrix dRdX;
    dRdX = new Matrix(ncells*nc, nvertices*ndim);
    dRdX.zeros();
    
    foreach (blk; gasBlocks) {
	foreach(vi, vtx; blk.vertices) {
	    // 0th perturbation: x
	    mixin(computeFluxMeshPointDerivativesAroundCell("pos[0].refx", "0"));
	    // 1st perturbation: y
	    mixin(computeFluxMeshPointDerivativesAroundCell("pos[0].refy", "1"));
	    // -----------------------------------------------------
	    // loop through influenced cells and fill out Jacobian 
	    // -----------------------------------------------------
	    // at this point we can use the cell counter ci to access
	    // the correct stencil
	    foreach(c; vtxStencil[vi]) {
		size_t I, J; // indices in Jacobian matrix
		double integral;
		double volInv = 1.0 / c.volume[0];
		for ( size_t ic = 0; ic < nc; ++ic ) {
		    I = c.id*nc + ic; // row index
		    for ( size_t jc = 0; jc < ndim; ++jc ) {
			integral = 0.0;
			J = vtx.id*ndim + jc; //vtx.id*nc + jc; // column index
			foreach(fi, iface; c.iface) {
			    integral -= c.outsign[fi] * iface.dFdU[ic][jc] * iface.area[0]; // gtl=0
			}
			dRdX[I,J] = volInv * integral;
		    }
		}
	    }
	    // clear the flux Jacobian entries
	    foreach (iface; blk.faceIndexListPerVertex[vtx.id]) {
		foreach (i; 0..blk.faces[iface].dFdU.length) {
		    foreach (j; 0..blk.faces[iface].dFdU[i].length) {
			blk.faces[iface].dFdU[i][j] = 0.0;
		    }
		}
	    }
	} // end foreach cell
    } // end foreach block
    // -----------------------------------------------------
    // form dX/dD -- mesh perturbation specific code
    // -----------------------------------------------------
    size_t nvar = 3; // number of design variables
    size_t nsurfnodes = 101; // number of surface nodes
    // sensitivity of mesh points to movements of the surface mesh points
    Matrix dXdXb;
    dXdXb = new Matrix(nvertices*ndim, nsurfnodes*ndim);
    dXdXb.zeros();
    foreach (blk; gasBlocks) {
	SBlock sblk = cast(SBlock) blk;
	foreach(vi, vtx; sblk.vertices) {
	    size_t[3] ijk;
	    ijk = sblk.to_ijk_indices(vtx.id);
	    foreach(vbi; 0..nsurfnodes) {
		if (ijk[0] == vbi) dXdXb[2*ijk[0]+1,2*vbi+1] = 1.0 - (sblk.jmax - ijk[1])/sblk.jmax;
	    }
	}
    } 

    // sensitivity of surface mesh points to movements of design variables
    Matrix dXbdD;
    dXbdD = new Matrix(ndim*nsurfnodes, nvar);
    dXbdD.zeros();
    // shape parameters
    double scale = 1.5;
    double b = 0.07;
    double c = 0.8;
    double d = 3.8;
    foreach (blk; gasBlocks) {
	SBlock sblk = cast(SBlock) blk;
	foreach(vi; 0..nsurfnodes) {
	    FVVertex vtx = sblk.get_vtx(vi+2,sblk.jmin,sblk.kmin);
	    writeln(vtx.pos[0].x);
	    dXbdD[vi*ndim+0,0] = 0.0;
	    dXbdD[vi*ndim+0,1] = 0.0;
	    dXbdD[vi*ndim+0,2] = 0.0;
	    dXbdD[vi*ndim+1,0] = tanh(d/scale) + tanh((c*vtx.pos[0].x - d)/scale);
	    dXbdD[vi*ndim+1,1] = b*vtx.pos[0].x*(-pow(tanh((c*vtx.pos[0].x - d)/scale),2) + 1)/scale;
	    dXbdD[vi*ndim+1,2] = b*(-pow(tanh(d/scale),2) + 1)/scale - b*(-pow(tanh((c*vtx.pos[0].x - d)/scale),2) + 1)/scale;
	}
    } 
    // sensitivity of mesh points to movements of the design variables
    Matrix dXdD;
    dXdD = new Matrix(ndim*nvertices, nvar);
    dot(dXdXb, dXbdD, dXdD);

    // compute transposes
    Matrix dXdD_T; Matrix dRdX_T;
    dXdD_T = transpose(dXdD);
    dRdX_T = transpose(dRdX);
    // temp matrix multiplication
    Matrix tempMatrix;
    tempMatrix = new Matrix(nvar, ncells*nc);
    dot(dXdD_T, dRdX_T, tempMatrix);
    // compute gradient
    double[3] grad;
    dot(tempMatrix, psi, grad);

    writeln(grad);
    
    writeln("Done simulation.");
}

string computeFluxFlowVariableDerivativesAroundCell(string varName, string posInArray, bool includeThermoUpdate)
{
    string codeStr;
    codeStr ~= "cellPp = new FVCell(dedicatedConfig[blk.id]);";
    codeStr ~= "ifacePp = new FVInterface(dedicatedConfig[blk.id], false);";
    codeStr ~= "cellPm = new FVCell(dedicatedConfig[blk.id]);";
    codeStr ~= "ifacePm = new FVInterface(dedicatedConfig[blk.id], false);";
    codeStr ~= "h = cell.fs."~varName~" * EPSILON + EPSILON;";
    codeStr ~= "cellPm.copy_values_from(cell, CopyDataOption.all);";
    codeStr ~= "cellPm.fs."~varName~" -= h;";
    codeStr ~= "cellPp.copy_values_from(cell, CopyDataOption.all);";
    codeStr ~= "cellPp.fs."~varName~" += h;";
    codeStr ~= "foreach(iface; cell.iface) {";
    // ------------------ negative perturbation ------------------
    if ( includeThermoUpdate ) {
	codeStr ~= "blk.myConfig.gmodel.update_thermo_from_rhop(cellPm.fs.gas);";
    }
    // ------------------ apply cell effect bcs ------------------
    codeStr ~= "if (iface.is_on_boundary) {";
    codeStr ~= "cell.fs."~varName~" -= h;";
    if ( includeThermoUpdate ) {
	codeStr ~= "blk.myConfig.gmodel.update_thermo_from_rhop(cell.fs.gas);";
    }
    codeStr ~= "blk.applyPreReconAction(0.0, 0, 0);";  // assume sim_time = 0.0, gtl = 0, ftl = 0
    codeStr ~= "blk.applyPostConvFluxAction(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryFaces(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryCells(0.0, 0, 0);";
    codeStr ~= "blk.applyPostDiffFluxAction(0.0, 0, 0);";
    codeStr ~= "cell.fs."~varName~" += h;";
    if ( includeThermoUpdate ) {
	codeStr ~= "blk.myConfig.gmodel.update_thermo_from_rhop(cell.fs.gas);";
    }
    codeStr ~= "}";
    // ------------------ compute interflux ------------------
    codeStr ~= "if(iface.left_cell.id == cellPm.id) {";
    codeStr ~= "cellR = iface.right_cell;";
    codeStr ~= "cellL = cellPm;";
    codeStr ~= "}";
    codeStr ~= "else {";
    codeStr ~= "cellR = cellPm;";
    codeStr ~= "cellL = iface.left_cell;";
    codeStr ~= "}";
    codeStr ~= "blk.Lft.copy_values_from(cellL.fs);";
    codeStr ~= "blk.Rght.copy_values_from(cellR.fs);";
    codeStr ~= "compute_interface_flux(blk.Lft, blk.Rght, iface, blk.myConfig, blk.omegaz);";
    // ------------------ apply interface effect bcs ------------------
    codeStr ~= "if (iface.is_on_boundary) {";
    codeStr ~= "cell.fs."~varName~" -= h;";
    if ( includeThermoUpdate ) {
	codeStr ~= "blk.myConfig.gmodel.update_thermo_from_rhop(cell.fs.gas);";
    }
    codeStr ~= "blk.applyPreReconAction(0.0, 0, 0);"; // assume sim_time = 0.0, gtl = 0, ftl = 0
    codeStr ~= "blk.applyPostConvFluxAction(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryFaces(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryCells(0.0, 0, 0);";
    codeStr ~= "blk.applyPostDiffFluxAction(0.0, 0, 0);";
    codeStr ~= "cell.fs."~varName~" += h;";
    if ( includeThermoUpdate ) {
	codeStr ~= "blk.myConfig.gmodel.update_thermo_from_rhop(cell.fs.gas);";
    }
    codeStr ~= "}";
    codeStr ~= "ifacePm.copy_values_from(iface, CopyDataOption.all);";
    // ------------------ positive perturbation ------------------
    // update thermo
    if ( includeThermoUpdate ) {
	codeStr ~= "blk.myConfig.gmodel.update_thermo_from_rhop(cellPp.fs.gas);";
    }
    // ------------------ apply cell effect bcs ------------------
    codeStr ~= "if (iface.is_on_boundary) {";
    codeStr ~= "cell.fs."~varName~" += h;";
    if ( includeThermoUpdate ) {
	codeStr ~= "blk.myConfig.gmodel.update_thermo_from_rhop(cell.fs.gas);";
    }
    codeStr ~= "blk.applyPreReconAction(0.0, 0, 0);"; // assume sim_time = 0.0, gtl = 0, ftl = 0
    codeStr ~= "blk.applyPostConvFluxAction(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryFaces(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryCells(0.0, 0, 0);";
    codeStr ~= "blk.applyPostDiffFluxAction(0.0, 0, 0);";
    codeStr ~= "cell.fs."~varName~" -= h;";
    if ( includeThermoUpdate ) {
	codeStr ~= "blk.myConfig.gmodel.update_thermo_from_rhop(cell.fs.gas);";
    }
    codeStr ~= "}";
    // ------------------ compute interface flux ------------------
    codeStr ~= "if(iface.left_cell.id == cellPp.id) {";
    codeStr ~= "cellR = iface.right_cell;";
    codeStr ~= "cellL = cellPp;";
    codeStr ~= "}";
    codeStr ~= "else {";
    codeStr ~= "cellR = cellPp;";
    codeStr ~= "cellL = iface.left_cell;";
    codeStr ~= "}";
    codeStr ~= "blk.Lft.copy_values_from(cellL.fs);";
    codeStr ~= "blk.Rght.copy_values_from(cellR.fs);";
    codeStr ~= "compute_interface_flux(blk.Lft, blk.Rght, iface, blk.myConfig, blk.omegaz);";
    // ------------------ apply interface effect bcs ------------------
    codeStr ~= "if (iface.is_on_boundary) {";
    codeStr ~= "cell.fs."~varName~" += h;";
    if ( includeThermoUpdate ) {
	codeStr ~= "blk.myConfig.gmodel.update_thermo_from_rhop(cell.fs.gas);";
    }
    codeStr ~= "blk.applyPreReconAction(0.0, 0, 0);"; // assume sim_time = 0.0, gtl = 0, ftl = 0
    codeStr ~= "blk.applyPostConvFluxAction(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryFaces(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryCells(0.0, 0, 0);";
    codeStr ~= "blk.applyPostDiffFluxAction(0.0, 0, 0);";
    codeStr ~= "cell.fs."~varName~" -= h;";
    if ( includeThermoUpdate ) {
	codeStr ~= "blk.myConfig.gmodel.update_thermo_from_rhop(cell.fs.gas);";
    }
    codeStr ~= "}";
    codeStr ~= "ifacePp.copy_values_from(iface, CopyDataOption.all);";
    // ------------------ compute interface flux derivatives ------------------
    codeStr ~= "diff = ifacePp.F.mass - ifacePm.F.mass;";
    codeStr ~= "iface.dFdU[0][" ~ posInArray ~ "] = diff/(2.0*h);";	    
    codeStr ~= "diff = ifacePp.F.momentum.x - ifacePm.F.momentum.x;";
    codeStr ~= "iface.dFdU[1][" ~ posInArray ~ "] = diff/(2.0*h);";
    codeStr ~= "diff = ifacePp.F.momentum.y - ifacePm.F.momentum.y;";
    codeStr ~= "iface.dFdU[2][" ~ posInArray ~ "] = diff/(2.0*h);";
    codeStr ~= "diff = ifacePp.F.total_energy - ifacePm.F.total_energy;";
    codeStr ~= "iface.dFdU[3][" ~ posInArray ~ "] = diff/(2.0*h);";
    //
    codeStr ~= "}";

    return codeStr;
}

string computeFluxMeshPointDerivativesAroundCell(string varName, string posInArray)
{
    string codeStr;
    codeStr ~= "ifacePp = new FVInterface(dedicatedConfig[blk.id], false);";
    codeStr ~= "ifacePm = new FVInterface(dedicatedConfig[blk.id], false);";
    codeStr ~= "h = vtx."~varName~" * EPSILON + EPSILON;";
    codeStr ~= "foreach (faceid; blk.faceIndexListPerVertex[vtx.id]) { ";
    codeStr ~= "FVInterface iface = blk.faces[faceid];";
    // ------------------ negative perturbation ------------------
    codeStr ~= "vtx."~varName~" -= h;";
    // ------------------ apply grid metrics ------------------
    codeStr ~= "foreach (cid; blk.cellIndexListPerVertex[vtx.id]) { blk.cells[cid].update_2D_geometric_data(0, dedicatedConfig[blk.id].axisymmetric); }";
    codeStr ~= "foreach (fid; blk.faceIndexListPerVertex[vtx.id]) { blk.faces[fid].update_2D_geometric_data(0, dedicatedConfig[blk.id].axisymmetric); }";
    //codeStr ~= "blk.compute_primary_cell_geometric_data(0);";
    //codeStr ~= "if (GlobalConfig.do_compute_distance_to_nearest_wall) {";
    //codeStr ~= "blk.compute_distance_to_nearest_wall_for_all_cells(0);";
    //codeStr ~= "}";
    //codeStr ~= "if ((blk.grid_type == Grid_t.unstructured_grid) &&";
    //codeStr ~= "(blk.myConfig.interpolation_order > 1)) {"; 
    //codeStr ~= "blk.compute_least_squares_setup_for_reconstruction(0);";
    //codeStr ~= "}";
    // ------------------ apply cell effect bcs ------------------
    codeStr ~= "if (iface.is_on_boundary) {";
    codeStr ~= "blk.applyPreReconAction(0.0, 0, 0);";  // assume sim_time = 0.0, gtl = 0, ftl = 0
    codeStr ~= "blk.applyPostConvFluxAction(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryFaces(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryCells(0.0, 0, 0);";
    codeStr ~= "blk.applyPostDiffFluxAction(0.0, 0, 0);";
    codeStr ~= "}";
    // ------------------ compute interflux ------------------
    codeStr ~= "cellR = iface.right_cell;";
    codeStr ~= "cellL = iface.left_cell;";
    codeStr ~= "blk.Lft.copy_values_from(cellL.fs);";
    codeStr ~= "blk.Rght.copy_values_from(cellR.fs);";
    codeStr ~= "compute_interface_flux(blk.Lft, blk.Rght, iface, blk.myConfig, blk.omegaz);";
    // ------------------ apply interface effect bcs ------------------
    codeStr ~= "if (iface.is_on_boundary) {";
    codeStr ~= "blk.applyPreReconAction(0.0, 0, 0);"; // assume sim_time = 0.0, gtl = 0, ftl = 0
    codeStr ~= "blk.applyPostConvFluxAction(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryFaces(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryCells(0.0, 0, 0);";
    codeStr ~= "blk.applyPostDiffFluxAction(0.0, 0, 0);";
    codeStr ~= "}";
    codeStr ~= "ifacePm.copy_values_from(iface, CopyDataOption.all);";
    codeStr ~= "vtx."~varName~" += h;";
    // ------------------ positive perturbation ------------------
    codeStr ~= "vtx."~varName~" += h;";
    // ------------------ apply grid metrics ------------------
    codeStr ~= "foreach (cid; blk.cellIndexListPerVertex[vtx.id]) { blk.cells[cid].update_2D_geometric_data(0, dedicatedConfig[blk.id].axisymmetric); }";
    codeStr ~= "foreach (fid; blk.faceIndexListPerVertex[vtx.id]) { blk.faces[fid].update_2D_geometric_data(0, dedicatedConfig[blk.id].axisymmetric); }";
    //codeStr ~= "if (GlobalConfig.do_compute_distance_to_nearest_wall) {";
    //codeStr ~= "blk.compute_distance_to_nearest_wall_for_all_cells(0);";
    //codeStr ~= "}";
    //codeStr ~= "if ((blk.grid_type == Grid_t.unstructured_grid) &&";
    //codeStr ~= "(blk.myConfig.interpolation_order > 1)) {"; 
    //codeStr ~= "blk.compute_least_squares_setup_for_reconstruction(0);";
    //codeStr ~= "}";
    // ------------------ apply cell effect bcs ------------------
    codeStr ~= "if (iface.is_on_boundary) {";
    codeStr ~= "blk.applyPreReconAction(0.0, 0, 0);"; // assume sim_time = 0.0, gtl = 0, ftl = 0
    codeStr ~= "blk.applyPostConvFluxAction(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryFaces(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryCells(0.0, 0, 0);";
    codeStr ~= "blk.applyPostDiffFluxAction(0.0, 0, 0);";
    codeStr ~= "}";
    // ------------------ compute interface flux ------------------
    codeStr ~= "cellR = iface.right_cell;";
    codeStr ~= "cellL = iface.left_cell;";
    codeStr ~= "blk.Lft.copy_values_from(cellL.fs);";
    codeStr ~= "blk.Rght.copy_values_from(cellR.fs);";
    codeStr ~= "compute_interface_flux(blk.Lft, blk.Rght, iface, blk.myConfig, blk.omegaz);";
    // ------------------ apply interface effect bcs ------------------
    codeStr ~= "if (iface.is_on_boundary) {";
    codeStr ~= "blk.applyPreReconAction(0.0, 0, 0);"; // assume sim_time = 0.0, gtl = 0, ftl = 0
    codeStr ~= "blk.applyPostConvFluxAction(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryFaces(0.0, 0, 0);";
    codeStr ~= "blk.applyPreSpatialDerivActionAtBndryCells(0.0, 0, 0);";
    codeStr ~= "blk.applyPostDiffFluxAction(0.0, 0, 0);";
    codeStr ~= "}";
    codeStr ~= "ifacePp.copy_values_from(iface, CopyDataOption.all);";
    codeStr ~= "vtx."~varName~" -= h;";
    // ------------------ compute interface flux derivatives ------------------
    codeStr ~= "diff = ifacePp.F.mass - ifacePm.F.mass;";
    codeStr ~= "iface.dFdU[0][" ~ posInArray ~ "] = diff/(2.0*h);";	    
    codeStr ~= "diff = ifacePp.F.momentum.x - ifacePm.F.momentum.x;";
    codeStr ~= "iface.dFdU[1][" ~ posInArray ~ "] = diff/(2.0*h);";
    codeStr ~= "diff = ifacePp.F.momentum.y - ifacePm.F.momentum.y;";
    codeStr ~= "iface.dFdU[2][" ~ posInArray ~ "] = diff/(2.0*h);";
    codeStr ~= "diff = ifacePp.F.total_energy - ifacePm.F.total_energy;";
    codeStr ~= "iface.dFdU[3][" ~ posInArray ~ "] = diff/(2.0*h);";
    // ------------------ restore original geometry ------------------
    codeStr ~= "foreach (cid; blk.cellIndexListPerVertex[vtx.id]) { blk.cells[cid].update_2D_geometric_data(0, dedicatedConfig[blk.id].axisymmetric); }";
    codeStr ~= "foreach (fid; blk.faceIndexListPerVertex[vtx.id]) { blk.faces[fid].update_2D_geometric_data(0, dedicatedConfig[blk.id].axisymmetric); }";
    //
    codeStr ~= "}";

    return codeStr;
}


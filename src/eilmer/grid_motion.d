// Authors: RG, PJ, KD & IJ
// Date: 2015-11-20

module grid_motion;

import std.string;
import std.conv;
import std.algorithm;

import util.lua;
import util.lua_service;
import nm.complex;
import nm.number;
import nm.luabbla;
import lua_helper;
import fvcore;
import fvvertex;
import fvinterface;
import globalconfig;
import globaldata;
import geom;
import geom.luawrap;
import fluidblock;
import sfluidblock;
import ufluidblock;
import std.stdio;


@nogc
int set_gcl_interface_properties(SFluidBlock blk, size_t gtl, double dt) {
    FVInterface IFace;
    Vector3 pos1, pos2, temp;
    Vector3 averaged_ivel, vol;
    if (blk.myConfig.dimensions == 2) {
        FVVertex vtx1, vtx2;
        size_t k = 0;
        // loop over i-interfaces and compute interface velocity wif'.
        foreach (j; 0 .. blk.njc) {
            foreach (i; 0 .. blk.niv) {
                vtx1 = blk.get_vtx(i,j,k);
                vtx2 = blk.get_vtx(i,j+1,k);
                IFace = blk.get_ifi(i,j,k);
                pos1 = vtx1.pos[gtl];
                pos1 -= vtx2.pos[0];
                pos2 = vtx2.pos[gtl];
                pos2 -= vtx1.pos[0];
                averaged_ivel = vtx1.vel[0];
                averaged_ivel += vtx2.vel[0];
                averaged_ivel.scale(0.5);
                // Use effective edge velocity
                // Reference: D. Ambrosi, L. Gasparini and L. Vigenano
                // Full Potential and Euler solutions for transonic unsteady flow
                // Aeronautical Journal November 1994 Eqn 25
                cross(vol, pos1, pos2);
                if (blk.myConfig.axisymmetric == false) {
                    vol.scale(0.5);
                } else {
                    vol.scale(0.125*(vtx1.pos[gtl].y+vtx1.pos[0].y+vtx2.pos[gtl].y+vtx2.pos[0].y));
                }
                temp = vol; temp /= dt*IFace.area[0];
                // temp is the interface velocity (W_if) from the GCL
                // interface area determined at gtl 0 since GCL formulation
                // recommends using initial interfacial area in calculation.
                IFace.gvel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
                averaged_ivel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
                IFace.gvel.set(temp.z, averaged_ivel.y, averaged_ivel.z);
                averaged_ivel.transform_to_global_frame(IFace.n, IFace.t1, IFace.t2);
                IFace.gvel.transform_to_global_frame(IFace.n, IFace.t1, IFace.t2);
            }
        }
        // loop over j-interfaces and compute interface velocity wif'.
        foreach (j; 0 .. blk.njv) {
            foreach (i; 0 .. blk.nic) {
                vtx1 = blk.get_vtx(i,j,k);
                vtx2 = blk.get_vtx(i+1,j,k);
                IFace = blk.get_ifj(i,j,k);
                pos1 = vtx2.pos[gtl]; pos1 -= vtx1.pos[0];
                pos2 = vtx1.pos[gtl]; pos2 -= vtx2.pos[0];
                averaged_ivel = vtx1.vel[0]; averaged_ivel += vtx2.vel[0]; averaged_ivel.scale(0.5);
                cross(vol, pos1, pos2);
                if (blk.myConfig.axisymmetric == false) {
                    vol.scale(0.5);
                } else {
                    vol.scale(0.125*(vtx1.pos[gtl].y+vtx1.pos[0].y+vtx2.pos[gtl].y+vtx2.pos[0].y));
                }
                IFace.gvel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
                averaged_ivel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
                if (blk.myConfig.axisymmetric && j == 0 && IFace.area[0] == 0.0) {
                    // For axi-symmetric cases the cells along the axis of symmetry have 0 interface area,
                    // this is a problem for determining Wif, so we have to catch the NaN from dividing by 0.
                    // We choose to set the y and z directions to 0, but take an averaged value for the
                    // x-direction so as to not force the grid to be stationary, defeating the moving grid's purpose.
                    IFace.gvel.set(averaged_ivel.x, to!number(0.0), to!number(0.0));
                } else {
                    temp = vol; temp /= dt*IFace.area[0];
                    IFace.gvel.set(temp.z, averaged_ivel.y, averaged_ivel.z);
                }
                averaged_ivel.transform_to_global_frame(IFace.n, IFace.t1, IFace.t2);
                IFace.gvel.transform_to_global_frame(IFace.n, IFace.t1, IFace.t2);
            }
        }
    } // end if (blk.myConfig.dimensions == 2)

    // Do 3-D cases, where faces move and create a new hexahedron
    if (blk.myConfig.dimensions == 3) {
        FVVertex vtx0, vtx1, vtx2, vtx3;
        Vector3 p0, p1, p2, p3, p4, p5, p6, p7;
        Vector3 centroid_hex, sub_centroid;
        number volume, sub_volume, temp2;
        // loop over i-interfaces and compute interface velocity wif'.
        foreach (k; 0 .. blk.nkc) {
            foreach (j; 0 .. blk.njc) {
                foreach (i; 0 .. blk.niv) {
                    // Calculate volume generated by sweeping face 0123 from pos[0] to pos[gtl]
                    vtx0 = blk.get_vtx(i,j  ,k  );
                    vtx1 = blk.get_vtx(i,j+1,k  );
                    vtx2 = blk.get_vtx(i,j+1,k+1);
                    vtx3 = blk.get_vtx(i,j  ,k+1);
                    p0 = vtx0.pos[0]; p1 = vtx1.pos[0];
                    p2 = vtx2.pos[0]; p3 = vtx3.pos[0];
                    p4 = vtx0.pos[gtl]; p5 = vtx1.pos[gtl];
                    p6 = vtx2.pos[gtl]; p7 = vtx3.pos[gtl];
                    // use 6x pyramid approach as used to calculate internal volume of hex cells
                    centroid_hex.set(0.125*(p0.x+p1.x+p2.x+p3.x+p4.x+p5.x+p6.x+p7.x),
                                 0.125*(p0.y+p1.y+p2.y+p3.y+p4.y+p5.y+p6.y+p7.y),
                                 0.125*(p0.z+p1.z+p2.z+p3.z+p4.z+p5.z+p6.z+p7.z));
                    volume = 0.0;
                    pyramid_properties(p6, p7, p3, p2, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    pyramid_properties(p5, p6, p2, p1, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    pyramid_properties(p4, p5, p1, p0, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    pyramid_properties(p7, p4, p0, p3, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    pyramid_properties(p7, p6, p5, p4, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    pyramid_properties(p0, p1, p2, p3, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    //
                    IFace = blk.get_ifi(i,j,k);
                    averaged_ivel = vtx0.vel[0];
                    averaged_ivel += vtx1.vel[0];
                    averaged_ivel += vtx2.vel[0];
                    averaged_ivel += vtx3.vel[0];
                    averaged_ivel.scale(0.25);
                    // Use effective face velocity, analoguous to edge velocity concept
                    // Reference: D. Ambrosi, L. Gasparini and L. Vigenano
                    // Full Potential and Euler solutions for transonic unsteady flow
                    // Aeronautical Journal November 1994 Eqn 25
                    temp2 = volume; temp /= dt*IFace.area[0];
                    // temp2 is the interface velocity (W_if) from the GCL
                    // interface area determined at gtl 0 since GCL formulation
                    // recommends using initial interfacial area in calculation.
                    IFace.gvel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
                    averaged_ivel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
                    IFace.gvel.set(temp2, averaged_ivel.y, averaged_ivel.z);
                    averaged_ivel.transform_to_global_frame(IFace.n, IFace.t1, IFace.t2);
                    IFace.gvel.transform_to_global_frame(IFace.n, IFace.t1, IFace.t2);
                }
            }
        }
        // loop over j-interfaces and compute interface velocity wif'.
        foreach (k; 0 .. blk.nkc) {
            foreach (j; 0 .. blk.njv) {
                foreach (i; 0 .. blk.nic) {
                    // Calculate volume generated by sweeping face 0123 from pos[0] to pos[gtl]
                    vtx0 = blk.get_vtx(i  ,j,k  );
                    vtx1 = blk.get_vtx(i  ,j,k+1);
                    vtx2 = blk.get_vtx(i+1,j,k+1);
                    vtx3 = blk.get_vtx(i+1,j,k  );
                    p0 = vtx0.pos[0]; p1 = vtx1.pos[0];
                    p2 = vtx2.pos[0]; p3 = vtx3.pos[0];
                    p4 = vtx0.pos[gtl]; p5 = vtx1.pos[gtl];
                    p6 = vtx2.pos[gtl]; p7 = vtx3.pos[gtl];
                    // use 6x pyramid approach as used to calculate internal volume of hex cells
                    centroid_hex.set(0.125*(p0.x+p1.x+p2.x+p3.x+p4.x+p5.x+p6.x+p7.x),
                                 0.125*(p0.y+p1.y+p2.y+p3.y+p4.y+p5.y+p6.y+p7.y),
                                 0.125*(p0.z+p1.z+p2.z+p3.z+p4.z+p5.z+p6.z+p7.z));
                    volume = 0.0;
                    pyramid_properties(p6, p7, p3, p2, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    pyramid_properties(p5, p6, p2, p1, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    pyramid_properties(p4, p5, p1, p0, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    pyramid_properties(p7, p4, p0, p3, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    pyramid_properties(p7, p6, p5, p4, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    pyramid_properties(p0, p1, p2, p3, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    //
                    IFace = blk.get_ifj(i,j,k);
                    averaged_ivel = vtx0.vel[0];
                    averaged_ivel += vtx1.vel[0];
                    averaged_ivel += vtx2.vel[0];
                    averaged_ivel += vtx3.vel[0];
                    averaged_ivel.scale(0.25);
                    // Use effective face velocity, analoguous to edge velocity concept
                    // Reference: D. Ambrosi, L. Gasparini and L. Vigenano
                    // Full Potential and Euler solutions for transonic unsteady flow
                    // Aeronautical Journal November 1994 Eqn 25
                    temp2 = volume; temp /= dt*IFace.area[0];
                    // temp2 is the interface velocity (W_if) from the GCL
                    // interface area determined at gtl 0 since GCL formulation
                    // recommends using initial interfacial area in calculation.
                    IFace.gvel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
                    averaged_ivel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
                    IFace.gvel.set(temp2, averaged_ivel.y, averaged_ivel.z);
                    averaged_ivel.transform_to_global_frame(IFace.n, IFace.t1, IFace.t2);
                    IFace.gvel.transform_to_global_frame(IFace.n, IFace.t1, IFace.t2);
                }
            }
        }
        // loop over k-interfaces and compute interface velocity wif'.
        foreach (k; 0 .. blk.nkv) {
            foreach (j; 0 .. blk.njc) {
                foreach (i; 0 .. blk.nic) {
                    // Calculate volume generated by sweeping face 0123 from pos[0] to pos[gtl]
                    vtx0 = blk.get_vtx(i  ,j  ,k);
                    vtx1 = blk.get_vtx(i+1,j  ,k);
                    vtx2 = blk.get_vtx(i+1,j+1,k);
                    vtx3 = blk.get_vtx(i  ,j+1,k);
                    p0 = vtx0.pos[0]; p1 = vtx1.pos[0];
                    p2 = vtx2.pos[0]; p3 = vtx3.pos[0];
                    p4 = vtx0.pos[gtl]; p5 = vtx1.pos[gtl];
                    p6 = vtx2.pos[gtl]; p7 = vtx3.pos[gtl];
                    // use 6x pyramid approach as used to calculate internal volume of hex cells
                    centroid_hex.set(0.125*(p0.x+p1.x+p2.x+p3.x+p4.x+p5.x+p6.x+p7.x),
                                 0.125*(p0.y+p1.y+p2.y+p3.y+p4.y+p5.y+p6.y+p7.y),
                                 0.125*(p0.z+p1.z+p2.z+p3.z+p4.z+p5.z+p6.z+p7.z));
                    volume = 0.0;
                    pyramid_properties(p6, p7, p3, p2, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    pyramid_properties(p5, p6, p2, p1, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    pyramid_properties(p4, p5, p1, p0, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    pyramid_properties(p7, p4, p0, p3, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    pyramid_properties(p7, p6, p5, p4, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    pyramid_properties(p0, p1, p2, p3, centroid_hex, sub_centroid, sub_volume);
                    volume += sub_volume;
                    //
                    IFace = blk.get_ifk(i,j,k);
                    averaged_ivel = vtx0.vel[0];
                    averaged_ivel += vtx1.vel[0];
                    averaged_ivel += vtx2.vel[0];
                    averaged_ivel += vtx3.vel[0];
                    averaged_ivel.scale(0.25);
                    // Use effective face velocity, analoguous to edge velocity concept
                    // Reference: D. Ambrosi, L. Gasparini and L. Vigenano
                    // Full Potential and Euler solutions for transonic unsteady flow
                    // Aeronautical Journal November 1994 Eqn 25
                    temp2 = volume; temp2 /= dt*IFace.area[0];
                    // temp2 is the interface velocity (W_if) from the GCL
                    // interface area determined at gtl 0 since GCL formulation
                    // recommends using initial interfacial area in calculation.
                    IFace.gvel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
                    averaged_ivel.transform_to_local_frame(IFace.n, IFace.t1, IFace.t2);
                    IFace.gvel.set(temp2, averaged_ivel.y, averaged_ivel.z);
                    averaged_ivel.transform_to_global_frame(IFace.n, IFace.t1, IFace.t2);
                    IFace.gvel.transform_to_global_frame(IFace.n, IFace.t1, IFace.t2);
                }
            }
        }
    }
    return 0;
} // end set_gcl_interface_properties()

@nogc
void predict_vertex_positions(SFluidBlock blk, double dt, int gtl)
{
    foreach (vtx; blk.vertices) {
        if (gtl == 0) {
            // predictor/sole step; update grid
            vtx.pos[1] = vtx.pos[0] + dt * vtx.vel[0];
        } else {
            // corrector step; keep grid fixed
            vtx.pos[2] = vtx.pos[1];
        }
    }
    return;
} // end predict_vertex_positions()

// ------------------ Lua interface functions below this point. ----------------------

void setGridMotionHelperFunctions(lua_State *L)
{
    lua_pushcfunction(L, &luafn_getVtxPosition);
    lua_setglobal(L, "getVtxPosition");
    lua_pushcfunction(L, &luafn_getVtxPositionXYZ);
    lua_setglobal(L, "getVtxPositionXYZ");
    lua_pushcfunction(L, &luafn_getVtxPositionVector3);
    lua_setglobal(L, "getVtxPositionVector3");
    lua_pushcfunction(L, &luafn_setVtxVelocitiesForDomain);
    lua_setglobal(L, "setVtxVelocitiesForDomain");
    lua_pushcfunction(L, &luafn_setVtxVelocitiesForDomainXYZ);
    lua_setglobal(L, "setVtxVelocitiesForDomainXYZ");
    lua_pushcfunction(L, &luafn_setVtxVelocitiesForBlock);
    lua_setglobal(L, "setVtxVelocitiesForBlock");
    lua_pushcfunction(L, &luafn_setVtxVelocitiesForBlockXYZ);
    lua_setglobal(L, "setVtxVelocitiesForBlockXYZ");
    lua_pushcfunction(L, &luafn_setVtxVelocitiesForRotatingBlock);
    lua_setglobal(L, "setVtxVelocitiesForRotatingBlock");
    lua_pushcfunction(L, &luafn_setVtxVelocitiesByCorners);
    lua_setglobal(L, "setVtxVelocitiesByCorners");
    lua_pushcfunction(L, &luafn_setVtxVelocitiesByQuad);
    lua_setglobal(L, "setVtxVelocitiesByQuad");
    lua_pushcfunction(L, &luafn_setVtxVelocitiesByCornersReg);
    lua_setglobal(L, "setVtxVelocitiesByCornersReg");
    lua_pushcfunction(L, &luafn_setVtxVelocity);
    lua_setglobal(L, "setVtxVelocity");
    lua_pushcfunction(L, &luafn_setVtxVelocityXYZ);
    lua_setglobal(L, "setVtxVelocityXYZ");
}

extern(C) int luafn_getVtxPosition(lua_State *L)
{
    // Get arguments from lua_stack
    auto blkId = lua_tointeger(L, 1);
    if (!canFind(GlobalConfig.localFluidBlockIds, blkId)) {
        string msg = format("Block id %d is not local to process.", blkId);
        luaL_error(L, msg.toStringz);
    }
    auto i = lua_tointeger(L, 2);
    auto j = lua_tointeger(L, 3);
    auto k = lua_tointeger(L, 4);
    //
    // Grab the appropriate vtx
    FVVertex vtx;
    auto sblk = cast(SFluidBlock) globalBlocks[blkId];
    if (sblk) {
        try {
            vtx = sblk.get_vtx(i, j, k);
        } catch (Exception e) {
            string msg = format("Failed to locate vertex[%d,%d,%d] in block %d.", i, j, k, blkId);
            luaL_error(L, msg.toStringz);
        }
    } else {
        string msg = "Not implemented.";
        msg ~= " You have asked for an ijk-index vertex in an unstructured-grid block.";
        luaL_error(L, msg.toStringz);
    }
    //
    // Return the interesting bits as a table with entries x, y, z.
    lua_newtable(L);
    lua_pushnumber(L, vtx.pos[0].x.re); lua_setfield(L, -2, "x");
    lua_pushnumber(L, vtx.pos[0].y.re); lua_setfield(L, -2, "y");
    lua_pushnumber(L, vtx.pos[0].z.re); lua_setfield(L, -2, "z");
    return 1;
} // end luafn_getVtxPosition()

extern(C) int luafn_getVtxPositionXYZ(lua_State *L)
{
    // Get arguments from lua_stack
    auto blkId = lua_tointeger(L, 1);
    if (!canFind(GlobalConfig.localFluidBlockIds, blkId)) {
        string msg = format("Block id %d is not local to process.", blkId);
        luaL_error(L, msg.toStringz);
    }
    auto i = lua_tointeger(L, 2);
    auto j = lua_tointeger(L, 3);
    auto k = lua_tointeger(L, 4);
    //
    // Grab the appropriate vtx
    FVVertex vtx;
    auto sblk = cast(SFluidBlock) globalBlocks[blkId];
    if (sblk) {
        try {
            vtx = sblk.get_vtx(i, j, k);
        } catch (Exception e) {
            string msg = format("Failed to locate vertex[%d,%d,%d] in block %d.", i, j, k, blkId);
            luaL_error(L, msg.toStringz);
        }
    } else {
        string msg = "Not implemented.";
        msg ~= " You have asked for an ijk-index vertex in an unstructured-grid block.";
        luaL_error(L, msg.toStringz);
    }
    //
    // Return the components x, y, z on the stack.
    lua_pushnumber(L, vtx.pos[0].x.re);
    lua_pushnumber(L, vtx.pos[0].y.re);
    lua_pushnumber(L, vtx.pos[0].z.re);
    return 3;
} // end luafn_getVtxPositionXYZ()

extern(C) int luafn_getVtxPositionVector3(lua_State *L)
{
    // Get arguments from lua_stack
    auto blkId = lua_tointeger(L, 1);
    if (!canFind(GlobalConfig.localFluidBlockIds, blkId)) {
        string msg = format("Block id %d is not local to process.", blkId);
        luaL_error(L, msg.toStringz);
    }
    auto i = lua_tointeger(L, 2);
    auto j = lua_tointeger(L, 3);
    auto k = lua_tointeger(L, 4);
    //
    // Grab the appropriate vtx
    FVVertex vtx;
    auto sblk = cast(SFluidBlock) globalBlocks[blkId];
    if (sblk) {
        try {
            vtx = sblk.get_vtx(i, j, k);
        } catch (Exception e) {
            string msg = format("Failed to locate vertex[%d,%d,%d] in block %d.", i, j, k, blkId);
            luaL_error(L, msg.toStringz);
        }
    } else {
        string msg = "Not implemented.";
        msg ~= " You have asked for an ijk-index vertex in an unstructured-grid block.";
        luaL_error(L, msg.toStringz);
    }
    //
    pushVector3(L, vtx.pos[0]);
    return 1;
} // end luafn_getVtxPositionVector3()

extern(C) int luafn_setVtxVelocitiesForDomain(lua_State* L)
{
    // Expect a single argument: a Vector3 object or table with x,y,z fields.
    auto vel = toVector3(L, 1);

    foreach ( blk; localFluidBlocks ) {
        foreach ( vtx; blk.vertices ) {
            /* We assume that we'll only update grid positions
               at the start of the increment. This should work
               well except in the most critical cases of time
               accuracy.
            */
            vtx.vel[0].set(vel);
        }
    }
    // In case, the user gave use more return values than
    // we used, just set the lua stack to empty and let
    // the lua garbage collector do its thing.
    lua_settop(L, 0);
    return 0;
} // end luafn_setVtxVelocitiesForDomain()

extern(C) int luafn_setVtxVelocitiesForDomainXYZ(lua_State* L)
{
    // Expect three velocity components.
    double velx = lua_tonumber(L, 1);
    double vely = lua_tonumber(L, 2);
    double velz = lua_tonumber(L, 3);

    foreach ( blk; localFluidBlocks ) {
        foreach ( vtx; blk.vertices ) {
            /* We assume that we'll only update grid positions
               at the start of the increment. This should work
               well except in the most critical cases of time
               accuracy.
            */
            vtx.vel[0].set(velx, vely, velz);
        }
    }
    // In case, the user gave use more return values than
    // we used, just set the lua stack to empty and let
    // the lua garbage collector do its thing.
    lua_settop(L, 0);
    return 0;
} // end luafn_setVtxVelocitiesForDomainXYZ()

extern(C) int luafn_setVtxVelocitiesForBlock(lua_State* L)
{
    // Expect two arguments: 1. a block id
    //                       2. a Vector3 object or table with x,y,z fields.
    auto blkId = lua_tointeger(L, 1);
    if (!canFind(GlobalConfig.localFluidBlockIds, blkId)) {
        string msg = format("Block id %d is not local to process.", blkId);
        luaL_error(L, msg.toStringz);
    }
    auto vel = toVector3(L, 2);

    auto blk = cast(FluidBlock) globalBlocks[blkId];
    assert(blk !is null, "Oops, this should be a FluidBlock object.");
    foreach ( vtx; blk.vertices ) {
        /* We assume that we'll only update grid positions
           at the start of the increment. This should work
           well except in the most critical cases of time
           accuracy.
        */
        vtx.vel[0].set(vel);
    }
    // In case, the user gave use more return values than
    // we used, just set the lua stack to empty and let
    // the lua garbage collector do its thing.
    lua_settop(L, 0);
    return 0;
} // end luafn_setVtxVelocitiesForBlock()

extern(C) int luafn_setVtxVelocitiesForBlockXYZ(lua_State* L)
{
    // Expect four arguments: 1. a block id
    //                        2. x velocity
    //                        3. y velocity
    //                        4. z velocity
    auto blkId = lua_tointeger(L, 1);
    if (!canFind(GlobalConfig.localFluidBlockIds, blkId)) {
        string msg = format("Block id %d is not local to process.", blkId);
        luaL_error(L, msg.toStringz);
    }
    double velx = lua_tonumber(L, 2);
    double vely = lua_tonumber(L, 3);
    double velz = lua_tonumber(L, 4);

    auto blk = cast(FluidBlock) globalBlocks[blkId];
    assert(blk !is null, "Oops, this should be a FluidBlock object.");
    foreach ( vtx; blk.vertices ) {
        /* We assume that we'll only update grid positions
           at the start of the increment. This should work
           well except in the most critical cases of time
           accuracy.
        */
        vtx.vel[0].set(velx, vely, velz);
    }
    // In case, the user gave use more return values than
    // we used, just set the lua stack to empty and let
    // the lua garbage collector do its thing.
    lua_settop(L, 0);
    return 0;
}

/**
 * Sets the velocity of an entire block, for the case
 * that the block is rotating about an axis with direction
 * (0 0 1) located at a point defined by vector (x y 0).
 *
 * setVtxVelocitiesRotatingBlock(blkId, omega, vector3)
 *      Sets rotational speed omega (rad/s) for rotation about
 *      (0 0 1) axis defined by Vector3.
 *
 * setVtxVelocitiesRotatingBlock(blkId, omega)
 *      Sets rotational speed omega (rad/s) for rotation about
 *      Z-axis.
 */
extern(C) int luafn_setVtxVelocitiesForRotatingBlock(lua_State* L)
{
    // Expect two/three arguments: 1. a block id
    //                             2. a float object
    //                             3. a Vector3/table with x,y,z fields (optional)
    int narg = lua_gettop(L);
    auto blkId = lua_tointeger(L, 1);
    if (!canFind(GlobalConfig.localFluidBlockIds, blkId)) {
        string msg = format("Block id %d is not local to process.", blkId);
        luaL_error(L, msg.toStringz);
    }
    double omega = lua_tonumber(L, 2);
    double velx, vely;

    auto blk = cast(FluidBlock) globalBlocks[blkId];
    assert(blk !is null, "Oops, this should be a FluidBlock object.");
    if ( narg == 2 ) {
        // assume rotation about Z-axis
        foreach ( vtx; blk.vertices ) {
            velx = - omega * vtx.pos[0].y.re;
            vely =   omega * vtx.pos[0].x.re;
            vtx.vel[0].set(velx, vely, 0.0);
        }
    }
    else if ( narg == 3 ) {
        auto axis = toVector3(L, 3);
        foreach ( vtx; blk.vertices ) {
            velx = - omega * (vtx.pos[0].y.re - axis.y.re);
            vely =   omega * (vtx.pos[0].x.re - axis.x.re);
            vtx.vel[0].set(velx, vely, 0.0);
        }
    }
    else {
        string errMsg = "ERROR: Too few arguments passed to luafn: setVtxVelocitiesRotatingBlock()\n";
        luaL_error(L, errMsg.toStringz);
    }
    // In case, the user gave use more return values than
    // we used, just set the lua stack to empty and let
    // the lua garbage collector do its thing.
    lua_settop(L, 0);
    return 0;
} // end luafn_setVtxVelocitiesForRotatingBlock()

/**
 * Sets the velocity of vertices in a block based on
 * specified corner velocities.
 * Works for clustered grids.
 *
 *   p3-----p2
 *   |      |
 *   |      |
 *   p0-----p1
 *
 * This function can be called for 2-D structured and
 * extruded 3-D grids only. The following calls are allowed:
 *
 * setVtxVelocitiesByCorners(blkId, p0vel, p1vel, p2vel, p3vel)
 *   Sets the velocity vectors for block with corner velocities
 *   specified by four corner velocities. This works for both
 *   2-D and 3- meshes. In 3-D a uniform velocity is applied
 *   in k direction.
 */
extern(C) int luafn_setVtxVelocitiesByCorners(lua_State* L)
{
    // Expect five/nine arguments: 1. a block id
    //                             2-5. corner velocities for 2-D motion
    //                             6-9. corner velocities for full 3-D motion
    //                                  (optional)
    int narg = lua_gettop(L);
    auto blkId = lua_tointeger(L, 1);
    if (!canFind(GlobalConfig.localFluidBlockIds, blkId)) {
        string msg = format("Block id %d is not local to process.", blkId);
        luaL_error(L, msg.toStringz);
    }
    auto blk = cast(SFluidBlock) globalBlocks[blkId];
    // get corner velocities
    Vector3 p00vel = toVector3(L, 2);
    Vector3 p10vel = toVector3(L, 3);
    Vector3 p11vel = toVector3(L, 4);
    Vector3 p01vel = toVector3(L, 5);
    // get coordinates for corner points
    size_t  k = 0;
    Vector3 p00 = blk.get_vtx(0,0,k).pos[0];
    Vector3 p10 = blk.get_vtx(blk.niv-1,0,k).pos[0];
    Vector3 p11 = blk.get_vtx(blk.niv-1,blk.njv-1,k).pos[0];
    Vector3 p01 = blk.get_vtx(0,blk.njv-1,k).pos[0];

    @nogc
    void setAsWeightedSum2(ref Vector3 result, double w0, Vector3 v0, double w1, Vector3 v1)
    {
        result.set(v0); result.scale(w0);
        result.add(v1, w1);
    }

    @nogc
    void setAsWeightedSum3(ref Vector3 result, number[3] w, Vector3 v0, Vector3 v1, Vector3 v2)
    {
        result.set(v0); result.scale(w[0]);
        result.add(v1, w[1]);
        result.add(v2, w[2]);
    }

    if (narg == 5) {
        if (blk.myConfig.dimensions == 2) {
            foreach (j; 0 .. blk.njv) {
                foreach (i; 0 .. blk.niv) {
                    // get position of current point
                    auto pos = blk.get_vtx(i,j,k).pos[0];
                    // Assuming we have a roughly-quadrilateral block,
                    // transfinite interpolation with reconstructed parameters.
                    // p01---pN----p11
                    //  |    |      |
                    // pW----p------pE
                    //  |    |      |
                    //  |    |      |
                    // p00---pS----p10
                    Vector3 pS = blk.get_vtx(i,0,k).pos[0];
                    Vector3 pE = blk.get_vtx(blk.niv-1,j,k).pos[0];
                    Vector3 pN = blk.get_vtx(i,blk.njv-1,k).pos[0];
                    Vector3 pW = blk.get_vtx(0,j,k).pos[0];
                    double dW = distance_between(pW, pos);
                    double dE = distance_between(pos, pE);
                    double r = dW/(dW+dE); double omr = 1.0-r;
                    double dS = distance_between(pS, pos);
                    double dN = distance_between(pos, pN);
                    double s = dS/(dS+dN); double oms = 1.0-s;
                    Vector3 pSvel, pEvel, pNvel, pWvel;
                    setAsWeightedSum2(pSvel, omr, p00vel, r, p10vel);
                    setAsWeightedSum2(pNvel, omr, p01vel, r, p11vel);
                    setAsWeightedSum2(pWvel, oms, p00vel, s, p01vel);
                    setAsWeightedSum2(pEvel, oms, p10vel, s, p11vel);
                    number velx = oms*pSvel.x + s*pNvel.x + omr*pWvel.x + r*pEvel.x -
                        (omr*oms*p00vel.x + omr*s*p01vel.x + r*oms*p10vel.x + r*s*p11vel.x);
                    number vely = oms*pSvel.y + s*pNvel.y + omr*pWvel.y + r*pEvel.y -
                        (omr*oms*p00vel.y + omr*s*p01vel.y + r*oms*p10vel.y + r*s*p11vel.y);
                    number velz = 0.0;
                    blk.get_vtx(i,j,k).vel[0].set(velx, vely, velz);
                } // end loop i
            } // end loop j
        } else {
            // dimensions==3
            string errMsg = "3D velocity interpolation not yet implemented: setVtxVelocitiesByCorners()\n";
            luaL_error(L, errMsg.toStringz);
        }
    } else {
        string errMsg = "Wrong number of arguments passed to luafn: setVtxVelocitiesByCorners()\n";
        luaL_error(L, errMsg.toStringz);
    }
    // In case, the user gave use more return values than
    // we used, just set the lua stack to empty and let
    // the lua garbage collector do its thing.
    lua_settop(L, 0);
    return 0;
} // end luafn_setVtxVelocitiesByCorners()

/**
 * Sets the velocity of vertices in a block based on
 * specified corner velocities of a given quadrilateral,
 * assuming that the block is within the quad.
 *
 *   p01-----p11
 *    |       |
 *    |       |
 *   p00-----p10
 *
 * This function can be called for 2D grids only.
 * It uses barycenter interpolation to determine the velocities
 * of the vertices within the block.
 * This works for clustered, structured or unstructured grid.
 *
 * The function expects its arguments in a single table with named fields,
 * with the supplied points and velocities as Vector3 objects or tables with x,y,z fields.
 *
 * setVtxVelocitiesByQuad{blkId=i,
 *                        p00=p0, p10=p1, p11=p2, p01=p3,
 *                        v00=v0, v10=v1, v11=v2, v01=v3}
 */
extern(C) int luafn_setVtxVelocitiesByQuad(lua_State* L)
{
    int narg = lua_gettop(L);
    if (!lua_istable(L, -1)) {
        luaL_error(L, "setVtxVelocitiesByQuad expected to receive a single table with named arguments.");
    }
    int blkId = -1;
    lua_getfield(L, 1, "blkId");
    if (lua_isnumber(L, -1)) {
        blkId = to!int(lua_tointeger(L, -1));
    } else {
        luaL_error(L, "setVtxVelocitiesByQuad expected to receive a integer for blkId.");
    }
    lua_pop(L, 1); // discard item
    if (!canFind(GlobalConfig.localFluidBlockIds, blkId)) {
        string msg = format("Block id %d is not local to process.", blkId);
        luaL_error(L, msg.toStringz);
    }
    auto blk = cast(FluidBlock) globalBlocks[blkId];
    assert(blk !is null, "Oops, this should be a FluidBlock object.");
    // Get corner positions and velocities for the quadrilateral.
    Vector3 p00, p10, p11, p01, vel00, vel10, vel11, vel01;
    lua_getfield(L, 1, "p00");
    if (!lua_isnil(L, -1)) {
        p00 = toVector3(L, -1);
    } else {
        luaL_error(L, "setVtxVelocitiesByQuad expected to receive a Vector3 for p00.");
    }
    lua_pop(L, 1); // discard item
    lua_getfield(L, 1, "p10");
    if (!lua_isnil(L, -1)) {
        p10 = toVector3(L, -1);
    } else {
        luaL_error(L, "setVtxVelocitiesByQuad expected to receive a Vector3 for p10.");
    }
    lua_pop(L, 1); // discard item
    lua_getfield(L, 1, "p11");
    if (!lua_isnil(L, -1)) {
        p11 = toVector3(L, -1);
    } else {
        luaL_error(L, "setVtxVelocitiesByQuad expected to receive a Vector3 for p11.");
    }
    lua_pop(L, 1); // discard item
    lua_getfield(L, 1, "p01");
    if (!lua_isnil(L, -1)) {
        p01 = toVector3(L, -1);
    } else {
        luaL_error(L, "setVtxVelocitiesByQuad expected to receive a Vector3 for p01.");
    }
    lua_pop(L, 1); // discard item
    lua_getfield(L, 1, "vel00");
    if (!lua_isnil(L, -1)) {
        vel00 = toVector3(L, -1);
    } else {
        luaL_error(L, "setVtxVelocitiesByQuad expected to receive a Vector3 for vel00.");
    }
    lua_pop(L, 1); // discard item
    lua_getfield(L, 1, "vel10");
    if (!lua_isnil(L, -1)) {
        vel10 = toVector3(L, -1);
    } else {
        luaL_error(L, "setVtxVelocitiesByQuad expected to receive a Vector3 for vel10.");
    }
    lua_pop(L, 1); // discard item
    lua_getfield(L, 1, "vel11");
    if (!lua_isnil(L, -1)) {
        vel11 = toVector3(L, -1);
    } else {
        luaL_error(L, "setVtxVelocitiesByQuad expected to receive a Vector3 for vel11.");
    }
    lua_pop(L, 1); // discard item
    lua_getfield(L, 1, "vel01");
    if (!lua_isnil(L, -1)) {
        vel01 = toVector3(L, -1);
    } else {
        luaL_error(L, "setVtxVelocitiesByQuad expected to receive a Vector3 for vel01.");
    }
    lua_pop(L, 1); // discard item
    //
    if (blk.myConfig.dimensions == 2) {
        foreach (vtx; blk.vertices) {
            // get position of current point
            auto pos = vtx.pos[0];
            // Find the normalized barycentric coordinates for position within the quad
            // and use those coordinates as weights to interpolate the corner velocity values.
            number[4] bcc;
            try {
                bcc = barycentricCoords(pos, p00, p10, p11, p01);
                vtx.vel[0].set(vel00); vtx.vel[0].scale(bcc[0]);
                vtx.vel[0].add(vel10, bcc[1]);
                vtx.vel[0].add(vel11, bcc[2]);
                vtx.vel[0].add(vel01, bcc[3]);
            } catch (GeometryException e) {
                writeln("GeometryException caught: %s", e.msg);
                writeln("Vertex index: ", vtx.id, " pos: ", pos, "Quad-corners: ", p00, p10, p11, p01);
                luaL_error(L, "Barycentric Calculation failed in luafn: setVtxVelocitiesByQuad()\n");
            }
        } // end loop vtx
    } else {
        // dimensions==3
        luaL_error(L, "3D velocity interpolation not yet implemented: setVtxVelocitiesByQuad()\n");
    }
    // In case, the user gave use more return values than
    // we used, just set the lua stack to empty and let
    // the lua garbage collector do its thing.
    lua_settop(L, 0);
    return 0;
} // end luafn_setVtxVelocitiesByQuad()

/**
 * Sets the velocity of vertices in a block based on
 * specified corner velocities. The velocity of any cell
 * is estimated using interpolation based on cell indices.
 * This should only be used for blocks with regular spacing.
 * On clustered grids deformation of the mesh occurs.
 *
 *   p3-----p2
 *   |      |
 *   |      |
 *   p0-----p1
 *
 * This function can be called for structured
 * grids only. The following calls are allowed:
 *
 * setVtxVelocitiesByCornersReg(blkId, p0vel, p1vel, p2vel, p3vel)
 *   Sets the velocity vectors for block with corner velocities
 *   specified by four corner velocities. This works for both
 *   2-D and 3- meshes. In 3-D a uniform velocity is applied
 *   in k direction.
 *
 * setVtxVelocitiesByCornersReg(blkId, p0vel, p1vel, p2vel, p3vel,
 *                                     p4vel, p5vel, p6vel, p7vel)
 *   As above but suitable for 3-D meshes with eight specified
 *   velocities.
 */
extern(C) int luafn_setVtxVelocitiesByCornersReg(lua_State* L)
{
    // Expect five/nine arguments: 1. a block id
    //                             2-5. corner velocities for 2-D motion
    //                             6-9. corner velocities for full 3-D motion
    //                                  (optional)
    int narg = lua_gettop(L);
    double u, v;
    auto blkId = lua_tointeger(L, 1);
    Vector3 velw, vele, veln, vels, vel;
    auto blk = cast(SFluidBlock) globalBlocks[blkId];
    if (!canFind(GlobalConfig.localFluidBlockIds, blkId)) {
        string msg = format("Block id %d is not local to process.", blkId);
        luaL_error(L, msg.toStringz);
    }
    // get corner velocities
    Vector3 p00vel = toVector3(L, 2);
    Vector3 p10vel = toVector3(L, 3);
    Vector3 p11vel = toVector3(L, 4);
    Vector3 p01vel = toVector3(L, 5);

    @nogc
    void setAsWeightedSum(ref Vector3 result,
                          double w0, Vector3 v0,
                          double w1, Vector3 v1)
    {
        result.set(v0); result.scale(w0);
        result.add(v1, w1);
    }

    if (narg == 5) {
        if (blk.myConfig.dimensions == 2) {
            // deal with 2-D meshes
            size_t k = 0;
            foreach (j; 0 .. blk.njv) {
                // find velocity along west and east edge
                v = to!double(j) / to!double(blk.njv - 1);
                setAsWeightedSum(velw, v, p01vel, 1-v, p00vel);
                setAsWeightedSum(vele, v, p11vel, 1-v, p10vel);
                foreach (i; 0 .. blk.niv) {
                    // interpolate in i direction
                    u = to!double(i) / to!double(blk.niv - 1);
                    setAsWeightedSum(vel, u, vele, 1-u, velw);
                    blk.get_vtx(i,j,k).vel[0].set(vel);
                }
            }
        } else { // deal with 3-D meshes (assume constant properties wrt k index)
            foreach (j; 0 .. blk.njv) {
                // find velocity along west and east edge
                v = to!double(j) / to!double(blk.njv - 1);
                setAsWeightedSum(velw, v, p01vel, 1-v, p00vel);
                setAsWeightedSum(vele, v, p11vel, 1-v, p10vel);
                foreach (i; 0 .. blk.niv) {
                    // interpolate in i direction
                    u = to!double(i) / to!double(blk.niv - 1);
                    setAsWeightedSum(vel, u, vele, 1-u, velw);
                    foreach (k; 0 .. blk.nkv) {
                        blk.get_vtx(i,j,k).vel[0].set(vel);
                    }
                }
            }
        }
    } else if (narg == 9) {
        // assume all blocks are 3-D
        writeln("setVtxVelocitiesByCorners not verified for 3-D.
                Proceed at own peril. See /src/eilmer/grid_motion.d");
        double w;
        Vector3 velwt, velet, velt;
        // get corner velocities
        Vector3 p001vel = toVector3(L, 6);
        Vector3 p101vel = toVector3(L, 7);
        Vector3 p111vel = toVector3(L, 8);
        Vector3 p011vel = toVector3(L, 9);
        foreach (j; 0 .. blk.njv) {
            // find velocity along west and east edge (four times)
            v = to!double(j) / to!double(blk.njv - 1);
            setAsWeightedSum(velw, v, p01vel, 1-v, p00vel);
            setAsWeightedSum(vele, v, p11vel, 1-v, p10vel);
            setAsWeightedSum(velwt, v, p011vel, 1-v, p001vel);
            setAsWeightedSum(velet, v, p111vel, 1-v, p101vel);
            foreach (i; 0 .. blk.niv) {
                // interpolate in i direction (twice)
                u = to!double(i) / to!double(blk.niv - 1);
                setAsWeightedSum(vel, u, vele, 1-u, velw);
                setAsWeightedSum(velt, u, velet, 1-u, velwt);
                // set velocity by interpolating in k.
                foreach (k; 0 .. blk.nkv) {
                    w = to!double(k) / to!double(blk.nkv - 1);
                    setAsWeightedSum(blk.get_vtx(i,j,k).vel[0], w, velt, 1-w, vel);
                }
            }
        }
    } else {
        string errMsg = "ERROR: Wrong number of arguments passed to luafn: setVtxVelocitiesByCornersReg()\n";
        luaL_error(L, errMsg.toStringz);
    }
    // In case, the user gave use more return values than
    // we used, just set the lua stack to empty and let
    // the lua garbage collector do its thing.
    lua_settop(L, 0);
    return 0;
} // end luafn_setVtxVelocitiesByCornersReg()

/**
 * Sets the velocity of an individual vertex.
 *
 * This function can be called for structured
 * or unstructured grids. We'll determine what
 * type grid is meant by the number of arguments
 * supplied. The following calls are allowed:
 *
 * setVtxVelocity(vel, blkId, vtxId)
 *   Sets the velocity vector for vertex vtxId in
 *   block blkId. This works for both structured
 *   and unstructured grids.
 *
 * setVtxVelocity(vel, blkId, i, j)
 *   Sets the velocity vector for vertex "i,j" in
 *   block blkId in a two-dimensional structured grid.
 *
 * setVtxVelocity(vel, blkId, i, j, k)
 *   Set the velocity vector for vertex "i,j,k" in
 *   block blkId in a three-dimensional structured grid.
 */
extern(C) int luafn_setVtxVelocity(lua_State* L)
{
    int narg = lua_gettop(L);
    auto vel = toVector3(L, 1);
    auto blkId = lua_tointeger(L, 2);
    if (!canFind(GlobalConfig.localFluidBlockIds, blkId)) {
        string msg = format("Block id %d is not local to process.", blkId);
        luaL_error(L, msg.toStringz);
    }

    if (narg == 3) {
        auto vtxId = lua_tointeger(L, 3);
        auto ublk = cast(UFluidBlock) globalBlocks[blkId];
        if (ublk) {
            try {
                ublk.vertices[vtxId].vel[0].set(vel);
            } catch (Exception e) {
                string msg = format("Failed to locate vertex[%d] in block %d.", vtxId, blkId);
                luaL_error(L, msg.toStringz);
            }
        } else {
            string msg = "Oops...";
            msg ~= " You have asked for an i-index vertex in a structured-grid block.";
            luaL_error(L, msg.toStringz);
        }
    } else if (narg == 4) {
        auto i = lua_tointeger(L, 3);
        auto j = lua_tointeger(L, 4);
        auto sblk = cast(SFluidBlock) globalBlocks[blkId];
        if (sblk) {
            try {
                sblk.get_vtx(i,j).vel[0].set(vel);
            } catch (Exception e) {
                string msg = format("Failed to locate vertex[%d,%d] in block %d.", i, j, blkId);
                luaL_error(L, msg.toStringz);
            }
        } else {
            string msg = "Oops...";
            msg ~= " You have asked for an ij-index vertex in an unstructured-grid block.";
            luaL_error(L, msg.toStringz);
        }
    } else if (narg >= 5) {
        auto i = lua_tointeger(L, 3);
        auto j = lua_tointeger(L, 4);
        auto k = lua_tointeger(L, 5);
        auto sblk = cast(SFluidBlock) globalBlocks[blkId];
        if (sblk) {
            try {
                sblk.get_vtx(i,j,k).vel[0].set(vel);
            } catch (Exception e) {
                string msg = format("Failed to locate vertex[%d,%d,%d] in block %d.", i, j, k, blkId);
                luaL_error(L, msg.toStringz);
            }
        } else {
            string msg = "Oops...";
            msg ~= " You have asked for an ijk-index vertex in an unstructured-grid block.";
            luaL_error(L, msg.toStringz);
        }
    } else {
        string errMsg = "ERROR: Too few arguments passed to luafn: setVtxVelocity()\n";
        luaL_error(L, errMsg.toStringz);
    }
    lua_settop(L, 0);
    return 0;
} // end luafn_setVtxVelocity()

/**
 * Sets the velocity components of an individual vertex.
 *
 * This function can be called for structured
 * or unstructured grids. We'll determine what
 * type grid is meant by the number of arguments
 * supplied. The following calls are allowed:
 *
 * setVtxVelocityXYZ(velx, vely, velz, blkId, vtxId)
 *   Sets the velocity vector for vertex vtxId in
 *   block blkId. This works for both structured
 *   and unstructured grids.
 *
 * setVtxVelocityXYZ(velx, vely, velz, blkId, i, j)
 *   Sets the velocity vector for vertex "i,j" in
 *   block blkId in a two-dimensional structured grid.
 *
 * setVtxVelocityXYZ(velx, vely, velz, blkId, i, j, k)
 *   Set the velocity vector for vertex "i,j,k" in
 *   block blkId in a three-dimensional structured grid.
 */
extern(C) int luafn_setVtxVelocityXYZ(lua_State* L)
{
    int narg = lua_gettop(L);
    double velx = lua_tonumber(L, 1);
    double vely = lua_tonumber(L, 2);
    double velz = lua_tonumber(L, 3);
    auto blkId = lua_tointeger(L, 4);
    if (!canFind(GlobalConfig.localFluidBlockIds, blkId)) {
        string msg = format("Block id %d is not local to process.", blkId);
        luaL_error(L, msg.toStringz);
    }

    if (narg == 5) {
        auto vtxId = lua_tointeger(L, 5);
        auto ublk = cast(UFluidBlock) globalBlocks[blkId];
        if (ublk) {
            try {
                ublk.vertices[vtxId].vel[0].set(velx, vely, velz);
            } catch (Exception e) {
                string msg = format("Failed to locate vertex[%d] in block %d.", vtxId, blkId);
                luaL_error(L, msg.toStringz);
            }
        } else {
            string msg = "Oops...";
            msg ~= " You have asked for an i-index vertex in a structured-grid block.";
            luaL_error(L, msg.toStringz);
        }
    } else if (narg == 6) {
        auto i = lua_tointeger(L, 5);
        auto j = lua_tointeger(L, 6);
        auto sblk = cast(SFluidBlock) globalBlocks[blkId];
        if (sblk) {
            try {
                sblk.get_vtx(i,j).vel[0].set(velx, vely, velz);
            } catch (Exception e) {
                string msg = format("Failed to locate vertex[%d,%d] in block %d.", i, j, blkId);
                luaL_error(L, msg.toStringz);
            }
        } else {
            string msg = "Oops...";
            msg ~= " You have asked for an ij-index vertex in an unstructured-grid block.";
            luaL_error(L, msg.toStringz);
        }
    } else if (narg >= 7) {
        auto i = lua_tointeger(L, 5);
        auto j = lua_tointeger(L, 6);
        auto k = lua_tointeger(L, 7);
        auto sblk = cast(SFluidBlock) globalBlocks[blkId];
        if (sblk) {
            try {
                sblk.get_vtx(i,j,k).vel[0].set(velx, vely, velz);
            } catch (Exception e) {
                string msg = format("Failed to locate vertex[%d,%d,%d] in block %d.", i, j, k, blkId);
                luaL_error(L, msg.toStringz);
            }
        } else {
            string msg = "Oops...";
            msg ~= " You have asked for an ijk-index vertex in an unstructured-grid block.";
            luaL_error(L, msg.toStringz);
        }
    } else {
        string errMsg = "ERROR: Too few arguments passed to luafn: setVtxVelocityXYZ()\n";
        luaL_error(L, errMsg.toStringz);
    }
    lua_settop(L, 0);
    return 0;
} // end luafn_setVtxVelocityXYZ()

void assign_vertex_velocities_via_udf(double sim_time, double dt)
{
    auto L = GlobalConfig.master_lua_State;
    if (GlobalConfig.user_pad_length > 0) {
        push_array_to_Lua(L, GlobalConfig.userPad, "userPad");
    }
    // After the call, do not copy userPad back from the Lua interpreter.
    // This makes it effectively read-only.
    //
    lua_getglobal(L, "assignVtxVelocities");
    lua_pushnumber(L, sim_time);
    lua_pushnumber(L, dt);
    int number_args = 2;
    int number_results = 0;
    //
    if ( lua_pcall(L, number_args, number_results, 0) != 0 ) {
        string errMsg = "ERROR: while running user-defined function assignVtxVelocities()\n";
        errMsg ~= to!string(lua_tostring(L, -1));
        throw new FlowSolverException(errMsg);
    }
    lua_settop(L, 0); // clear stack
} // end assign_vertex_velocities_via_udf()

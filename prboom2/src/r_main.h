/* Emacs style mode select   -*- C -*-
 *-----------------------------------------------------------------------------
 *
 *
 *  PrBoom: a Doom port merged with LxDoom and LSDLDoom
 *  based on BOOM, a modified and improved DOOM engine
 *  Copyright (C) 1999 by
 *  id Software, Chi Hoang, Lee Killough, Jim Flynn, Rand Phares, Ty Halderman
 *  Copyright (C) 1999-2000 by
 *  Jess Haas, Nicolas Kalkhof, Colin Phipps, Florian Schulze
 *  Copyright 2005, 2006 by
 *  Florian Schulze, Colin Phipps, Neil Stevens, Andrey Budko
 *
 *  This program is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU General Public License
 *  as published by the Free Software Foundation; either version 2
 *  of the License, or (at your option) any later version.
 *
 *  This program is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with this program; if not, write to the Free Software
 *  Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA
 *  02111-1307, USA.
 *
 * DESCRIPTION:
 *      Renderer main interface.
 *
 *-----------------------------------------------------------------------------*/

#ifndef __R_MAIN__
#define __R_MAIN__

#include "d_player.h"
#include "r_data.h"

extern int r_frame_count;

//
// POV related.
//

extern fixed_t  viewcos;
extern fixed_t  viewsin;
extern fixed_t  viewtancos;
extern fixed_t  viewtansin;
extern int      viewwidth;
extern int      viewheight;
extern int      centerx;
extern int      centery;
extern fixed_t  globaluclip;
extern fixed_t  globaldclip;
extern fixed_t  centerxfrac;
extern fixed_t  centeryfrac;
extern fixed_t  yaspectmul;
extern fixed_t  viewheightfrac; //e6y: for correct cliping of things
extern fixed_t  projection;
extern fixed_t  skyiscale;
// e6y: wide-res
extern int wide_centerx;
#define RMUL (1.6f/1.333333f)

// proff 11/06/98: Added for high-res
extern fixed_t  projectiony;
extern int      validcount;
extern int      validcount2;
// e6y: Added for more precise flats drawing
extern fixed_t viewfocratio;

//
// Lighting LUT.
// Used for z-depth cuing per column/row,
//  and other lighting effects (sector ambient, flash).
//

// Lighting constants.

// SoM: I am really speechless at this... just... why?
// Lighting in doom was originally clamped off to just 16 brightness levels
// for sector lighting. Simply changing the constants is enough to change this
// it seriously bottles the mind why this wasn't done in doom from the start
// except for maybe memory usage savings.
#define LIGHTLEVELS_MAX   32

extern int LIGHTSEGSHIFT;
extern int LIGHTBRIGHT;
extern int LIGHTLEVELS;

#define MAXLIGHTSCALE     48
#define LIGHTSCALESHIFT   12
#define MAXLIGHTZ        128
#define LIGHTZSHIFT       20

// killough 3/20/98: Allow colormaps to be dynamic (e.g. underwater)
extern const lighttable_t *(*scalelight)[MAXLIGHTSCALE];
extern const lighttable_t *(*c_zlight)[LIGHTLEVELS_MAX][MAXLIGHTZ];
extern const lighttable_t *(*zlight)[MAXLIGHTZ];
extern const lighttable_t *fullcolormap;
extern int numcolormaps;    // killough 4/4/98: dynamic number of maps
extern const lighttable_t **colormaps;
// killough 3/20/98, 4/4/98: end dynamic colormaps

extern const byte* colormap_lump;

//e6y: for Boom colormaps in OpenGL mode
extern dboolean use_boom_cm;
extern int boom_cm;         // current colormap
extern int frame_fixedcolormap;

extern int          extralight;
extern const lighttable_t *fixedcolormap;

// Number of diminishing brightness levels.
// There a 0-31, i.e. 32 LUT in the COLORMAP lump.

#define NUMCOLORMAPS 32
// Index of the special effects (INVUL inverse) map.
#define INVERSECOLORMAP 32

//
// Utility functions.
//

PUREFUNC int R_CompatiblePointOnSide(fixed_t x, fixed_t y, const node_t *node);
PUREFUNC int R_ZDoomPointOnSide(fixed_t x, fixed_t y, const node_t *node);
extern int (*R_PointOnSide)(fixed_t x, fixed_t y, const node_t *node);

PUREFUNC int R_CompatiblePointOnSegSide(fixed_t x, fixed_t y, const seg_t *line);
PUREFUNC int R_ZDoomPointOnSegSide(fixed_t x, fixed_t y, const seg_t *line);
extern int (*R_PointOnSegSide)(fixed_t x, fixed_t y, const seg_t *line);

angle_t R_PointToAngle2(fixed_t x1, fixed_t y1, fixed_t x, fixed_t y);
subsector_t *R_PointInSubsector(fixed_t x, fixed_t y);
sector_t *R_PointInSector(fixed_t x, fixed_t y);
void R_SectorCenter(fixed_t *x, fixed_t *y, sector_t *sec);
void R_LineCenter(fixed_t *x, fixed_t *y, line_t *line);

//e6y: made more precise
angle_t R_PointToAngleEx(fixed_t x, fixed_t y);
angle_t R_PointToAngleEx2(fixed_t x1, fixed_t y1, fixed_t x, fixed_t y);
angle_t R_PointToPseudoAngle(fixed_t x, fixed_t y);

//
// REFRESH - the actual rendering functions.
//

void R_ResetColorMap(void);
// How a frame is composed around the view. The frame path fills in what it
// knows and the renderer answers with how it wants the frame put together.
//
// This is one call rather than a set of flags on the interface deliberately. A
// flag left out of an initialiser is silently false, which is a behaviour
// change no compiler and possibly no test will catch; a method left out is a
// null pointer, which fails on the first frame. It also keeps each decision
// next to the reasoning for it, instead of splitting the policy between the
// renderer and the caller that combines it with global state.
typedef struct {
  // What the frame path knows.
  dboolean in_level;
  dboolean automap;
  dboolean border_invalidated;  // something has made the view border stale
  dboolean can_letterbox;       // the window has area outside the scene to clear

  // What the renderer decides.
  dboolean letterbox_clear;
  dboolean draw_border;
  dboolean border_after_view;
  dboolean record_ui;
} frame_plan_t;

// How a renderer draws the 3D view, in the two halves the frame is split into.
// build_view runs on the main thread and may not issue any GL; draw_view runs
// wherever the GL context lives, which may be the render thread.
//
// The split is what the two renderers disagree about. OpenGL walks the BSP into
// a draw list in the build half and turns that list into draw calls in the draw
// half. The software renderer rasterises straight into the screen buffer as it
// walks, so all of its work is in the build half and its draw half is empty.
typedef struct {
  void (*build_view)(player_t *player);
  void (*draw_view)(player_t *player);

  // Start-of-frame setup, before the BSP walk.
  void (*init_scene)(void);

  // Recomputes anything derived from the view pitch. The software renderer
  // rebuilds its projection tables; GL carries pitch in the view matrix and so
  // has nothing to do.
  void (*setup_freelook)(void);

  // Per-level setup. The GL renderer builds vertex buffers and texture state
  // for the map; the software renderer has nothing to prepare.
  void (*preprocess_level)(void);

  // Called when the view size changes, to update anything derived from it.
  void (*set_viewport_params)(void);

  // Wrapped around each frame of a screen wipe. GL renders the melt through an
  // offscreen texture so it runs at scene resolution rather than window
  // resolution.
  void (*begin_wipe_frame)(void);
  void (*end_wipe_frame)(void);

  // Builds the view matrix, if this renderer needs one.
  void (*setup_view_matrix)(void);

  // Decides how the frame is composed around the view. See frame_plan_t.
  void (*plan_frame)(frame_plan_t *plan);
} view_renderer_t;

const view_renderer_t *R_ViewRenderer(void);

// The two halves of the frame. R_BuildPlayerView issues no GL and stays on the
// main thread; R_DrawPlayerView is GL only and runs wherever the context lives.
void R_BuildPlayerView(player_t *player);
void R_DrawPlayerView(player_t *player);
void R_Init(void);                           // Called by startup code.
void R_SetViewSize(void);              // Called by M_Responder.
void R_ExecuteSetViewSize(void);             // cph - called by D_Display to complete a view resize
dboolean R_FullView(void);
dboolean R_PartialView(void);
dboolean R_StatusBarVisible(void);

#define Pi 3.14159265358979323846f
#define DEG2RAD(a) ((a * Pi) / 180.0f)
#define RAD2DEG(a) ((a / Pi) * 180.0f)
#define MAP_COEFF 128.0f
#define MAP_SCALE (MAP_COEFF*(float)FRACUNIT)

extern int viewport[4];
extern float modelMatrix[16];
extern float projMatrix[16];
int R_Project(float objx, float objy, float objz, float *winx, float *winy, float *winz);

#endif

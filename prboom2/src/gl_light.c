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
 *
 *---------------------------------------------------------------------
 */

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <SDL.h>

#include <math.h>

#include "doomstat.h"
#include "lprintf.h"
#include "v_video.h"
#include "r_main.h"
#include "gl_intern.h"
#include "gl_opengl.h"
#include "e6y.h"

#include "dsda/configuration.h"

dboolean gl_ui_lightmode_indexed = false;
dboolean gl_automap_lightmode_indexed = false;
dboolean gl_menu_lightmode_indexed = false;

static float lighttable[5][256];

/*
 * lookuptable for lightvalues
 * calculated as follow:
 * floatlight=(1.0-exp((light^3)*gamma)) / (1.0-exp(1.0*gamma));
 * gamma=-0,2;-2,0;-4,0;-6,0;-8,0
 * light=0,0 .. 1,0
 */
void gld_InitLightTable(void)
{
  int i, g;
  float gamma[5] = {-0.2f, -2.0f, -4.0f, -6.0f, -8.0f};

  for (g = 0; g < 5; g++)
  {
    for (i = 0; i < 256; i++)
    {
      lighttable[g][i] = (float)((1.0f - exp(pow(i / 255.0f, 3) * gamma[g])) / (1.0f - exp(1.0f * gamma[g])));
    }
  }
}

float gld_Calc2DLightLevel(int lightlevel)
{
  return lighttable[usegamma][BETWEEN(0, 255, lightlevel)];
}

float gld_CalcLightLevel(int lightlevel)
{
  int light;

  light = BETWEEN(0, 255, lightlevel);

  return (float)light/255.0f;
}

// The light the shader should see for a given sector light level. An active
// fixed colormap (invulnerability, light amp) means full bright regardless.
float gld_EffectiveLight(float light)
{
  player_t *player = &players[displayplayer];

  return player->fixedcolormap ? 1.0f : light;
}

void gld_StaticLightAlpha(float light, float alpha)
{
  glColor4f(1.0f, 1.0f, 1.0f, alpha);

  // Sets the *current* value of the unit 1 texture coordinate, which gls_v
  // reads as the light level. It applies to every vertex of the following
  // draws until changed, because these callers leave the unit 1 array
  // disabled; the wall batcher enables that array instead and supplies a
  // value per vertex.
  GLEXT_glMultiTexCoord2fARB(GL_TEXTURE1_ARB, gld_EffectiveLight(light), 0.0f);
}

// [XA] return amount of light to add from the player's gun flash.
int gld_GetGunFlashLight(void)
{
  return (extralight << 4);
}

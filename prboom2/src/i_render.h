/* Emacs style mode select   -*- C -*-
 *-----------------------------------------------------------------------------
 *
 *  Copyright (C) 2026 by Alessio Galdy
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
 *      The render thread.
 *
 *-----------------------------------------------------------------------------*/

#ifndef __I_RENDER__
#define __I_RENDER__

#include "SDL.h"

#include "doomtype.h"

/* The render thread.
 *
 * In OpenGL mode the GL context lives on a dedicated thread; I_RenderDispatch
 * runs a job there and I_RenderFlush waits for it. Outside OpenGL mode, and if
 * the thread could not be created, jobs run inline and the rest are no-ops --
 * so callers never need to ask whether the thread exists.
 *
 * I_GLAcquire / I_GLRelease borrow the context back onto the main thread. Every
 * GL call made outside a dispatched job must sit between them. They are for
 * rare work only -- level load, texture flushes, video mode changes -- because
 * detaching the context per frame changes rendered output on macOS.
 */

/* Registered by the video code when the window and context are created. */
void I_RenderSetTarget(SDL_Window *window, SDL_GLContext context);

void I_StartRenderThread(void);
void I_StopRenderThread(void);
void I_RestartRenderThread(void);
dboolean I_RenderThreadActive(void);

void I_RenderDispatch(void (*fn)(void));
void I_RenderFlush(void);

void I_GLAcquire(void);
void I_GLRelease(void);

#endif

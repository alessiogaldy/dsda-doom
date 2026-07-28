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
 *      The render thread: runs the frame's GL on a thread that owns the
 *      context, so the main thread can simulate the next tic meanwhile.
 *
 *-----------------------------------------------------------------------------*/

#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include "SDL.h"

#include "doomtype.h"
#include "lprintf.h"
#include "v_video.h"
#include "i_system.h"
#include "i_render.h"

// The window and context this thread drives. Registered by the video code when
// it creates them, so nothing here has to reach into how they were made.
static SDL_Window *render_window;
static SDL_GLContext render_context;

void I_RenderSetTarget(SDL_Window *window, SDL_GLContext context)
{
  render_window = window;
  render_context = context;
}

//
// A GL context may be current on one thread at a time, so moving any drawing
// off the main thread means moving all of it. The context is handed to a
// dedicated thread that does nothing else, and the main thread borrows it back
// for the rare operations that touch GL outside a frame -- level load, texture
// flushes, video mode changes.
//
// The main thread submits a job and, at present, immediately waits for it. That
// wait is what a later change removes: once the frame's GL work no longer reads
// anything the simulation is concurrently writing, the main thread can run the
// next tic while this one draws.

static SDL_Thread *render_thread;
static SDL_sem *render_start;         // main -> render: a job is queued
static SDL_sem *render_finished;      // render -> main: the job is done
static void (*render_job)(void);
static dboolean render_stopping;

// Main-thread only. Jobs posted but not yet waited for; never more than a
// handful, but a count rather than a flag keeps I_RenderFlush idempotent.
static int render_pending;
static int gl_borrow_depth;
static dboolean render_thread_wanted;
static SDL_threadID render_thread_id;

// True when the caller already has the context, so borrowing it is a no-op.
// The bracket sits inside the GL functions rather than at their call sites,
// which means it is reached both from the main thread and from inside a
// dispatched job; without this the latter would post a job to itself.
static dboolean I_OnRenderThread(void)
{
  return render_thread && SDL_ThreadID() == render_thread_id;
}

static void I_RenderTakeContext(void)
{
  SDL_GL_MakeCurrent(render_window, render_context);
}

static void I_RenderDropContext(void)
{
  SDL_GL_MakeCurrent(render_window, NULL);
}

static int I_RenderThread(void *unused)
{
  render_thread_id = SDL_ThreadID();

  for (;;)
  {
    SDL_SemWait(render_start);

    if (render_stopping)
      break;

    render_job();
    SDL_SemPost(render_finished);
  }

  SDL_SemPost(render_finished);
  return 0;
}

// Post a job without waiting for it. Any previously posted job is drained
// first, so at most one is ever in flight.
static void I_RenderPost(void (*fn)(void))
{
  I_RenderFlush();
  render_job = fn;
  render_pending++;
  SDL_SemPost(render_start);
}

void I_RenderFlush(void)
{
  while (render_pending > 0)
  {
    SDL_SemWait(render_finished);
    render_pending--;
  }
}

void I_RenderDispatch(void (*fn)(void))
{
  if (!render_thread)
  {
    fn();
    return;
  }

  I_RenderPost(fn);
}

// Take the context back onto the main thread for a non-frame GL operation.
// Nests, because these call sites reach each other (a video mode change
// reloads the level, which preprocesses textures).
void I_GLAcquire(void)
{
  if (!render_thread || I_OnRenderThread() || gl_borrow_depth++)
    return;

  I_RenderPost(I_RenderDropContext);
  I_RenderFlush();
  SDL_GL_MakeCurrent(render_window, render_context);
}

void I_GLRelease(void)
{
  if (!render_thread || I_OnRenderThread() || --gl_borrow_depth)
    return;

  SDL_GL_MakeCurrent(render_window, NULL);
  I_RenderPost(I_RenderTakeContext);
  I_RenderFlush();
}

dboolean I_RenderThreadActive(void)
{
  return render_thread != NULL;
}

void I_StartRenderThread(void)
{
  if (render_thread || !V_IsOpenGLMode())
    return;

  render_thread_wanted = true;

  // Moving or resizing the window marks the GL context dirty, and the next
  // swap then updates it. [NSOpenGLContext update] has to run on the main
  // thread, so SDL dispatches it there -- synchronously by default. Off the
  // main thread that deadlocks us outright: the render thread blocks in
  // dispatch_sync waiting for the main queue while the main thread is blocked
  // in I_RenderFlush waiting for that very swap to finish. Neither ever wakes.
  //
  // This hint exists for exactly this case; it makes the dispatch async, so the
  // update lands on the main thread a frame later instead of holding the render
  // thread hostage. The cost is that a window drag can smear for a frame, which
  // is the right trade against a hang.
  //
  // Forced, because a plain SDL_SetHint loses to the environment: SDL_GetHint
  // returns the environment value unless the stored hint was set at override
  // priority. Someone with SDL_HINT_MAC_OPENGL_ASYNC_DISPATCH=0 exported would
  // otherwise get the deadlock back, and nothing about the freeze would point
  // at their environment.
  SDL_SetHintWithPriority(SDL_HINT_MAC_OPENGL_ASYNC_DISPATCH, "1", SDL_HINT_OVERRIDE);

  render_start = SDL_CreateSemaphore(0);
  render_finished = SDL_CreateSemaphore(0);

  if (!render_start || !render_finished)
    I_Error("I_StartRenderThread: could not create semaphores: %s", SDL_GetError());

  render_thread = SDL_CreateThread(I_RenderThread, "dsda-render", NULL);

  if (!render_thread)
  {
    // Not fatal: without the thread every job runs inline on the main thread,
    // which is what the build did before this existed.
    lprintf(LO_WARN, "I_StartRenderThread: %s; drawing on the main thread\n",
            SDL_GetError());
    return;
  }

  // Hand the context over for good. It must not come back per frame:
  // detaching a context on macOS lets the window server rotate the drawable,
  // and gld_Clear only clears colour when it has to, so frames that inherit
  // untouched back buffer pixels come out different. Verified -- a
  // MakeCurrent(NULL)/MakeCurrent(ctx) pair around each swap moves five of the
  // fourteen frame hashes whether or not a second thread is involved.
  SDL_GL_MakeCurrent(render_window, NULL);
  I_RenderPost(I_RenderTakeContext);
  I_RenderFlush();
}

// I_UpdateVideoMode also runs at startup, long before the main loop asks for a
// thread, so restarting is conditional on the thread having been wanted.
void I_RestartRenderThread(void)
{
  if (render_thread_wanted)
    I_StartRenderThread();
}

void I_StopRenderThread(void)
{
  if (!render_thread)
    return;

  // Reached from the error path, which can fire inside a job. Waiting here
  // would be the render thread waiting on itself, turning any crash into a
  // hang; leave the thread alone and let exit tear it down.
  if (I_OnRenderThread())
    return;

  I_RenderFlush();
  I_RenderPost(I_RenderDropContext);
  I_RenderFlush();

  render_stopping = true;
  SDL_SemPost(render_start);
  SDL_SemWait(render_finished);
  SDL_WaitThread(render_thread, NULL);
  render_thread = NULL;

  SDL_DestroySemaphore(render_start);
  SDL_DestroySemaphore(render_finished);
  render_start = render_finished = NULL;
  render_stopping = false;

  SDL_GL_MakeCurrent(render_window, render_context);
}


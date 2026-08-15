//
// Copyright(C) 2022 by Ryan Krafnick
//
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// DESCRIPTION:
//	DSDA Game Controller
//

#include "SDL.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "d_event.h"
#include "d_main.h"
#include "i_system.h"
#include "lprintf.h"
#include "m_file.h"

#include "dsda/args.h"
#include "dsda/configuration.h"

#include "game_controller.h"

static int use_game_controller;
static SDL_GameController* game_controller;
static SDL_JoystickID game_controller_instance = -1;
static char game_controller_status[256] = "not initialized";
static char game_controller_input[256] = "none";
static unsigned long game_controller_input_events;
static int game_controller_axis_state[SDL_CONTROLLER_AXIS_MAX];

static const char* dsda_ControllerText(const char* text) {
  return text && *text ? text : "<none>";
}

static void dsda_SetGameControllerStatus(const char* status) {
  snprintf(game_controller_status, sizeof(game_controller_status), "%s", status);
}

static void dsda_WriteGameControllerEnvironment(FILE* file, const char* name) {
  const char* value = SDL_getenv(name);

  fprintf(file, "environment.%s: %s\n", name,
          value && *value ? value : "<unset>");
}

static void dsda_WriteGameControllerStatus(const char* event) {
  const char* config_dir = I_ConfigDir();
  const char* video_driver = SDL_GetCurrentVideoDriver();
  const char* audio_driver = SDL_GetCurrentAudioDriver();
  SDL_version runtime_version;
  Uint32 initialized;
  time_t now;
  struct tm* local_time;
  char timestamp[64] = "unknown";
  char* status_path;
  FILE* file;
  size_t status_path_size;
  int joystick_count;
  int device_index;

  status_path_size = strlen(config_dir) + sizeof("/controller-status.txt");
  status_path = malloc(status_path_size);
  if (!status_path)
    return;

  snprintf(status_path, status_path_size, "%s/controller-status.txt", config_dir);
  file = M_OpenFile(status_path, "w");
  if (!file) {
    lprintf(LO_ERROR, "Could not write controller status to %s\n", status_path);
    free(status_path);
    return;
  }

  now = time(NULL);
  local_time = localtime(&now);
  if (local_time)
    strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S %z", local_time);

  SDL_GetVersion(&runtime_version);
  initialized = SDL_WasInit(0);

  fprintf(file, "DSDA-Doom controller status\n");
  fprintf(file, "generated: %s\n", timestamp);
  fprintf(file, "status_file: %s\n", status_path);
  fprintf(file, "event: %s\n", dsda_ControllerText(event));
  fprintf(file, "status: %s\n", game_controller_status);
  fprintf(file, "configuration.use_game_controller: %d\n",
          dsda_IntConfig(dsda_config_use_game_controller));
  fprintf(file, "command_line.nojoy: %s\n",
          dsda_Flag(dsda_arg_nojoy) ? "yes" : "no");
  fprintf(file, "controller.enabled: %s\n", use_game_controller ? "yes" : "no");
  fprintf(file, "input.event_count: %lu\n", game_controller_input_events);
  fprintf(file, "input.last_event: %s\n", game_controller_input);
  fprintf(file, "\n");

  fprintf(file, "SDL.compiled_version: %d.%d.%d\n",
          SDL_MAJOR_VERSION, SDL_MINOR_VERSION, SDL_PATCHLEVEL);
  fprintf(file, "SDL.runtime_version: %d.%d.%d\n",
          runtime_version.major, runtime_version.minor, runtime_version.patch);
  fprintf(file, "SDL.revision: %s\n", dsda_ControllerText(SDL_GetRevision()));
  fprintf(file, "SDL.platform: %s\n", dsda_ControllerText(SDL_GetPlatform()));
  fprintf(file, "SDL.initialized_flags: 0x%08x\n", initialized);
  fprintf(file, "SDL.gamecontroller_initialized: %s\n",
          initialized & SDL_INIT_GAMECONTROLLER ? "yes" : "no");
  fprintf(file, "SDL.video_driver: %s\n", dsda_ControllerText(video_driver));
  fprintf(file, "SDL.audio_driver: %s\n", dsda_ControllerText(audio_driver));
  fprintf(file, "SDL.hint.joystick_allow_background_events: %s\n",
          dsda_ControllerText(SDL_GetHint(SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS)));
  fprintf(file, "SDL.hint.joystick_hidapi: %s\n",
          dsda_ControllerText(SDL_GetHint(SDL_HINT_JOYSTICK_HIDAPI)));
  fprintf(file, "\n");

  dsda_WriteGameControllerEnvironment(file, "SteamAppId");
  dsda_WriteGameControllerEnvironment(file, "SteamGameId");
  dsda_WriteGameControllerEnvironment(file, "SteamOverlayGameId");
  dsda_WriteGameControllerEnvironment(
    file, "SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD"
  );
  dsda_WriteGameControllerEnvironment(file, "SDL_GAMECONTROLLER_IGNORE_DEVICES");
  dsda_WriteGameControllerEnvironment(
    file, "SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT"
  );
  fprintf(file, "\n");

  if (!(initialized & SDL_INIT_JOYSTICK)) {
    fprintf(file, "joystick.count: unavailable (SDL joystick subsystem is not initialized)\n");
  }
  else {
    SDL_ClearError();
    joystick_count = SDL_NumJoysticks();
    fprintf(file, "joystick.count: %d\n", joystick_count);
    if (joystick_count < 0)
      fprintf(file, "joystick.enumeration_error: %s\n",
              dsda_ControllerText(SDL_GetError()));

    for (device_index = 0; device_index < joystick_count; ++device_index) {
      SDL_JoystickGUID guid = SDL_JoystickGetDeviceGUID(device_index);
      char guid_text[33];
      int is_controller = SDL_IsGameController(device_index);
      char* mapping = NULL;

      SDL_JoystickGetGUIDString(guid, guid_text, sizeof(guid_text));
      if (is_controller)
        mapping = SDL_GameControllerMappingForDeviceIndex(device_index);

      fprintf(file, "\n");
      fprintf(file, "joystick[%d].name: %s\n", device_index,
              dsda_ControllerText(SDL_JoystickNameForIndex(device_index)));
      fprintf(file, "joystick[%d].path: %s\n", device_index,
              dsda_ControllerText(SDL_JoystickPathForIndex(device_index)));
      fprintf(file, "joystick[%d].guid: %s\n", device_index, guid_text);
      fprintf(file, "joystick[%d].vendor: 0x%04x\n", device_index,
              SDL_JoystickGetDeviceVendor(device_index));
      fprintf(file, "joystick[%d].product: 0x%04x\n", device_index,
              SDL_JoystickGetDeviceProduct(device_index));
      fprintf(file, "joystick[%d].product_version: 0x%04x\n", device_index,
              SDL_JoystickGetDeviceProductVersion(device_index));
      fprintf(file, "joystick[%d].player_index: %d\n", device_index,
              SDL_JoystickGetDevicePlayerIndex(device_index));
      fprintf(file, "joystick[%d].is_game_controller: %s\n", device_index,
              is_controller ? "yes" : "no");
      fprintf(file, "joystick[%d].controller_name: %s\n", device_index,
              is_controller ? dsda_ControllerText(
                SDL_GameControllerNameForIndex(device_index)) : "<not a game controller>");
      fprintf(file, "joystick[%d].mapping: %s\n", device_index,
              mapping ? mapping : "<none>");

      SDL_free(mapping);
    }
  }

  fprintf(file, "\n");
  fprintf(file, "active.present: %s\n", game_controller ? "yes" : "no");
  if (game_controller) {
    int axis;
    int button;
    char* mapping = SDL_GameControllerMapping(game_controller);

    fprintf(file, "active.name: %s\n",
            dsda_ControllerText(SDL_GameControllerName(game_controller)));
    fprintf(file, "active.instance_id: %d\n", game_controller_instance);
    fprintf(file, "active.attached: %s\n",
            SDL_GameControllerGetAttached(game_controller) ? "yes" : "no");
    fprintf(file, "active.mapping: %s\n", mapping ? mapping : "<none>");
    SDL_free(mapping);

    for (axis = 0; axis < SDL_CONTROLLER_AXIS_MAX; ++axis)
      fprintf(file, "active.axis.%s: %d\n",
              dsda_ControllerText(SDL_GameControllerGetStringForAxis(axis)),
              SDL_GameControllerGetAxis(game_controller, axis));

    for (button = 0; button < SDL_CONTROLLER_BUTTON_MAX; ++button)
      fprintf(file, "active.button.%s: %d\n",
              dsda_ControllerText(SDL_GameControllerGetStringForButton(button)),
              SDL_GameControllerGetButton(game_controller, button));
  }

  fprintf(file, "SDL.last_error: %s\n", dsda_ControllerText(SDL_GetError()));
  fclose(file);
  lprintf(LO_INFO, "Controller status written to %s\n", status_path);
  free(status_path);
}

typedef struct {
  SDL_GameControllerAxis axis;
  int deadzone;
  int sensitivity;
} axis_t;

static axis_t left_analog_x = { SDL_CONTROLLER_AXIS_LEFTX };
static axis_t left_analog_y = { SDL_CONTROLLER_AXIS_LEFTY };
static axis_t right_analog_x = { SDL_CONTROLLER_AXIS_RIGHTX };
static axis_t right_analog_y = { SDL_CONTROLLER_AXIS_RIGHTY };
static axis_t left_trigger = { SDL_CONTROLLER_AXIS_TRIGGERLEFT };
static axis_t right_trigger = { SDL_CONTROLLER_AXIS_TRIGGERRIGHT };

static int swap_analogs;

static const char* button_names[] = {
  [DSDA_CONTROLLER_BUTTON_A] = "pad a",
  [DSDA_CONTROLLER_BUTTON_B] = "pad b",
  [DSDA_CONTROLLER_BUTTON_X] = "pad x",
  [DSDA_CONTROLLER_BUTTON_Y] = "pad y",
  [DSDA_CONTROLLER_BUTTON_BACK] = "pad back",
  [DSDA_CONTROLLER_BUTTON_GUIDE] = "pad guide",
  [DSDA_CONTROLLER_BUTTON_START] = "pad start",
  [DSDA_CONTROLLER_BUTTON_LEFTSTICK] = "lstick",
  [DSDA_CONTROLLER_BUTTON_RIGHTSTICK] = "rstick",
  [DSDA_CONTROLLER_BUTTON_LEFTSHOULDER] = "pad l",
  [DSDA_CONTROLLER_BUTTON_RIGHTSHOULDER] = "pad r",
  [DSDA_CONTROLLER_BUTTON_DPAD_UP] = "dpad u",
  [DSDA_CONTROLLER_BUTTON_DPAD_DOWN] = "dpad d",
  [DSDA_CONTROLLER_BUTTON_DPAD_LEFT] = "dpad l",
  [DSDA_CONTROLLER_BUTTON_DPAD_RIGHT] = "dpad r",
  [DSDA_CONTROLLER_BUTTON_MISC1] = "misc 1",
  [DSDA_CONTROLLER_BUTTON_PADDLE1] = "paddle 1",
  [DSDA_CONTROLLER_BUTTON_PADDLE2] = "paddle 2",
  [DSDA_CONTROLLER_BUTTON_PADDLE3] = "paddle 3",
  [DSDA_CONTROLLER_BUTTON_PADDLE4] = "paddle 4",
  [DSDA_CONTROLLER_BUTTON_TOUCHPAD] = "touchpad",
  [DSDA_CONTROLLER_BUTTON_TRIGGERLEFT] = "pad lt",
  [DSDA_CONTROLLER_BUTTON_TRIGGERRIGHT] = "pad rt",
};

const char* dsda_GameControllerButtonName(int button) {
  if (button >= sizeof(button_names) || !button_names[button])
    return "misc";

  return button_names[button];
}

static float dsda_AxisValue(axis_t* axis) {
  int value;

  value = SDL_GameControllerGetAxis(game_controller, axis->axis);

  // the positive axis max is 1 less
  if (value > (axis->deadzone - 1))
    value -= (axis->deadzone - 1);
  else if (value < -axis->deadzone)
    value += axis->deadzone;
  else
    value = 0;

  return (float) value * axis->sensitivity / (32768 - axis->deadzone);
}

static void dsda_PollLeftStick(void) {
  event_t ev;

  ev.type = swap_analogs ? ev_look_analog : ev_move_analog;
  ev.data1.f = dsda_AxisValue(&left_analog_x);
  ev.data2.f = -dsda_AxisValue(&left_analog_y);

  if (ev.data1.f || ev.data2.f)
    D_PostEvent(&ev);
}

static void dsda_PollRightStick(void) {
  event_t ev;

  ev.type = swap_analogs ? ev_move_analog : ev_look_analog;
  ev.data1.f = dsda_AxisValue(&right_analog_x);
  ev.data2.f = -dsda_AxisValue(&right_analog_y);

  if (ev.data1.f || ev.data2.f)
    D_PostEvent(&ev);
}

static inline int PollButton(dsda_game_controller_button_t button)
{
  // This depends on enums having same values
  return SDL_GameControllerGetButton(game_controller, (SDL_GameControllerButton) button) << button;
}

void dsda_PollGameControllerButtons(void) {
  event_t ev;
  float trigger;

  if (!game_controller)
    return;

  ev.type = ev_joystick;
  ev.data1.i = PollButton(DSDA_CONTROLLER_BUTTON_A) |
               PollButton(DSDA_CONTROLLER_BUTTON_B) |
               PollButton(DSDA_CONTROLLER_BUTTON_X) |
               PollButton(DSDA_CONTROLLER_BUTTON_Y) |
               PollButton(DSDA_CONTROLLER_BUTTON_BACK) |
               PollButton(DSDA_CONTROLLER_BUTTON_GUIDE) |
               PollButton(DSDA_CONTROLLER_BUTTON_START) |
               PollButton(DSDA_CONTROLLER_BUTTON_LEFTSTICK) |
               PollButton(DSDA_CONTROLLER_BUTTON_RIGHTSTICK) |
               PollButton(DSDA_CONTROLLER_BUTTON_LEFTSHOULDER) |
               PollButton(DSDA_CONTROLLER_BUTTON_RIGHTSHOULDER) |
               PollButton(DSDA_CONTROLLER_BUTTON_DPAD_UP) |
               PollButton(DSDA_CONTROLLER_BUTTON_DPAD_DOWN) |
               PollButton(DSDA_CONTROLLER_BUTTON_DPAD_LEFT) |
               PollButton(DSDA_CONTROLLER_BUTTON_DPAD_RIGHT) |
               PollButton(DSDA_CONTROLLER_BUTTON_MISC1) |
               PollButton(DSDA_CONTROLLER_BUTTON_PADDLE1) |
               PollButton(DSDA_CONTROLLER_BUTTON_PADDLE2) |
               PollButton(DSDA_CONTROLLER_BUTTON_PADDLE3) |
               PollButton(DSDA_CONTROLLER_BUTTON_PADDLE4) |
               PollButton(DSDA_CONTROLLER_BUTTON_TOUCHPAD);

  trigger = dsda_AxisValue(&left_trigger);
  if (trigger)
    ev.data1.i |= (1 << DSDA_CONTROLLER_BUTTON_TRIGGERLEFT);

  trigger = dsda_AxisValue(&right_trigger);
  if (trigger)
    ev.data1.i |= (1 << DSDA_CONTROLLER_BUTTON_TRIGGERRIGHT);

  D_PostEvent(&ev);
}

void dsda_PollGameController(void) {
  if (!game_controller)
    return;

  dsda_PollGameControllerButtons();
  dsda_PollLeftStick();
  dsda_PollRightStick();
}

void dsda_InitGameControllerParameters(void) {
  left_analog_x.deadzone = dsda_IntConfig(dsda_config_left_analog_deadzone);
  left_analog_x.sensitivity = dsda_IntConfig(dsda_config_left_analog_sensitivity_x);
  left_analog_y.deadzone = left_analog_x.deadzone;
  left_analog_y.sensitivity = dsda_IntConfig(dsda_config_left_analog_sensitivity_y);

  right_analog_x.deadzone = dsda_IntConfig(dsda_config_right_analog_deadzone);
  right_analog_x.sensitivity = dsda_IntConfig(dsda_config_right_analog_sensitivity_x);
  right_analog_y.deadzone = right_analog_x.deadzone;
  right_analog_y.sensitivity = dsda_IntConfig(dsda_config_right_analog_sensitivity_y);

  left_trigger.deadzone = dsda_IntConfig(dsda_config_left_trigger_deadzone);
  left_trigger.sensitivity = 1;
  right_trigger.deadzone = dsda_IntConfig(dsda_config_right_trigger_deadzone);
  right_trigger.sensitivity = 1;

  swap_analogs = dsda_IntConfig(dsda_config_swap_analogs);
}

static void dsda_ReleaseGameControllerButtons(void) {
  event_t ev;

  ev.type = ev_joystick;
  ev.data1.i = 0;
  D_PostEvent(&ev);
}

static void dsda_CloseGameController(void) {
  if (!game_controller)
    return;

  dsda_ReleaseGameControllerButtons();
  SDL_GameControllerClose(game_controller);
  game_controller = NULL;
  game_controller_instance = -1;
}

static int dsda_OpenGameController(int device_index) {
  SDL_Joystick* joystick;

  if (!SDL_IsGameController(device_index))
    return false;

  game_controller = SDL_GameControllerOpen(device_index);

  if (!game_controller) {
    snprintf(game_controller_status, sizeof(game_controller_status),
             "failed to open device %d: %s", device_index, SDL_GetError());
    lprintf(LO_ERROR, "dsda_OpenGameController: error opening device %d: %s\n",
            device_index, SDL_GetError());
    return false;
  }

  joystick = SDL_GameControllerGetJoystick(game_controller);
  if (joystick)
    game_controller_instance = SDL_JoystickInstanceID(joystick);

  if (game_controller_instance < 0) {
    snprintf(game_controller_status, sizeof(game_controller_status),
             "failed to identify device %d: %s", device_index, SDL_GetError());
    lprintf(LO_ERROR, "dsda_OpenGameController: error identifying device %d: %s\n",
            device_index, SDL_GetError());
    SDL_GameControllerClose(game_controller);
    game_controller = NULL;
    game_controller_instance = -1;
    return false;
  }

  lprintf(LO_DEBUG, "Opened game controller %s\n",
          SDL_GameControllerName(game_controller));
  snprintf(game_controller_status, sizeof(game_controller_status),
           "opened device %d (%s)", device_index,
           dsda_ControllerText(SDL_GameControllerName(game_controller)));

  return true;
}

static int dsda_OpenFirstGameController(void) {
  int device_index;

  for (device_index = 0; device_index < SDL_NumJoysticks(); ++device_index)
    if (dsda_OpenGameController(device_index))
      return true;

  return false;
}

void dsda_InitGameController(void) {
  dsda_CloseGameController();

  use_game_controller =
    dsda_IntConfig(dsda_config_use_game_controller) && !dsda_Flag(dsda_arg_nojoy);

  if (!use_game_controller) {
    dsda_SetGameControllerStatus(
      dsda_Flag(dsda_arg_nojoy) ? "disabled by -nojoy" : "disabled by configuration"
    );
    dsda_WriteGameControllerStatus("controller initialization");
    return;
  }

#ifdef __APPLE__
  // SDL filters Steam's virtual Xbox gamepad by default. Steam normally
  // opts games into it through this environment variable, but macOS
  // non-Steam shortcuts do not consistently receive it. Set the missing
  // opt-in before SDL scans for controllers, while respecting any value
  // explicitly supplied by Steam or the user.
  if ((SDL_getenv("SteamGameId") || SDL_getenv("SteamAppId")) &&
      !SDL_getenv("SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD") &&
      SDL_setenv("SDL_GAMECONTROLLER_ALLOW_STEAM_VIRTUAL_GAMEPAD", "1", 0) < 0)
    lprintf(LO_WARN, "Could not enable SDL Steam virtual gamepad detection: %s\n",
            SDL_GetError());
#endif

  dsda_InitGameControllerParameters();
  if (SDL_InitSubSystem(SDL_INIT_GAMECONTROLLER) < 0) {
    snprintf(game_controller_status, sizeof(game_controller_status),
             "SDL initialization failed: %s", SDL_GetError());
    lprintf(LO_ERROR, "dsda_InitGameController: SDL initialization failed: %s\n",
            SDL_GetError());
    dsda_WriteGameControllerStatus("controller initialization");
    return;
  }

  if (!dsda_OpenFirstGameController()) {
    dsda_SetGameControllerStatus("no supported game controller found");
    lprintf(LO_WARN, "dsda_InitGameController: no supported game controller found\n");
  }

  dsda_WriteGameControllerStatus("controller initialization");
}

void dsda_GameControllerAdded(int device_index) {
  char event[64];

  snprintf(event, sizeof(event), "device added (index %d)", device_index);

  if (!use_game_controller) {
    dsda_SetGameControllerStatus("device added while controller input is disabled");
  }
  else if (game_controller) {
    dsda_SetGameControllerStatus("device added; existing controller remains active");
  }
  else if (!dsda_OpenGameController(device_index) &&
           !dsda_OpenFirstGameController())
    dsda_SetGameControllerStatus("device added but no supported controller found");

  dsda_WriteGameControllerStatus(event);
}

void dsda_GameControllerRemoved(int instance_id) {
  char event[64];

  snprintf(event, sizeof(event), "device removed (instance %d)", instance_id);

  if (!game_controller || game_controller_instance != instance_id) {
    dsda_SetGameControllerStatus("non-active device removed");
    dsda_WriteGameControllerStatus(event);
    return;
  }

  dsda_CloseGameController();

  if (use_game_controller && !dsda_OpenFirstGameController())
    dsda_SetGameControllerStatus("active controller removed; no replacement found");

  dsda_WriteGameControllerStatus(event);
}

void dsda_GameControllerButtonEvent(int button, int pressed) {
  const char* name = SDL_GameControllerGetStringForButton(button);

  ++game_controller_input_events;
  snprintf(game_controller_input, sizeof(game_controller_input),
           "button %s %s", dsda_ControllerText(name),
           pressed ? "pressed" : "released");
  dsda_WriteGameControllerStatus("controller button input");
}

void dsda_GameControllerAxisEvent(int axis, int value) {
  int state;

  if (axis < 0 || axis >= SDL_CONTROLLER_AXIS_MAX)
    return;

  state = value > 8000 ? 1 : value < -8000 ? -1 : 0;
  if (game_controller_axis_state[axis] == state)
    return;

  game_controller_axis_state[axis] = state;
  ++game_controller_input_events;
  snprintf(game_controller_input, sizeof(game_controller_input),
           "axis %s changed to %d", dsda_ControllerText(
             SDL_GameControllerGetStringForAxis(axis)), value);
  dsda_WriteGameControllerStatus("controller axis input");
}

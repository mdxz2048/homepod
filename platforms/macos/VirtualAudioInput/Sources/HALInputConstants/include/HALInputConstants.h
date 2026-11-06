#pragma once
#include <stdint.h>

/* The Swift CoreAudio overlay does not import all AudioServerPlugIn constants.
 * Resolve this selector from the public target SDK, never a guessed FourCC. */
uint32_t flow_input_zero_timestamp_period_selector(void);

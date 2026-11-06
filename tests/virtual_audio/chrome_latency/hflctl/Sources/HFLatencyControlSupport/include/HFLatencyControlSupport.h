#pragma once
#include <stdint.h>

/* The Swift CoreAudio overlay does not import every AudioServerPlugIn
 * constant. Resolve this selector from the public target SDK headers, never
 * from a guessed FourCC. Mirrors the production HALInputConstants target. */
uint32_t hfl_zero_timestamp_period_selector(void);

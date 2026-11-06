#pragma once
/*
 * Layout/slot model aligned with MULTICHANNEL_CONTRACT.md v1.
 *
 * This file is free of CoreAudio headers so capture/route policy can be tested
 * without a HAL, device, or running coreaudiod.
 *
 * Capture policy encoded here:
 *   - identity: source labels and container labels are identical.
 *   - pad_silent: source labels are a subset of container labels; extra slots
 *     are exactly silent.  This is not an upmix.
 *   - refuse: source exceeds the container or a source label has no same-named
 *     container slot.  The capture layer never downmixes, upmixes, remaps, or
 *     applies gain/delay.  A downmix/remap is an explicit Flow route decision.
 *
 * Layout token, channel order, and labels are frozen by the contract:
 *   mono M; stereo FL FR; 3_0 FL FR FC; 4_0 FL FR BL BR;
 *   5_1_side FL FR FC LFE SL SR; 5_1_back FL FR FC LFE BL BR;
 *   7_1 FL FR FC LFE SL SR BL BR;
 *   5_1_2 / 7_1_2 / 7_1_4 are RES (name/order only, not enumerated).
 */

#include <stdbool.h>
#include <stdint.h>

#define MC_MAX_CHANNELS 16

typedef enum {
    MC_LABEL_NONE = 0,
    MC_LABEL_M,
    MC_LABEL_FL,
    MC_LABEL_FR,
    MC_LABEL_FC,
    MC_LABEL_LFE,
    MC_LABEL_SL,
    MC_LABEL_SR,
    MC_LABEL_BL,
    MC_LABEL_BR,
    MC_LABEL_TFL,
    MC_LABEL_TFR,
    MC_LABEL_TRL,
    MC_LABEL_TRR
} MCLabel;

typedef enum {
    MC_LAYOUT_NONE = 0,
    MC_LAYOUT_MONO,
    MC_LAYOUT_STEREO,
    MC_LAYOUT_3_0,
    MC_LAYOUT_4_0,
    MC_LAYOUT_5_1_SIDE,
    MC_LAYOUT_5_1_BACK,
    MC_LAYOUT_7_1,
    MC_LAYOUT_5_1_2,   /* RES */
    MC_LAYOUT_7_1_2,   /* RES */
    MC_LAYOUT_7_1_4    /* RES */
} MCLayout;

typedef enum {
    MC_AUTHORITY_NONE = 0,
    MC_AUTHORITY_DEVICE,
    MC_AUTHORITY_DECODER
} MCLayoutAuthority;

typedef enum {
    MC_PROVENANCE_UNKNOWN = 0,
    MC_PROVENANCE_SOURCE_NATIVE,
    MC_PROVENANCE_SOURCE_PADDED,
    MC_PROVENANCE_STEREO_PASSTHROUGH_IN_MULTICHANNEL,
    MC_PROVENANCE_SOURCE_UPSTREAM_MAPPED,
    MC_PROVENANCE_UNKNOWN_RESTRICTED
} MCProvenance;

typedef enum {
    MC_TRANSFORM_IDENTITY = 0,
    MC_TRANSFORM_PAD_SILENT,
    MC_TRANSFORM_PAD_5_1_SIDE_TO_7_1,
    MC_TRANSFORM_PAD_5_1_BACK_TO_7_1,
    MC_TRANSFORM_STEREO_PASSTHROUGH
} MCTransformation;

typedef enum {
    MC_PLAN_OK = 0,
    MC_PLAN_CONTAINER_UNSUPPORTED,
    MC_PLAN_SOURCE_UNSUPPORTED,
    MC_PLAN_LAYOUT_UNVERIFIED,
    MC_PLAN_CHANNEL_COUNT_MISMATCH,
    MC_PLAN_SOURCE_EXCEEDS_CONTAINER,
    MC_PLAN_CONTAINER_LAYOUT_MISMATCH,
    MC_PLAN_PROVENANCE_MISMATCH
} MCPlanStatus;

typedef struct {
    MCLayout layout;
    const char *token;
    const char *displayName;
    uint32_t channelCount;
    MCLabel labels[MC_MAX_CHANNELS];
    bool reserved;
} MCLayoutDescriptor;

typedef struct {
    MCLayout layout;
    uint32_t channelCount;
    MCLabel labels[MC_MAX_CHANNELS];
    MCLayoutAuthority authority;
    bool layoutVerified;
    bool upstreamMapped;
} MCSourceDescriptor;

typedef struct {
    MCPlanStatus status;
    MCLayout containerLayout;
    uint32_t containerChannels;
    MCLabel containerLabels[MC_MAX_CHANNELS];
    MCLayout sourceLayout;
    uint32_t sourceChannels;
    MCLabel sourceLabels[MC_MAX_CHANNELS];
    MCProvenance provenance;
    MCTransformation transformation;
    bool nativeClaim;
    bool containerMatchesSource;
    uint32_t silentSlotMask;
    /* -1 means the container slot has no source channel. */
    int32_t sourceIndexForSlot[MC_MAX_CHANNELS];
    /* 0xFF means the source channel could not be placed. */
    uint8_t slotForSourceChannel[MC_MAX_CHANNELS];
    /* [container slot][source channel], exactly 0.0 or 1.0; no mix gains. */
    float matrix[MC_MAX_CHANNELS][MC_MAX_CHANNELS];
} MCChannelPlan;

const MCLayoutDescriptor *MCLayoutDescriptorFor(MCLayout layout);
uint32_t MCLayoutChannelCount(MCLayout layout);
const char *MCLayoutToken(MCLayout layout);
const char *MCLayoutDisplayName(MCLayout layout);
bool MCLayoutIsReserved(MCLayout layout);
const char *MCLabelName(MCLabel label);
const char *MCPlanStatusName(MCPlanStatus status);
const char *MCProvenanceName(MCProvenance provenance);
const char *MCTransformationName(MCTransformation transformation);

bool MCLayoutLabels(MCLayout layout, MCLabel out[MC_MAX_CHANNELS], uint32_t *outCount);
bool MCSourceDescriptorForLayout(MCLayout layout, MCLayoutAuthority authority,
                                 bool verified, bool upstreamMapped,
                                 MCSourceDescriptor *out);

MCChannelPlan MCPlanForContainer(MCLayout container, const MCSourceDescriptor *source);
bool MCPlanSlotIsSilent(const MCChannelPlan *plan, uint32_t slot);
bool MCPlanSourceChannelMapped(const MCChannelPlan *plan, uint32_t sourceChannel);

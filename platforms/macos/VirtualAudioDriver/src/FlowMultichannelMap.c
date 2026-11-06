#include "FlowMultichannelMap.h"

#include <string.h>

/*
 * Frozen layout table from MULTICHANNEL_CONTRACT.md §3.1.
 * Slot order is the interleaved wire order.  Labels, not channel counts,
 * decide placement.  The three height layouts are RES: names and order only;
 * the HAL family does not enumerate them.
 */
static const MCLayoutDescriptor kLayouts[] = {
    {.layout = MC_LAYOUT_MONO,
     .token = "mono",
     .displayName = "Mono",
     .channelCount = 1,
     .labels = {MC_LABEL_M},
     .reserved = false},
    {.layout = MC_LAYOUT_STEREO,
     .token = "stereo",
     .displayName = "Stereo",
     .channelCount = 2,
     .labels = {MC_LABEL_FL, MC_LABEL_FR},
     .reserved = false},
    {.layout = MC_LAYOUT_3_0,
     .token = "3_0",
     .displayName = "3.0",
     .channelCount = 3,
     .labels = {MC_LABEL_FL, MC_LABEL_FR, MC_LABEL_FC},
     .reserved = false},
    {.layout = MC_LAYOUT_4_0,
     .token = "4_0",
     .displayName = "4.0 (quad back)",
     .channelCount = 4,
     .labels = {MC_LABEL_FL, MC_LABEL_FR, MC_LABEL_BL, MC_LABEL_BR},
     .reserved = false},
    {.layout = MC_LAYOUT_5_1_SIDE,
     .token = "5_1_side",
     .displayName = "5.1 Side",
     .channelCount = 6,
     .labels = {MC_LABEL_FL, MC_LABEL_FR, MC_LABEL_FC, MC_LABEL_LFE,
                MC_LABEL_SL, MC_LABEL_SR},
     .reserved = false},
    {.layout = MC_LAYOUT_5_1_BACK,
     .token = "5_1_back",
     .displayName = "5.1 Back",
     .channelCount = 6,
     .labels = {MC_LABEL_FL, MC_LABEL_FR, MC_LABEL_FC, MC_LABEL_LFE,
                MC_LABEL_BL, MC_LABEL_BR},
     .reserved = false},
    {.layout = MC_LAYOUT_7_1,
     .token = "7_1",
     .displayName = "7.1 (side + back)",
     .channelCount = 8,
     .labels = {MC_LABEL_FL, MC_LABEL_FR, MC_LABEL_FC, MC_LABEL_LFE,
                MC_LABEL_SL, MC_LABEL_SR, MC_LABEL_BL, MC_LABEL_BR},
     .reserved = false},
    {.layout = MC_LAYOUT_5_1_2,
     .token = "5_1_2",
     .displayName = "5.1.2 (reserved)",
     .channelCount = 8,
     .labels = {MC_LABEL_FL, MC_LABEL_FR, MC_LABEL_FC, MC_LABEL_LFE,
                MC_LABEL_SL, MC_LABEL_SR, MC_LABEL_TFL, MC_LABEL_TFR},
     .reserved = true},
    {.layout = MC_LAYOUT_7_1_2,
     .token = "7_1_2",
     .displayName = "7.1.2 (reserved)",
     .channelCount = 10,
     .labels = {MC_LABEL_FL, MC_LABEL_FR, MC_LABEL_FC, MC_LABEL_LFE,
                MC_LABEL_SL, MC_LABEL_SR, MC_LABEL_BL, MC_LABEL_BR,
                MC_LABEL_TFL, MC_LABEL_TFR},
     .reserved = true},
    {.layout = MC_LAYOUT_7_1_4,
     .token = "7_1_4",
     .displayName = "7.1.4 (reserved)",
     .channelCount = 12,
     .labels = {MC_LABEL_FL, MC_LABEL_FR, MC_LABEL_FC, MC_LABEL_LFE,
                MC_LABEL_SL, MC_LABEL_SR, MC_LABEL_BL, MC_LABEL_BR,
                MC_LABEL_TFL, MC_LABEL_TFR, MC_LABEL_TRL, MC_LABEL_TRR},
     .reserved = true},
};

const MCLayoutDescriptor *MCLayoutDescriptorFor(MCLayout layout) {
    for (size_t i = 0; i < sizeof(kLayouts) / sizeof(kLayouts[0]); ++i) {
        if (kLayouts[i].layout == layout) return &kLayouts[i];
    }
    return NULL;
}

uint32_t MCLayoutChannelCount(MCLayout layout) {
    const MCLayoutDescriptor *descriptor = MCLayoutDescriptorFor(layout);
    return descriptor ? descriptor->channelCount : 0;
}

const char *MCLayoutToken(MCLayout layout) {
    const MCLayoutDescriptor *descriptor = MCLayoutDescriptorFor(layout);
    return descriptor ? descriptor->token : "unknown";
}

const char *MCLayoutDisplayName(MCLayout layout) {
    const MCLayoutDescriptor *descriptor = MCLayoutDescriptorFor(layout);
    return descriptor ? descriptor->displayName : "Unknown";
}

bool MCLayoutIsReserved(MCLayout layout) {
    const MCLayoutDescriptor *descriptor = MCLayoutDescriptorFor(layout);
    return descriptor && descriptor->reserved;
}

const char *MCLabelName(MCLabel label) {
    switch (label) {
        case MC_LABEL_M: return "M";
        case MC_LABEL_FL: return "FL";
        case MC_LABEL_FR: return "FR";
        case MC_LABEL_FC: return "FC";
        case MC_LABEL_LFE: return "LFE";
        case MC_LABEL_SL: return "SL";
        case MC_LABEL_SR: return "SR";
        case MC_LABEL_BL: return "BL";
        case MC_LABEL_BR: return "BR";
        case MC_LABEL_TFL: return "TFL";
        case MC_LABEL_TFR: return "TFR";
        case MC_LABEL_TRL: return "TRL";
        case MC_LABEL_TRR: return "TRR";
        case MC_LABEL_NONE:
        default: return "NONE";
    }
}

const char *MCPlanStatusName(MCPlanStatus status) {
    switch (status) {
        case MC_PLAN_OK: return "ok";
        case MC_PLAN_CONTAINER_UNSUPPORTED: return "container_unsupported";
        case MC_PLAN_SOURCE_UNSUPPORTED: return "unsupported_layout";
        case MC_PLAN_LAYOUT_UNVERIFIED: return "layout_unverified";
        case MC_PLAN_CHANNEL_COUNT_MISMATCH: return "channel_count_mismatch";
        case MC_PLAN_SOURCE_EXCEEDS_CONTAINER: return "source_exceeds_container";
        case MC_PLAN_CONTAINER_LAYOUT_MISMATCH: return "container_layout_mismatch";
        case MC_PLAN_PROVENANCE_MISMATCH: return "provenance_mismatch";
        default: return "unknown";
    }
}

const char *MCProvenanceName(MCProvenance provenance) {
    switch (provenance) {
        case MC_PROVENANCE_SOURCE_NATIVE: return "source_native";
        case MC_PROVENANCE_SOURCE_PADDED: return "source_padded";
        case MC_PROVENANCE_STEREO_PASSTHROUGH_IN_MULTICHANNEL:
            return "stereo_passthrough_in_multichannel";
        case MC_PROVENANCE_SOURCE_UPSTREAM_MAPPED: return "source_upstream_mapped";
        case MC_PROVENANCE_UNKNOWN_RESTRICTED: return "unknown_restricted";
        case MC_PROVENANCE_UNKNOWN:
        default: return "unknown";
    }
}

const char *MCTransformationName(MCTransformation transformation) {
    switch (transformation) {
        case MC_TRANSFORM_IDENTITY: return "identity";
        case MC_TRANSFORM_PAD_SILENT: return "pad_silent";
        case MC_TRANSFORM_PAD_5_1_SIDE_TO_7_1: return "pad_5_1_side_to_7_1";
        case MC_TRANSFORM_PAD_5_1_BACK_TO_7_1: return "pad_5_1_back_to_7_1";
        case MC_TRANSFORM_STEREO_PASSTHROUGH: return "stereo_passthrough";
        default: return "unknown";
    }
}

bool MCLayoutLabels(MCLayout layout, MCLabel out[MC_MAX_CHANNELS], uint32_t *outCount) {
    const MCLayoutDescriptor *descriptor = MCLayoutDescriptorFor(layout);
    if (!descriptor || descriptor->channelCount > MC_MAX_CHANNELS) return false;
    if (out) {
        memset(out, 0, sizeof(MCLabel) * MC_MAX_CHANNELS);
        memcpy(out, descriptor->labels, sizeof(MCLabel) * descriptor->channelCount);
    }
    if (outCount) *outCount = descriptor->channelCount;
    return true;
}

bool MCSourceDescriptorForLayout(MCLayout layout, MCLayoutAuthority authority,
                                 bool verified, bool upstreamMapped,
                                 MCSourceDescriptor *out) {
    const MCLayoutDescriptor *descriptor = MCLayoutDescriptorFor(layout);
    if (!descriptor || !out) return false;
    memset(out, 0, sizeof(*out));
    out->layout = layout;
    out->channelCount = descriptor->channelCount;
    memcpy(out->labels, descriptor->labels, sizeof(MCLabel) * descriptor->channelCount);
    out->authority = authority;
    out->layoutVerified = verified;
    out->upstreamMapped = upstreamMapped;
    return true;
}

MCChannelPlan MCPlanForContainer(MCLayout container, const MCSourceDescriptor *source) {
    MCChannelPlan plan;
    memset(&plan, 0, sizeof(plan));
    for (uint32_t i = 0; i < MC_MAX_CHANNELS; ++i) {
        plan.sourceIndexForSlot[i] = -1;
        plan.slotForSourceChannel[i] = 0xFF;
    }

    const MCLayoutDescriptor *containerDescriptor = MCLayoutDescriptorFor(container);
    if (!containerDescriptor || containerDescriptor->channelCount > MC_MAX_CHANNELS) {
        plan.status = MC_PLAN_CONTAINER_UNSUPPORTED;
        return plan;
    }
    plan.containerLayout = container;
    plan.containerChannels = containerDescriptor->channelCount;
    memcpy(plan.containerLabels, containerDescriptor->labels,
           sizeof(MCLabel) * containerDescriptor->channelCount);

    if (!source) {
        plan.status = MC_PLAN_SOURCE_UNSUPPORTED;
        return plan;
    }
    const MCLayoutDescriptor *sourceDescriptor = MCLayoutDescriptorFor(source->layout);
    if (!sourceDescriptor || sourceDescriptor->channelCount > MC_MAX_CHANNELS) {
        plan.status = MC_PLAN_SOURCE_UNSUPPORTED;
        return plan;
    }
    plan.sourceLayout = source->layout;
    plan.sourceChannels = source->channelCount;
    memcpy(plan.sourceLabels, source->labels, sizeof(MCLabel) * MC_MAX_CHANNELS);

    if (source->channelCount != sourceDescriptor->channelCount) {
        plan.status = MC_PLAN_CHANNEL_COUNT_MISMATCH;
        return plan;
    }
    if (!source->layoutVerified || source->authority == MC_AUTHORITY_NONE) {
        plan.status = MC_PLAN_LAYOUT_UNVERIFIED;
        return plan;
    }
    for (uint32_t i = 0; i < source->channelCount; ++i) {
        if (source->labels[i] != sourceDescriptor->labels[i]) {
            plan.status = MC_PLAN_CONTAINER_LAYOUT_MISMATCH;
            return plan;
        }
    }

    if (source->channelCount > containerDescriptor->channelCount) {
        plan.status = MC_PLAN_SOURCE_EXCEEDS_CONTAINER;
        return plan;
    }

    /* Copy each source channel into the uniquely labelled container slot.
     * No downmix, upmix, remap, gain, or delay is ever applied here. */
    for (uint32_t s = 0; s < source->channelCount; ++s) {
        bool placed = false;
        for (uint32_t c = 0; c < containerDescriptor->channelCount; ++c) {
            if (sourceDescriptor->labels[s] != containerDescriptor->labels[c]) continue;
            plan.sourceIndexForSlot[c] = (int32_t)s;
            plan.slotForSourceChannel[s] = (uint8_t)c;
            plan.matrix[c][s] = 1.0f;
            placed = true;
            break;
        }
        if (!placed) {
            plan.status = MC_PLAN_CONTAINER_LAYOUT_MISMATCH;
            return plan;
        }
    }

    for (uint32_t c = 0; c < containerDescriptor->channelCount; ++c) {
        if (plan.sourceIndexForSlot[c] < 0) {
            plan.silentSlotMask |= (uint32_t)1u << c;
        }
    }

    plan.containerMatchesSource = (source->layout == container) &&
                                  (source->channelCount == containerDescriptor->channelCount);

    if (source->layout == MC_LAYOUT_STEREO && containerDescriptor->channelCount > 2) {
        plan.provenance = MC_PROVENANCE_STEREO_PASSTHROUGH_IN_MULTICHANNEL;
        plan.transformation = MC_TRANSFORM_STEREO_PASSTHROUGH;
    } else if (source->upstreamMapped) {
        plan.provenance = MC_PROVENANCE_SOURCE_UPSTREAM_MAPPED;
        plan.transformation = plan.silentSlotMask ? MC_TRANSFORM_PAD_SILENT
                                                  : MC_TRANSFORM_IDENTITY;
    } else if (plan.containerMatchesSource) {
        plan.provenance = MC_PROVENANCE_SOURCE_NATIVE;
        plan.transformation = MC_TRANSFORM_IDENTITY;
    } else if (source->channelCount < containerDescriptor->channelCount) {
        plan.provenance = MC_PROVENANCE_SOURCE_PADDED;
        if (source->layout == MC_LAYOUT_5_1_SIDE && container == MC_LAYOUT_7_1) {
            plan.transformation = MC_TRANSFORM_PAD_5_1_SIDE_TO_7_1;
        } else if (source->layout == MC_LAYOUT_5_1_BACK && container == MC_LAYOUT_7_1) {
            plan.transformation = MC_TRANSFORM_PAD_5_1_BACK_TO_7_1;
        } else {
            plan.transformation = MC_TRANSFORM_PAD_SILENT;
        }
    } else {
        /* Equal channel count, different labels, cannot be reached after the
         * label checks above, but keep the failure explicit. */
        plan.status = MC_PLAN_CONTAINER_LAYOUT_MISMATCH;
        return plan;
    }

    /* nativeClaim is about the source layout, not about the container width.
     * A padded source can still be a native source claim when a decoder
     * authorititatively reported it; stereo passthrough and upstream-mapped
     * sources never claim native multichannel. */
    if (source->upstreamMapped || plan.provenance ==
                                     MC_PROVENANCE_STEREO_PASSTHROUGH_IN_MULTICHANNEL) {
        plan.nativeClaim = false;
    } else if (source->authority == MC_AUTHORITY_DECODER && source->layoutVerified) {
        plan.nativeClaim = true;
    } else if (plan.containerMatchesSource &&
               source->authority == MC_AUTHORITY_DEVICE && source->layoutVerified) {
        plan.nativeClaim = true;
    } else {
        plan.nativeClaim = false;
    }

    plan.status = MC_PLAN_OK;
    return plan;
}

bool MCPlanSlotIsSilent(const MCChannelPlan *plan, uint32_t slot) {
    if (!plan || plan->status != MC_PLAN_OK || slot >= plan->containerChannels) return false;
    return (plan->silentSlotMask & ((uint32_t)1u << slot)) != 0;
}

bool MCPlanSourceChannelMapped(const MCChannelPlan *plan, uint32_t sourceChannel) {
    if (!plan || plan->status != MC_PLAN_OK || sourceChannel >= plan->sourceChannels) return false;
    return plan->slotForSourceChannel[sourceChannel] != 0xFF;
}

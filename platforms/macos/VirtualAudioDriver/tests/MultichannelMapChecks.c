/* Pure C checks for the contract layout/slot policy.  No HAL or audio access. */
#include "../src/FlowMultichannelMap.c"

#include <assert.h>
#include <stdio.h>
#include <string.h>

static MCSourceDescriptor Source(MCLayout layout, MCLayoutAuthority authority,
                                 bool verified, bool upstreamMapped) {
    MCSourceDescriptor source;
    assert(MCSourceDescriptorForLayout(layout, authority, verified, upstreamMapped,
                                       &source));
    return source;
}

static void CheckLayoutLabels(MCLayout layout, const MCLabel *expected, uint32_t count) {
    MCLabel labels[MC_MAX_CHANNELS];
    uint32_t actual = 0;
    assert(MCLayoutChannelCount(layout) == count);
    assert(MCLayoutLabels(layout, labels, &actual));
    assert(actual == count);
    for (uint32_t i = 0; i < count; ++i) assert(labels[i] == expected[i]);
}

static void CheckMatrix(const MCChannelPlan *plan) {
    for (uint32_t c = 0; c < plan->containerChannels; ++c) {
        bool rowUsed = false;
        for (uint32_t s = 0; s < plan->sourceChannels; ++s) {
            float value = plan->matrix[c][s];
            assert(value == 0.0f || value == 1.0f);
            if (value == 1.0f) rowUsed = true;
        }
        if (plan->sourceIndexForSlot[c] < 0) {
            assert(!rowUsed);
            assert(MCPlanSlotIsSilent(plan, c));
        } else {
            assert(rowUsed);
            assert(!MCPlanSlotIsSilent(plan, c));
        }
    }
    for (uint32_t s = 0; s < plan->sourceChannels; ++s) {
        assert(MCPlanSourceChannelMapped(plan, s));
    }
}

int main(void) {
    const MCLabel mono[] = {MC_LABEL_M};
    const MCLabel stereo[] = {MC_LABEL_FL, MC_LABEL_FR};
    const MCLabel three[] = {MC_LABEL_FL, MC_LABEL_FR, MC_LABEL_FC};
    const MCLabel four[] = {MC_LABEL_FL, MC_LABEL_FR, MC_LABEL_BL, MC_LABEL_BR};
    const MCLabel side[] = {MC_LABEL_FL, MC_LABEL_FR, MC_LABEL_FC, MC_LABEL_LFE,
                            MC_LABEL_SL, MC_LABEL_SR};
    const MCLabel back[] = {MC_LABEL_FL, MC_LABEL_FR, MC_LABEL_FC, MC_LABEL_LFE,
                            MC_LABEL_BL, MC_LABEL_BR};
    const MCLabel seven[] = {MC_LABEL_FL, MC_LABEL_FR, MC_LABEL_FC, MC_LABEL_LFE,
                             MC_LABEL_SL, MC_LABEL_SR, MC_LABEL_BL, MC_LABEL_BR};
    const MCLabel h512[] = {MC_LABEL_FL, MC_LABEL_FR, MC_LABEL_FC, MC_LABEL_LFE,
                            MC_LABEL_SL, MC_LABEL_SR, MC_LABEL_TFL, MC_LABEL_TFR};
    const MCLabel h712[] = {MC_LABEL_FL, MC_LABEL_FR, MC_LABEL_FC, MC_LABEL_LFE,
                            MC_LABEL_SL, MC_LABEL_SR, MC_LABEL_BL, MC_LABEL_BR,
                            MC_LABEL_TFL, MC_LABEL_TFR};
    const MCLabel h714[] = {MC_LABEL_FL, MC_LABEL_FR, MC_LABEL_FC, MC_LABEL_LFE,
                            MC_LABEL_SL, MC_LABEL_SR, MC_LABEL_BL, MC_LABEL_BR,
                            MC_LABEL_TFL, MC_LABEL_TFR, MC_LABEL_TRL, MC_LABEL_TRR};

    CheckLayoutLabels(MC_LAYOUT_MONO, mono, 1);
    CheckLayoutLabels(MC_LAYOUT_STEREO, stereo, 2);
    CheckLayoutLabels(MC_LAYOUT_3_0, three, 3);
    CheckLayoutLabels(MC_LAYOUT_4_0, four, 4);
    CheckLayoutLabels(MC_LAYOUT_5_1_SIDE, side, 6);
    CheckLayoutLabels(MC_LAYOUT_5_1_BACK, back, 6);
    CheckLayoutLabels(MC_LAYOUT_7_1, seven, 8);
    CheckLayoutLabels(MC_LAYOUT_5_1_2, h512, 8);
    CheckLayoutLabels(MC_LAYOUT_7_1_2, h712, 10);
    CheckLayoutLabels(MC_LAYOUT_7_1_4, h714, 12);

    /* 7.1 canonical order is Apple/HAL: side before back. */
    assert(seven[4] == MC_LABEL_SL && seven[5] == MC_LABEL_SR);
    assert(seven[6] == MC_LABEL_BL && seven[7] == MC_LABEL_BR);
    assert(strcmp(MCLabelName(MC_LABEL_SL), "SL") == 0);
    assert(strcmp(MCLabelName(MC_LABEL_BL), "BL") == 0);
    assert(strcmp(MCLabelName(MC_LABEL_TRL), "TRL") == 0);
    assert(MC_LABEL_SL != MC_LABEL_BL);

    /* Height layouts are reserved by name/order only. */
    assert(MCLayoutIsReserved(MC_LAYOUT_5_1_2));
    assert(MCLayoutIsReserved(MC_LAYOUT_7_1_2));
    assert(MCLayoutIsReserved(MC_LAYOUT_7_1_4));
    assert(!MCLayoutIsReserved(MC_LAYOUT_MONO));
    assert(!MCLayoutIsReserved(MC_LAYOUT_7_1));
    assert(strcmp(MCLayoutToken(MC_LAYOUT_5_1_SIDE), "5_1_side") == 0);
    assert(strcmp(MCLayoutToken(MC_LAYOUT_7_1), "7_1") == 0);

    MCSourceDescriptor monoSource = Source(MC_LAYOUT_MONO, MC_AUTHORITY_DECODER, true, false);
    MCSourceDescriptor stereoSource =
        Source(MC_LAYOUT_STEREO, MC_AUTHORITY_DECODER, true, false);
    MCSourceDescriptor threeSource =
        Source(MC_LAYOUT_3_0, MC_AUTHORITY_DECODER, true, false);
    MCSourceDescriptor fourSource =
        Source(MC_LAYOUT_4_0, MC_AUTHORITY_DECODER, true, false);
    MCSourceDescriptor sideSource =
        Source(MC_LAYOUT_5_1_SIDE, MC_AUTHORITY_DECODER, true, false);
    MCSourceDescriptor backSource =
        Source(MC_LAYOUT_5_1_BACK, MC_AUTHORITY_DECODER, true, false);
    MCSourceDescriptor sevenSource =
        Source(MC_LAYOUT_7_1, MC_AUTHORITY_DECODER, true, false);

    /* Native identities. */
    const MCLayout identities[] = {MC_LAYOUT_MONO, MC_LAYOUT_STEREO, MC_LAYOUT_3_0,
                                   MC_LAYOUT_4_0, MC_LAYOUT_5_1_SIDE,
                                   MC_LAYOUT_5_1_BACK, MC_LAYOUT_7_1};
    const MCSourceDescriptor *sources[] = {&monoSource, &stereoSource, &threeSource,
                                           &fourSource, &sideSource, &backSource,
                                           &sevenSource};
    for (uint32_t i = 0; i < 7; ++i) {
        MCChannelPlan plan = MCPlanForContainer(identities[i], sources[i]);
        assert(plan.status == MC_PLAN_OK);
        assert(plan.containerMatchesSource);
        assert(plan.nativeClaim);
        assert(plan.provenance == MC_PROVENANCE_SOURCE_NATIVE);
        assert(plan.transformation == MC_TRANSFORM_IDENTITY);
        assert(plan.silentSlotMask == 0);
        CheckMatrix(&plan);
    }

    /* Stereo into a wider container: FL/FR only, never native 5.1/7.1. */
    MCChannelPlan plan = MCPlanForContainer(MC_LAYOUT_5_1_SIDE, &stereoSource);
    assert(plan.status == MC_PLAN_OK && !plan.nativeClaim);
    assert(plan.provenance == MC_PROVENANCE_STEREO_PASSTHROUGH_IN_MULTICHANNEL);
    assert(plan.transformation == MC_TRANSFORM_STEREO_PASSTHROUGH);
    for (uint32_t slot = 2; slot < 6; ++slot) assert(MCPlanSlotIsSilent(&plan, slot));
    CheckMatrix(&plan);
    plan = MCPlanForContainer(MC_LAYOUT_7_1, &stereoSource);
    assert(plan.status == MC_PLAN_OK && !plan.nativeClaim);
    for (uint32_t slot = 2; slot < 8; ++slot) assert(MCPlanSlotIsSilent(&plan, slot));
    CheckMatrix(&plan);

    /* 3.0/4.0 pad by same label. */
    plan = MCPlanForContainer(MC_LAYOUT_5_1_SIDE, &threeSource);
    assert(plan.status == MC_PLAN_OK);
    assert(plan.provenance == MC_PROVENANCE_SOURCE_PADDED);
    assert(plan.transformation == MC_TRANSFORM_PAD_SILENT);
    assert(plan.nativeClaim); /* decoder-verified source claim, not native 5.1 */
    assert(plan.sourceIndexForSlot[2] == 2);
    for (uint32_t slot = 3; slot < 6; ++slot) assert(MCPlanSlotIsSilent(&plan, slot));
    CheckMatrix(&plan);

    plan = MCPlanForContainer(MC_LAYOUT_5_1_BACK, &fourSource);
    assert(plan.status == MC_PLAN_OK);
    assert(plan.sourceIndexForSlot[0] == 0 && plan.sourceIndexForSlot[1] == 1);
    assert(plan.sourceIndexForSlot[4] == 2 && plan.sourceIndexForSlot[5] == 3);
    assert(MCPlanSlotIsSilent(&plan, 2) && MCPlanSlotIsSilent(&plan, 3));
    CheckMatrix(&plan);

    /* 4.0 has BL/BR, so it cannot enter 5.1 side without an explicit remap. */
    plan = MCPlanForContainer(MC_LAYOUT_5_1_SIDE, &fourSource);
    assert(plan.status == MC_PLAN_CONTAINER_LAYOUT_MISMATCH);

    /* 5.1 side/back -> 7.1: side vs back slots remain distinct. */
    plan = MCPlanForContainer(MC_LAYOUT_7_1, &sideSource);
    assert(plan.status == MC_PLAN_OK);
    assert(plan.provenance == MC_PROVENANCE_SOURCE_PADDED);
    assert(plan.transformation == MC_TRANSFORM_PAD_5_1_SIDE_TO_7_1);
    assert(plan.sourceIndexForSlot[4] == 4 && plan.sourceIndexForSlot[5] == 5);
    assert(MCPlanSlotIsSilent(&plan, 6) && MCPlanSlotIsSilent(&plan, 7));
    CheckMatrix(&plan);

    plan = MCPlanForContainer(MC_LAYOUT_7_1, &backSource);
    assert(plan.status == MC_PLAN_OK);
    assert(plan.provenance == MC_PROVENANCE_SOURCE_PADDED);
    assert(plan.transformation == MC_TRANSFORM_PAD_5_1_BACK_TO_7_1);
    assert(plan.sourceIndexForSlot[6] == 4 && plan.sourceIndexForSlot[7] == 5);
    assert(MCPlanSlotIsSilent(&plan, 4) && MCPlanSlotIsSilent(&plan, 5));
    CheckMatrix(&plan);

    /* 5.1 side/back never swap labels silently. */
    plan = MCPlanForContainer(MC_LAYOUT_5_1_BACK, &sideSource);
    assert(plan.status == MC_PLAN_CONTAINER_LAYOUT_MISMATCH);
    plan = MCPlanForContainer(MC_LAYOUT_5_1_SIDE, &backSource);
    assert(plan.status == MC_PLAN_CONTAINER_LAYOUT_MISMATCH);

    /* 7.1 cannot enter 6ch; a downmix is an explicit Flow route decision. */
    plan = MCPlanForContainer(MC_LAYOUT_5_1_SIDE, &sevenSource);
    assert(plan.status == MC_PLAN_SOURCE_EXCEEDS_CONTAINER);
    plan = MCPlanForContainer(MC_LAYOUT_5_1_BACK, &sevenSource);
    assert(plan.status == MC_PLAN_SOURCE_EXCEEDS_CONTAINER);

    /* Height RES model: names/order only; mapping may be tested offline. */
    MCSourceDescriptor h512Source =
        Source(MC_LAYOUT_5_1_2, MC_AUTHORITY_DECODER, true, false);
    MCSourceDescriptor h712Source =
        Source(MC_LAYOUT_7_1_2, MC_AUTHORITY_DECODER, true, false);
    plan = MCPlanForContainer(MC_LAYOUT_5_1_2, &sideSource);
    assert(plan.status == MC_PLAN_OK && plan.provenance == MC_PROVENANCE_SOURCE_PADDED);
    assert(MCPlanSlotIsSilent(&plan, 6) && MCPlanSlotIsSilent(&plan, 7));
    CheckMatrix(&plan);
    plan = MCPlanForContainer(MC_LAYOUT_7_1_2, &sevenSource);
    assert(plan.status == MC_PLAN_OK && plan.provenance == MC_PROVENANCE_SOURCE_PADDED);
    assert(MCPlanSlotIsSilent(&plan, 8) && MCPlanSlotIsSilent(&plan, 9));
    CheckMatrix(&plan);
    plan = MCPlanForContainer(MC_LAYOUT_7_1, &h512Source);
    assert(plan.status == MC_PLAN_CONTAINER_LAYOUT_MISMATCH);
    plan = MCPlanForContainer(MC_LAYOUT_7_1, &h712Source);
    assert(plan.status == MC_PLAN_SOURCE_EXCEEDS_CONTAINER);

    /* Metadata rejection. */
    MCSourceDescriptor unverified =
        Source(MC_LAYOUT_5_1_SIDE, MC_AUTHORITY_DECODER, false, false);
    plan = MCPlanForContainer(MC_LAYOUT_5_1_SIDE, &unverified);
    assert(plan.status == MC_PLAN_LAYOUT_UNVERIFIED);
    MCSourceDescriptor noAuthority =
        Source(MC_LAYOUT_5_1_SIDE, MC_AUTHORITY_NONE, true, false);
    plan = MCPlanForContainer(MC_LAYOUT_5_1_SIDE, &noAuthority);
    assert(plan.status == MC_PLAN_LAYOUT_UNVERIFIED);
    MCSourceDescriptor wrongCount = sideSource;
    wrongCount.channelCount = 2;
    plan = MCPlanForContainer(MC_LAYOUT_5_1_SIDE, &wrongCount);
    assert(plan.status == MC_PLAN_CHANNEL_COUNT_MISMATCH);
    MCSourceDescriptor wrongLabel = sideSource;
    wrongLabel.labels[4] = MC_LABEL_BL;
    plan = MCPlanForContainer(MC_LAYOUT_5_1_SIDE, &wrongLabel);
    assert(plan.status == MC_PLAN_CONTAINER_LAYOUT_MISMATCH);
    plan = MCPlanForContainer(MC_LAYOUT_NONE, &sideSource);
    assert(plan.status == MC_PLAN_CONTAINER_UNSUPPORTED);

    /* Upstream-mapped and 2ch claims never become native multichannel. */
    MCSourceDescriptor mapped =
        Source(MC_LAYOUT_5_1_SIDE, MC_AUTHORITY_DECODER, true, true);
    plan = MCPlanForContainer(MC_LAYOUT_7_1, &mapped);
    assert(plan.status == MC_PLAN_OK);
    assert(plan.provenance == MC_PROVENANCE_SOURCE_UPSTREAM_MAPPED);
    assert(!plan.nativeClaim);
    MCSourceDescriptor fakeSurround = stereoSource;
    fakeSurround.layout = MC_LAYOUT_5_1_SIDE;
    plan = MCPlanForContainer(MC_LAYOUT_5_1_SIDE, &fakeSurround);
    assert(plan.status == MC_PLAN_CHANNEL_COUNT_MISMATCH);
    assert(!plan.nativeClaim);

    /* Device authority does not assert native for a padded source. */
    MCSourceDescriptor devicePadded =
        Source(MC_LAYOUT_3_0, MC_AUTHORITY_DEVICE, true, false);
    plan = MCPlanForContainer(MC_LAYOUT_5_1_SIDE, &devicePadded);
    assert(plan.status == MC_PLAN_OK && !plan.nativeClaim);

    assert(strcmp(MCPlanStatusName(MC_PLAN_CONTAINER_LAYOUT_MISMATCH),
                  "container_layout_mismatch") == 0);
    assert(strcmp(MCProvenanceName(MC_PROVENANCE_SOURCE_PADDED), "source_padded") == 0);
    assert(strcmp(MCTransformationName(MC_TRANSFORM_PAD_5_1_BACK_TO_7_1),
                  "pad_5_1_back_to_7_1") == 0);
    puts("PASS multichannel map: contract layouts, 7.1 side-before-back order, "
         "source_padded, no silent drop/downmix/upmix");
    return 0;
}

# 009 Mechanical single-device build patch

Implement now, no investigation/plan/testing. Coordinator already audited entire driver. Only 3 files below. No other reads (at most ONE batched read of these three if necessary), no grep/git/tests/temp scripts. Use apply_patch then final<=100 Chinese characters. This is a mechanical change, do not expand scope.

1. src/FlowVirtualAudioMultichannel.h under platforms/macos/VirtualAudioDriver: add MC_SINGLE_DEVICE default0 before identity branches. Existing final '#define MC_DEVICE_COUNT 7' becomes conditional1 when MC_SINGLE_DEVICE else7. After identity branches override MC_DEVICE_NAME_71 to 'HomePod Flow Audio' when MC_SINGLE_DEVICE. No other identity changes.
2. src/FlowVirtualAudioMultichannel.c: static gDevices[MC_DEVICE_COUNT] initializer has seven entries. Wrap the first SIX entries (stereo through51B) in #if !MC_SINGLE_DEVICE ... #endif. Keep existing71 entry always. That genuinely makes list1/owned1/Translate only71, all loops already use MC_DEVICE_COUNT. No hiding trick. No other C changes. It is fixed8ch, no format-switching.
3. scripts/build-stage-multichannel.sh: existing identity_flag variable passed to clang. Add single_flag='' or '-DMC_SINGLE_DEVICE=1' when MC_SINGLE_DEVICE env1 and pass it to clang alongside $identity_flag. Print SINGLE_DEVICE marker at end. No install/reload/reboot.

Prefix is platforms/macos/VirtualAudioDriver/. Preserve existing dev/family builds. Coordinator writes/runs acceptance; do not read tests or docs. No SSH/credentials/commits/agents/models. Return after three edits.

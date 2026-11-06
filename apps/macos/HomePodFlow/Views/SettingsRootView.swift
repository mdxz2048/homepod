import SwiftUI

struct SettingsRootView: View {
    @Bindable var state: AppState
    @State private var showingDevices = false
    private var editable: Bool { state.layoutEditable }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("空间布局").font(.title2.bold())
                    Text(state.mode == .cinema ? "添加实际音箱，拖动到房间中的位置。" : "同步播放不使用空间位置，布局只读。")
                        .foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                Button { showingDevices = true } label: {
                    Label("添加音箱", systemImage: "plus")
                }.controlSize(.large).disabled(!editable)
            }
            Divider()
            HStack(alignment: .top, spacing: 20) {
                ZStack {
                    RoomCanvas(layout: $state.draftLayout, selectedDeviceID: $state.selectedDeviceID, editable: editable)
                    if state.draftLayout.devices.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "hifispeaker.and.homepodmini").font(.largeTitle).foregroundStyle(.secondary)
                            Text("还没有添加音箱").font(.headline)
                            Button("查找音箱") { showingDevices = true }.disabled(!editable)
                        }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                }.frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                inspector.frame(width: 240)
            }
            HStack {
                Button("重置位置", action: state.resetLayout).disabled(!editable || state.draftLayout.devices.isEmpty)
                Spacer()
                Button("取消修改", action: state.cancelLayout).disabled(!editable || !state.hasUnsavedLayout)
                Button("保存布局", action: state.applyLayout).buttonStyle(.borderedProminent)
                    .disabled(!editable || !state.hasUnsavedLayout || !state.unconfirmedSpeakerHosts.isEmpty)
            }.controlSize(.large)
            Text(state.notice).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(24).frame(minWidth: 820, minHeight: 580)
        .navigationTitle("HomePod Flow · 空间布局")
        .sheet(isPresented: $showingDevices) { DeviceDiscoverySheet(state: state) }
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("音箱（\(state.draftLayout.devices.count)）").font(.headline)
                ForEach(state.draftLayout.devices) { device in
                    Button { state.selectedDeviceID = device.id } label: {
                        HStack(spacing: 10) {
                            SpeakerGlyph(isMini: device.kind == .mini).frame(width: 30, height: 30)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name).font(.callout.weight(.medium))
                                Text(state.unconfirmedSpeakerHosts.contains(device.host ?? "") ? "请选择型号" :
                                     (device.kind == .mini ? "HomePod mini" : "HomePod"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(10).contentShape(Rectangle())
                            .background(state.selectedDeviceID == device.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
                if let index = state.draftLayout.devices.firstIndex(where: { $0.id == state.selectedDeviceID }) {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("音箱型号", selection: speakerKind(index)) {
                            Text("选择型号").tag(Optional<SpeakerKind>.none)
                            Text("HomePod").tag(Optional(SpeakerKind.homePod))
                            Text("HomePod mini").tag(Optional(SpeakerKind.mini))
                        }.pickerStyle(.menu)
                        coordinate("左右", value: deviceCoordinate(index, horizontal: true))
                        coordinate("前后", value: deviceCoordinate(index, horizontal: false))
                        Button("从布局移除", role: .destructive) {
                            state.removeDevice(state.draftLayout.devices[index].id)
                        }
                    }.disabled(!editable)
                }
                Divider()
                Label("听音位置", systemImage: "person.fill").font(.headline)
                Text("在画布上拖动蓝色听音位置，面向前方电视。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("状态栏使用保存后的布局。当前系统立体声在影院模式下按同声播放处理。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func coordinate(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.caption)
            Slider(value: value, in: 0...1, step: 0.01).accessibilityLabel("\(title)位置")
            Text(value.wrappedValue, format: .number.precision(.fractionLength(2)))
                .font(.caption.monospacedDigit()).frame(width: 32)
        }
    }
    private func speakerKind(_ index: Int) -> Binding<SpeakerKind?> {
        Binding(get: {
            guard state.draftLayout.devices.indices.contains(index) else { return nil }
            let device = state.draftLayout.devices[index]
            return state.unconfirmedSpeakerHosts.contains(device.host ?? "") ? nil : device.kind
        }, set: { kind in
            guard editable, let kind, state.draftLayout.devices.indices.contains(index) else { return }
            state.confirmSpeakerKind(kind, for: state.draftLayout.devices[index].id)
        })
    }
    private func deviceCoordinate(_ index: Int, horizontal: Bool) -> Binding<Double> {
        Binding(get: {
            guard state.draftLayout.devices.indices.contains(index) else { return 0.5 }
            let point = state.draftLayout.devices[index].position
            return horizontal ? point.x : point.y
        }, set: { value in
            guard editable, state.draftLayout.devices.indices.contains(index) else { return }
            if horizontal { state.draftLayout.devices[index].position.x = value }
            else { state.draftLayout.devices[index].position.y = value }
        })
    }
}

private struct DeviceDiscoverySheet: View {
    @Bindable var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加音箱").font(.title2.bold())
            Text("选择同一局域网中的独立音箱。发现音箱不会播放声音。")
                .font(.callout).foregroundStyle(.secondary)
            Text(state.systemAudio.statusText).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(state.systemAudio.devices) { device in
                        Toggle(device.name, isOn: Binding(get: { selection.contains(device.id) }, set: { selected in
                            if selected { selection.insert(device.id) } else { selection.remove(device.id) }
                        }))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 110, maxHeight: 240)
            HStack {
                Button("重新查找") { Task { await discover() } }.disabled(state.systemAudio.isBusy)
                Spacer()
                Button("取消") { dismiss() }
                Button("添加到布局") {
                    state.stageSystemDevices(selection)
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(selection.isEmpty || state.systemAudio.isBusy || state.systemAudio.desiredEnabled)
            }
        }.padding(24).frame(width: 450)
            .task {
                selection = Set(state.draftLayout.devices.compactMap(\.host))
                await discover()
            }
    }
    private func discover() async {
        if !state.systemAudio.serviceReady { await state.systemAudio.connectLocalWorker() }
        await state.systemAudio.scanDevices()
    }
}

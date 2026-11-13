import SwiftUI

struct SettingsRootView: View {
    @Bindable var state: AppState
    @State private var showingDevices = false
    private var editable: Bool { state.layoutEditable }
    private var removeEditable: Bool { state.canRemoveDevice }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("空间布局").font(.title2.bold())
                    Text(state.mode == .cinema
                         ? "添加实际音箱，拖动到房间中的位置。"
                         : "同步播放不使用空间位置；仍可移除已保存的音箱。")
                        .foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
                Button { showingDevices = true } label: {
                    Label("添加音箱", systemImage: "plus")
                }.controlSize(.large).disabled(!editable)
            }
            if !state.visualDemo {
                AudioComponentSection(service: state.audioComponent,
                                      canInstall: !state.sessionControlsLocked)
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
                Button("取消修改", action: state.cancelLayout).disabled(!removeEditable || !state.hasUnsavedLayout)
                Button("保存布局", action: state.applyLayout).buttonStyle(.borderedProminent)
                    .disabled(!removeEditable || !state.hasUnsavedLayout || !state.unconfirmedSpeakerHosts.isEmpty)
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
                    HStack(spacing: 4) {
                        Button { state.selectedDeviceID = device.id } label: {
                            HStack(spacing: 10) {
                                SpeakerGlyph(kind: device.kind)
                                    .frame(width: device.kind.form == .homePod ? 26 : 30,
                                           height: device.kind.form == .homePod ? 36 : 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name).font(.callout.weight(.medium))
                                    Text(state.unconfirmedSpeakerHosts.contains(device.host ?? "")
                                         ? "请选择型号" : device.kind.displayName)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }.padding(10).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Button(role: .destructive) {
                            state.removeDevice(device.id)
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!removeEditable)
                        .help("从布局移除")
                        .accessibilityLabel("移除 \(device.name)")
                    }
                    .background(state.selectedDeviceID == device.id ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10))
                }
                if let index = state.draftLayout.devices.firstIndex(where: { $0.id == state.selectedDeviceID }) {
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("音箱型号", selection: speakerKind(index)) {
                                Text("选择型号").tag(Optional<SpeakerKind>.none)
                                Section("HomePod") {
                                    ForEach(SpeakerKind.homePodChoices) { kind in
                                        Text(kind.displayName).tag(Optional(kind))
                                    }
                                }
                                Section("HomePod mini") {
                                    ForEach(SpeakerKind.miniChoices) { kind in
                                        Text(kind.displayName).tag(Optional(kind))
                                    }
                                }
                            }.pickerStyle(.menu)
                            Text("型号决定轮廓，颜色只影响画布外观。")
                                .font(.caption).foregroundStyle(.secondary)
                            coordinate("左右", value: deviceCoordinate(index, horizontal: true))
                            coordinate("前后", value: deviceCoordinate(index, horizontal: false))
                        }.disabled(!editable)
                        Button("从布局移除", role: .destructive) {
                            state.removeDevice(state.draftLayout.devices[index].id)
                        }
                        .disabled(!removeEditable)
                        Text("断电或不再使用的音箱可直接移除。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Label("听音位置", systemImage: "person.fill").font(.headline)
                Text("在画布上拖动蓝色听音位置，面向前方电视。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("状态栏使用保存后的布局。当前系统立体声在影院模式下按同声播放处理。")
                    .font(.caption).foregroundStyle(.secondary)
                if !state.systemAudio.latencyStatusText.isEmpty {
                    Text(state.systemAudio.latencyStatusText)
                        .font(.caption).foregroundStyle(.secondary)
                }
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

private struct AudioComponentSection: View {
    @Bindable var service: AudioComponentService
    var canInstall: Bool
    @State private var actionNote = ""

    private var snapshot: AudioComponentSnapshot { service.snapshot }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title).font(.callout.weight(.semibold))
                    Text("App \(AudioComponentService.appVersion)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if let version = snapshot.driverVersion {
                        Text("驱动 \(version)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Text(snapshot.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !actionNote.isEmpty {
                    Text(actionNote).font(.caption).foregroundStyle(.orange)
                }
                if !canInstall {
                    Text("请先停止系统声音，再安装或更新音频组件。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                if snapshot.state == .checking {
                    ProgressView().controlSize(.small)
                } else if snapshot.state == .ready {
                    Button("升级/重装…") {
                        if !service.install() { actionNote = service.lastActionMessage }
                    }
                    .disabled(!canInstall)
                    .help(service.installerName.map { "打开 \($0)" } ?? "未找到安装包")
                    Button("重新检查") { service.refresh() }
                } else {
                    Button("安装/升级音频组件…") {
                        if !service.install() { actionNote = service.lastActionMessage }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canInstall)
                    .help(service.installerName.map { "打开 \($0)" } ?? "未找到安装包")
                    Button("重新检查") { service.refresh() }
                    if snapshot.state == .installedNeedsReload {
                        Button("声音设置") { service.openSoundSettings() }
                    }
                    Button("日志") { service.openInstallLog() }
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.25), lineWidth: 1))
    }

    private var title: String {
        switch snapshot.state {
        case .checking: "音频组件"
        case .notInstalled: "音频组件未安装"
        case .installedNeedsReload: "音频组件等待加载"
        case .ready: "音频组件已就绪"
        case .conflict: "音频组件有冲突"
        case .invalid: "音频组件无效"
        }
    }

    private var icon: String {
        switch snapshot.state {
        case .checking: "waveform"
        case .notInstalled: "exclamationmark.triangle.fill"
        case .installedNeedsReload: "clock.arrow.circlepath"
        case .ready: "checkmark.circle.fill"
        case .conflict: "exclamationmark.triangle.fill"
        case .invalid: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch snapshot.state {
        case .checking: Color.gray
        case .notInstalled: Color.orange
        case .installedNeedsReload: Color.orange
        case .ready: Color.green
        case .conflict, .invalid: Color.red
        }
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
            if !state.draftLayout.devices.isEmpty {
                Divider()
                Text("已保存的音箱").font(.headline)
                Text("断电、搬走或不再使用的音箱可直接移除。")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(state.draftLayout.devices) { device in
                            HStack {
                                Text(device.name).font(.callout)
                                Spacer()
                                Button(role: .destructive) {
                                    state.removeDevice(device.id)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .disabled(!state.canRemoveDevice)
                                .help("从布局移除")
                                .accessibilityLabel("移除 \(device.name)")
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 120)
            }
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

import Foundation

@main struct AudioComponentChecks {
    static func main() {
        let uid = "com.homepodflow.virtual-audio.surround71.v1"
        let valid = AudioComponentBundle(path: "/Library/Audio/Plug-Ins/HAL/HomePodFlowAudioFamily.driver",
                                         version: "0.1.0",
                                         executable: "HomePodFlowAudioFamily",
                                         bundleIdentifier: "com.homepodflow.audio.driver",
                                         isValid: true)
        let invalid = AudioComponentBundle(path: "/Library/Audio/Plug-Ins/HAL/Broken.driver",
                                           version: "0.1.0",
                                           executable: "Wrong",
                                           bundleIdentifier: "com.homepodflow.audio.driver",
                                           isValid: false)

        var snapshot = AudioComponentEvaluator.evaluate(bundles: [], devicePresent: false,
                                                        deviceUID: uid, installerAvailable: true)
        precondition(snapshot.state == .notInstalled && snapshot.canInstall)
        precondition(snapshot.message.contains("HomePod Flow Audio"))

        snapshot = AudioComponentEvaluator.evaluate(bundles: [], devicePresent: false,
                                                    deviceUID: uid, installerAvailable: false)
        precondition(snapshot.state == .notInstalled && !snapshot.canInstall)

        snapshot = AudioComponentEvaluator.evaluate(bundles: [valid], devicePresent: false,
                                                    deviceUID: uid, installerAvailable: true)
        precondition(snapshot.state == .installedNeedsReload)
        precondition(snapshot.driverVersion == "0.1.0")
        precondition(snapshot.driverPath == valid.path)
        precondition(snapshot.message.contains("重新启动"))

        snapshot = AudioComponentEvaluator.evaluate(bundles: [valid], devicePresent: true,
                                                    deviceUID: uid, installerAvailable: true)
        precondition(snapshot.state == .ready && snapshot.devicePresent)
        precondition(snapshot.message.contains("已就绪"))

        snapshot = AudioComponentEvaluator.evaluate(bundles: [valid, valid], devicePresent: true,
                                                    deviceUID: uid, installerAvailable: true)
        precondition(snapshot.state == .conflict)
        precondition(snapshot.message.contains("多个"))

        snapshot = AudioComponentEvaluator.evaluate(bundles: [invalid], devicePresent: false,
                                                    deviceUID: uid, installerAvailable: true)
        precondition(snapshot.state == .invalid)
        precondition(snapshot.message.contains("重新安装"))

        print("PASS: audio component states, version/path reporting, conflict and invalid handling")
    }
}

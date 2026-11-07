import Foundation
import Virtualization

// MARK: - Repo root

func resolveDiosRoot() -> URL {
    if let env = ProcessInfo.processInfo.environment["DIOS_ROOT"], !env.isEmpty {
        let url = URL(fileURLWithPath: env, isDirectory: true)
        let marker = url.appendingPathComponent("guest/boot.sh")
        if FileManager.default.fileExists(atPath: marker.path) {
            return url
        }
        fputs("DIOS_ROOT is set but guest/boot.sh is missing at \(marker.path)\n", stderr)
        exit(1)
    }

    var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let fm = FileManager.default
    for _ in 0 ..< 32 {
        let marker = dir.appendingPathComponent("guest/boot.sh")
        if fm.fileExists(atPath: marker.path) {
            return dir
        }
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path {
            break
        }
        dir = parent
    }

    fputs(
        "Could not find dios repo root. cd into the repo or set DIOS_ROOT.\n",
        stderr
    )
    exit(1)
}

func requireFile(at url: URL, label: String) {
    if !FileManager.default.fileExists(atPath: url.path) {
        fputs("missing \(label): \(url.path)\n", stderr)
        exit(1)
    }
}

// MARK: - TTY

var origTermios = termios()
var ttyConfigured = false

func configureRawTTY() {
    guard tcgetattr(STDIN_FILENO, &origTermios) == 0 else { return }
    var raw = origTermios
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    ttyConfigured = true
}

func restoreTTY() {
    guard ttyConfigured else { return }
    tcsetattr(STDIN_FILENO, TCSANOW, &origTermios)
    ttyConfigured = false
}

// MARK: - VM

final class VMDelegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_: VZVirtualMachine) {
        restoreTTY()
        exit(0)
    }

    func virtualMachine(_: VZVirtualMachine, didStopWithError error: Error) {
        restoreTTY()
        fputs("VM error: \(error)\n", stderr)
        exit(1)
    }
}

let diosRoot = resolveDiosRoot()
let artifacts = diosRoot.appendingPathComponent("artifacts", isDirectory: true)

let kernelURL = artifacts.appendingPathComponent("Image")
let initrdURL = artifacts.appendingPathComponent("initramfs.cpio")
let bundleURL = artifacts.appendingPathComponent("bundle", isDirectory: true)

requireFile(at: kernelURL, label: "kernel Image (make kernel)")
requireFile(at: initrdURL, label: "initramfs (make initramfs)")
requireFile(at: bundleURL, label: "bundle dir (make bundle)")

configureRawTTY()
atexit {
    restoreTTY()
}

let boot = VZLinuxBootLoader(kernelURL: kernelURL)
boot.initialRamdiskURL = initrdURL
boot.commandLine = "console=hvc0 rdinit=/init"

let config = VZVirtualMachineConfiguration()
config.bootLoader = boot
config.cpuCount = 2
config.memorySize = 1024 * 1024 * 1024

let console = VZVirtioConsoleDeviceSerialPortConfiguration()
console.attachment = VZFileHandleSerialPortAttachment(
    fileHandleForReading: .standardInput,
    fileHandleForWriting: .standardOutput
)
config.serialPorts = [console]

let net = VZVirtioNetworkDeviceConfiguration()
net.attachment = VZNATNetworkDeviceAttachment()
config.networkDevices = [net]

let fs = VZVirtioFileSystemDeviceConfiguration(tag: "bundle")
fs.share = VZSingleDirectoryShare(
    directory: VZSharedDirectory(url: bundleURL, readOnly: false)
)
config.directorySharingDevices = [fs]

config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

do {
    try config.validate()
} catch {
    restoreTTY()
    fputs("invalid VM configuration: \(error)\n", stderr)
    exit(1)
}

let vm = VZVirtualMachine(configuration: config)
let delegate = VMDelegate()
vm.delegate = delegate

vm.start { result in
    if case .failure(let error) = result {
        restoreTTY()
        fputs("start failed: \(error)\n", stderr)
        exit(1)
    }
}

RunLoop.main.run()

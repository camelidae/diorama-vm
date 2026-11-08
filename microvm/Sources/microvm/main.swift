import Foundation
import Virtualization

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

/// Prefer the zstd-compressed initramfs (kernel needs CONFIG_RD_ZSTD);
/// fall back to the raw cpio when only that exists.
func resolveInitrd(in artifacts: URL) -> URL {
    let zst = artifacts.appendingPathComponent("initramfs.cpio.zst")
    let raw = artifacts.appendingPathComponent("initramfs.cpio")
    return FileManager.default.fileExists(atPath: zst.path) ? zst : raw
}

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
let initrdURL = resolveInitrd(in: artifacts)
let bundleURL = artifacts.appendingPathComponent("bundle", isDirectory: true)

requireFile(at: kernelURL, label: "kernel Image (make kernel)")
requireFile(at: initrdURL, label: "initramfs (make initramfs)")
requireFile(at: bundleURL, label: "bundle dir (make bundle)")
fputs("initrd: \(initrdURL.lastPathComponent)\n", stderr)

configureRawTTY()
atexit {
    restoreTTY()
}

let boot = VZLinuxBootLoader(kernelURL: kernelURL)
boot.initialRamdiskURL = initrdURL
boot.commandLine = "console=hvc0 rdinit=/init cgroup_no_v1=all"

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

// Persistent ext4 for /var/lib/containerd (guest mounts /dev/vda).
// Created by `make disk`; the VM boots without it if absent.
let diskURL = artifacts.appendingPathComponent("disk.img")
if FileManager.default.fileExists(atPath: diskURL.path) {
    do {
        let attachment = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        let blk = VZVirtioBlockDeviceConfiguration(attachment: attachment)
        config.storageDevices = [blk]
        fputs("disk: \(diskURL.lastPathComponent)\n", stderr)
    } catch {
        restoreTTY()
        fputs("disk attach failed: \(error)\n", stderr)
        exit(1)
    }
}

// vsock control plane: guest dios-vsockd listens on CID_ANY:1024 and relays
// to /run/containerd/containerd.sock. Bridge host unix socket
// artifacts/run/containerd.sock to guest port 1024.
config.socketDevices = [VZVirtioSocketDeviceConfiguration()]

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

let runDir = artifacts.appendingPathComponent("run", isDirectory: true)
try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
let hostSockURL = runDir.appendingPathComponent("containerd.sock")
// Retain for process lifetime: VsockBridge.start() detaches its accept loop
// with [weak self], so a discarded instance would never accept.
// connect(toPort:) must run on the main actor (it asserts its queue).
@MainActor
func guestConnect(_ device: VZVirtioSocketDevice) async throws -> VZVirtioSocketConnection {
    try await device.connect(toPort: 1024)
}

let vsockBridge = VsockBridge(hostSockURL: hostSockURL) { completion in
    guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
        completion(nil, nil)
        return
    }
    Task {
        // connect(toPort:) asserts its dispatch queue (main actor). Hop the
        // connect onto the main actor; the relay itself stays on this task.
        let result: Result<VZVirtioSocketConnection, Error>
        do {
            result = .success(try await guestConnect(device))
        } catch {
            result = .failure(error)
        }
        switch result {
        case .success(let conn):
            completion(conn.fileDescriptor, conn)
        case .failure(let error):
            fputs("vsock connect failed: \(error)\n", stderr)
            completion(nil, nil)
        }
    }
}?.start()
_ = vsockBridge // keep the bridge (and its accept loop) alive
vm.start { result in
    if case .failure(let error) = result {
        restoreTTY()
        fputs("start failed: \(error)\n", stderr)
        exit(1)
    }
}
RunLoop.main.run()

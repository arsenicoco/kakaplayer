import Foundation
@preconcurrency import Virtualization

/// Boots the bundled Linux guest (kernel + ext4 root image) with Apple's
/// Virtualization.framework. The guest runs the Ace Stream engine and exposes
/// it over vsock (port 6878) plus a poweroff listener (vsock port 6880).
final class VMController: NSObject, VZVirtualMachineDelegate {
    enum VMError: LocalizedError {
        case rosettaUnavailable
        case notRunning
        case vsockConnectFailed(String)
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .rosettaUnavailable: return "Rosetta is not available on this Mac (required to run the x86_64 Ace Stream engine)."
            case .notRunning: return "The engine virtual machine is not running."
            case .vsockConnectFailed(let s): return "Could not connect to the engine over vsock: \(s)"
            case .timeout(let s): return "Timed out: \(s)"
            }
        }
    }

    let queue = DispatchQueue(label: "dev.kakaplayer.vm")
    private(set) var vm: VZVirtualMachine?
    private let guestOutput = Pipe()
    private let guestInput = Pipe()
    private var lineBuffer = Data()
    private var stateObservation: NSKeyValueObservation?

    /// Called on an arbitrary queue for every complete console line.
    var onConsoleLine: ((String) -> Void)?
    /// Called on an arbitrary queue when the VM state changes.
    var onStateChange: ((VZVirtualMachine.State) -> Void)?

    static func ensureRosetta() async throws {
        switch VZLinuxRosettaDirectoryShare.availability {
        case .installed:
            return
        case .notInstalled:
            try await VZLinuxRosettaDirectoryShare.installRosetta()
        case .notSupported:
            throw VMError.rosettaUnavailable
        @unknown default:
            throw VMError.rosettaUnavailable
        }
    }

    func makeConfiguration(kernelURL: URL, diskURL: URL, networkHandle: FileHandle, cpus: Int, memoryBytes: UInt64) throws -> VZVirtualMachineConfiguration {
        let config = VZVirtualMachineConfiguration()
        config.platform = VZGenericPlatformConfiguration()

        let minCPU = VZVirtualMachineConfiguration.minimumAllowedCPUCount
        let maxCPU = VZVirtualMachineConfiguration.maximumAllowedCPUCount
        config.cpuCount = max(minCPU, min(maxCPU, cpus))
        let minMem = VZVirtualMachineConfiguration.minimumAllowedMemorySize
        let maxMem = VZVirtualMachineConfiguration.maximumAllowedMemorySize
        config.memorySize = max(minMem, min(maxMem, memoryBytes))

        let bootLoader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootLoader.commandLine = "console=hvc0 root=/dev/vda rw rootfstype=ext4 rootwait init=/init panic=5 quiet loglevel=4 "
            + "kaka.ip=\(GvproxyNetwork.guestIP) kaka.gw=\(GvproxyNetwork.gateway) kaka.dns=\(GvproxyNetwork.gateway)"
        config.bootLoader = bootLoader

        // Serial console: guest stdout -> guestOutput pipe, guestInput pipe -> guest stdin.
        let console = VZVirtioConsoleDeviceSerialPortConfiguration()
        console.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: guestInput.fileHandleForReading,
            fileHandleForWriting: guestOutput.fileHandleForWriting)
        config.serialPorts = [console]

        // Root disk (ext4, read-write).
        let disk = try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)
        config.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]

        // User-space networking through gvproxy (see GvproxyNetwork).
        let net = VZVirtioNetworkDeviceConfiguration()
        net.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: networkHandle)
        net.macAddress = VZMACAddress(string: GvproxyNetwork.guestMAC) ?? VZMACAddress.randomLocallyAdministered()
        config.networkDevices = [net]

        // Rosetta share (tag "rosetta") lets the guest run x86_64 Linux binaries.
        let rosetta = try VZLinuxRosettaDirectoryShare()
        let share = VZVirtioFileSystemDeviceConfiguration(tag: "rosetta")
        share.share = rosetta
        config.directorySharingDevices = [share]

        config.socketDevices = [VZVirtioSocketDeviceConfiguration()]
        config.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        try config.validate()
        return config
    }

    func start(configuration: VZVirtualMachineConfiguration) async throws {
        startConsoleReader()
        let vm = VZVirtualMachine(configuration: configuration, queue: queue)
        vm.delegate = self
        self.vm = vm
        stateObservation = vm.observe(\.state, options: [.initial, .new]) { [weak self] vm, _ in
            self?.onStateChange?(vm.state)
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                vm.start { result in
                    switch result {
                    case .success: cont.resume()
                    case .failure(let e): cont.resume(throwing: e)
                    }
                }
            }
        }
    }

    var isRunning: Bool {
        queue.sync { vm?.state == .running }
    }

    /// Opens a vsock connection to `port` in the guest. Returns a connection whose
    /// fileDescriptor is a connected socket. Caller must keep the connection alive
    /// and call `close()` when done.
    func connectVsock(port: UInt32) throws -> VZVirtioSocketConnection {
        let sema = DispatchSemaphore(value: 0)
        var outcome: Result<VZVirtioSocketConnection, Error> = .failure(VMError.notRunning)
        queue.async { [self] in
            guard let vm, vm.state == .running,
                  let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
                sema.signal(); return
            }
            device.connect(toPort: port) { result in
                outcome = result
                sema.signal()
            }
        }
        if sema.wait(timeout: .now() + 10) == .timedOut {
            throw VMError.timeout("vsock connect to port \(port)")
        }
        switch outcome {
        case .success(let c): return c
        case .failure(let e): throw VMError.vsockConnectFailed(e.localizedDescription)
        }
    }

    /// Asks the guest to power off (vsock 6880), then force-stops if it doesn't
    /// exit within `graceSeconds`.
    func shutdown(graceSeconds: Double = 6) {
        guard let vm else { return }
        if let conn = try? connectVsock(port: 6880) {
            // Just connecting triggers the poweroff hook; give it a moment.
            Thread.sleep(forTimeInterval: 0.2)
            conn.close()
        }
        let deadline = Date().addingTimeInterval(graceSeconds)
        while Date() < deadline {
            if queue.sync(execute: { vm.state == .stopped || vm.state == .error }) { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let sema = DispatchSemaphore(value: 0)
        queue.async {
            if vm.state == .running {
                vm.stop { _ in sema.signal() }
            } else {
                sema.signal()
            }
        }
        _ = sema.wait(timeout: .now() + 5)
        self.vm = nil
        stateObservation = nil
    }

    private func startConsoleReader() {
        let handle = guestOutput.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard let self, !data.isEmpty else { return }
            self.lineBuffer.append(data)
            while let nl = self.lineBuffer.firstIndex(of: 0x0A) {
                let line = self.lineBuffer.subdata(in: self.lineBuffer.startIndex..<nl)
                self.lineBuffer.removeSubrange(self.lineBuffer.startIndex...nl)
                if let s = String(data: line, encoding: .utf8) ?? String(data: line, encoding: .isoLatin1) {
                    self.onConsoleLine?(s.trimmingCharacters(in: .init(charactersIn: "\r")))
                }
            }
        }
    }

    // MARK: VZVirtualMachineDelegate
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        onConsoleLine?("[vm] guest powered off")
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        onConsoleLine?("[vm] stopped with error: \(error.localizedDescription)")
    }
}

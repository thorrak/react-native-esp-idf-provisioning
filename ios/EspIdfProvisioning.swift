// React Native bridge for ESPProvision. SDK callbacks are marshalled to the
// main queue so cancellation, timeouts and Bluetooth events settle once.
import Foundation
import CoreBluetooth
import ESPProvision

private final class PendingOperation {
    let id = UUID()
    let deviceName: String?
    let kind: String
    let resolve: RCTPromiseResolveBlock
    let reject: RCTPromiseRejectBlock
    var timeout: DispatchWorkItem?

    init(deviceName: String?, kind: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        self.deviceName = deviceName
        self.kind = kind
        self.resolve = resolve
        self.reject = reject
    }
}

// ESPProvision's session completion is not a disconnect subscription. Its
// per-device BLE delegate is the source that includes an actual peripheral.
private final class DeviceDelegate: ESPBLEDelegate, ESPDeviceConnectionDelegate {
    let pop: String
    var username: String?
    let onDisconnect: (Error?) -> Void

    init(pop: String?, username: String?, onDisconnect: @escaping (Error?) -> Void) {
        self.pop = pop ?? ""
        self.username = username
        self.onDisconnect = onDisconnect
    }

    func peripheralConnected() {}
    func peripheralFailedToConnect(peripheral: CBPeripheral?, error: Error?) {}
    func peripheralDisconnected(peripheral: CBPeripheral, error: Error?) { onDisconnect(error) }
    func getProofOfPossesion(forDevice: ESPDevice, completionHandler: @escaping (String) -> Void) { completionHandler(pop) }
    func getUsername(forDevice: ESPDevice, completionHandler: @escaping (String?) -> Void) { completionHandler(username) }
}

@objc(EspIdfProvisioning)
class EspIdfProvisioning: RCTEventEmitter, CBCentralManagerDelegate {
    private var espDevices: [String: ESPDevice] = [:]
    private var softAPPasswords: [String: String] = [:]
    private var deviceDelegates: [String: DeviceDelegate] = [:]
    private var operations: [UUID: PendingOperation] = [:]
    private var bluetoothWaiters: [UUID: () -> Void] = [:]
    private var bluetoothMonitor: CBCentralManager?
    private var scanOperation: UUID?
    private var connectedDeviceNames = Set<String>()
    private var sdkScanActive = false
    private var hasListeners = false

    override func supportedEvents() -> [String]! { ["EspIdfProvisioningDeviceDisconnected"] }
    override func startObserving() { hasListeners = true }
    override func stopObserving() { hasListeners = false }

    private func onMain(_ action: @escaping () -> Void) {
        if Thread.isMainThread { action() } else { DispatchQueue.main.async(execute: action) }
    }

    private func debugBluetooth(_ message: @autoclosure () -> String) {
        #if DEBUG
        print("[EspIdfProvisioning] \(message())")
        #endif
    }

    private func begin(_ kind: String, deviceName: String? = nil, seconds: Double,
                       resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) -> PendingOperation {
        let operation = PendingOperation(deviceName: deviceName, kind: kind, resolve: resolve, reject: reject)
        operations[operation.id] = operation
        let timeout = DispatchWorkItem { [weak self, weak operation] in
            guard let self = self, let operation = operation, self.operations[operation.id] != nil else { return }
            self.fail(operation, code: kind == "connect" || kind == "create" ? "connect_timeout" : "operation_timeout", message: "\(kind) timed out.")
            // Stop the abandoned native exchange before callers can retry.
            if let name = deviceName { self.disconnectDevice(name, reason: "Operation timed out.", emitEvent: true) }
        }
        operation.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
        return operation
    }

    @discardableResult
    private func take(_ operation: PendingOperation) -> Bool {
        guard operations.removeValue(forKey: operation.id) != nil else { return false }
        operation.timeout?.cancel()
        bluetoothWaiters.removeValue(forKey: operation.id)
        if scanOperation == operation.id {
            scanOperation = nil
            let shouldStop = sdkScanActive
            sdkScanActive = false
            if shouldStop { ESPProvisionManager.shared.stopESPDevicesSearch() }
        }
        return true
    }

    private func succeed(_ operation: PendingOperation, _ value: Any?) {
        if take(operation) { operation.resolve(value) }
    }

    private func fail(_ operation: PendingOperation, code: String, message: String) {
        if take(operation) {
            if operation.kind == "scan" || operation.kind == "create" {
                debugBluetooth("terminal kind=\(operation.kind) outcome=rejected code=\(code) state=\(bluetoothMonitor?.state.rawValue ?? -1)")
            }
            operation.reject(code, message, nil)
        }
    }

    private func cancelSearch() {
        if let id = scanOperation, let operation = operations[id] {
            fail(operation, code: "scan_cancelled", message: "Device search was cancelled.")
        }
    }

    private func bluetoothError(_ state: CBManagerState) -> (String, String)? {
        switch state {
        case .unauthorized: return ("bluetooth_unauthorized", "Bluetooth permission is denied. Enable it in Settings.")
        case .poweredOff: return ("bluetooth_powered_off", "Bluetooth is turned off.")
        case .unsupported: return ("bluetooth_unavailable", "Bluetooth is not supported on this device.")
        default: return nil
        }
    }

    private func whenBluetoothReady(_ operation: PendingOperation, action: @escaping () -> Void) {
        if bluetoothMonitor == nil {
            bluetoothMonitor = CBCentralManager(delegate: self, queue: .main)
        }
        guard let state = bluetoothMonitor?.state else { return }
        debugBluetooth("readiness kind=\(operation.kind) state=\(state.rawValue)")
        if let (code, message) = bluetoothError(state) {
            fail(operation, code: code, message: message)
        } else if state == .poweredOn {
            action()
        } else {
            // Initial authorization/state callbacks are asynchronous. The
            // operation deadline also bounds this wait, including resetting.
            bluetoothWaiters[operation.id] = action
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        debugBluetooth("stateChanged state=\(central.state.rawValue) pending=\(operations.count) waiting=\(bluetoothWaiters.count)")
        if let (code, message) = bluetoothError(central.state) {
            for operation in Array(operations.values) { fail(operation, code: code, message: message) }
            for name in Array(deviceDelegates.keys) { disconnectDevice(name, reason: message, emitEvent: true) }
        } else if central.state == .poweredOn {
            let waiters = bluetoothWaiters
            bluetoothWaiters.removeAll()
            for (id, action) in waiters where operations[id] != nil { action() }
        }
    }

    private func sessionCode(_ error: ESPSessionError) -> String {
        switch error {
        case .sessionInitError: return "session_init_failed"
        case .securityMismatch: return "security_mismatch"
        case .noPOP: return "missing_pop"
        case .noUsername: return "missing_username"
        case .sessionNotEstablished: return "session_not_established"
        default: return "connect_error"
        }
    }

    private func disconnectDevice(_ name: String, reason: String, emitEvent: Bool = false) {
        for operation in Array(operations.values) where operation.deviceName == name {
            fail(operation, code: "device_disconnected", message: reason)
        }
        let device = espDevices.removeValue(forKey: name)
        deviceDelegates.removeValue(forKey: name)
        softAPPasswords.removeValue(forKey: name)
        device?.bleDelegate = nil
        device?.disconnect()
        if connectedDeviceNames.remove(name) != nil && emitEvent && hasListeners {
            sendEvent(withName: "EspIdfProvisioningDeviceDisconnected", body: ["deviceName": name, "reason": reason])
        }
    }

    override func invalidate() {
        onMain {
            for operation in Array(self.operations.values) {
                self.fail(operation, code: "operation_cancelled", message: "Native module was invalidated.")
            }
            self.hasListeners = false
            for name in Array(self.espDevices.keys) { self.disconnectDevice(name, reason: "Native module was invalidated.") }
            self.bluetoothMonitor?.delegate = nil
            self.bluetoothMonitor = nil
        }
        super.invalidate()
    }

    @objc(searchESPDevices:transport:security:resolve:reject:)
    func searchESPDevices(devicePrefix: String, transport: String, security: Int, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        cancelSearch()
        let operation = begin("scan", seconds: 10, resolve: resolve, reject: reject)
        scanOperation = operation.id
        let start = {
            self.sdkScanActive = true
            ESPProvisionManager.shared.searchESPDevices(devicePrefix: devicePrefix, transport: ESPTransport(rawValue: transport) ?? .ble, security: ESPSecurity(rawValue: security)) { [weak self, weak operation] devices, error in
                guard let self = self, let operation = operation else { return }
                self.onMain {
                    self.debugBluetooth("scanCompletion kind=scan active=\(self.operations[operation.id] != nil) state=\(self.bluetoothMonitor?.state.rawValue ?? -1) resultCount=\(devices?.count ?? 0) errorType=\(error.map { String(describing: type(of: $0)) } ?? "none") errorMessage=\(error?.description ?? "none")")
                    guard self.operations[operation.id] != nil else { return }
                    self.sdkScanActive = false
                    // The SDK reports an empty scan even when its radio is
                    // unavailable. Preserve a known system Bluetooth error.
                    if transport == "ble", let state = self.bluetoothMonitor?.state, let (code, message) = self.bluetoothError(state) {
                        self.fail(operation, code: code, message: message)
                        return
                    }
                    if let error = error {
                        self.fail(operation, code: "scan_failed", message: error.description)
                        return
                    }
                    let devices = devices ?? []
                    devices.forEach { self.espDevices[$0.name] = $0 }
                    self.succeed(operation, devices.map { ["name": $0.name, "transport": $0.transport.rawValue, "security": $0.security.rawValue] })
                }
            }
        }
        if transport == "ble" { whenBluetoothReady(operation, action: start) } else { start() }
    }

    @objc(stopESPDevicesSearch)
    func stopESPDevicesSearch() { cancelSearch() }

    @objc(createESPDevice:transport:security:proofOfPossession:softAPPassword:username:resolve:reject:)
    func createESPDevice(deviceName: String, transport: String, security: Int, proofOfPossession: String? = nil, softAPPassword: String? = nil, username: String? = nil, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        cancelSearch()
        disconnectDevice(deviceName, reason: "Device connection was replaced.")
        let operation = begin("create", deviceName: deviceName, seconds: 10, resolve: resolve, reject: reject)
        scanOperation = operation.id
        let start = {
            self.sdkScanActive = transport == "ble"
            ESPProvisionManager.shared.createESPDevice(deviceName: deviceName, transport: ESPTransport(rawValue: transport) ?? .ble, security: ESPSecurity(rawValue: security), proofOfPossession: proofOfPossession, softAPPassword: softAPPassword, username: username) { [weak self, weak operation] device, error in
                guard let self = self, let operation = operation else { return }
                self.onMain {
                    self.debugBluetooth("scanCompletion kind=create active=\(self.operations[operation.id] != nil) state=\(self.bluetoothMonitor?.state.rawValue ?? -1) resultCount=\(device == nil ? 0 : 1) errorType=\(error.map { String(describing: type(of: $0)) } ?? "none") errorMessage=\(error?.description ?? "none")")
                    guard self.operations[operation.id] != nil else { return }
                    self.sdkScanActive = false
                    if transport == "ble", let state = self.bluetoothMonitor?.state, let (code, message) = self.bluetoothError(state) {
                        self.fail(operation, code: code, message: message)
                        return
                    }
                    guard let device = device, error == nil else {
                        self.fail(operation, code: "scan_failed", message: error?.description ?? "No ESP device found.")
                        return
                    }
                    let delegate = DeviceDelegate(pop: proofOfPossession, username: username) { [weak self, weak device] error in
                        self?.onMain {
                            guard let self = self, let device = device, self.espDevices[deviceName] === device else { return }
                            self.disconnectDevice(deviceName, reason: error?.localizedDescription ?? "Device disconnected.", emitEvent: true)
                        }
                    }
                    self.deviceDelegates[deviceName] = delegate
                    device.bleDelegate = delegate
                    self.softAPPasswords[deviceName] = softAPPassword
                    self.espDevices[deviceName] = device
                    self.succeed(operation, ["name": device.name, "transport": device.transport.rawValue, "security": device.security.rawValue])
                }
            }
        }
        if transport == "ble" { whenBluetoothReady(operation, action: start) } else { start() }
    }

    @objc(connect:resolve:reject:)
    func connect(deviceName: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let device = espDevices[deviceName] else {
            reject("device_not_found", "No ESP device found. Call createESPDevice first.", nil)
            return
        }
        let operation = begin("connect", deviceName: deviceName, seconds: 30, resolve: resolve, reject: reject)
        let start = {
            device.connect(delegate: self.deviceDelegates[deviceName]) { [weak self, weak operation] status in
                guard let self = self, let operation = operation else { return }
                self.onMain {
                    guard self.operations[operation.id] != nil else { return }
                    switch status {
                    case .connected:
                        self.connectedDeviceNames.insert(deviceName)
                        self.succeed(operation, ["status": "connected"])
                    case .failedToConnect(let error):
                        self.fail(operation, code: self.sessionCode(error), message: error.description)
                        self.disconnectDevice(deviceName, reason: error.description)
                    case .disconnected:
                        self.disconnectDevice(deviceName, reason: "Device disconnected.", emitEvent: true)
                    }
                }
            }
        }
        if device.transport == .ble { whenBluetoothReady(operation, action: start) } else { start() }
    }

    @objc(sendData:path:data:resolve:reject:)
    func sendData(deviceName: String, path: String, data: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let device = espDevices[deviceName] else {
            reject("device_disconnected", "Device is not connected.", nil)
            return
        }
        guard let payload = Data(base64Encoded: data) else {
            reject("invalid_data", "Data is not base64 encoded.", nil)
            return
        }
        let operation = begin("sendData", deviceName: deviceName, seconds: 15, resolve: resolve, reject: reject)
        device.sendData(path: path, data: payload) { [weak self, weak operation] data, error in
            guard let self = self, let operation = operation else { return }
            self.onMain {
                if let error = error { self.fail(operation, code: self.sessionCode(error), message: error.description) }
                else if let data = data { self.succeed(operation, data.base64EncodedString()) }
                else { self.fail(operation, code: "invalid_response", message: "Device returned no data.") }
            }
        }
    }

    @objc(scanWifiList:resolve:reject:)
    func scanWifiList(deviceName: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let device = espDevices[deviceName] else {
            reject("device_disconnected", "Device is not connected.", nil)
            return
        }
        let operation = begin("scanWifi", deviceName: deviceName, seconds: 20, resolve: resolve, reject: reject)
        device.scanWifiList { [weak self, weak operation] wifiList, error in
            guard let self = self, let operation = operation else { return }
            self.onMain {
                // ESPDevice performs its reconnect/retry before this completion.
                // Errors arriving here are terminal and must settle the promise.
                if let error = error {
                    if error.code == ESPWiFiScanError.emptyResultCount.code { self.succeed(operation, []) }
                    else { self.fail(operation, code: "scan_failed", message: error.description) }
                } else {
                    self.succeed(operation, (wifiList ?? []).map { ["ssid": $0.ssid, "bssid": $0.bssid.toHexString(), "rssi": $0.rssi, "auth": $0.auth.rawValue, "channel": $0.channel] })
                }
            }
        }
    }

    @objc(disconnect:)
    func disconnect(deviceName: String) { disconnectDevice(deviceName, reason: "Device connection was cancelled.") }

    @objc(provision:ssid:passphrase:resolve:reject:)
    func provision(deviceName: String, ssid: String, passphrase: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let device = espDevices[deviceName] else {
            reject("device_disconnected", "Device is not connected.", nil)
            return
        }
        let operation = begin("provision", deviceName: deviceName, seconds: 65, resolve: resolve, reject: reject)
        device.provision(ssid: ssid, passPhrase: passphrase) { [weak self, weak operation] status in
            guard let self = self, let operation = operation else { return }
            self.onMain {
                switch status {
                case .success: self.succeed(operation, ["status": "success"])
                case .failure(let error): self.fail(operation, code: "provision_failed", message: error.description)
                case .configApplied: break
                }
            }
        }
    }

    @objc(getProofOfPossession:resolve:reject:)
    func getProofOfPossession(deviceName: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let espDevice = self.espDevices[deviceName] else {
            reject("error", "No ESP device found. Call createESPDevice first.", nil)
            return
        }

        resolve(deviceDelegates[deviceName]?.pop)
    }
    
    @objc(setProofOfPossession:proofOfPossession:resolve:reject:)
    func setProofOfPossession(deviceName: String, proofOfPossession: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let espDevice = self.espDevices[deviceName] else {
            reject("error", "No ESP device found. Call createESPDevice first.", nil)
            return
        }

        // Need to recreate the device to set proof of possession
        createESPDevice(deviceName: deviceName, transport: espDevice.transport.rawValue, security: espDevice.security.rawValue, proofOfPossession: proofOfPossession, softAPPassword: softAPPasswords[deviceName], username: espDevice.username, resolve: resolve, reject: reject)
    }
    
    @objc(getUsername:resolve:reject:)
    func getUsername(deviceName: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let espDevice = self.espDevices[deviceName] else {
            reject("error", "No ESP device found. Call createESPDevice first.", nil)
            return
        }

        resolve(espDevice.username)
    }
    
    @objc(setUsername:username:resolve:reject:)
    func setUsername(deviceName: String, username: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let espDevice = self.espDevices[deviceName] else {
            reject("error", "No ESP device found. Call createESPDevice first.", nil)
            return
        }

        espDevice.username = username
        deviceDelegates[deviceName]?.username = username
        resolve(username)
    }
    
    @objc(getDeviceName:resolve:reject:)
    func getDeviceName(deviceName: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let espDevice = self.espDevices[deviceName] else {
            reject("error", "No ESP device found. Call createESPDevice first.", nil)
            return
        }

        resolve(espDevice.name)
    }
    
    @objc(setDeviceName:newDeviceName:resolve:reject:)
    func setDeviceName(deviceName: String, newDeviceName: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let espDevice = self.espDevices[deviceName] else {
            reject("error", "No ESP device found. Call createESPDevice first.", nil)
            return
        }

        // No-op: Can't change device name on iOS
        resolve(newDeviceName)
    }
    
    @objc(getPrimaryServiceUuid:resolve:reject:)
    func getPrimaryServiceUuid(deviceName: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let espDevice = self.espDevices[deviceName] else {
            reject("error", "No ESP device found. Call createESPDevice first.", nil)
            return
        }

        // No-op: primaryServiceUuid does not exist on iOS
        resolve("")
    }
    
    @objc(setPrimaryServiceUuid:primaryServiceUuid:resolve:reject:)
    func setPrimaryServiceUuid(deviceName: String, primaryServiceUuid: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let espDevice = self.espDevices[deviceName] else {
            reject("error", "No ESP device found. Call createESPDevice first.", nil)
            return
        }

        // No-op: primaryServiceUuid does not exist on iOS
        resolve("")
    }
    
    @objc(getSecurityType:resolve:reject:)
    func getSecurityType(deviceName: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let espDevice = self.espDevices[deviceName] else {
            reject("error", "No ESP device found. Call createESPDevice first.", nil)
            return
        }

        resolve(espDevice.security.rawValue)
    }
    
    @objc(setSecurityType:security:resolve:reject:)
    func setSecurityType(deviceName: String, security: Int, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let espDevice = self.espDevices[deviceName] else {
            reject("error", "No ESP device found. Call createESPDevice first.", nil)
            return
        }

        let security = ESPSecurity(rawValue: security)
        espDevice.security = security
        resolve(security.rawValue)
    }
    
    @objc(getTransportType:resolve:reject:)
    func getTransportType(deviceName: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let espDevice = self.espDevices[deviceName] else {
            reject("error", "No ESP device found. Call createESPDevice first.", nil)
            return
        }

        resolve(espDevice.transport.rawValue)
    }
    
    @objc(getVersionInfo:resolve:reject:)
    func getVersionInfo(deviceName: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let espDevice = self.espDevices[deviceName] else {
            reject("error", "No ESP device found. Call createESPDevice first.", nil)
            return
        }

        resolve(espDevice.versionInfo)
    }
    
    @objc(getDeviceCapabilities:resolve:reject:)
    func getDeviceCapabilities(deviceName: String, resolve: @escaping RCTPromiseResolveBlock, reject: @escaping RCTPromiseRejectBlock) {
        guard let espDevice = self.espDevices[deviceName] else {
            reject("error", "No ESP device found. Call createESPDevice first.", nil)
            return
        }

        resolve(espDevice.capabilities)
    }
}

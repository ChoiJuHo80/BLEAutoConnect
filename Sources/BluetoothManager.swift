import Foundation
import CoreBluetooth

// 발견된 기기 정보 (UI 표시용)
struct DiscoveredDevice: Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String
    var rssi: Int
}

class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    // MARK: - Published State
    @Published var isBluetoothOn       = false
    @Published var connectionStatus    = "연결 해제됨"
    @Published var bluetoothStateString = "대기 중 (Initial)"
    @Published var logMessages: [String] = ["Manager initialized"]
    @Published var isScanning          = false
    @Published var discoveredDevices   = [DiscoveredDevice]()

    /// 현재 연결 완료된 기기 이름 (nil = 미연결)
    @Published var connectedDeviceName: String? = nil
    /// 등록(저장)된 기기 이름
    @Published var savedDeviceName: String? = nil

    // MARK: - Private
    private var centralManager: CBCentralManager?

    /// 연결 대상 peripheral (강한 참조 유지 필수)
    private var targetPeripheral: CBPeripheral?

    private var unknownStateRetryTimer: DispatchWorkItem?
    private var scanTimeoutTimer: DispatchWorkItem?

    /// 주기적 재연결 스캔 타이머
    private var reconnectTimer: DispatchWorkItem?

    /// 재연결 시도 횟수 (로그용)
    private var reconnectAttemptCount = 0

    /// 스캔 → 대기 주기 (초). 5~10초 권장.
    private let reconnectScanInterval: TimeInterval = 10
    /// 주기당 실제 스캔 시간 (초)
    private let reconnectScanDuration: TimeInterval = 5

    private let savedUUIDKey = "SavedDeviceUUID"
    private let savedNameKey = "SavedDeviceName"

    // MARK: - Singleton
    static let shared = BluetoothManager()

    private override init() {
        super.init()
        savedDeviceName = UserDefaults.standard.string(forKey: savedNameKey)
    }

    // MARK: - Logging
    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timeStr = formatter.string(from: Date())
        DispatchQueue.main.async {
            self.logMessages.append("[\(timeStr)] \(message)")
            if self.logMessages.count > 30 { self.logMessages.removeFirst() }
        }
    }

    // MARK: - Setup
    func setup() {
        log("setup() 호출.")
        guard centralManager == nil else { return }
        connectionStatus = "블루투스 서비스 시작 중..."
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.log("CBCentralManager 초기화 중...")
            self.centralManager = CBCentralManager(
                delegate: self,
                queue: .main,
                options: [
                    CBCentralManagerOptionShowPowerAlertKey: true,
                    CBCentralManagerOptionRestoreIdentifierKey: "com.bleautoconnect.central"
                ]
            )
        }
    }

    func forceReset() {
        log("강제 재설정.")
        stopAllTimers()
        centralManager = nil
        targetPeripheral = nil
        connectedDeviceName = nil
        setup()
    }

    // MARK: - 저장 / 불러오기

    private func saveDevice(uuid: String, name: String) {
        UserDefaults.standard.set(uuid, forKey: savedUUIDKey)
        UserDefaults.standard.set(name, forKey: savedNameKey)
        UserDefaults.standard.synchronize()   // ← 즉시 디스크 기록
        savedDeviceName = name
        log("💾 기기 저장됨: '\(name)' [\(uuid.prefix(8))...]")
    }

    private func clearSavedDevice() {
        UserDefaults.standard.removeObject(forKey: savedUUIDKey)
        UserDefaults.standard.removeObject(forKey: savedNameKey)
        UserDefaults.standard.synchronize()
        savedDeviceName = nil
        log("🗑 저장된 기기 삭제됨.")
    }

    private var savedUUID: UUID? {
        guard let s = UserDefaults.standard.string(forKey: savedUUIDKey) else { return nil }
        return UUID(uuidString: s)
    }

    // MARK: - Manual Scan (기기 목록 검색용)

    func startScanning() {
        guard let manager = centralManager, manager.state == .poweredOn else {
            log("스캔 불가: BT 상태 = \(centralManager?.state.rawValue ?? -1)")
            return
        }
        stopAllTimers()
        discoveredDevices.removeAll()
        isScanning = true
        connectionStatus = "주변 기기 검색 중..."
        log("📡 수동 스캔 시작 (30초)")

        centralManager?.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.isScanning else { return }
            self.log("⏱ 30초 타임아웃 — 스캔 종료. \(self.discoveredDevices.count)개 발견")
            self.stopManualScan()
            self.connectionStatus = self.discoveredDevices.isEmpty
                ? "주변에 기기가 없습니다. 워치 블루투스를 확인해주세요."
                : "검색 완료. 기기를 선택하세요."
        }
        scanTimeoutTimer = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: timeout)
    }

    private func stopManualScan() {
        scanTimeoutTimer?.cancel()
        scanTimeoutTimer = nil
        centralManager?.stopScan()
        isScanning = false
    }

    func stopScanning() {
        stopManualScan()
        log("스캔 중지.")
    }

    // MARK: - 기기 선택 → 연결

    func selectDevice(_ device: DiscoveredDevice) {
        stopManualScan()

        let peripheral = device.peripheral
        targetPeripheral = peripheral          // 강한 참조 유지
        targetPeripheral?.delegate = self

        // 즉시 저장
        saveDevice(uuid: peripheral.identifier.uuidString, name: device.name)

        connectionStatus = "'\(device.name)'에 연결 중..."
        log("🔗 연결 시도: \(device.name)")
        centralManager?.connect(peripheral, options: nil)
    }

    // MARK: - 자동 재연결

    /// 저장된 UUID로 재연결 시도. 없으면 이름 기반 주기 스캔 시작.
    func attemptAutoReconnect() {
        reconnectAttemptCount = 0
        tryReconnectByUUID()
    }

    private func tryReconnectByUUID() {
        guard let uuid = savedUUID else {
            log("저장된 UUID 없음 — 수동 검색 필요.")
            connectionStatus = "등록된 기기가 없습니다. 검색 후 선택해주세요."
            return
        }

        // ① 시스템 캐시에서 peripheral 조회 (가장 빠름)
        let known = centralManager?.retrievePeripherals(withIdentifiers: [uuid]) ?? []
        if let peripheral = known.first {
            log("✅ UUID로 기기 발견 → 연결 요청")
            targetPeripheral = peripheral
            targetPeripheral?.delegate = self
            let name = savedDeviceName ?? "기기"
            connectionStatus = "'\(name)' 재연결 중..."
            centralManager?.connect(peripheral, options: nil)
            return
        }

        // ② 이미 연결된 peripheral 중 확인
        let connected = centralManager?.retrieveConnectedPeripherals(withServices: []) ?? []
        if let peripheral = connected.first(where: { $0.identifier == uuid }) {
            log("✅ 이미 연결된 기기 발견 → 연결 요청")
            targetPeripheral = peripheral
            targetPeripheral?.delegate = self
            centralManager?.connect(peripheral, options: nil)
            return
        }

        // ③ 범위 밖이거나 캐시 없음 → 주기적 스캔으로 전환
        log("UUID 캐시 없음 — \(Int(reconnectScanInterval))초 주기 스캔 시작")
        let name = savedDeviceName ?? "기기"
        connectionStatus = "'\(name)' 찾는 중... (자동 재연결 대기)"
        startPeriodicReconnectScan()
    }

    /// 연결이 끊긴 뒤 주기적으로 스캔해 기기를 찾아 재연결
    private func startPeriodicReconnectScan() {
        stopAllTimers()
        guard savedUUID != nil else { return }

        reconnectAttemptCount += 1
        let name = savedDeviceName ?? "기기"
        log("🔄 재연결 스캔 #\(reconnectAttemptCount) — '\(name)' 검색 중...")

        // 스캔 시작
        centralManager?.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        // reconnectScanDuration 후 스캔 중지, reconnectScanInterval 후 재시도
        let stopWork = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.centralManager?.stopScan()

            // 아직 미연결이면 다음 주기 예약
            if self.connectedDeviceName == nil, self.savedUUID != nil {
                let nextWork = DispatchWorkItem { [weak self] in
                    self?.startPeriodicReconnectScan()
                }
                self.reconnectTimer = nextWork
                DispatchQueue.main.asyncAfter(
                    deadline: .now() + self.reconnectScanInterval,
                    execute: nextWork
                )
            }
        }
        reconnectTimer = stopWork
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectScanDuration, execute: stopWork)
    }

    private func stopAllTimers() {
        scanTimeoutTimer?.cancel(); scanTimeoutTimer = nil
        reconnectTimer?.cancel();   reconnectTimer = nil
        unknownStateRetryTimer?.cancel(); unknownStateRetryTimer = nil
    }

    // MARK: - 연결 해제

    func disconnect() {
        stopAllTimers()
        if let p = targetPeripheral { centralManager?.cancelPeripheralConnection(p) }
        targetPeripheral = nil
        connectedDeviceName = nil
        clearSavedDevice()
        connectionStatus = "연결 해제됨"
        log("수동 연결 해제.")
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("BT 상태: \(central.state.rawValue)")
        isBluetoothOn = central.state == .poweredOn

        switch central.state {
        case .poweredOn:
            bluetoothStateString = "활성화됨 (Powered On)"
            attemptAutoReconnect()

        case .poweredOff:
            bluetoothStateString = "비활성화됨 (Powered Off)"
            connectionStatus = "블루투스가 꺼져 있습니다."
            stopAllTimers()

        case .unauthorized:
            bluetoothStateString = "권한 없음 (Unauthorized)"
            connectionStatus = "[설정] > [BLEAutoConnect]에서 블루투스 권한을 허용해주세요."

        case .unsupported:
            bluetoothStateString = "지원되지 않음 (Unsupported)"
            connectionStatus = "이 기기는 블루투스 LE를 지원하지 않습니다."

        case .resetting:
            bluetoothStateString = "재설정 중 (Resetting)"
            connectionStatus = "블루투스 서비스가 재설정 중입니다..."

        case .unknown:
            bluetoothStateString = "알 수 없음 (Unknown)"
            connectionStatus = "블루투스 초기화 중..."
            log("Unknown 상태. 3초 후 재시도.")
            unknownStateRetryTimer?.cancel()
            let retry = DispatchWorkItem { [weak self] in
                guard let self, self.centralManager?.state == .unknown else { return }
                self.log("Unknown 지속 — CBCentralManager 재생성.")
                self.centralManager = nil
                self.centralManager = CBCentralManager(
                    delegate: self, queue: .main,
                    options: [
                        CBCentralManagerOptionShowPowerAlertKey: true,
                        CBCentralManagerOptionRestoreIdentifierKey: "com.bleautoconnect.central"
                    ]
                )
            }
            unknownStateRetryTimer = retry
            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: retry)

        @unknown default:
            bluetoothStateString = "알 수 없는 상태"
            connectionStatus = "알 수 없는 블루투스 오류."
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let peripheralName = peripheral.name ?? ""
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        let resolvedName   = peripheralName.isEmpty ? advertisedName : peripheralName

        // ── 자동 재연결 스캔 중일 때: 저장된 기기와 UUID 매칭 ──
        if connectedDeviceName == nil, let uuid = savedUUID, !isScanning {
            if peripheral.identifier == uuid {
                log("✅ 저장된 기기 발견 (UUID 일치) → 재연결")
                stopAllTimers()
                centralManager?.stopScan()
                targetPeripheral = peripheral
                targetPeripheral?.delegate = self
                let name = savedDeviceName ?? resolvedName
                connectionStatus = "'\(name)' 재연결 중..."
                centralManager?.connect(peripheral, options: nil)
                return
            }
            // 이름으로도 매칭 시도 (UUID 변경 대응)
            if let savedName = savedDeviceName,
               !resolvedName.isEmpty,
               resolvedName.localizedCaseInsensitiveContains(savedName) {
                log("✅ 저장된 기기 발견 (이름 일치: '\(resolvedName)') → UUID 갱신 후 재연결")
                stopAllTimers()
                centralManager?.stopScan()
                saveDevice(uuid: peripheral.identifier.uuidString, name: resolvedName)
                targetPeripheral = peripheral
                targetPeripheral?.delegate = self
                connectionStatus = "'\(resolvedName)' 재연결 중..."
                centralManager?.connect(peripheral, options: nil)
                return
            }
        }

        // ── 수동 스캔 중일 때: 목록에 추가 ──
        guard isScanning else { return }
        guard !resolvedName.isEmpty else { return }

        let rssiValue = RSSI.intValue
        if let idx = discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
            discoveredDevices[idx].rssi = rssiValue
        } else {
            log("📡 발견: '\(resolvedName)' (\(rssiValue) dBm)")
            discoveredDevices.append(DiscoveredDevice(
                id: peripheral.identifier,
                peripheral: peripheral,
                name: resolvedName,
                rssi: rssiValue
            ))
            discoveredDevices.sort { $0.rssi > $1.rssi }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        stopAllTimers()
        let name = peripheral.name ?? savedDeviceName ?? "기기"
        // UUID·이름 최신 상태로 재저장
        saveDevice(uuid: peripheral.identifier.uuidString, name: name)
        connectedDeviceName = name
        connectionStatus    = "✅ '\(name)' 연결됨"
        isScanning          = false
        discoveredDevices.removeAll()
        log("🟢 연결 성공: \(name)")
        central.stopScan()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("❌ 연결 실패: \(error?.localizedDescription ?? "알 수 없는 오류") — \(Int(reconnectScanInterval))초 후 재시도")
        connectionStatus = "연결 실패 — 자동 재시도 중..."
        // 일정 시간 후 재시도
        let retry = DispatchWorkItem { [weak self] in self?.tryReconnectByUUID() }
        reconnectTimer = retry
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectScanInterval, execute: retry)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let name = savedDeviceName ?? peripheral.name ?? "기기"
        log("🔴 연결 끊김: \(name)\(error != nil ? " (\(error!.localizedDescription))" : "")")
        connectedDeviceName = nil
        connectionStatus    = "'\(name)' 연결 끊김 — 자동 재연결 중..."

        // 저장된 기기가 있으면 즉시 재연결 시도
        if savedUUID != nil {
            targetPeripheral = peripheral  // 참조 유지
            tryReconnectByUUID()
        }
    }

    func centralManager(_ central: CBCentralManager,
                        willRestoreState dict: [String: Any]) {
        log("🔁 백그라운드 복원 중...")
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = peripherals.first {
            targetPeripheral = p
            targetPeripheral?.delegate = self
            central.connect(p, options: nil)
            log("복원된 기기 재연결 요청: \(p.name ?? "기기")")
        }
    }
}

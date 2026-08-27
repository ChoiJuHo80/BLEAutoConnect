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
    @Published var isBluetoothOn = false
    @Published var connectionStatus = "연결 해제됨"
    @Published var bluetoothStateString = "대기 중 (Initial)"
    @Published var logMessages: [String] = ["Manager initialized"]
    @Published var isScanning = false

    /// 스캔 중 발견된 기기 목록 (이름 있는 것만)
    @Published var discoveredDevices: [DiscoveredDevice] = []

    /// 현재 연결된 기기 이름 (nil이면 미연결)
    @Published var connectedDeviceName: String? = nil

    /// 등록된 기기 이름 (UI 표시용)
    @Published var savedDeviceName: String? = nil

    // MARK: - Private
    private var centralManager: CBCentralManager?
    private var targetPeripheral: CBPeripheral?
    private var unknownStateRetryTimer: DispatchWorkItem?
    private var scanTimeoutTimer: DispatchWorkItem?

    private let savedUUIDKey  = "SavedDeviceUUID"
    private let savedNameKey  = "SavedDeviceName"

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
        let logLine = "[\(timeStr)] \(message)"
        DispatchQueue.main.async {
            self.logMessages.append(logLine)
            if self.logMessages.count > 20 {
                self.logMessages.removeFirst()
            }
        }
    }

    // MARK: - Setup
    func setup() {
        log("setup() 호출됨.")
        guard centralManager == nil else { return }
        connectionStatus = "블루투스 서비스 시작 중..."

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.log("CBCentralManager 초기화...")
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
        log("강제 재설정 중...")
        stopScanning()
        centralManager = nil
        targetPeripheral = nil
        connectedDeviceName = nil
        setup()
    }

    // MARK: - Scanning

    func startScanning() {
        guard let manager = centralManager, manager.state == .poweredOn else {
            log("스캔 불가: BT 상태 = \(centralManager?.state.rawValue ?? -1)")
            return
        }
        discoveredDevices.removeAll()
        isScanning = true
        connectionStatus = "주변 기기 검색 중..."
        log("스캔 시작 (30초)")

        centralManager?.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        // 30초 타임아웃
        scanTimeoutTimer?.cancel()
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isScanning else { return }
            self.log("30초 타임아웃 — 스캔 종료. 발견 \(self.discoveredDevices.count)개")
            self.stopScanning()
            if self.discoveredDevices.isEmpty {
                self.connectionStatus = "주변에 기기가 없습니다."
            } else {
                self.connectionStatus = "검색 완료. 기기를 선택하세요."
            }
        }
        scanTimeoutTimer = timeoutItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: timeoutItem)
    }

    func stopScanning() {
        scanTimeoutTimer?.cancel()
        scanTimeoutTimer = nil
        centralManager?.stopScan()
        isScanning = false
        log("스캔 중지.")
    }

    // MARK: - Connection

    /// 목록에서 기기 선택 시 호출
    func selectDevice(_ device: DiscoveredDevice) {
        stopScanning()
        let peripheral = device.peripheral
        targetPeripheral = peripheral
        targetPeripheral?.delegate = self
        connectionStatus = "'\(device.name)'에 연결 중..."
        log("연결 시도: \(device.name)")

        // UUID + 이름 저장 (다음 실행 시 자동 재연결용)
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: savedUUIDKey)
        UserDefaults.standard.set(device.name, forKey: savedNameKey)
        savedDeviceName = device.name

        centralManager?.connect(peripheral, options: nil)
    }

    /// 저장된 UUID로 빠른 재연결 시도 (스캔 없이)
    func attemptReconnectByUUID() {
        guard let uuidString = UserDefaults.standard.string(forKey: savedUUIDKey),
              let uuid = UUID(uuidString: uuidString) else {
            log("저장된 기기 없음. 수동 검색 필요.")
            connectionStatus = "등록된 기기가 없습니다. 검색 후 선택해주세요."
            return
        }

        let peripherals = centralManager?.retrievePeripherals(withIdentifiers: [uuid]) ?? []
        if let peripheral = peripherals.first {
            let name = UserDefaults.standard.string(forKey: savedNameKey) ?? "기기"
            log("저장된 기기 재연결 시도: \(name)")
            targetPeripheral = peripheral
            targetPeripheral?.delegate = self
            connectionStatus = "'\(name)' 자동 재연결 중..."
            centralManager?.connect(peripheral, options: nil)
        } else {
            log("저장된 UUID 기기 없음. 범위 밖일 수 있음.")
            connectionStatus = "'\(savedDeviceName ?? "기기")'을 찾는 중... (범위 내 진입 대기)"
            // UUID로 pending connection 등록 — 범위 내 오면 자동 연결
            if let uuidString = UserDefaults.standard.string(forKey: savedUUIDKey),
               let uuid = UUID(uuidString: uuidString) {
                // retrieveConnectedPeripherals로도 한 번 더 시도
                let connected = centralManager?.retrieveConnectedPeripherals(withServices: []) ?? []
                if let p = connected.first(where: { $0.identifier == uuid }) {
                    targetPeripheral = p
                    targetPeripheral?.delegate = self
                    centralManager?.connect(p, options: nil)
                }
            }
        }
    }

    func disconnect() {
        if let peripheral = targetPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        UserDefaults.standard.removeObject(forKey: savedUUIDKey)
        UserDefaults.standard.removeObject(forKey: savedNameKey)
        targetPeripheral = nil
        connectedDeviceName = nil
        savedDeviceName = nil
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
            attemptReconnectByUUID()

        case .poweredOff:
            bluetoothStateString = "비활성화됨 (Powered Off)"
            connectionStatus = "블루투스가 꺼져 있습니다."

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
            let retryItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.centralManager?.state == .unknown else { return }
                self.log("Unknown 지속. CBCentralManager 재생성.")
                self.centralManager = nil
                self.centralManager = CBCentralManager(
                    delegate: self, queue: .main,
                    options: [
                        CBCentralManagerOptionShowPowerAlertKey: true,
                        CBCentralManagerOptionRestoreIdentifierKey: "com.bleautoconnect.central"
                    ]
                )
            }
            unknownStateRetryTimer = retryItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0, execute: retryItem)

        @unknown default:
            bluetoothStateString = "알 수 없는 상태"
            connectionStatus = "알 수 없는 블루투스 오류."
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // peripheral.name 과 광고 데이터 LocalName 둘 다 확인
        let peripheralName = peripheral.name ?? ""
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        let resolvedName = peripheralName.isEmpty ? advertisedName : peripheralName

        // 이름 없는 기기는 목록에서 제외
        guard !resolvedName.isEmpty else { return }

        let rssiValue = RSSI.intValue
        if let idx = discoveredDevices.firstIndex(where: { $0.id == peripheral.identifier }) {
            // 이미 있으면 RSSI만 업데이트
            discoveredDevices[idx].rssi = rssiValue
        } else {
            log("📡 발견: '\(resolvedName)' (RSSI: \(rssiValue))")
            let device = DiscoveredDevice(
                id: peripheral.identifier,
                peripheral: peripheral,
                name: resolvedName,
                rssi: rssiValue
            )
            discoveredDevices.append(device)
            // RSSI 강한 순으로 정렬
            discoveredDevices.sort { $0.rssi > $1.rssi }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name
            ?? UserDefaults.standard.string(forKey: savedNameKey)
            ?? "기기"
        connectedDeviceName = name
        connectionStatus = "✅ '\(name)' 연결됨"
        isScanning = false
        discoveredDevices.removeAll()
        log("연결 성공: \(name)")
        centralManager?.stopScan()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("연결 실패: \(error?.localizedDescription ?? "알 수 없는 오류") — 재시도")
        connectionStatus = "연결 실패. 재시도 중..."
        centralManager?.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let name = UserDefaults.standard.string(forKey: savedNameKey) ?? "기기"
        log("연결 끊김: \(name). 재연결 대기 중...")
        connectedDeviceName = nil
        connectionStatus = "'\(name)' 연결 끊김 — 범위 내 진입 시 자동 재연결"
        centralManager?.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        willRestoreState dict: [String: Any]) {
        connectionStatus = "연결 복원 중..."
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            targetPeripheral = restored
            targetPeripheral?.delegate = self
            centralManager?.connect(restored, options: nil)
            log("백그라운드 복원: \(restored.name ?? "기기")")
        }
    }
}

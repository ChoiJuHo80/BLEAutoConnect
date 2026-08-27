import Foundation
import CoreBluetooth

class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    // MARK: - Published State
    @Published var isBluetoothOn = false
    @Published var connectionStatus = "연결 해제됨"
    @Published var bluetoothStateString = "대기 중 (Initial)"
    @Published var logMessages: [String] = ["Manager initialized"]
    @Published var isScanning = false

    /// 사용자가 설정한 연결 대상 기기 이름
    @Published var targetDeviceName: String = ""

    /// 현재 연결된(또는 연결 중인) 기기 이름
    @Published var connectedDeviceName: String? = nil

    // MARK: - Private
    private var centralManager: CBCentralManager?
    private var targetPeripheral: CBPeripheral?
    private var unknownStateRetryTimer: DispatchWorkItem?
    private var scanTimeoutTimer: DispatchWorkItem?

    private let targetDeviceNameKey = "TargetDeviceName"
    private let savedUUIDKey        = "SavedWatchUUID"

    // MARK: - Singleton
    static let shared = BluetoothManager()

    private override init() {
        super.init()
        targetDeviceName = UserDefaults.standard.string(forKey: targetDeviceNameKey) ?? ""
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
                    // 재부팅 후 BLE 이벤트 발생 시 iOS가 앱을 백그라운드로 자동 재시작
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

    /// 대상 기기 이름으로 스캔 시작 (이름이 비어있으면 전체 스캔)
    func startScanning() {
        guard let manager = centralManager, manager.state == .poweredOn else {
            log("스캔 불가: BT 상태 = \(centralManager?.state.rawValue ?? -1)")
            return
        }

        isScanning = true
        let nameFilter = targetDeviceName.trimmingCharacters(in: .whitespaces)
        if nameFilter.isEmpty {
            connectionStatus = "주변 기기 검색 중... (전체)"
            log("스캔 시작 — 이름 필터 없음 (전체 기기)")
        } else {
            connectionStatus = "'\(nameFilter)' 기기 검색 중..."
            log("스캔 시작 — 필터: '\(nameFilter)'")
        }

        centralManager?.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])

        // 30초 타임아웃
        scanTimeoutTimer?.cancel()
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.isScanning else { return }
            self.log("30초 타임아웃 — 기기를 찾지 못했습니다.")
            self.stopScanning()
            self.connectionStatus = "'\(self.targetDeviceName)' 기기를 찾지 못했습니다. 워치의 블루투스를 확인해주세요."
        }
        scanTimeoutTimer = timeoutItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: timeoutItem)
    }

    func stopScanning() {
        scanTimeoutTimer?.cancel()
        scanTimeoutTimer = nil
        centralManager?.stopScan()
        isScanning = false
        log("스캔 중지됨.")
    }

    // MARK: - Connection

    func connect(to peripheral: CBPeripheral) {
        stopScanning()
        targetPeripheral = peripheral
        targetPeripheral?.delegate = self
        let name = peripheral.name ?? "기기"
        connectionStatus = "'\(name)'에 연결 중..."
        log("연결 시도: \(name)")

        // UUID 저장 (재연결용)
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: savedUUIDKey)

        centralManager?.connect(peripheral, options: nil)
    }

    /// 저장된 UUID로 빠른 재연결 시도 (스캔 없이)
    func attemptReconnectByUUID() {
        guard let uuidString = UserDefaults.standard.string(forKey: savedUUIDKey),
              let uuid = UUID(uuidString: uuidString) else {
            // UUID 없으면 이름으로 스캔 시작
            if !targetDeviceName.trimmingCharacters(in: .whitespaces).isEmpty {
                log("저장된 UUID 없음. 이름 스캔으로 전환.")
                startScanning()
            }
            return
        }

        let peripherals = centralManager?.retrievePeripherals(withIdentifiers: [uuid]) ?? []
        if let peripheral = peripherals.first {
            log("저장된 UUID로 재연결 시도: \(peripheral.name ?? uuid.uuidString)")
            targetPeripheral = peripheral
            targetPeripheral?.delegate = self
            connectionStatus = "이전 기기 자동 재연결 중..."
            centralManager?.connect(peripheral, options: nil)
        } else {
            log("저장된 UUID 기기 없음. 이름 스캔으로 전환.")
            startScanning()
        }
    }

    func disconnect() {
        if let peripheral = targetPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        UserDefaults.standard.removeObject(forKey: savedUUIDKey)
        targetPeripheral = nil
        connectedDeviceName = nil
        connectionStatus = "연결 해제됨"
        log("수동 연결 해제.")
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("BT 상태 변경: \(central.state.rawValue)")
        isBluetoothOn = central.state == .poweredOn

        switch central.state {
        case .poweredOn:
            bluetoothStateString = "활성화됨 (Powered On)"
            // 앱 시작 시 자동 재연결 시도
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
            log("Unknown 상태. 3초 후 재시도 예약.")
            unknownStateRetryTimer?.cancel()
            let retryItem = DispatchWorkItem { [weak self] in
                guard let self = self, self.centralManager?.state == .unknown else { return }
                self.log("Unknown 상태 지속. CBCentralManager 재생성.")
                self.centralManager = nil
                self.centralManager = CBCentralManager(
                    delegate: self, queue: .main,
                    options: [CBCentralManagerOptionShowPowerAlertKey: true]
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
        let name = peripheral.name ?? ""
        let filter = targetDeviceName.trimmingCharacters(in: .whitespaces)

        // 이름 필터가 설정된 경우: 포함 여부로 매칭 (대소문자 무시)
        if !filter.isEmpty {
            guard name.localizedCaseInsensitiveContains(filter) else { return }
            log("✅ 대상 기기 발견: '\(name)' (RSSI: \(RSSI)) — 자동 연결 시작")
            connect(to: peripheral)
        } else {
            // 필터 없을 때 전체 목록 수집 (수동 선택용)
            log("기기 발견: '\(name.isEmpty ? "이름없음" : name)' RSSI: \(RSSI)")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name ?? "기기"
        connectedDeviceName = name
        connectionStatus = "✅ '\(name)' 연결됨"
        isScanning = false
        log("연결 성공: \(name)")
        centralManager?.stopScan()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("연결 실패: \(error?.localizedDescription ?? "알 수 없는 오류") — 재시도 중...")
        connectionStatus = "연결 실패. 재시도 중..."
        centralManager?.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        log("연결 끊김: \(peripheral.name ?? "기기"). 자동 재연결 대기 중...")
        connectedDeviceName = nil
        connectionStatus = "연결 끊김 — 범위 내 진입 시 자동 재연결"
        // 범위 안에 오면 OS가 자동으로 연결해줌
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

import Foundation
import CoreBluetooth

class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var isBluetoothOn = false
    @Published var connectionStatus = "연결 해제됨"
    @Published var discoveredPeripherals = [CBPeripheral]()
    @Published var savedDeviceName: String? = nil
    @Published var bluetoothStateString = "대기 중 (Initial)"
    @Published var logMessages: [String] = ["Manager initialized"]
    
    private var centralManager: CBCentralManager?
    private var targetPeripheral: CBPeripheral?
    
    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let timeStr = formatter.string(from: Date())
        let logLine = "[\(timeStr)] \(message)"
        DispatchQueue.main.async {
            self.logMessages.append(logLine)
            if self.logMessages.count > 12 {
                self.logMessages.removeFirst()
            }
        }
    }
    
    static let shared = BluetoothManager()
    
    private let savedUUIDKey = "SavedWatchUUID"
    private let savedNameKey = "SavedWatchName"
    
    private override init() {
        super.init()
        savedDeviceName = UserDefaults.standard.string(forKey: savedNameKey)
    }
    
    func setup() {
        log("setup() 호출됨. centralManager: \(centralManager == nil ? "nil" : "존재함")")
        
        // Info.plist 권한 설정 검증 로그 추가
        let alwaysDesc = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String
        let peripheralDesc = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothPeripheralUsageDescription") as? String
        log("Always 권한설명: \(alwaysDesc ?? "없음 (nil)")")
        log("Peripheral 권한설명: \(peripheralDesc ?? "없음 (nil)")")
        
        guard centralManager == nil else { return }
        connectionStatus = "블루투스 서비스 시작 대기 중..."
        
        // 앱이 완전히 활성화(Foreground Active)된 상태에서 팝업을 띄우기 위해 1.5초 지연
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            self.log("1.5초 지연 후 CBCentralManager 초기화 시도...")
            self.connectionStatus = "블루투스 서비스 시작 중..."
            self.centralManager = CBCentralManager(delegate: self, queue: .main, options: [
                CBCentralManagerOptionShowPowerAlertKey: true
            ])
            self.log("CBCentralManager 생성 완료.")
            if let state = self.centralManager?.state {
                self.log("매니저 초기 상태값: \(state.rawValue)")
            }
        }
    }
    
    func forceReset() {
        log("forceReset() 호출됨. 강제 재설정 중...")
        centralManager = nil
        setup()
    }
    
    // 주변 블루투스 기기 스캔 시작
    func startScanning() {
        guard let manager = centralManager, manager.state == .poweredOn else { return }
        discoveredPeripherals.removeAll()
        connectionStatus = "주변 기기 검색 중..."
        
        // 포그라운드 상태에서는 모든 서비스를 스캔하도록 nil 설정
        centralManager?.scanForPeripherals(withServices: nil, options: nil)
    }
    
    // 스캔 중지
    func stopScanning() {
        centralManager?.stopScan()
        if targetPeripheral == nil {
            connectionStatus = "연결 해제됨"
        }
    }
    
    // 특정 기기에 연결 요청 및 정보 저장
    func connect(to peripheral: CBPeripheral) {
        centralManager?.stopScan()
        targetPeripheral = peripheral
        targetPeripheral?.delegate = self
        connectionStatus = "\(peripheral.name ?? "기기")에 연결 중..."
        
        // 기기의 고유 UUID와 이름을 기기에 영구 저장
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: savedUUIDKey)
        UserDefaults.standard.set(peripheral.name ?? "기기", forKey: savedNameKey)
        savedDeviceName = peripheral.name ?? "기기"
        
        centralManager?.connect(peripheral, options: nil)
    }
    
    // 기기 연동 해제
    func disconnect() {
        if let peripheral = targetPeripheral {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        UserDefaults.standard.removeObject(forKey: savedUUIDKey)
        UserDefaults.standard.removeObject(forKey: savedNameKey)
        savedDeviceName = nil
        targetPeripheral = nil
        connectionStatus = "연결 해제됨"
    }
    
    // 저장된 기기 정보를 바탕으로 자동 재연동 시도
    func attemptAutoConnect() {
        guard let uuidString = UserDefaults.standard.string(forKey: savedUUIDKey),
              let uuid = UUID(uuidString: uuidString) else {
            return
        }
        
        // 이미 저장된 UUID를 통해 기기 객체를 조회 (스캔 불필요)
        let peripherals = centralManager?.retrievePeripherals(withIdentifiers: [uuid]) ?? []
        if let peripheral = peripherals.first {
            targetPeripheral = peripheral
            targetPeripheral?.delegate = self
            connectionStatus = "이전 등록된 기기 자동 연결 대기 중..."
            
            // 연결 대기 (Pending Connection) 시작 - 범위 내에 감지되면 OS가 자동 연결함
            centralManager?.connect(peripheral, options: nil)
        } else {
            connectionStatus = "이전 등록된 기기를 찾을 수 없습니다. 다시 페어링해 주세요."
        }
    }
    
    // MARK: - CBCentralManagerDelegate
    
    // 블루투스 상태 변경 감지
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("centralManagerDidUpdateState() 호출됨. 상태: \(central.state.rawValue)")
        isBluetoothOn = central.state == .poweredOn
        
        switch central.state {
        case .poweredOn:
            bluetoothStateString = "활성화됨 (Powered On)"
            attemptAutoConnect()
        case .poweredOff:
            bluetoothStateString = "비활성화됨 (Powered Off)"
            connectionStatus = "블루투스가 꺼져 있습니다. 설정이나 제어 센터에서 블루투스를 켜주세요."
        case .unauthorized:
            bluetoothStateString = "권한 없음 (Unauthorized)"
            connectionStatus = "블루투스 권한이 거부되었습니다. 아이폰 [설정] > [BLEAutoConnect]에서 블루투스 권한을 허용해주세요."
        case .unsupported:
            bluetoothStateString = "지원되지 않음 (Unsupported)"
            connectionStatus = "이 기기는 블루투스를 지원하지 않습니다. (시뮬레이터 대신 실제 iOS 기기에서 실행해 주세요.)"
        case .resetting:
            bluetoothStateString = "재설정 중 (Resetting)"
            connectionStatus = "블루투스 서비스가 재설정 중입니다. 잠시만 기다려주세요."
        case .unknown:
            bluetoothStateString = "알 수 없음 (Unknown)"
            connectionStatus = "블루투스 상태를 초기화하는 중입니다..."
        @unknown default:
            bluetoothStateString = "알 수 없는 상태"
            connectionStatus = "알 수 없는 블루투스 오류가 발생했습니다."
        }
    }
    
    // 주변 기기 검색 결과 수신
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        // 이름이 없는 기기는 제외
        guard let name = peripheral.name, !name.isEmpty else { return }
        
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
        }
    }
    
    // 연결 성공시
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectionStatus = "\(peripheral.name ?? "기기") 연결됨"
        centralManager?.stopScan()
    }
    
    // 연결 실패시 (재대기)
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionStatus = "연결 실패: \(error?.localizedDescription ?? "알 수 없는 오류")"
        // 실패 시 즉시 재연결 대기 상태로 변경
        centralManager?.connect(peripheral, options: nil)
    }
    
    // 연결이 끊어졌을 때 (★ 핵심: 다시 백그라운드 재연결 대기 상태로 설정)
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionStatus = "연결 해제됨 (연결 범위 진입 시 자동 연동 대기)"
        
        // 기기가 감지되면 자동으로 연결을 진행하도록 대기 큐에 등록
        centralManager?.connect(peripheral, options: nil)
    }
    
    // 앱이 꺼진 후 백그라운드에서 블루투스 복원 시 처리
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        connectionStatus = "연결 복원 중..."
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restoredPeripheral = peripherals.first {
            self.targetPeripheral = restoredPeripheral
            self.targetPeripheral?.delegate = self
            // 복원된 기기에 연결 요청 유지
            centralManager?.connect(restoredPeripheral, options: nil)
        }
    }
}

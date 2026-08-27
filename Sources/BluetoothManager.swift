import Foundation
import CoreBluetooth

class BluetoothManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var isBluetoothOn = false
    @Published var connectionStatus = "연결 해제됨"
    @Published var discoveredPeripherals = [CBPeripheral]()
    @Published var savedDeviceName: String? = nil
    
    private var centralManager: CBCentralManager!
    private var targetPeripheral: CBPeripheral?
    
    private let savedUUIDKey = "SavedWatchUUID"
    private let savedNameKey = "SavedWatchName"
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        
        savedDeviceName = UserDefaults.standard.string(forKey: savedNameKey)
    }
    
    // 주변 블루투스 기기 스캔 시작
    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        discoveredPeripherals.removeAll()
        connectionStatus = "주변 기기 검색 중..."
        
        // 포그라운드 상태에서는 모든 서비스를 스캔하도록 nil 설정
        centralManager.scanForPeripherals(withServices: nil, options: nil)
    }
    
    // 스캔 중지
    func stopScanning() {
        centralManager.stopScan()
        if targetPeripheral == nil {
            connectionStatus = "연결 해제됨"
        }
    }
    
    // 특정 기기에 연결 요청 및 정보 저장
    func connect(to peripheral: CBPeripheral) {
        centralManager.stopScan()
        targetPeripheral = peripheral
        targetPeripheral?.delegate = self
        connectionStatus = "\(peripheral.name ?? "기기")에 연결 중..."
        
        // 기기의 고유 UUID와 이름을 기기에 영구 저장
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: savedUUIDKey)
        UserDefaults.standard.set(peripheral.name ?? "기기", forKey: savedNameKey)
        savedDeviceName = peripheral.name ?? "기기"
        
        centralManager.connect(peripheral, options: nil)
    }
    
    // 기기 연동 해제
    func disconnect() {
        if let peripheral = targetPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
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
        let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
        if let peripheral = peripherals.first {
            targetPeripheral = peripheral
            targetPeripheral?.delegate = self
            connectionStatus = "이전 등록된 기기 자동 연결 대기 중..."
            
            // 연결 대기 (Pending Connection) 시작 - 범위 내에 감지되면 OS가 자동 연결함
            centralManager.connect(peripheral, options: nil)
        } else {
            connectionStatus = "이전 등록된 기기를 찾을 수 없습니다. 다시 페어링해 주세요."
        }
    }
    
    // MARK: - CBCentralManagerDelegate
    
    // 블루투스 상태 변경 감지
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isBluetoothOn = central.state == .poweredOn
        if central.state == .poweredOn {
            attemptAutoConnect()
        } else {
            connectionStatus = "블루투스가 꺼져 있습니다."
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
        centralManager.stopScan()
    }
    
    // 연결 실패시 (재대기)
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionStatus = "연결 실패: \(error?.localizedDescription ?? "알 수 없는 오류")"
        // 실패 시 즉시 재연결 대기 상태로 변경
        centralManager.connect(peripheral, options: nil)
    }
    
    // 연결이 끊어졌을 때 (★ 핵심: 다시 백그라운드 재연결 대기 상태로 설정)
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionStatus = "연결 해제됨 (연결 범위 진입 시 자동 연동 대기)"
        
        // 기기가 감지되면 자동으로 연결을 진행하도록 대기 큐에 등록
        centralManager.connect(peripheral, options: nil)
    }
    
    // 앱이 꺼진 후 백그라운드에서 블루투스 복원 시 처리
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        connectionStatus = "연결 복원 중..."
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restoredPeripheral = peripherals.first {
            self.targetPeripheral = restoredPeripheral
            self.targetPeripheral?.delegate = self
            // 복원된 기기에 연결 요청 유지
            centralManager.connect(restoredPeripheral, options: nil)
        }
    }
}

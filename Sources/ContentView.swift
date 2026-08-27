import SwiftUI

struct ContentView: View {
    @StateObject private var bluetoothManager = BluetoothManager()
    @State private var isScanning = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Status Section
                VStack(spacing: 8) {
                    Text("연동 상태 (Connection Status)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text(bluetoothManager.connectionStatus)
                        .font(.headline)
                        .foregroundColor(statusColor)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Divider()
                        .padding(.horizontal, 40)
                    
                    HStack(spacing: 4) {
                        Text("HW 블루투스:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text(bluetoothManager.bluetoothStateString)
                            .font(.caption2)
                            .bold()
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color(.systemGray6))
                .cornerRadius(10)
                .padding(.horizontal)
                
                // Saved Device Section
                if let savedName = bluetoothManager.savedDeviceName {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("등록된 기기 (Registered Device)")
                            .font(.subheadline)
                            .bold()
                        
                        HStack {
                            Image(systemName: "applewatch")
                                .font(.title)
                                .foregroundColor(.blue)
                            
                            VStack(alignment: .leading) {
                                Text(savedName)
                                    .font(.body)
                                    .bold()
                                Text("범위 내 진입 시 백그라운드 자동 연결")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button(action: {
                                bluetoothManager.disconnect()
                            }) {
                                Text("등록 해제")
                                    .foregroundColor(.red)
                                    .font(.footnote)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(5)
                            }
                        }
                        .padding()
                        .background(Color.blue.opacity(0.05))
                        .cornerRadius(10)
                    }
                    .padding(.horizontal)
                }
                
                // Scan Toggle Button
                Button(action: {
                    if isScanning {
                        bluetoothManager.stopScanning()
                        isScanning = false
                    } else {
                        bluetoothManager.startScanning()
                        isScanning = true
                    }
                }) {
                    Text(isScanning ? "스캔 중지 (Stop Scanning)" : "주변 기기 검색 (Scan for Devices)")
                        .font(.headline)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(bluetoothManager.isBluetoothOn ? (isScanning ? Color.red : Color.blue) : Color.gray)
                        .cornerRadius(10)
                }
                .disabled(!bluetoothManager.isBluetoothOn)
                .padding(.horizontal)
                
                // Scan Results
                if isScanning {
                    List(bluetoothManager.discoveredPeripherals, id: \.identifier) { peripheral in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(peripheral.name ?? "이름 없는 기기")
                                    .font(.body)
                                    .bold()
                                Text(peripheral.identifier.uuidString)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button("연동 (Pair)") {
                                bluetoothManager.connect(to: peripheral)
                                isScanning = false
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                } else {
                    Spacer()
                }
            }
            .navigationTitle("BLE Auto Connect")
            .onAppear {
                bluetoothManager.setup()
            }
            .onChange(of: bluetoothManager.connectionStatus) { newStatus in
                if newStatus.contains("Connected to") || newStatus.contains("연결됨") {
                    isScanning = false
                }
            }
        }
    }
    
    private var statusColor: Color {
        if bluetoothManager.connectionStatus.contains("Connected") || bluetoothManager.connectionStatus.contains("연결됨") {
            return .green
        } else if bluetoothManager.connectionStatus.contains("Connecting") || bluetoothManager.connectionStatus.contains("연결 중") || bluetoothManager.connectionStatus.contains("Scanning") || bluetoothManager.connectionStatus.contains("스캔") {
            return .orange
        } else {
            return .red
        }
    }
}
